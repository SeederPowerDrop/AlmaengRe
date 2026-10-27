import AppKit
import Combine

enum FolderComparisonSide: String, CaseIterable, Identifiable {
  case first, second
  var id: Self { self }
  func title(in arrangement: FolderComparisonArrangement) -> String {
    switch (self, arrangement) {
    case (.first, .horizontal): L10n.text("A · 왼쪽")
    case (.first, .vertical): L10n.text("A · 위")
    case (.second, .horizontal): L10n.text("B · 오른쪽")
    case (.second, .vertical): L10n.text("B · 아래")
    }
  }
}

enum FolderComparisonArrangement: String, CaseIterable, Identifiable {
  case horizontal, vertical
  var id: Self { self }
  var title: String { L10n.text(self == .horizontal ? "좌우 배치" : "상하 배치") }
}

enum ComparisonEndBehavior: String, CaseIterable, Identifiable {
  case hold, loop
  var id: Self { self }
  var title: String { L10n.text(self == .hold ? "마지막 이미지 유지" : "처음부터 반복") }
}

enum ComparisonNavigationTarget: String, CaseIterable, Identifiable {
  case first, both, second
  var id: Self { self }
  var title: String {
    switch self {
    case .first: L10n.text("A만")
    case .both: L10n.text("양쪽")
    case .second: L10n.text("B만")
    }
  }
}

enum ComparisonAlignment: String, CaseIterable, Identifiable {
  case filename, sequence
  var id: Self { self }
  var title: String { L10n.text(self == .filename ? "같은 파일명" : "목록 순서") }
}

/// Frequent image transforms notify only the canvas/readout, not the folder list
/// or its filmstrip. One snapshot keeps linked changes coherent for observers.
@MainActor
final class FolderComparisonViewport: ObservableObject {
  struct Snapshot: Equatable {
    var zoom: CGFloat = 1
    var normalizedPan: CGSize = .zero
    var baseImageSize = CGSize(width: 1, height: 1)
    var viewportSize: CGSize?
    var geometryAssetID: URL?
    var scaleMode: BaseScaleMode = .fit

    func constrainedPan(_ offset: CGSize, zoom: CGFloat) -> CGSize {
      guard let viewportSize else { return offset }
      return ImagePanGeometry(baseImageSize: baseImageSize, viewportSize: viewportSize)
        .constrained(offset, zoom: zoom)
    }

    func normalizedOffset(for offset: CGSize, zoom: CGFloat) -> CGSize {
      let width = baseImageSize.width * zoom, height = baseImageSize.height * zoom
      guard width.isFinite, height.isFinite, width > 0, height > 0 else { return .zero }
      return CGSize(width: offset.width / width, height: offset.height / height)
    }

    mutating func constrainPan() {
      guard viewportSize != nil else { return }
      let rendered = CGSize(width: baseImageSize.width * zoom, height: baseImageSize.height * zoom)
      let proposed = CGSize(width: normalizedPan.width * rendered.width,
        height: normalizedPan.height * rendered.height)
      let bounded = constrainedPan(proposed, zoom: zoom)
      normalizedPan = normalizedOffset(for: bounded, zoom: zoom)
    }
  }

  @Published private(set) var snapshot = Snapshot()
  var zoom: CGFloat { snapshot.zoom }
  var normalizedPan: CGSize { snapshot.normalizedPan }
  var baseImageSize: CGSize { snapshot.baseImageSize }
  var scaleMode: BaseScaleMode { snapshot.scaleMode }

  fileprivate func update(_ change: (inout Snapshot) -> Void) {
    var next = snapshot
    change(&next)
    // Scaling modes have different base sizes. Wait for the tile's authoritative
    // geometry instead of clipping a restored position with the previous mode.
    if next.scaleMode != snapshot.scaleMode { next.viewportSize = nil }
    next.constrainPan()
    guard next != snapshot else { return }
    snapshot = next
  }
}

/// Live gesture deltas never reach session persistence or the surrounding UI.
@MainActor
final class ComparisonLiveInput: ObservableObject {
  struct Snapshot: Equatable {
    var gestureSide: FolderComparisonSide?
    var liveMagnification: CGFloat = 1
    var liveTranslation: CGSize = .zero
  }

  @Published private(set) var snapshot = Snapshot()
  var gestureSide: FolderComparisonSide? { snapshot.gestureSide }
  var liveMagnification: CGFloat { snapshot.liveMagnification }
  var liveTranslation: CGSize { snapshot.liveTranslation }

  fileprivate func update(_ change: (inout Snapshot) -> Void) {
    var next = snapshot
    change(&next)
    guard next != snapshot else { return }
    snapshot = next
  }
}

/// 각 칸의 목록·선택·확대 상태는 독립적이고 디코더/캐시만 기존 뷰어와 공유합니다.
@MainActor
final class FolderComparisonPane: ObservableObject {
  struct PresentationTracking: Equatable {
    var isTracking = false
    var assetID: URL?
    var byteCount: Int64?
    var modificationDate: Date?
  }

  @Published private(set) var assets: [ImageAsset] = []
  @Published private(set) var folderURL: URL?
  @Published private(set) var index = 0
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var showsMissingCounterpart = false
  @Published private(set) var isFiltering = false
  @Published fileprivate(set) var customName: String?
  @Published private(set) var presentationTracking = PresentationTracking()
  @Published var query = LibraryQuery() {
    didSet { if oldValue != query { applyQuery() } }
  }
  @Published var photoMarkFilter = PhotoMarkFilter() {
    didSet {
      guard oldValue != photoMarkFilter else { return }
      freezePhotoMarkMembershipIfNeeded()
      applyQuery()
    }
  }
  fileprivate var isPhotoMarking = false {
    didSet {
      guard oldValue != isPhotoMarking else { return }
      freezePhotoMarkMembershipIfNeeded()
      if !isPhotoMarking, photoMarkFilter.isActive { applyQuery() }
    }
  }
  private(set) var sourceURLs: [URL] = []
  private(set) var sessionSources: [SessionLocation] = []
  fileprivate private(set) var automaticSourceName: String?
  fileprivate private(set) var sourceLocationIdentity: String?
  private var namingSourceKeys: Set<String> = []
  private var allAssets: [ImageAsset] = [] {
    didSet { cachedAvailableExtensions = nil }
  }
  private var cachedAvailableExtensions: [String]?
  // Navigation and viewport changes keep the same source collection. Reuse its
  // bounded format choices rather than scanning every photo for each toolbar.
  var availableExtensions: [String] {
    if let cachedAvailableExtensions { return cachedAvailableExtensions }
    let extensions = Set(allAssets.map(\.fileExtension)).sorted()
    cachedAvailableExtensions = extensions
    return extensions
  }
  private var locationsLoaded = false
  private var queryTask: Task<Void, Never>?
  private var queryGeneration = UUID()
  private let photoMarks: PhotoMarkStore?
  private var markSubscription: AnyCancellable?
  private var frozenPhotoMarkIDs: Set<String>?
  private var needsQueryRefresh = false
  private var needsSourceReconciliation = false
  let viewport = FolderComparisonViewport()
  fileprivate(set) var zoom: CGFloat {
    get { viewport.zoom }
    set { viewport.update { $0.zoom = newValue } }
  }
  @Published fileprivate(set) var isLocked = false {
    didSet { if oldValue, !isLocked, needsQueryRefresh { applyQuery() } }
  }
  // 이미지 중심에서 얼마나 이동했는지 이미지 크기에 대한 비율로 저장합니다.
  // 두 이미지의 해상도·종횡비·표시 영역이 달라도 같은 상대 좌표를 볼 수 있습니다.
  fileprivate(set) var normalizedPan: CGSize {
    get { viewport.normalizedPan }
    set { viewport.update { $0.normalizedPan = newValue } }
  }
  fileprivate(set) var baseImageSize: CGSize {
    get { viewport.baseImageSize }
    set { viewport.update { $0.baseImageSize = newValue } }
  }
  var pan: CGSize {
    CGSize(width: normalizedPan.width * baseImageSize.width * zoom,
      height: normalizedPan.height * baseImageSize.height * zoom)
  }
  fileprivate(set) var scaleMode: BaseScaleMode {
    get { viewport.scaleMode }
    set { viewport.update { $0.scaleMode = newValue } }
  }

