import Combine
import Foundation

struct FolderTreeRow: Identifiable, Equatable, Sendable {
  var id: URL { url }
  let url: URL
  let depth: Int
  let isExpanded: Bool
  let isLoading: Bool
  let canExpand: Bool
  let errorMessage: String?
}

/// A read keeps its security scope alive even if a newer navigation replaces the tree.
private final class FolderTreeAccess: @unchecked Sendable {
  let url: URL
  private let isScoped: Bool

  init(_ url: URL) {
    self.url = url
    isScoped = url.startAccessingSecurityScopedResource()
  }

  deinit {
    if isScoped { url.stopAccessingSecurityScopedResource() }
  }
}

@MainActor
final class FolderTreeStore: ObservableObject {
  @Published private(set) var rootURL: URL?
  @Published private(set) var rows: [FolderTreeRow] = []

  private struct Node {
    var children: [URL]?
    var isLoading = false
    var errorMessage: String?
  }

  private enum ReadResult: Sendable {
    case children([URL])
    case failure(String)
    case cancelled
  }

  private struct PendingRead: Sendable {
    let id: UUID
    let task: Task<ReadResult, Never>
  }

  private var nodes: [URL: Node] = [:]
  private var expanded: Set<URL> = []
  private var pendingReads: [URL: PendingRead] = [:]
  private var generation = UUID()
  private var revealID = UUID()
  private var rootAccess: FolderTreeAccess?
  private var selectedAccess: FolderTreeAccess?
  private let directoryReader: @Sendable (URL) throws -> [URL]

  init(directoryReader: @escaping @Sendable (URL) throws -> [URL] = FolderTreeStore.readDirectory) {
    self.directoryReader = directoryReader
  }

  deinit {
    for read in pendingReads.values { read.task.cancel() }
  }

  var canShowParent: Bool {
    guard let rootURL else { return false }
    return Self.normalized(rootURL.deletingLastPathComponent()) != rootURL
  }

  /// Opening a folder keeps nearby branches available and reveals its children lazily.
  func reveal(_ folder: URL?) async {
    // A blank comparison pane has no selection, but must keep the user's browsing location.
    guard folder != nil || rootURL == nil else { return }
    let request = UUID()
    revealID = request
    let target = Self.normalized(folder ?? FileManager.default.homeDirectoryForCurrentUser)
    selectedAccess = folder.map(FolderTreeAccess.init)
    if rootURL == nil || !Self.contains(target, in: rootURL!) {
      let root = folder == nil ? target : Self.normalized(target.deletingLastPathComponent())
      resetRoot(root)
    }
    guard let rootURL else { return }
    let currentGeneration = generation
    var path: [URL] = []
    var cursor = target
    while cursor != rootURL {
      path.append(cursor)
      let parent = Self.normalized(cursor.deletingLastPathComponent())
      guard parent != cursor else { return }
      cursor = parent
    }
    path.append(rootURL)
    let orderedPath = Array(path.reversed())
    for (index, url) in orderedPath.enumerated() {
      guard revealID == request, generation == currentGeneration, !Task.isCancelled,
        nodes[url] != nil else { return }
      expanded.insert(url)
      await loadChildren(url)
      if index + 1 < orderedPath.count, nodes[orderedPath[index + 1]] == nil {
        // A folder opened elsewhere may have been created after this branch was cached.
        guard revealID == request, generation == currentGeneration, !Task.isCancelled else { return }
        await loadChildren(url, force: true)
      }
    }
    publishRows()
  }

  func setRoot(_ folder: URL) async {
    revealID = UUID()
    selectedAccess = nil
    resetRoot(Self.normalized(folder), accessURL: folder)
    await loadChildren(rootURL!)
  }

  func toggleExpansion(_ folder: URL) async {
    revealID = UUID()
    let url = Self.normalized(folder)
    guard nodes[url] != nil else { return }
    if expanded.remove(url) != nil {
      publishRows()
    } else {
      expanded.insert(url)
      await loadChildren(url)
    }
  }

  func showParent() async {
    guard let rootURL, canShowParent else { return }
    revealID = UUID()
    let previousRoot = rootURL
    resetRoot(Self.normalized(rootURL.deletingLastPathComponent()))
    let expectedGeneration = generation
    await loadChildren(self.rootURL!)
    guard generation == expectedGeneration,
      nodes[previousRoot] != nil else { return }
    expanded.insert(previousRoot)
    await loadChildren(previousRoot)
  }

