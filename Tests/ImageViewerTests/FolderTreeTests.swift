import Foundation
import Testing

@testable import ImageViewer

@Suite("폴더 트리 탐색")
@MainActor
struct FolderTreeTests {
  @Test("폴더만 자연순서로 표시하고 숨김·패키지·순환 링크는 제외한다")
  func filtersAndSortsDirectories() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["Album 10", "Album 2", "Album 1", ".hidden", "Hidden.app"] {
      try makeFolder(root.appendingPathComponent(name))
    }
    try Data().write(to: root.appendingPathComponent("photo.jpg"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"),
      withDestinationURL: root)
    let tree = FolderTreeStore()
    await tree.setRoot(root)
    #expect(tree.rows.map(\.url.lastPathComponent) == [root.lastPathComponent, "Album 1", "Album 2", "Album 10"])
    #expect(tree.rows.map(\.depth) == [0, 1, 1, 1])
    #expect(tree.rows.first?.isExpanded == true)
    #expect(tree.rows.allSatisfy { !$0.isLoading && $0.errorMessage == nil })
    await tree.toggleExpansion(root.appendingPathComponent("Album 1"))
    let empty = try #require(tree.rows.first { $0.url.lastPathComponent == "Album 1" })
    #expect(!empty.canExpand && empty.isExpanded)
  }