  var onContentsChanged: (() -> Void)?
  var onCollectionOpened: ((OpenedImageLibrary, [URL]) -> Void)?

  private let library = ImageLibrary()
  private let loadingGovernor: ImageResourceGovernor?
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = UUID()
  private var access: [ImageLibraryAccess] = []

  init(photoMarks: PhotoMarkStore? = nil, loadingGovernor: ImageResourceGovernor? = nil) {
    self.photoMarks = photoMarks
    self.loadingGovernor = loadingGovernor
    markSubscription = photoMarks?.$revision.dropFirst().sink { [weak self] _ in
      // @Published emits before the mark dictionary update has fully completed.
      Task { @MainActor [weak self] in
        guard let self, self.photoMarkFilter.isActive, !self.isPhotoMarking else { return }
        // An in-flight query reads the latest marks after its suspended work.
        if !self.isFiltering { self.applyQuery() }
      }
    }
  }

  var currentAsset: ImageAsset? { !showsMissingCounterpart && assets.indices.contains(index) ? assets[index] : nil }
  /// Navigation may retain the previous bitmap while the next one loads. Marks
  /// must never be applied to that next file before its own image is visible.
  var canMarkPresentedAsset: Bool {
    guard presentationTracking.isTracking else { return true }
    guard let currentAsset else { return false }
    return presentationTracking.assetID == currentAsset.id
      && presentationTracking.byteCount == currentAsset.byteCount
      && presentationTracking.modificationDate == currentAsset.modificationDate
  }

  func beginTrackingPresentation() {
    guard !presentationTracking.isTracking else { return }
    // Child appearance callbacks may report the image before its canvas appears.
    presentationTracking = PresentationTracking(isTracking: true,
      assetID: presentationTracking.assetID, byteCount: presentationTracking.byteCount,
      modificationDate: presentationTracking.modificationDate)
  }

  func recordPresentedAsset(_ asset: ImageAsset?) {
    let next = PresentationTracking(isTracking: presentationTracking.isTracking,
      assetID: asset?.id, byteCount: asset?.byteCount, modificationDate: asset?.modificationDate)
    guard presentationTracking != next else { return }
    presentationTracking = next
  }

  func endTrackingPresentation() {
    guard presentationTracking != PresentationTracking() else { return }
    presentationTracking = PresentationTracking()
  }

  var position: String {
    if showsMissingCounterpart { return "— / \(assets.count)" }
    return assets.isEmpty ? "0 / 0" : "\(index + 1) / \(assets.count)"
  }

  func load(_ folder: URL) {
    guard !isLocked else { return }
    open(urls: [folder])
    folderURL = folder
  }

  func open(urls: [URL]) {
    guard !isLocked, !urls.isEmpty else { return }
    cancelLoad()
    let generation = loadGeneration
    // Resolve only when opening a source, never while SwiftUI reads its title.
    // Input ordering and symlink spellings do not turn a reload into a new source.
    let sourceKeys = Set(urls.map(Self.canonicalSourceKey))
    if sourceKeys != namingSourceKeys {
      customName = nil
      automaticSourceName = nil
      sourceLocationIdentity = nil
    }
    namingSourceKeys = sourceKeys
    sourceURLs = urls
    sessionSources = urls.map(SessionLocation.init(url:))
    access = []
    folderURL = nil
    // 폴더를 바꾸는 즉시 이전 이미지 상태를 제거해 같은 순번의 셀 재사용을 막습니다.
    assets = []
    allAssets = []
    locationsLoaded = false
    frozenPhotoMarkIDs = nil
    needsSourceReconciliation = true
    showsMissingCounterpart = false
    index = 0
    resetViewport()
    errorMessage = nil
    isLoading = true
    onContentsChanged?()
    loadTask = Task { [weak self, library] in
      do {
        let opened = try await library.open(urls: urls, allowsEmptyFolder: true)
        try Task.checkCancellation()
        guard let self, self.loadGeneration == generation else { return }
        self.access = opened.access
        self.folderURL = opened.folderURL
        self.updateSourceName(folder: opened.folderURL)
        self.assets = opened.assets
        self.allAssets = opened.assets
        self.index = opened.focusedURL.flatMap { focused in
          opened.assets.firstIndex { $0.url.standardizedFileURL == focused.standardizedFileURL }
        } ?? 0
        self.isLoading = false
        self.onCollectionOpened?(opened, urls)
        if self.query != LibraryQuery() || self.photoMarkFilter.isActive || self.needsQueryRefresh {
          self.applyQuery()
        }
        else { self.onContentsChanged?() }
      } catch {
        guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
        self.errorMessage = error.localizedDescription
        self.isLoading = false
        self.onContentsChanged?()
      }
    }
  }

  private static func canonicalSourceKey(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
  }

  private func updateSourceName(folder: URL?) {
    if namingSourceKeys.count == 1, let archive = sourceURLs.first,
      archive.pathExtension.lowercased() == "zip" {
      automaticSourceName = archive.lastPathComponent
      sourceLocationIdentity = "archive:" + Self.canonicalSourceKey(archive)
    } else if let folder {
      automaticSourceName = folder.lastPathComponent.isEmpty ? "/" : folder.lastPathComponent
      sourceLocationIdentity = "folder:" + Self.canonicalSourceKey(folder)
    } else {
      automaticSourceName = nil
      sourceLocationIdentity = nil
    }
  }

