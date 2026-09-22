import AppKit
import Combine

enum FolderComparisonSide: String, CaseIterable, Identifiable {
  case first, second
  var id: Self { self }
  var title: String { L10n.text(self == .first ? "A · 왼쪽/위" : "B · 오른쪽/아래") }
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

enum ComparisonAlignment: String, CaseIterable, Identifiable {
  case filename, sequence
  var id: Self { self }
  var title: String { L10n.text(self == .filename ? "같은 파일명" : "목록 순서") }
}

/// 각 칸의 목록·선택·확대 상태는 독립적이고 디코더/캐시만 기존 뷰어와 공유합니다.
@MainActor
final class FolderComparisonPane: ObservableObject {
  @Published private(set) var assets: [ImageAsset] = []
  @Published private(set) var folderURL: URL?
  @Published private(set) var index = 0
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var showsMissingCounterpart = false
  @Published private(set) var isFiltering = false
  @Published var query = LibraryQuery() {
    didSet { if oldValue != query { applyQuery() } }
  }
  private(set) var sourceURLs: [URL] = []
  private(set) var sessionSources: [SessionLocation] = []
  private var allAssets: [ImageAsset] = []
  private var locationsLoaded = false
  private var queryTask: Task<Void, Never>?
  private var queryGeneration = UUID()
  @Published fileprivate(set) var zoom: CGFloat = 1
  @Published fileprivate(set) var isLocked = false
  // 이미지 중심에서 얼마나 이동했는지 이미지 크기에 대한 비율로 저장합니다.
  // 두 이미지의 해상도·종횡비·표시 영역이 달라도 같은 상대 좌표를 볼 수 있습니다.
  @Published fileprivate(set) var normalizedPan: CGSize = .zero
  @Published fileprivate(set) var baseImageSize = CGSize(width: 1, height: 1)
  var pan: CGSize {
    CGSize(width: normalizedPan.width * baseImageSize.width * zoom,
      height: normalizedPan.height * baseImageSize.height * zoom)
  }
  @Published fileprivate(set) var scaleMode: BaseScaleMode = .fit

  var onContentsChanged: (() -> Void)?

  private let library = ImageLibrary()
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = UUID()
  private var access: [ImageLibraryAccess] = []