  /// Refresh only visible expanded branches; collapsed branches are invalidated for their next open.
  func refresh() async {
    revealID = UUID()
    invalidateReads()
    for url in Array(nodes.keys) {
      guard nodes[url] != nil else { continue }
      nodes[url]?.isLoading = false
      nodes[url]?.errorMessage = nil
      if !expanded.contains(url) {
        for child in nodes[url]?.children ?? [] { removeBranch(child) }
        nodes[url]?.children = nil
      }
    }
    guard let rootURL else { return }
    let currentGeneration = generation
    await refreshBranch(rootURL, generation: currentGeneration)
  }

  private func resetRoot(_ url: URL, accessURL: URL? = nil) {
    invalidateReads()
    rootURL = url
    rootAccess = FolderTreeAccess(accessURL ?? url)
    nodes = [url: Node()]
    expanded = [url]
    publishRows()
  }

  private func invalidateReads() {
    generation = UUID()
    for read in pendingReads.values { read.task.cancel() }
    pendingReads.removeAll()
  }

  private func refreshBranch(_ url: URL, generation expectedGeneration: UUID) async {
    guard generation == expectedGeneration, !Task.isCancelled else { return }
    await loadChildren(url, force: true)
    guard generation == expectedGeneration, expanded.contains(url) else { return }
    for child in nodes[url]?.children ?? [] where expanded.contains(child) {
      await refreshBranch(child, generation: expectedGeneration)
    }
  }

  private func loadChildren(_ url: URL, force: Bool = false) async {
    guard let node = nodes[url] else { return }
    if !force, node.children != nil, node.errorMessage == nil {
      publishRows()
      return
    }
    let expectedGeneration = generation
    let read: PendingRead
    if !force, let pending = pendingReads[url] {
      read = pending
    } else {
      pendingReads[url]?.task.cancel()
      let reader = directoryReader
      let scopes = [rootAccess, selectedAccess].compactMap { $0 }
      read = PendingRead(id: UUID(), task: Task.detached(priority: .userInitiated) {
        withExtendedLifetime(scopes) {
          do {
            try Task.checkCancellation()
            let children = try reader(url)
            try Task.checkCancellation()
            return .children(children)
          } catch is CancellationError {
            return .cancelled
          } catch {
            return .failure(error.localizedDescription)
          }
        }
      })
      pendingReads[url] = read
      nodes[url]?.isLoading = true
      nodes[url]?.errorMessage = nil
      publishRows()
    }
    let result = await read.task.value
    guard generation == expectedGeneration, pendingReads[url]?.id == read.id,
      nodes[url] != nil else { return }
    pendingReads[url] = nil
    nodes[url]?.isLoading = false
    switch result {
    case .children(let children):
      let children = children.map(Self.normalized)
      let removed = Set(nodes[url]?.children ?? []).subtracting(children)
      for child in removed { removeBranch(child) }
      nodes[url]?.children = children
      nodes[url]?.errorMessage = nil
      for child in children where nodes[child] == nil { nodes[child] = Node() }
    case .failure(let message):
      // Do not present stale descendants as current contents after permission or I/O failure.
      for child in nodes[url]?.children ?? [] { removeBranch(child) }
      nodes[url]?.children = nil
      nodes[url]?.errorMessage = message
    case .cancelled:
      break
    }
    publishRows()
  }

  private func removeBranch(_ url: URL) {
    for child in Array(nodes.keys) where Self.contains(child, in: url) {
      pendingReads.removeValue(forKey: child)?.task.cancel()
      nodes[child] = nil
      expanded.remove(child)
    }
  }

  private func publishRows() {
    guard let rootURL else { rows = []; return }
    var result: [FolderTreeRow] = []
    func append(_ url: URL, depth: Int) {
      guard let node = nodes[url] else { return }
      let isExpanded = expanded.contains(url)
      result.append(FolderTreeRow(url: url, depth: depth, isExpanded: isExpanded,
        isLoading: node.isLoading, canExpand: node.children?.isEmpty != true,
        errorMessage: node.errorMessage))
      if isExpanded {
        for child in node.children ?? [] { append(child, depth: depth + 1) }
      }
    }
    append(rootURL, depth: 0)
    rows = result
  }

  private nonisolated static func normalized(_ url: URL) -> URL {
    URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
  }

  private nonisolated static func contains(_ url: URL, in root: URL) -> Bool {
    url.pathComponents.starts(with: root.pathComponents)
  }

  private nonisolated static func readDirectory(_ folder: URL) throws -> [URL] {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey, .isPackageKey, .isSymbolicLinkKey]
    return try FileManager.default.contentsOfDirectory(at: folder,
      includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants])
      .filter { url in
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: keys)
        return values.isDirectory == true && values.isHidden != true
          && values.isPackage != true && values.isSymbolicLink != true
      }
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
  }
}