  fileprivate func setCustomName(_ value: String) {
    let words = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    let normalized = String(words.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
    let next = normalized.isEmpty ? nil : normalized
    if customName != next { customName = next }
  }

  func cancelLoad() {
    loadGeneration = UUID()
    loadTask?.cancel()
    loadTask = nil
    isLoading = false
    queryGeneration = UUID()
    queryTask?.cancel()
    queryTask = nil
    isFiltering = false
    onContentsChanged?()
  }

  private func applyQuery() {
    guard !isLoading, !isLocked else { needsQueryRefresh = true; return }
    needsQueryRefresh = false
    queryTask?.cancel()
    queryGeneration = UUID()
    let generation = queryGeneration
    let source = allAssets
    let options = query
    let selectedID = currentAsset?.sessionID
    let needsLocations = (options.sort.requiresLocation || options.geographicSelection != nil)
      && !locationsLoaded
    let retryUnavailable = needsSourceReconciliation
    isFiltering = true
    onContentsChanged?()
    queryTask = Task { [weak self, library, photoMarks, loadingGovernor] in
      do {
        // Rapid typing should not launch a full scan/sort for every intermediate query.
        try await Task.sleep(for: .milliseconds(100))
        if let photoMarks {
          await photoMarks.waitUntilReady()
          try Task.checkCancellation()
          // Reconcile the complete original collection before filtering, including
          // legacy path marks and returned drives. Cached queries do not rescan.
          await photoMarks.reconcileAssets(source, retryUnavailable: retryUnavailable)?.wait()
          try Task.checkCancellation()
        }
        let located = needsLocations
          ? try await library.enrichLocations(source, governor: loadingGovernor) : source
        let prepared = try await library.enrichQueryMetadata(located, for: options,
          governor: loadingGovernor)
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) {
          try Task.checkCancellation()
          return try RustImageEngine.query(prepared, options: options)
        }
        let queried = try await withTaskCancellationHandler {
          try await work.value
        } onCancel: { work.cancel() }
        try Task.checkCancellation()
        guard let self, self.queryGeneration == generation else { return }
        self.needsSourceReconciliation = false
        if needsLocations || options.requiresMetadata { self.allAssets = prepared }
        if needsLocations { self.locationsLoaded = true }
        let result = self.filteredByPhotoMarks(queried)
        let oldID = self.currentAsset?.id
        self.assets = result
        self.index = selectedID.flatMap { id in result.firstIndex { $0.sessionID == id } } ?? 0
        self.showsMissingCounterpart = false
        if oldID != self.currentAsset?.id { self.resetViewport() }
        self.isFiltering = false
        self.onContentsChanged?()
      } catch {
        guard !Task.isCancelled, let self, self.queryGeneration == generation else { return }
        self.errorMessage = error.localizedDescription
        self.isFiltering = false
        self.onContentsChanged?()
      }
    }
  }

  private func filteredByPhotoMarks(_ input: [ImageAsset]) -> [ImageAsset] {
    guard photoMarkFilter.isActive else { return input }
    if isPhotoMarking {
      if frozenPhotoMarkIDs == nil { freezePhotoMarkMembershipIfNeeded() }
      let membership = frozenPhotoMarkIDs ?? []
      return input.filter { membership.contains($0.sessionID) }
    }
    return input.filter { photoMarkFilter.matches(photoMarks?.marks(for: $0) ?? []) }
  }

  private func freezePhotoMarkMembershipIfNeeded() {
    frozenPhotoMarkIDs = nil
    guard isPhotoMarking, photoMarkFilter.isActive, !isLoading,
      photoMarks?.isReady != false else { return }
    frozenPhotoMarkIDs = Set(allAssets.filter {
      photoMarkFilter.matches(photoMarks?.marks(for: $0) ?? [])
    }.map(\.sessionID))
  }

  /// Shares a scanned immutable collection and its access grants. No directory
  /// scan, archive extraction, image decode, or per-image bookmark is performed.
  fileprivate func useOpenedCollection(_ images: [ImageAsset], folder: URL?,
    sources: [SessionLocation], grants: [ImageLibraryAccess], options: LibraryQuery,
    filter: PhotoMarkFilter
  ) {
    guard !isLocked else { return }
    cancelLoad()
    isLoading = true
    let urls = sources.map(\.url)
    let sourceKeys = Set(urls.map(Self.canonicalSourceKey))
    if sourceKeys != namingSourceKeys { customName = nil }
    namingSourceKeys = sourceKeys
    sourceURLs = urls
    sessionSources = sources
    access = grants
    folderURL = folder
    updateSourceName(folder: folder)
    assets = []
    allAssets = images
    locationsLoaded = images.allSatisfy(\.hasReadLocation)
    frozenPhotoMarkIDs = nil
    needsSourceReconciliation = false
    index = 0
    showsMissingCounterpart = false
    errorMessage = nil
    resetViewport()
    query = options
    photoMarkFilter = filter
    isLoading = false
    applyQuery()
  }

  func waitUntilLoaded() async {
    while !Task.isCancelled {
      let loading = loadGeneration
      await loadTask?.value
      guard !Task.isCancelled else { return }
      if loading != loadGeneration { continue }
      let querying = queryGeneration
      await queryTask?.value
      guard !Task.isCancelled else { return }
      // A cancelled/replaced task completing does not mean its successor is ready.
      if loading == loadGeneration, querying == queryGeneration,
        !isLoading, !isFiltering { return }
      await Task.yield()
    }
  }

  fileprivate func setMatchedIndex(_ matchingIndex: Int?) {
    guard !isLocked else { return }
    let oldID = currentAsset?.id
    let missing = matchingIndex == nil
    if showsMissingCounterpart != missing { showsMissingCounterpart = missing }
    if let matchingIndex, assets.indices.contains(matchingIndex), index != matchingIndex {
      index = matchingIndex
    }
    if oldID != currentAsset?.id { resetViewport() }
  }

  fileprivate func clearMatching() {
    if showsMissingCounterpart { showsMissingCounterpart = false }
  }

  func canStep(_ direction: Int) -> Bool {
    !isLocked && !isLoading && !isFiltering && direction != 0 && assets.indices.contains(index + (direction > 0 ? 1 : -1))
  }

  func step(_ direction: Int) {
    guard canStep(direction) else { return }
    index += direction > 0 ? 1 : -1
    clearMatching()
    resetViewport()
  }

  func select(number: Int) {
    guard !isLocked, !isLoading, !isFiltering,
      number > 0, assets.indices.contains(number - 1) else { return }
    if index != number - 1 { index = number - 1 }
    clearMatching()
    resetViewport()
  }