  var currentAsset: ImageAsset? { !showsMissingCounterpart && assets.indices.contains(index) ? assets[index] : nil }
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
    sourceURLs = urls
    sessionSources = urls.map(SessionLocation.init(url:))
    access = []
    folderURL = nil
    // 폴더를 바꾸는 즉시 이전 이미지 상태를 제거해 같은 순번의 셀 재사용을 막습니다.
    assets = []
    allAssets = []
    locationsLoaded = false
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
        self.assets = opened.assets
        self.allAssets = opened.assets
        self.index = opened.focusedURL.flatMap { focused in
          opened.assets.firstIndex { $0.url.standardizedFileURL == focused.standardizedFileURL }
        } ?? 0
        self.isLoading = false
        if self.query != LibraryQuery() { self.applyQuery() }
        else { self.onContentsChanged?() }
      } catch {
        guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
        self.errorMessage = error.localizedDescription
        self.isLoading = false
        self.onContentsChanged?()
      }
    }
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
    guard !isLoading, !isLocked else { return }
    queryTask?.cancel()
    queryGeneration = UUID()
    let generation = queryGeneration
    let source = allAssets
    let options = query
    let selectedID = currentAsset?.sessionID
    let needsLocations = [LibrarySort.northToSouth, .southToNorth, .eastToWest, .westToEast].contains(options.sort)
      && !locationsLoaded
    isFiltering = true
    onContentsChanged?()
    queryTask = Task { [weak self, library] in
      do {
        let prepared = needsLocations ? try await library.enrichLocations(source) : source
        let result = try await Task.detached(priority: .userInitiated) {
          try RustImageEngine.query(prepared, options: options)
        }.value
        try Task.checkCancellation()
        guard let self, self.queryGeneration == generation else { return }
        if needsLocations { self.allAssets = prepared; self.locationsLoaded = true }
        self.assets = result
        self.index = selectedID.flatMap { id in result.firstIndex { $0.sessionID == id } } ?? 0
        self.showsMissingCounterpart = false
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

  fileprivate func waitUntilLoaded() async {
    await loadTask?.value
    await queryTask?.value
  }

  fileprivate func setMatchedIndex(_ matchingIndex: Int?) {
    guard !isLocked else { return }
    let oldID = currentAsset?.id
    showsMissingCounterpart = matchingIndex == nil
    if let matchingIndex, assets.indices.contains(matchingIndex) { index = matchingIndex }
    if oldID != currentAsset?.id { resetViewport() }
  }

  fileprivate func clearMatching() { showsMissingCounterpart = false }

  func canStep(_ direction: Int) -> Bool {
    !isLocked && !isLoading && !isFiltering && direction != 0 && assets.indices.contains(index + (direction > 0 ? 1 : -1))
  }

  func step(_ direction: Int) {
    guard canStep(direction) else { return }
    index += direction > 0 ? 1 : -1
    showsMissingCounterpart = false
    resetViewport()
  }

  func select(number: Int) {
    guard !isLocked, !isLoading, number > 0, assets.indices.contains(number - 1) else { return }
    index = number - 1
    showsMissingCounterpart = false
    resetViewport()
  }

  fileprivate func resetViewport() { zoom = 1; normalizedPan = .zero }
}

/// 함께 이동할 때 가장 긴 목록의 끝까지 탐색하고, 짧은 목록은 끝에서 유지하거나 반복합니다.
@MainActor
final class FolderComparisonStore: ObservableObject {
  let first = FolderComparisonPane()
  let second = FolderComparisonPane()
  @Published private(set) var pairs: [ImageMatchPair] = []
  @Published private(set) var matchIndex = 0
  @Published private(set) var isMatching = false
  @Published var alignment: ComparisonAlignment {
    didSet {
      defaults.set(alignment.rawValue, forKey: "ImageViewer.ComparisonAlignment.v1")
      if oldValue != alignment { rebuildMatches() }
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
  @Published var gestureSide: FolderComparisonSide?
  @Published var liveMagnification: CGFloat = 1
  @Published var liveTranslation: CGSize = .zero
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

  init(defaults: UserDefaults = .standard, alignment: ComparisonAlignment? = nil) {
    self.defaults = defaults
    self.alignment = alignment ?? defaults.string(forKey: "ImageViewer.ComparisonAlignment.v1")
      .flatMap(ComparisonAlignment.init(rawValue:)) ?? .filename
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
        let result = try await Task.detached(priority: .userInitiated) {
          try RustImageEngine.match(first: a, second: b, sort: sort)
        }.value
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
    guard alignment == .filename else { return pane(side).canStep(direction) }
    return !pane(side).isLocked && canNavigateBoth(direction)
  }

  func pane(_ side: FolderComparisonSide) -> FolderComparisonPane { side == .first ? first : second }

  func chooseItems(for side: FolderComparisonSide) {
    guard !pane(side).isLocked else { return }
    let panel = ImageOpenPanel.make()
    if panel.runModal() == .OK { open(urls: panel.urls, for: side) }
  }

  func chooseFolder(for side: FolderComparisonSide) { chooseItems(for: side) }

  func open(urls: [URL], for side: FolderComparisonSide) {
    guard !pane(side).isLocked, !urls.isEmpty else { return }
    resetLiveInput()
    restoreGeneration = UUID()
    activeSide = side
    pane(side).open(urls: urls)
  }

  func choosePair(selectFolder: @MainActor (FolderComparisonSide, URL?) -> URL? = {
    ComparisonFolderOpenPanel.choose(for: $0, directoryURL: $1)
  }) {
    guard !isChoosingPair, !first.isLocked, !second.isLocked else { return }
    isChoosingPair = true
    defer { isChoosingPair = false }
    guard let firstFolder = selectFolder(.first, first.folderURL),
      !first.isLocked, !second.isLocked else { return }
    guard let secondFolder = selectFolder(.second,
      second.folderURL ?? firstFolder.deletingLastPathComponent()),
      !first.isLocked, !second.isLocked else { return }
    // 어느 단계에서 취소하더라도 기존 두 목록과 선택·확대 상태를 유지합니다.
    resetLiveInput()
    restoreGeneration = UUID()
    activeSide = .first
    first.load(firstFolder)
    second.load(secondFolder)
  }

  func canNavigateBoth(_ direction: Int) -> Bool {
    if alignment == .filename {
      return direction != 0 && !isMatching && !first.isLoading && !second.isLoading
        && !first.isFiltering && !second.isFiltering && (!first.isLocked || !second.isLocked)
        && pairs.indices.contains(matchIndex + (direction > 0 ? 1 : -1))
    }
    let panes = navigablePanes
    guard direction != 0, let longestCount = panes.map({ $0.assets.count }).max() else { return false }
    return panes.contains { $0.assets.count == longestCount && $0.canStep(direction) }
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
    [first, second].filter { !$0.isLocked && !$0.isLoading && !$0.assets.isEmpty }
  }

  func navigate(_ side: FolderComparisonSide, direction: Int) {
    guard canNavigate(side, direction: direction) else { return }
    if alignment == .filename {
      activeSide = side
      navigateBoth(direction)
      return
    }
    resetLiveInput()
    activeSide = side
    pane(side).step(direction)
    if linksViewport { copyActiveViewport() }
  }

  func jump(_ side: FolderComparisonSide, number: Int) {
    let target = pane(side)
    guard !target.isLocked, !target.isLoading, number > 0,
      target.assets.indices.contains(number - 1) else { return }
    resetLiveInput()
    activeSide = side
    if alignment == .filename {
      guard let row = pairs.firstIndex(where: {
        (side == .first ? $0.firstIndex : $0.secondIndex) == number - 1
      }) else { return }
      matchIndex = row
      applyMatchedRow()
      return
    }
    target.select(number: number)
    if linksViewport { copyActiveViewport() }
  }

  func toggleLock(on side: FolderComparisonSide) {
    resetLiveInput()
    let target = pane(side)
    guard target.isLocked || (!target.isLoading && !target.isFiltering && !isMatching) else { return }
    target.isLocked.toggle()
    if !target.isLocked && alignment == .filename { applyMatchedRow() }
    let otherSide: FolderComparisonSide = side == .first ? .second : .first
    if target.isLocked, activeSide == side, !pane(otherSide).isLocked {
      activeSide = otherSide
    } else if !target.isLocked, pane(activeSide).isLocked {
      activeSide = side
    }
  }

  func updateZoom(_ multiplier: CGFloat, on side: FolderComparisonSide? = nil) {
    let side = side ?? activeSide
    guard !pane(side).isLocked, multiplier.isFinite, multiplier > 0 else { return }
    activeSide = side
    let active = pane(side)
    active.zoom = clampedZoom(active.zoom * multiplier)
    if active.zoom <= 1, active.scaleMode == .fit { active.normalizedPan = .zero }
    if linksViewport { copyActiveViewport() }
  }

  func canPan(on side: FolderComparisonSide) -> Bool {
    let target = pane(side)
    return !target.isLocked && (target.zoom > 1 || target.scaleMode == .actualPixels)
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
    guard canPan(on: side), delta.width.isFinite, delta.height.isFinite else { return }
    activeSide = side
    let active = pane(side)
    active.normalizedPan.width += delta.width / (active.baseImageSize.width * active.zoom)
    active.normalizedPan.height += delta.height / (active.baseImageSize.height * active.zoom)
    if linksViewport { copyActiveViewport() }
  }

  func setScale(_ mode: BaseScaleMode) {
    let active = pane(activeSide)
    guard !active.isLocked else { return }
    active.scaleMode = mode
    active.resetViewport()
    if linksViewport { copyActiveViewport() }
  }

  /// 값은 타일이 실제로 표시한 크기이며 원본을 별도로 디코딩하지 않습니다.
  func updateBaseImageSize(_ size: CGSize, on side: FolderComparisonSide, assetID: URL? = nil) {
    let target = pane(side)
    if let assetID, target.currentAsset?.id != assetID { return }
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      target.baseImageSize != size else { return }
    target.baseImageSize = size
  }

  private func copyActiveViewport() {
    let source = pane(activeSide), destination = pane(activeSide == .first ? .second : .first)
    guard !source.isLocked, !destination.isLocked else { return }
    destination.zoom = source.zoom
    destination.normalizedPan = source.normalizedPan
    destination.scaleMode = source.scaleMode
  }

  func updateLiveMagnification(_ value: CGFloat, on side: FolderComparisonSide) {
    guard !pane(side).isLocked, value.isFinite, value > 0 else { return }
    prepareLiveInput(on: side)
    liveMagnification = value
  }

  func updateLiveTranslation(_ value: CGSize, on side: FolderComparisonSide) {
    guard canPan(on: side) else { return }
    prepareLiveInput(on: side)
    liveTranslation = value
  }

  private func prepareLiveInput(on side: FolderComparisonSide) {
    activeSide = side
    if gestureSide != side, linksViewport { copyActiveViewport() }
    gestureSide = side
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
      // 실시간 드래그도 원본 칸의 픽셀 델타를 비율로 바꾼 뒤 각 칸의 크기에 맞춥니다.
      normalized.width += liveTranslation.width / (source.baseImageSize.width * effectiveZoom(on: gestureSide))
      normalized.height += liveTranslation.height / (source.baseImageSize.height * effectiveZoom(on: gestureSide))
      if zoom <= 1, target.scaleMode == .fit { normalized = .zero }
    }
    return CGSize(width: normalized.width * target.baseImageSize.width * zoom,
      height: normalized.height * target.baseImageSize.height * zoom)
  }

  private func clampedZoom(_ value: CGFloat) -> CGFloat { min(16, max(0.1, value)) }

  func resetLiveInput() { gestureSide = nil; liveMagnification = 1; liveTranslation = .zero }

  func captureSession() -> ComparisonSession? {
    guard !first.sourceURLs.isEmpty || !second.sourceURLs.isEmpty else { return nil }
    func snapshot(_ pane: FolderComparisonPane) -> ComparisonPaneSession {
      ComparisonPaneSession(sources: pane.sessionSources, selectedID: pane.currentAsset?.sessionID,
        index: pane.index, zoom: Double(pane.zoom), panX: Double(pane.normalizedPan.width),
        panY: Double(pane.normalizedPan.height), actualPixels: pane.scaleMode == .actualPixels,
        isLocked: pane.isLocked)
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
      alignment = ComparisonAlignment(rawValue: session.alignment) ?? .filename
      query = session.query
      if !firstURLs.isEmpty { first.open(urls: firstURLs) }
      if !secondURLs.isEmpty { second.open(urls: secondURLs) }
      await first.waitUntilLoaded()
      await second.waitUntilLoaded()
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
        // A missing pane has no selectedID; the union-row position preserves that empty slot.
        if session.first.selectedID == nil || session.second.selectedID == nil
          || session.first.isLocked || session.second.isLocked {
          matchIndex = min(max(0, session.matchIndex), max(0, pairs.count - 1))
          applyMatchedRow()
        }
      }
      for (pane, saved) in [(first, session.first), (second, session.second)] {
        pane.zoom = saved.zoom.isFinite ? clampedZoom(saved.zoom) : 1
        pane.normalizedPan = CGSize(width: saved.panX.isFinite ? saved.panX : 0,
          height: saved.panY.isFinite ? saved.panY : 0)
        pane.scaleMode = saved.actualPixels ? .actualPixels : .fit
        pane.isLocked = saved.isLocked && pane.currentAsset != nil
      }
      activeSide = FolderComparisonSide(rawValue: session.activeSide) ?? .first
    } catch {
      guard !Task.isCancelled, restoreGeneration == generation else { return }
      alert = ViewerAlert(title: L10n.text("이전 비교 복원"), message: error.localizedDescription)
    }
  }

  func cancelSessionRestore() {
    guard isRestoringSession else { return }
    cancelLoads()
  }

  func cancelLoads() {
    restoreGeneration = UUID()
    isRestoringSession = false
    matchGeneration = UUID()
    matchTask?.cancel()
    matchTask = nil
    isMatching = false
    first.cancelLoad()
    second.cancelLoad()
  }
}