  @Test("펼친 단계만 백그라운드에서 읽고 접었다 펼치면 캐시를 사용한다")
  func readsOnlyExpandedDirectories() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let child = root.appendingPathComponent("child", isDirectory: true)
    let grandchild = child.appendingPathComponent("grandchild", isDirectory: true)
    let record = ReadRecord()
    let tree = FolderTreeStore { url in
      record.append(url)
      return url == root ? [child] : (url == child ? [grandchild] : [])
    }
    await tree.setRoot(root)
    #expect(record.urls == [root])
    #expect(!record.readOnMainThread)
    await tree.toggleExpansion(child)
    #expect(record.urls == [root, child])
    #expect(tree.rows.last?.url == grandchild && tree.rows.last?.depth == 2)
    await tree.toggleExpansion(child)
    #expect(tree.rows.count == 2)
    await tree.toggleExpansion(child)
    #expect(record.urls == [root, child])
    #expect(tree.rows.count == 3)
  }

  @Test("같은 트리의 이동은 펼친 분기를 보존하고 바깥 폴더는 새 부모부터 연다")
  func revealsFoldersAndPreservesBranches() async throws {
    let root = try fixture(), outside = try fixture()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let a = root.appendingPathComponent("A", isDirectory: true)
    let nested = a.appendingPathComponent("nested", isDirectory: true)
    let b = root.appendingPathComponent("B", isDirectory: true)
    let external = outside.appendingPathComponent("external", isDirectory: true)
    for url in [nested, b, external] { try makeFolder(url) }
    let tree = FolderTreeStore()
    await tree.reveal(a)
    #expect(tree.rootURL == root)
    #expect(tree.rows.contains { $0.url == nested && $0.depth == 2 })
    await tree.reveal(b)
    #expect(tree.rootURL == root)
    #expect(tree.rows.first { $0.url == a }?.isExpanded == true)
    #expect(tree.rows.contains { $0.url == nested })
    let rowsBeforeBlankSelection = tree.rows
    await tree.reveal(nil)
    #expect(tree.rootURL == root && tree.rows == rowsBeforeBlankSelection)
    await tree.reveal(external)
    #expect(tree.rootURL == outside)
    #expect(!tree.rows.contains { $0.url == a })
    #expect(tree.rows.first { $0.url == external }?.isExpanded == true)
  }

  @Test("다른 경로에서 새로 만든 폴더를 열면 캐시된 트리에서도 선택 경로를 드러낸다")
  func revealsNewFolderInCachedBranch() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let tree = FolderTreeStore()
    await tree.setRoot(root)
    let child = root.appendingPathComponent("new child", isDirectory: true)
    try makeFolder(child)
    await tree.reveal(child)
    #expect(tree.rootURL == root)
    #expect(tree.rows.contains { $0.url == child && $0.isExpanded })
  }

  @Test("새로고침은 삭제된 분기를 제거하고 읽기 오류 뒤 다시 시도한다")
  func refreshRemovesDeletedFoldersAndRetries() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let child = root.appendingPathComponent("child", isDirectory: true)
    let nested = child.appendingPathComponent("nested", isDirectory: true)
    try makeFolder(nested)
    let tree = FolderTreeStore()
    await tree.setRoot(root)
    await tree.toggleExpansion(child)
    #expect(tree.rows.contains { $0.url == nested })
    try FileManager.default.removeItem(at: child)
    await tree.refresh()
    #expect(tree.rows.count == 1)
    try makeFolder(child)
    await tree.refresh()
    #expect(tree.rows.count == 2)
    #expect(tree.rows.first { $0.url == child }?.isExpanded == false)
    await tree.toggleExpansion(child)
    #expect(!tree.rows.contains { $0.url == nested })
    try FileManager.default.removeItem(at: root)
    await tree.refresh()
    #expect(tree.rows.count == 1 && tree.rows.first?.errorMessage != nil)
    #expect(tree.rows.first?.isLoading == false)
    try makeFolder(root.appendingPathComponent("recovered", isDirectory: true))
    await tree.refresh()
    #expect(tree.rows.first?.errorMessage == nil)
    #expect(tree.rows.last?.url.lastPathComponent == "recovered")
  }

  @Test("접힌 폴더도 새로고침 후 재확장하면 삭제된 하위 캐시를 버린다")
  func refreshInvalidatesCollapsedDescendants() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let child = root.appendingPathComponent("child", isDirectory: true)
    let nested = child.appendingPathComponent("nested", isDirectory: true)
    try makeFolder(nested)
    let tree = FolderTreeStore()
    await tree.setRoot(root)
    await tree.toggleExpansion(child)
    await tree.toggleExpansion(child)
    try FileManager.default.removeItem(at: nested)
    await tree.refresh()
    await tree.toggleExpansion(child)
    #expect(tree.rows.count == 2)
    #expect(tree.rows.last?.canExpand == false)
  }

  @Test("빠른 루트·선택 변경 뒤 늦게 도착한 읽기가 새 트리를 덮어쓰지 않는다")
  func staleReadsCannotReplaceNewNavigation() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let slowRoot = root.appendingPathComponent("slow", isDirectory: true)
    let fastRoot = root.appendingPathComponent("fast", isDirectory: true)
    let slowChild = slowRoot.appendingPathComponent("old", isDirectory: true)
    let fastChild = fastRoot.appendingPathComponent("new", isDirectory: true)
    let tree = FolderTreeStore { url in
      if url == slowRoot { Thread.sleep(forTimeInterval: 0.1); return [slowChild] }
      return url == fastRoot ? [fastChild] : []
    }
    let old = Task { await tree.reveal(slowChild) }
    while tree.rootURL != slowRoot { await Task.yield() }
    await tree.reveal(fastChild)
    await old.value
    #expect(tree.rootURL == fastRoot)
    #expect(tree.rows.map(\.url) == [fastRoot, fastChild])
    #expect(tree.rows.allSatisfy { !$0.isLoading })
  }

  @Test("상위 폴더로 이동하면 이전 루트를 펼쳐 보여주고 파일 시스템 루트에서 멈춘다")
  func parentNavigation() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let child = root.appendingPathComponent("child", isDirectory: true)
    try makeFolder(child)
    let tree = FolderTreeStore()
    await tree.setRoot(child)
    #expect(tree.canShowParent)
    await tree.showParent()
    #expect(tree.rootURL == root)
    #expect(tree.rows.first { $0.url == child }?.isExpanded == true)
    let filesystemTree = FolderTreeStore { _ in [] }
    await filesystemTree.setRoot(URL(fileURLWithPath: "/", isDirectory: true))
    #expect(!filesystemTree.canShowParent)
    await filesystemTree.showParent()
    #expect(filesystemTree.rootURL?.path == "/")
  }

  @Test("초기 선택이 없으면 홈 폴더에서 시작한다")
  func initialHome() async {
    let tree = FolderTreeStore { _ in [] }
    await tree.reveal(nil)
    #expect(tree.rootURL?.path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
    #expect(tree.rows.count == 1 && tree.rows.first?.errorMessage == nil)
  }

  private func fixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("FolderTreeTests-\(UUID())", isDirectory: true)
      .standardizedFileURL
    try makeFolder(url)
    return url
  }

  private func makeFolder(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }
}

private final class ReadRecord: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedURLs: [URL] = []
  private var usedMainThread = false

  func append(_ url: URL) {
    lock.withLock {
      recordedURLs.append(url)
      usedMainThread = usedMainThread || Thread.isMainThread
    }
  }

  var urls: [URL] { lock.withLock { recordedURLs } }
  var readOnMainThread: Bool { lock.withLock { usedMainThread } }
}