  fileprivate func resetViewport() {
    viewport.update {
      $0.zoom = 1
      $0.normalizedPan = .zero
      if $0.geometryAssetID != currentAsset?.id {
        $0.viewportSize = nil
        $0.geometryAssetID = nil
      }
    }
  }
}

/// 함께 이동할 때 가장 긴 목록의 끝까지 탐색하고, 짧은 목록은 끝에서 유지하거나 반복합니다.
@MainActor
final class FolderComparisonStore: ObservableObject {
  let first: FolderComparisonPane
  let second: FolderComparisonPane
  @Published private(set) var pairs: [ImageMatchPair] = []
  @Published private(set) var matchIndex = 0
  @Published private(set) var isMatching = false
  @Published var alignment: ComparisonAlignment {
    didSet {
      defaults.set(alignment.rawValue, forKey: "ImageViewer.ComparisonAlignment.v1")
      if alignment == .filename, !first.isLocked, !second.isLocked,
        navigationTarget != .both { navigationTarget = .both }
      if oldValue != alignment { rebuildMatches() }
    }
  }
  @Published var navigationTarget: ComparisonNavigationTarget {
    didSet {
      defaults.set(navigationTarget.rawValue, forKey: "ImageViewer.ComparisonNavigationTarget.v1")
      guard !isSynchronizingNavigationTarget else { return }
      if first.isLocked || second.isLocked {
        synchronizeNavigationTargetWithLocks(resetUnlocked: false)
        return
      }
      // A single-pane choice must never advance a matched row in both panes.
      if navigationTarget != .both, alignment == .filename { alignment = .sequence }
    }
  }
  @Published var query = LibraryQuery() {
    didSet {
      guard oldValue != query else { return }
      first.query = query
      second.query = query
    }
  }
  @Published var activeSide: FolderComparisonSide = .first
  /// Kept during this workspace session; pane activation and locks never change it.
  @Published var photoMarkTarget: ComparisonPhotoMarkTarget = .first
  @Published var isEditingNames = false
  @Published var editingPhotoMarkSide: FolderComparisonSide? {
    didSet { if editingPhotoMarkSide != nil { resetLiveInput() } }
  }
  var isEditingControls: Bool { isEditingNames || editingPhotoMarkSide != nil }
  var isPhotoMarking = false {
    didSet {
      first.isPhotoMarking = isPhotoMarking
      second.isPhotoMarking = isPhotoMarking
    }
  }
  let liveInput = ComparisonLiveInput()
  private var lastDragTranslation: CGSize = .zero
  private var lastRawMagnification: CGFloat = 1
  private var magnificationAnchor: CGFloat = 1
  private var isDragging = false
  private var isMagnifying = false
  var gestureSide: FolderComparisonSide? {
    get { liveInput.gestureSide }
    set { liveInput.update { $0.gestureSide = newValue } }
  }
  var liveMagnification: CGFloat {
    get { liveInput.liveMagnification }
    set { liveInput.update { $0.liveMagnification = newValue } }
  }
  var liveTranslation: CGSize {
    get { liveInput.liveTranslation }
    set { liveInput.update { $0.liveTranslation = newValue } }
  }
  @Published var arrangement: FolderComparisonArrangement {
    didSet { defaults.set(arrangement.rawValue, forKey: "ImageViewer.FolderComparisonArrangement.v1") }
  }
  @Published var endBehavior: ComparisonEndBehavior {
    didSet { defaults.set(endBehavior.rawValue, forKey: "ImageViewer.ComparisonEndBehavior.v1") }
  }
  @Published var showsThumbnails: Bool {
    didSet { defaults.set(showsThumbnails, forKey: "ImageViewer.ComparisonShowsThumbnails.v1") }
  }
  @Published var linksViewport: Bool {
    didSet {
      defaults.set(linksViewport, forKey: "ImageViewer.FolderComparisonLinksViewport.v1")
      if linksViewport { copyActiveViewport() }
    }
  }
  @Published var alert: ViewerAlert?
  private let defaults: UserDefaults
  private var subscriptions: Set<AnyCancellable> = []
  private var isChoosingPair = false
  private var matchTask: Task<Void, Never>?
  private var matchGeneration = UUID()
  private var restoreGeneration = UUID()
  private var isRestoringSession = false
  private var isSynchronizingNavigationTarget = false

