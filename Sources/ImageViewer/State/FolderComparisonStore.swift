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

/// 각 칸의 목록·선택·확대 상태는 독립적이고 디코더/캐시만 기존 뷰어와 공유합니다.
@MainActor
final class FolderComparisonPane: ObservableObject {
  @Published private(set) var assets: [ImageAsset] = []
  @Published private(set) var folderURL: URL?
  @Published private(set) var index = 0
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?
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

  private let library = ImageLibrary()
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = UUID()
  private var access: [ImageLibraryAccess] = []

  var currentAsset: ImageAsset? { assets.indices.contains(index) ? assets[index] : nil }
  var position: String { assets.isEmpty ? "0 / 0" : "\(index + 1) / \(assets.count)" }

  func load(_ folder: URL) {
    guard !isLocked else { return }
    open(urls: [folder])
    folderURL = folder
  }

  func open(urls: [URL]) {
    guard !isLocked, !urls.isEmpty else { return }
    cancelLoad()
    let generation = loadGeneration
    access = []
    folderURL = nil
    // 폴더를 바꾸는 즉시 이전 이미지 상태를 제거해 같은 순번의 셀 재사용을 막습니다.
    assets = []
    index = 0
    resetViewport()
    errorMessage = nil
    isLoading = true
    loadTask = Task { [weak self, library] in
      do {
        let opened = try await library.open(urls: urls)
        try Task.checkCancellation()
        guard let self, self.loadGeneration == generation else { return }
        self.access = opened.access
        self.folderURL = opened.folderURL
        self.assets = opened.assets
        self.index = opened.focusedURL.flatMap { focused in
          opened.assets.firstIndex { $0.url.standardizedFileURL == focused.standardizedFileURL }
        } ?? 0
        self.isLoading = false
      } catch {
        guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
        self.errorMessage = error.localizedDescription
        self.isLoading = false
      }
    }
  }

  func cancelLoad() {
    loadGeneration = UUID()
    loadTask?.cancel()
    loadTask = nil
    isLoading = false
  }

  func canStep(_ direction: Int) -> Bool {
    !isLocked && !isLoading && direction != 0 && assets.indices.contains(index + (direction > 0 ? 1 : -1))
  }

  func step(_ direction: Int) {
    guard canStep(direction) else { return }
    index += direction > 0 ? 1 : -1
    resetViewport()
  }

  func select(number: Int) {
    guard !isLocked, !isLoading, number > 0, assets.indices.contains(number - 1) else { return }
    index = number - 1
    resetViewport()
  }

  fileprivate func resetViewport() { zoom = 1; normalizedPan = .zero }
}

/// 함께 이동할 때 가장 긴 목록의 끝까지 탐색하고, 짧은 목록은 끝에서 유지하거나 반복합니다.
@MainActor
final class FolderComparisonStore: ObservableObject {
  let first = FolderComparisonPane()
  let second = FolderComparisonPane()
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

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
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
    activeSide = .first
    first.load(firstFolder)
    second.load(secondFolder)
  }

  func canNavigateBoth(_ direction: Int) -> Bool {
    let panes = navigablePanes
    guard direction != 0, let longestCount = panes.map({ $0.assets.count }).max() else { return false }
    return panes.contains { $0.assets.count == longestCount && $0.canStep(direction) }
  }

  func navigateBoth(_ direction: Int) {
    guard canNavigateBoth(direction) else { return }
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
    guard pane(side).canStep(direction) else { return }
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
    target.select(number: number)
    if linksViewport { copyActiveViewport() }
  }

  func toggleLock(on side: FolderComparisonSide) {
    resetLiveInput()
    let target = pane(side)
    target.isLocked.toggle()
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

  func cancelLoads() { first.cancelLoad(); second.cancelLoad() }
}