  init(defaults: UserDefaults = .standard, alignment: ComparisonAlignment? = nil,
    photoMarks: PhotoMarkStore? = nil, loadingGovernor: ImageResourceGovernor? = nil
  ) {
    first = FolderComparisonPane(photoMarks: photoMarks, loadingGovernor: loadingGovernor)
    second = FolderComparisonPane(photoMarks: photoMarks, loadingGovernor: loadingGovernor)
    self.defaults = defaults
    let savedAlignment = alignment ?? defaults.string(forKey: "ImageViewer.ComparisonAlignment.v1")
      .flatMap(ComparisonAlignment.init(rawValue:)) ?? .sequence
    self.alignment = savedAlignment
    navigationTarget = savedAlignment == .filename ? .both
      : defaults.string(forKey: "ImageViewer.ComparisonNavigationTarget.v1")
        .flatMap(ComparisonNavigationTarget.init(rawValue:)) ?? .both
    arrangement = defaults.string(forKey: "ImageViewer.FolderComparisonArrangement.v1")
      .flatMap(FolderComparisonArrangement.init(rawValue:)) ?? .horizontal
    endBehavior = defaults.string(forKey: "ImageViewer.ComparisonEndBehavior.v1")
      .flatMap(ComparisonEndBehavior.init(rawValue:)) ?? .hold
    showsThumbnails = defaults.object(forKey: "ImageViewer.ComparisonShowsThumbnails.v1") == nil
      ? true : defaults.bool(forKey: "ImageViewer.ComparisonShowsThumbnails.v1")
    linksViewport = defaults.object(forKey: "ImageViewer.FolderComparisonLinksViewport.v1") == nil
      ? true : defaults.bool(forKey: "ImageViewer.FolderComparisonLinksViewport.v1")
    for pane in [first, second] {
      pane.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &subscriptions)
    }
    // Notify after the complete pane mutation. Queued @Published willSet events can
    // otherwise cancel a newer match task while session restoration awaits it.
    for pane in [first, second] {
      pane.onContentsChanged = { [weak self] in self?.rebuildMatches() }
    }
  }

  var matchedPosition: String { pairs.isEmpty ? "0 / 0" : "\(matchIndex + 1) / \(pairs.count)" }

  private func rebuildMatches() {
    matchTask?.cancel()
    matchGeneration = UUID()
    guard alignment == .filename else {
      pairs = []
      isMatching = false
      first.clearMatching()
      second.clearMatching()
      return
    }
    guard !first.isLoading, !second.isLoading, !first.isFiltering, !second.isFiltering else {
      isMatching = true
      return
    }
    let a = first.assets
    let b = second.assets
    let selectedA = first.currentAsset?.sessionID
    let selectedB = second.currentAsset?.sessionID
    let sort = query.sort
    let generation = matchGeneration
    isMatching = true
    matchTask = Task { [weak self] in
      do {
        await Task.yield()
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) {
          try Task.checkCancellation()
          return try RustImageEngine.match(first: a, second: b, sort: sort)
        }
        let result = try await withTaskCancellationHandler {
          try await work.value
        } onCancel: { work.cancel() }
        try Task.checkCancellation()
        guard let self, self.matchGeneration == generation else { return }
        self.pairs = result
        let rowA = selectedA.flatMap { id in result.firstIndex { pair in
          pair.firstIndex.map { a[$0].sessionID == id } ?? false
        } }
        let rowB = selectedB.flatMap { id in result.firstIndex { pair in
          pair.secondIndex.map { b[$0].sessionID == id } ?? false
        } }
        let preferredRow = self.activeSide == .first ? (rowA ?? rowB) : (rowB ?? rowA)
        self.matchIndex = preferredRow ?? min(self.matchIndex, max(0, result.count - 1))
        self.isMatching = false
        self.applyMatchedRow()
      } catch {
        guard !Task.isCancelled, let self, self.matchGeneration == generation else { return }
        self.isMatching = false
        self.alert = ViewerAlert(title: L10n.text("이미지 비교"), message: error.localizedDescription)
      }
    }
  }

  private func applyMatchedRow() {
    guard alignment == .filename else { return }
    guard pairs.indices.contains(matchIndex) else {
      first.setMatchedIndex(nil)
      second.setMatchedIndex(nil)
      return
    }
    let pair = pairs[matchIndex]
    first.setMatchedIndex(pair.firstIndex)
    second.setMatchedIndex(pair.secondIndex)
  }

  func canNavigate(_ side: FolderComparisonSide, direction: Int) -> Bool {
    guard !isEditingControls else { return false }
    guard alignment == .filename else { return pane(side).canStep(direction) }
    return !pane(side).isLocked && canNavigateBoth(direction)
  }

  func pane(_ side: FolderComparisonSide) -> FolderComparisonPane { side == .first ? first : second }

  func automaticName(for side: FolderComparisonSide) -> String {
    automaticSourceDisplayName(for: side) ?? (side == .first ? "A" : "B")
  }

  private func automaticSourceDisplayName(for side: FolderComparisonSide) -> String? {
    let target = pane(side)
    let other = pane(side == .first ? .second : .first)
    let letter = side == .first ? "A" : "B"
    guard let name = target.automaticSourceName,
      let identity = target.sourceLocationIdentity else { return nil }
    if identity == other.sourceLocationIdentity { return nil }
    return name == other.automaticSourceName ? "\(name) (\(letter))" : name
  }

  func displayName(for side: FolderComparisonSide) -> String {
    pane(side).customName ?? automaticName(for: side)
  }

  func navigationTitle(for target: ComparisonNavigationTarget) -> String {
    guard target != .both else { return target.title }
    let side: FolderComparisonSide = target == .first ? .first : .second
    let name = displayName(for: side)
    return pane(side).customName == nil && automaticSourceDisplayName(for: side) == nil
      ? target.title : name
  }

  func customName(for side: FolderComparisonSide) -> String { pane(side).customName ?? "" }

  func setCustomName(_ name: String, for side: FolderComparisonSide) {
    pane(side).setCustomName(name)
  }

  func resetNames() {
    first.setCustomName("")
    second.setCustomName("")
  }

  func chooseItems(for side: FolderComparisonSide, selectItems: @MainActor () -> [URL]? = {
    let panel = ImageOpenPanel.make()
    return panel.runModal() == .OK ? panel.urls : nil
  }) {
    guard !isEditingControls, !pane(side).isLocked else { return }
    if let urls = selectItems() { open(urls: urls, for: side) }
  }

  func chooseFolder(for side: FolderComparisonSide) { chooseItems(for: side) }

  func open(urls: [URL], for side: FolderComparisonSide) {
    guard !isEditingControls, !pane(side).isLocked, !urls.isEmpty else { return }
    resetLiveInput()
    restoreGeneration = UUID()
    activeSide = side
    pane(side).open(urls: urls)
  }

  func choosePair(selectFolder: @MainActor (FolderComparisonSide, URL?) -> URL? = {
    ComparisonFolderOpenPanel.choose(for: $0, directoryURL: $1)
  }) {
    guard !isEditingControls, !isChoosingPair, !first.isLocked, !second.isLocked else { return }
    isChoosingPair = true
    defer { isChoosingPair = false }
    guard let firstFolder = selectFolder(.first, first.folderURL),
      !isEditingControls, !first.isLocked, !second.isLocked else { return }
    guard let secondFolder = selectFolder(.second,
      second.folderURL ?? firstFolder.deletingLastPathComponent()),
      !isEditingControls, !first.isLocked, !second.isLocked else { return }
    // 어느 단계에서 취소하더라도 기존 두 목록과 선택·확대 상태를 유지합니다.
    resetLiveInput()
    restoreGeneration = UUID()
    activeSide = .first
    first.load(firstFolder)
    second.load(secondFolder)
  }

  @discardableResult
  func openCollectionForMarkComparison(assets: [ImageAsset], folderURL: URL?,
    sources: [SessionLocation], access: [ImageLibraryAccess], query: LibraryQuery,
    initialFilter: PhotoMarkFilter
  ) -> Bool {
    guard !isEditingControls, !first.isLocked, !second.isLocked else { return false }
    let images = assets.filter { !$0.isPlaybackMedia }
    guard !images.isEmpty else { return false }
    resetLiveInput()
    restoreGeneration = UUID()
    editingPhotoMarkSide = nil
    alignment = .sequence
    navigationTarget = .both
    activeSide = .first
    self.query = query
    first.useOpenedCollection(images, folder: folderURL, sources: sources, grants: access,
      options: query, filter: initialFilter)
    second.useOpenedCollection(images, folder: folderURL, sources: sources, grants: access,
      options: query, filter: PhotoMarkFilter())
    return true
  }

  func canNavigateBoth(_ direction: Int) -> Bool {
    guard !isEditingControls else { return false }
    if alignment == .filename {
      return direction != 0 && !isMatching && !first.isLoading && !second.isLoading
        && !first.isFiltering && !second.isFiltering && (!first.isLocked || !second.isLocked)
        && pairs.indices.contains(matchIndex + (direction > 0 ? 1 : -1))
    }
    let panes = navigablePanes
    guard direction != 0, let longestCount = panes.map({ $0.assets.count }).max() else { return false }
    return panes.contains { $0.assets.count == longestCount && $0.canStep(direction) }
  }

  func canNavigateSelection(_ direction: Int) -> Bool {
    switch navigationTarget {
    case .first: canNavigate(.first, direction: direction)
    case .both: canNavigateBoth(direction)
    case .second: canNavigate(.second, direction: direction)
    }
  }

  func navigateSelection(_ direction: Int) {
    guard !isEditingControls else { return }
    switch navigationTarget {
    case .first: navigate(.first, direction: direction)
    case .both: navigateBoth(direction)
    case .second: navigate(.second, direction: direction)
    }
  }

  func navigateBoth(_ direction: Int) {
    guard canNavigateBoth(direction) else { return }
    if alignment == .filename {
      resetLiveInput()
      matchIndex += direction > 0 ? 1 : -1
      applyMatchedRow()
      return
    }
    let panes = navigablePanes
    let longestCount = panes.map { $0.assets.count }.max() ?? 0
    resetLiveInput()
    for pane in panes {
      if pane.canStep(direction) {
        pane.step(direction)
      } else if endBehavior == .loop, pane.assets.count < longestCount {
        let number = direction > 0 ? 1 : pane.assets.count
        // 이미지가 하나뿐인 칸은 반복해도 그대로 보이므로 확대·이동을 유지합니다.
        if pane.index != number - 1 { pane.select(number: number) }
      }
    }
  }

  private var navigablePanes: [FolderComparisonPane] {
    [first, second].filter { !$0.isLocked && !$0.isLoading && !$0.isFiltering && !$0.assets.isEmpty }
  }

  func navigate(_ side: FolderComparisonSide, direction: Int) {
    guard canNavigate(side, direction: direction) else { return }
    if alignment == .filename {
      if activeSide != side { activeSide = side }
      navigateBoth(direction)
      return
    }
    resetLiveInput()
    if activeSide != side { activeSide = side }
    pane(side).step(direction)
    if linksViewport { copyActiveViewport() }
  }

  func jump(_ side: FolderComparisonSide, number: Int) {
    let target = pane(side)
    guard !isEditingControls, !target.isLocked, !target.isLoading, !target.isFiltering, number > 0,
      target.assets.indices.contains(number - 1) else { return }
    // Pending queries retain the old list/pairs until their replacement is ready.
    // Do not accept a selection that those pending results would overwrite.
    if alignment == .filename {
      guard !isMatching, !first.isLoading, !second.isLoading,
        !first.isFiltering, !second.isFiltering else { return }
    }
    resetLiveInput()
    if activeSide != side { activeSide = side }
    if alignment == .filename {
      guard let row = pairs.firstIndex(where: {
        (side == .first ? $0.firstIndex : $0.secondIndex) == number - 1
      }) else { return }
      if matchIndex != row { matchIndex = row }
      applyMatchedRow()
      return
    }
    target.select(number: number)
    if linksViewport { copyActiveViewport() }
  }

  func toggleLock(on side: FolderComparisonSide) {
    resetLiveInput()
    let target = pane(side)
    guard target.isLocked || (!target.isLoading && !target.isFiltering && !isMatching
      && target.canMarkPresentedAsset) else { return }
    target.isLocked.toggle()
    if !target.isLocked && alignment == .filename && !target.isFiltering && !isMatching {
      applyMatchedRow()
    }
    let otherSide: FolderComparisonSide = side == .first ? .second : .first
    if target.isLocked, activeSide == side, !pane(otherSide).isLocked {
      activeSide = otherSide
    } else if !target.isLocked, pane(activeSide).isLocked {
      activeSide = side
    }
    synchronizeNavigationTargetWithLocks(resetUnlocked: true)
  }

  private func synchronizeNavigationTargetWithLocks(resetUnlocked: Bool) {
    let target: ComparisonNavigationTarget
    if first.isLocked != second.isLocked {
      target = first.isLocked ? .second : .first
    } else if !first.isLocked && resetUnlocked {
      target = .both
    } else {
      return
    }
    guard navigationTarget != target else { return }
    isSynchronizingNavigationTarget = true
    navigationTarget = target
    isSynchronizingNavigationTarget = false
  }

  func updateZoom(_ multiplier: CGFloat, on side: FolderComparisonSide? = nil) {
    let side = side ?? activeSide
    guard !pane(side).isLocked, multiplier.isFinite, multiplier > 0 else { return }
    if activeSide != side { activeSide = side }
    let active = pane(side)
    active.viewport.update {
      $0.zoom = clampedZoom($0.zoom * multiplier)
      if $0.zoom <= 1, $0.scaleMode == .fit { $0.normalizedPan = .zero }
    }
    if linksViewport { copyActiveViewport() }
  }

  func canPan(on side: FolderComparisonSide) -> Bool {
    let target = pane(side)
    return !target.isLocked && (target.zoom > 1 || target.scaleMode.canOverflowAtBaseScale)
  }

  /// 비교 모드에서는 설정과 관계없이 트랙패드 두 손가락 이동을 항상 제공합니다.
  func handlePointerPan(_ input: PanInputKind, delta: CGSize,
    on side: FolderComparisonSide, preferredMode: PanInteractionMode) -> Bool
  {
    let isTrackpad: Bool
    if case .trackpadScroll = input { isTrackpad = true } else { isTrackpad = false }
    // 잠긴 칸의 입력을 소비해 스와이프나 다른 감시자의 조작으로 이어지지 않게 합니다.
    if pane(side).isLocked { return true }
    guard (isTrackpad || preferredMode.accepts(input)), canPan(on: side) else { return false }
    pan(delta, on: side)
    return true
  }

  func pan(_ delta: CGSize, on side: FolderComparisonSide? = nil) {
    let side = side ?? activeSide
    guard canPan(on: side), delta.width.isFinite, delta.height.isFinite,
      delta != .zero else { return }
    if activeSide != side { activeSide = side }
    let active = pane(side)
    active.viewport.update {
      let normalized = $0.normalizedOffset(for: delta, zoom: $0.zoom)
      $0.normalizedPan.width += normalized.width
      $0.normalizedPan.height += normalized.height
    }
    if linksViewport { copyActiveViewport() }
  }

  func setScale(_ mode: BaseScaleMode) {
    let active = pane(activeSide)
    guard !active.isLocked else { return }
    resetLiveInput()
    active.viewport.update { $0.scaleMode = mode; $0.zoom = 1; $0.normalizedPan = .zero }
    if linksViewport { copyActiveViewport() }
  }

  func centerImage() {
    guard !pane(activeSide).isLocked else { return }
    let sides = linksViewport ? FolderComparisonSide.allCases : [activeSide]
    // Preserve the size currently on screen even if a pinch is still active.
    // Centering must not replace a pane's fit mode or the locked reference.
    let targets = sides.filter { !pane($0).isLocked }.map { ($0, effectiveZoom(on: $0)) }
    resetLiveInput()
    for (side, zoom) in targets {
      pane(side).viewport.update { $0.zoom = zoom; $0.normalizedPan = .zero }
    }
  }

  /// 값은 타일이 실제로 표시한 크기이며 원본을 별도로 디코딩하지 않습니다.
  func updateBaseImageSize(_ size: CGSize, on side: FolderComparisonSide, assetID: URL? = nil) {
    let target = pane(side)
    if let assetID, target.currentAsset?.id != assetID { return }
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      target.baseImageSize != size else { return }
    target.baseImageSize = size
  }

  func updatePanGeometry(_ geometry: ImagePanGeometry, on side: FolderComparisonSide,
    assetID: URL? = nil
  ) {
    let target = pane(side)
    if let assetID, target.currentAsset?.id != assetID { return }
    let sizes = [geometry.baseImageSize, geometry.viewportSize]
    guard sizes.allSatisfy({ $0.width.isFinite && $0.height.isFinite
      && $0.width > 0 && $0.height > 0 }) else { return }
    target.viewport.update {
      $0.baseImageSize = geometry.baseImageSize
      $0.viewportSize = geometry.viewportSize
      $0.geometryAssetID = target.currentAsset?.id
    }
    if linksViewport, side == activeSide { copyActiveViewport() }
  }

  private func copyActiveViewport() {
    let source = pane(activeSide), destination = pane(activeSide == .first ? .second : .first)
    guard !source.isLocked, !destination.isLocked else { return }
    destination.viewport.update {
      $0.zoom = source.zoom
      $0.normalizedPan = source.normalizedPan
      $0.scaleMode = source.scaleMode
    }
  }

  func updateLiveMagnification(_ value: CGFloat, on side: FolderComparisonSide) {
    guard !pane(side).isLocked, value.isFinite, value > 0 else { return }
    let startsGesture = gestureSide != side
    prepareLiveInput(on: side)
    isMagnifying = true
    lastRawMagnification = value
    liveInput.update {
      if startsGesture { $0 = .init() }
      $0.gestureSide = side
      $0.liveMagnification = value / magnificationAnchor
    }
  }

  func updateLiveTranslation(_ value: CGSize, on side: FolderComparisonSide) {
    guard canPan(on: side), value.width.isFinite, value.height.isFinite else { return }
    let startsGesture = gestureSide != side
    prepareLiveInput(on: side)
    isDragging = true
    let target = pane(side)
    let zoom = startsGesture ? target.zoom : effectiveZoom(on: side)
    let current = startsGesture ? target.pan : effectivePan(on: side)
    let delta = CGSize(width: value.width - lastDragTranslation.width,
      height: value.height - lastDragTranslation.height)
    lastDragTranslation = value
    let proposed = CGSize(width: current.width + delta.width, height: current.height + delta.height)
    let bounded = target.viewport.snapshot.constrainedPan(proposed, zoom: zoom)
    let committed = CGSize(width: target.normalizedPan.width * target.baseImageSize.width * zoom,
      height: target.normalizedPan.height * target.baseImageSize.height * zoom)
    let translation = CGSize(width: bounded.width - committed.width,
      height: bounded.height - committed.height)
    liveInput.update {
      if startsGesture { $0 = .init() }
      $0.gestureSide = side
      $0.liveTranslation = translation
    }
  }

  func endLiveTranslation(_ value: CGSize, on side: FolderComparisonSide) {
    guard value.width.isFinite, value.height.isFinite,
      canPan(on: side) || (isDragging && gestureSide == side) else { return }
    // A simultaneous pinch can already have committed a fit-sized image. The
    // drag recognizer must still finish so its old cumulative delta cannot leak
    // into the next drag after zooming in again.
    if canPan(on: side) { updateLiveTranslation(value, on: side) }
    isDragging = false
    commitLiveTransform(on: side)
    lastDragTranslation = .zero
    if !isMagnifying { resetLiveInput() }
  }

  func endLiveMagnification(_ value: CGFloat, on side: FolderComparisonSide) {
    guard !pane(side).isLocked, value.isFinite, value > 0 else { return }
    updateLiveMagnification(value, on: side)
    isMagnifying = false
    commitLiveTransform(on: side)
    lastRawMagnification = 1
    magnificationAnchor = 1
    if !isDragging { resetLiveInput() }
  }

  /// Either recognizer may end first. Commit the exact visible transform, then
  /// rebase the recognizer that is still active instead of applying its cumulative
  /// translation/magnification a second time against a different committed zoom.
  private func commitLiveTransform(on side: FolderComparisonSide) {
    let target = pane(side)
    let zoom = effectiveZoom(on: side)
    let pan = effectivePan(on: side)
    target.viewport.update {
      $0.zoom = zoom
      $0.normalizedPan = $0.normalizedOffset(for: pan, zoom: zoom)
    }
    if linksViewport { copyActiveViewport() }
    magnificationAnchor = lastRawMagnification
    liveInput.update {
      $0.gestureSide = side
      $0.liveMagnification = 1
      $0.liveTranslation = .zero
    }
  }

  private func prepareLiveInput(on side: FolderComparisonSide) {
    if activeSide != side { activeSide = side }
    if gestureSide != side {
      lastDragTranslation = .zero
      lastRawMagnification = 1
      magnificationAnchor = 1
      isDragging = false
      isMagnifying = false
      if linksViewport { copyActiveViewport() }
    }
  }

  func showsLiveInput(on side: FolderComparisonSide) -> Bool {
    guard let gestureSide, !pane(gestureSide).isLocked, !pane(side).isLocked else { return false }
    return gestureSide == side || linksViewport
  }

  func effectiveZoom(on side: FolderComparisonSide) -> CGFloat {
    clampedZoom(pane(side).zoom * (showsLiveInput(on: side) ? liveMagnification : 1))
  }

  func effectivePan(on side: FolderComparisonSide) -> CGSize {
    let target = pane(side)
    let zoom = effectiveZoom(on: side)
    var normalized = target.normalizedPan
    if showsLiveInput(on: side), let gestureSide {
      let source = pane(gestureSide)
      // Linked panes follow the source's relative position, then each clips to
      // its own bounds. Reusing a clipped destination as the origin would jump
      // when the same gesture is committed by copyActiveViewport().
      if linksViewport { normalized = source.normalizedPan }
      // 실시간 드래그도 원본 칸의 픽셀 델타를 비율로 바꾼 뒤 각 칸의 크기에 맞춥니다.
      let translation = source.viewport.snapshot.normalizedOffset(for: liveTranslation,
        zoom: effectiveZoom(on: gestureSide))
      normalized.width += translation.width
      normalized.height += translation.height
      if zoom <= 1, target.scaleMode == .fit { normalized = .zero }
    }
    return target.viewport.snapshot.constrainedPan(
      CGSize(width: normalized.width * target.baseImageSize.width * zoom,
        height: normalized.height * target.baseImageSize.height * zoom), zoom: zoom)
  }

  private func clampedZoom(_ value: CGFloat) -> CGFloat { min(16, max(0.1, value)) }

  func resetLiveInput() {
    lastDragTranslation = .zero
    lastRawMagnification = 1
    magnificationAnchor = 1
    isDragging = false
    isMagnifying = false
    liveInput.update { $0 = .init() }
  }

  func captureSession() -> ComparisonSession? {
    guard !first.sourceURLs.isEmpty || !second.sourceURLs.isEmpty else { return nil }
    func snapshot(_ pane: FolderComparisonPane) -> ComparisonPaneSession {
      ComparisonPaneSession(sources: pane.sessionSources, selectedID: pane.currentAsset?.sessionID,
        index: pane.index, zoom: Double(pane.zoom), panX: Double(pane.normalizedPan.width),
        panY: Double(pane.normalizedPan.height), actualPixels: pane.scaleMode == .actualPixels,
        scaleMode: pane.scaleMode.rawValue,
        isLocked: pane.isLocked, customName: pane.customName, photoMarkFilter: pane.photoMarkFilter)
    }
    var result = ComparisonSession(first: snapshot(first), second: snapshot(second),
      activeSide: activeSide.rawValue, alignment: alignment.rawValue, matchIndex: matchIndex)
    result.query = query
    return result
  }

  func restoreSession(_ session: ComparisonSession) async {
    restoreGeneration = UUID()
    let generation = restoreGeneration
    isRestoringSession = true
    defer { if restoreGeneration == generation { isRestoringSession = false } }
    do {
      let firstURLs = try session.first.sources.map { try $0.resolve() }
      let secondURLs = try session.second.sources.map { try $0.resolve() }
      let grants = ImageLibraryAccess(firstURLs + secondURLs)
      defer { withExtendedLifetime(grants) {} }
      guard !Task.isCancelled, restoreGeneration == generation else { return }
      first.isLocked = false
      second.isLocked = false
      editingPhotoMarkSide = nil
      alignment = ComparisonAlignment(rawValue: session.alignment) ?? .sequence
      query = session.query
      first.photoMarkFilter = session.first.photoMarkFilter ?? PhotoMarkFilter()
      second.photoMarkFilter = session.second.photoMarkFilter ?? PhotoMarkFilter()
      if !firstURLs.isEmpty { first.open(urls: firstURLs) }
      if !secondURLs.isEmpty { second.open(urls: secondURLs) }
      // Restore names before awaiting, so a later user edit is never overwritten
      // when an asynchronous scan or query finishes.
      first.setCustomName(session.first.customName ?? "")
      second.setCustomName(session.second.customName ?? "")
      repeat {
        await first.waitUntilLoaded()
        await second.waitUntilLoaded()
        guard !Task.isCancelled, restoreGeneration == generation else { return }
        // Waiting for B can allow a new query to start on A. Both lists must be
        // settled in the same actor turn before restoring their selected IDs.
      } while first.isLoading || first.isFiltering || second.isLoading || second.isFiltering
      guard !Task.isCancelled, restoreGeneration == generation else { return }
      // Select by stable source identity: ZIP materialization paths may change each launch.
      for (pane, saved) in [(first, session.first), (second, session.second)] {
        let index = saved.selectedID.flatMap { id in pane.assets.firstIndex { $0.sessionID == id } }
          ?? min(max(0, saved.index), max(0, pane.assets.count - 1))
        pane.select(number: index + 1)
        pane.isLocked = saved.isLocked && pane.currentAsset != nil
      }
      activeSide = FolderComparisonSide(rawValue: session.activeSide) ?? .first
      rebuildMatches()
      await matchTask?.value
      guard !Task.isCancelled, restoreGeneration == generation else { return }
      if alignment == .filename {
        // A missing pane has no selectedID. Resolve the other, unlocked member
        // before using the old row number: a new sort or file changes that number.
        if session.first.selectedID == nil || session.second.selectedID == nil
          || session.first.isLocked || session.second.isLocked {
          matchIndex = restoredMatchIndex(for: session)
          applyMatchedRow()
        }
      }
      for (pane, saved) in [(first, session.first), (second, session.second)] {
        pane.viewport.update {
          $0.zoom = saved.zoom.isFinite ? clampedZoom(saved.zoom) : 1
          $0.normalizedPan = CGSize(width: saved.panX.isFinite ? saved.panX : 0,
            height: saved.panY.isFinite ? saved.panY : 0)
          $0.scaleMode = BaseScaleMode.restored(rawValue: saved.scaleMode,
            actualPixels: saved.actualPixels)
        }
        pane.isLocked = saved.isLocked && pane.currentAsset != nil
      }
      activeSide = FolderComparisonSide(rawValue: session.activeSide) ?? .first
      synchronizeNavigationTargetWithLocks(resetUnlocked: false)
    } catch {
      guard !Task.isCancelled, restoreGeneration == generation else { return }
      alert = ViewerAlert(title: L10n.text("이전 비교 복원"), message: error.localizedDescription)
    }
  }

  private func restoredMatchIndex(for session: ComparisonSession) -> Int {
    let sides: [FolderComparisonSide] = activeSide == .first ? [.first, .second] : [.second, .first]
    for side in sides {
      let saved = side == .first ? session.first : session.second
      // A locked pane is an independent reference and may show a different row.
      guard !saved.isLocked, let id = saved.selectedID,
        let index = pane(side).assets.firstIndex(where: { $0.sessionID == id }),
        let row = pairs.firstIndex(where: {
          (side == .first ? $0.firstIndex : $0.secondIndex) == index
        }) else { continue }
      return row
    }
    return min(max(0, session.matchIndex), max(0, pairs.count - 1))
  }

  func cancelSessionRestore() {
    guard isRestoringSession else { return }
    cancelLoads()
  }

  func resumeMatching() {
    guard alignment == .filename else { return }
    // A mode change may have interrupted matching after the pane lists changed.
    // Rebuild before navigation uses those lists again; keep their selection/viewports.
    rebuildMatches()
  }

  func cancelLoads() {
    restoreGeneration = UUID()
    isRestoringSession = false
    first.cancelLoad()
    second.cancelLoad()
    // Pane cancellation notifies onContentsChanged and can enqueue matching.
    // Cancel that final task too, so leaving comparison does not restart work.
    matchGeneration = UUID()
    matchTask?.cancel()
    matchTask = nil
    isMatching = false
  }
}
