import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct ViewerAlert: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

enum BatchSheet: String, Identifiable {
  case rename, export
  var id: Self { self }
}

/// 앱의 탐색 상태와 비파괴 편집 상태를 소유하는 메인 액터 모델입니다.
@MainActor
final class AppStore: ObservableObject {
  @Published private(set) var assets: [ImageAsset] = [] {
    didSet {
      libraryRevision = UUID()
      overviewSelectionSession = nil
      pauseSlideshow()
      slideshowPresentedAsset = nil
    }
  }
  /// The complete source collection stays intact when search or format filters change.
  @Published private(set) var allAssets: [ImageAsset] = []
  @Published var libraryQuery = LibraryQuery() {
    didSet {
      guard oldValue != libraryQuery, !isApplyingSession else { return }
      libraryQueryRevision &+= 1
      applyLibraryQuery()
    }
  }
  @Published private(set) var isFiltering = false
  @Published private(set) var favoriteFolders: [FavoriteFolder] = []
  @Published var showsAIUpscaling = false
  @Published private(set) var libraryRevision = UUID()
  @Published private(set) var currentFolderURL: URL?
  @Published var showsFolderTree: Bool {
    didSet { preferences.set(showsFolderTree, forKey: Self.folderTreeDefaultsKey) }
  }
  @Published private(set) var overviewSelectionSession: OverviewSelectionSession?
  @Published private(set) var selectedURLs: Set<URL> = []
  @Published var batchSheet: BatchSheet? {
    didSet { if batchSheet != nil { pauseSlideshow() } }
  }
  @Published var wallpaperRequest: WallpaperRequest? {
    didSet { if wallpaperRequest != nil { pauseSlideshow() } }
  }
  @Published private(set) var isSettingWallpaper = false
  @Published private(set) var isRenaming = false
  @Published private(set) var isBatchExporting = false
  /// 현재 다중 보기 페이지의 첫 번째 이미지입니다.
  @Published private(set) var pageStartIndex = 0
  /// 조정 패널과 테두리가 가리키는 활성 이미지입니다.
  @Published private(set) var currentIndex = 0 {
    didSet {
      if oldValue != currentIndex {
        slideshowPresentedAsset = nil
        invalidateSlideshowCountdown()
      }
    }
  }
  @Published var presentationMode: PresentationMode = .viewer {
    didSet {
      guard oldValue != presentationMode else { return }
      if !isApplyingSession { invalidateSessionRestore() }
      if presentationMode == .folderComparison {
        comparisonReturnMode = oldValue
        cancelLibraryLoad()
      }
      if oldValue == .folderComparison { folderComparison.cancelLoads() }
      if presentationMode != .viewer {
        pauseSlideshow()
        slideshowPresentedAsset = nil
        isFocusMode = false
      }
      prefetchAroundCurrentPosition()
    }
  }
  @Published var baseScaleMode: BaseScaleMode = .fit
  @Published var imagesPerPage = 1
  @Published var thumbnailSize: CGFloat {
    didSet {
      let normalized = OverviewThumbnailSizing.normalized(thumbnailSize)
      if thumbnailSize != normalized {
        thumbnailSize = normalized
      }
      preferences.set(Double(normalized), forKey: Self.thumbnailSizeDefaultsKey)
    }
  }
  @Published var zoom: CGFloat = 1
  @Published var showsOverviewNumbers: Bool {
    didSet { preferences.set(showsOverviewNumbers, forKey: Self.overviewNumbersDefaultsKey) }
  }
  @Published var panOffset: CGSize = .zero
  @Published var thumbnailPanelPlacement: ThumbnailPanelPlacement {
    didSet {
      preferences.set(
        thumbnailPanelPlacement.rawValue, forKey: Self.thumbnailPlacementDefaultsKey)
    }
  }
  @Published var panInteractionMode: PanInteractionMode {
    didSet {
      preferences.set(panInteractionMode.rawValue, forKey: Self.panModeDefaultsKey)
    }
  }
  @Published var filenameDisplaySize: FilenameDisplaySize {
    didSet {
      preferences.set(
        filenameDisplaySize.rawValue, forKey: Self.filenameDisplaySizeDefaultsKey)
    }
  }
  @Published var imageLoadingMode: ImageLoadingMode {
    didSet {
      guard oldValue != imageLoadingMode else { return }
      preferences.set(imageLoadingMode.rawValue, forKey: Self.imageLoadingModeDefaultsKey)
      updateImageLoadingMode()
    }
  }
  @Published var imageInterpolationMode: ImageInterpolationMode {
    didSet {
      preferences.set(
        imageInterpolationMode.rawValue, forKey: Self.imageInterpolationModeDefaultsKey)
      if imageInterpolationMode == .pixelated { comparisonLayout = .off }
    }
  }
  /// 비교는 현재 보기에서만 사용하며 재실행 시 일반 보기로 시작합니다.
  @Published private(set) var comparisonLayout: MagnificationComparisonLayout = .off

  // 사용자 표기는 ‘고화질 확대’입니다. 이전 설정/단축키를 위해 내부 이름은 유지합니다.
  var isAntialiasingEnabled: Bool {
    get { imageInterpolationMode == .smooth }
    set { imageInterpolationMode = newValue ? .smooth : .pixelated }
  }

  func setComparisonLayout(_ layout: MagnificationComparisonLayout) {
    if layout != .off { isAntialiasingEnabled = true }
    comparisonLayout = layout
  }
  @Published var inspectorPanel: InspectorPanel?
  @Published var isFocusMode = false {
    didSet { if !isFocusMode { pauseSlideshow() } }
  }
  @Published private(set) var isSlideshowPlaying = false
  @Published var slideshowInterval: TimeInterval {
    didSet {
      let normalized = SlideshowSettings.normalized(slideshowInterval)
      if slideshowInterval != normalized { slideshowInterval = normalized }
      preferences.set(normalized, forKey: Self.slideshowIntervalDefaultsKey)
      restartSlideshowCountdown()
    }
  }
  @Published var slideshowRepeats: Bool {
    didSet { preferences.set(slideshowRepeats, forKey: Self.slideshowRepeatsDefaultsKey) }
  }
  @Published var prefersHDR = true
  @Published var wrapsNavigation = true
  @Published private(set) var isLoading = false {
    didSet { if isLoading { pauseSlideshow() } }
  }
  @Published private(set) var isExporting = false
  @Published private(set) var isSavingMetadata = false
  @Published private(set) var currentMetadata: ImageMetadata?
  @Published var exportFormat: ExportFormat = ExportFormat.available.first ?? .jpeg
  @Published var exportQuality = 0.92
  @Published var alert: ViewerAlert? {
    didSet { if alert != nil { pauseSlideshow() } }
  }
  @Published var statusMessage: String?

  let aiUpscaling: AIUpscalingStore
  let pipeline: ImagePipeline
  let thumbnailPipeline: ThumbnailPipeline
  let loadingGovernor: ImageResourceGovernor
  let wallpaperService: WallpaperService
  let folderComparison: FolderComparisonStore
  let folderTree = FolderTreeStore()
  private var comparisonReturnMode: PresentationMode = .viewer

  private let preferences: UserDefaults
  private let sessionPersistence: ViewerSessionPersistence
  private var sessionSubscriptions: Set<AnyCancellable> = []
  private var sessionSaveTask: Task<Void, Never>?
  private var restoreGeneration = UUID()
  private var didAttemptSessionRestore = false
  private var isRestoringSession = false
  private var isApplyingSession = false
  private var sourceLocations: [SessionLocation] = []
  private var queryTask: Task<Void, Never>?
  private var queryGeneration = UUID()
  private var libraryQueryRevision: UInt64 = 0
  private var queryFocusID: String?
  private var favoriteAccess: [UUID: ImageLibraryAccess] = [:]
  private let library = ImageLibrary()
  private let exporter: ImageExporter
  private let metadataWriter = ImageMetadataWriter()
  private let batchRenamer = BatchRenamer()
  private let batchExporter: BatchImageExporter
  private var selectionAnchor: Int?
  private var adjustments: [URL: ImageAdjustments] = [:]
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = UUID()
  private var metadataTask: Task<Void, Never>?
  private var prefetchTask: Task<Void, Never>?
  private var loadingModeUpdateTask: Task<Void, Never>?
  private var resourceMonitor: ImageSystemResourceMonitor?
  private var viewerPrefetchPixels = 512
  private var libraryAccess: [ImageLibraryAccess] = []
  private var slideshowTask: Task<Void, Never>?
  private var slideshowGeneration = UUID()
  private var slideshowPresentedAsset: ImageAsset?
  private var slideshowActivity: SlideshowDisplayActivity?
  private let managesSlideshowDisplaySleep: Bool

  private static let thumbnailPlacementDefaultsKey = "ImageViewer.ThumbnailPlacement.v1"
  private static let folderTreeDefaultsKey = "ImageViewer.ShowsFolderTree.v1"
  private static let thumbnailSizeDefaultsKey = "ImageViewer.OverviewThumbnailSize.v1"
  private static let overviewNumbersDefaultsKey = "ImageViewer.ShowsOverviewNumbers.v1"
  private static let panModeDefaultsKey = "ImageViewer.PanInteractionMode.v1"
  private static let filenameDisplaySizeDefaultsKey = "ImageViewer.FilenameDisplaySize.v1"
  private static let imageLoadingModeDefaultsKey = "ImageViewer.ImageLoadingMode.v1"
  private static let imageInterpolationModeDefaultsKey = "ImageViewer.ImageInterpolationMode.v1"
  private static let slideshowIntervalDefaultsKey = "ImageViewer.SlideshowInterval.v1"
  private static let slideshowRepeatsDefaultsKey = "ImageViewer.SlideshowRepeats.v1"

  init(defaults: UserDefaults = .standard, monitorsSystemResources: Bool = true) {
    preferences = defaults
    sessionPersistence = ViewerSessionPersistence(defaults: defaults)
    favoriteFolders = sessionPersistence.loadFavorites()
    showsFolderTree = defaults.bool(forKey: Self.folderTreeDefaultsKey)
    folderComparison = FolderComparisonStore(defaults: defaults)
    managesSlideshowDisplaySleep = monitorsSystemResources
    slideshowInterval = SlideshowSettings.normalized(
      defaults.object(forKey: Self.slideshowIntervalDefaultsKey) == nil
        ? SlideshowSettings.defaultInterval : defaults.double(forKey: Self.slideshowIntervalDefaultsKey))
    slideshowRepeats = defaults.object(forKey: Self.slideshowRepeatsDefaultsKey) == nil
      ? true : defaults.bool(forKey: Self.slideshowRepeatsDefaultsKey)
    let savedThumbnailSize =
      defaults.object(forKey: Self.thumbnailSizeDefaultsKey) == nil
      ? OverviewThumbnailSizing.defaultSize
      : CGFloat(defaults.double(forKey: Self.thumbnailSizeDefaultsKey))
    thumbnailSize = OverviewThumbnailSizing.normalized(savedThumbnailSize)
    showsOverviewNumbers = defaults.object(forKey: Self.overviewNumbersDefaultsKey) == nil
      ? true : defaults.bool(forKey: Self.overviewNumbersDefaultsKey)

    let loadingMode =
      defaults.string(forKey: Self.imageLoadingModeDefaultsKey)
      .flatMap(ImageLoadingMode.init(rawValue:)) ?? .comfortable
    imageLoadingMode = loadingMode
    imageInterpolationMode =
      defaults.string(forKey: Self.imageInterpolationModeDefaultsKey)
      .flatMap(ImageInterpolationMode.init(rawValue:)) ?? .smooth
    let loadingGovernor = ImageResourceGovernor(mode: loadingMode)
    self.loadingGovernor = loadingGovernor
    let pipeline = ImagePipeline(governor: loadingGovernor)
    self.pipeline = pipeline
    aiUpscaling = AIUpscalingStore(pipeline: pipeline)
    wallpaperService = WallpaperService(pipeline: pipeline)
    thumbnailPipeline = ThumbnailPipeline(governor: loadingGovernor)
    exporter = ImageExporter(pipeline: pipeline)
    batchExporter = BatchImageExporter(pipeline: pipeline)

    thumbnailPanelPlacement =
      defaults.string(forKey: Self.thumbnailPlacementDefaultsKey)
      .flatMap(ThumbnailPanelPlacement.init(rawValue:)) ?? .left
    panInteractionMode =
      defaults.string(forKey: Self.panModeDefaultsKey)
      .flatMap(PanInteractionMode.init(rawValue:)) ?? .primaryDrag
    filenameDisplaySize =
      defaults.string(forKey: Self.filenameDisplaySizeDefaultsKey)
      .flatMap(FilenameDisplaySize.init(rawValue:)) ?? .medium
    inspectorPanel = nil
    if monitorsSystemResources {
      resourceMonitor = ImageSystemResourceMonitor(isAppActive: NSApp?.isActive ?? true) {
        snapshot in
        Task { await loadingGovernor.update(snapshot) }
      }
    }
    objectWillChange.sink { [weak self] in self?.scheduleSessionSave() }
      .store(in: &sessionSubscriptions)
    folderComparison.objectWillChange.sink { [weak self] in self?.scheduleSessionSave() }
      .store(in: &sessionSubscriptions)
  }

  private func updateImageLoadingMode() {
    prefetchTask?.cancel()
    prefetchTask = nil
    let mode = imageLoadingMode
    let previousUpdate = loadingModeUpdateTask
    // Preserve selection order across actor hops when the picker changes rapidly.
    loadingModeUpdateTask = Task { [weak self, loadingGovernor] in
      await previousUpdate?.value
      guard let self, self.imageLoadingMode == mode else { return }
      await loadingGovernor.setMode(mode)
      guard self.imageLoadingMode == mode else { return }
      self.prefetchAroundCurrentPosition()
    }
  }

  var currentAsset: ImageAsset? {
    assets.indices.contains(currentIndex) ? assets[currentIndex] : nil
  }

  var selectedAssets: [ImageAsset] {
    assets.filter { selectedURLs.contains($0.url) }
  }

  var isBatchBusy: Bool { isRenaming || isBatchExporting }

  var canStartBatchOperation: Bool {
    presentationMode != .folderComparison && !selectedAssets.isEmpty && !isLoading && !isFiltering && !isBatchBusy && !isSavingMetadata && !isExporting
      && batchSheet == nil && overviewSelectionSession == nil
      && wallpaperRequest == nil && !isSettingWallpaper
  }

  func selectForBatch(index: Int, modifiers: NSEvent.ModifierFlags) {
    guard assets.indices.contains(index), batchSheet == nil, !isBatchBusy,
      overviewSelectionSession == nil else { return }
    if modifiers.contains(.shift) {
      let anchor = selectionAnchor ?? currentIndex
      let range = Set(assets[min(anchor, index)...max(anchor, index)].map(\.url))
      selectedURLs = modifiers.contains(.command) ? selectedURLs.union(range) : range
    } else if modifiers.contains(.command) {
      let url = assets[index].url
      if selectedURLs.contains(url) { selectedURLs.remove(url) }
      else { selectedURLs.insert(url) }
      selectionAnchor = index
    } else {
      selectedURLs = [assets[index].url]
      selectionAnchor = index
    }
    focus(index: index)
  }

  func selectAllAssets() {
    guard batchSheet == nil, !isBatchBusy else { return }
    if let session = overviewSelectionSession { finishOverviewSelection(session.id) }
    selectedURLs = Set(assets.map(\.url))
    if selectionAnchor == nil { selectionAnchor = currentIndex }
  }

  func clearSelection() {
    guard batchSheet == nil, !isBatchBusy else { return }
    if let session = overviewSelectionSession { finishOverviewSelection(session.id) }
    selectedURLs = []
    selectionAnchor = nil
  }

  func beginOverviewSelection(modifiers: NSEvent.ModifierFlags) -> UUID? {
    guard presentationMode == .overview, !assets.isEmpty, !isLoading, batchSheet == nil, !isBatchBusy,
      overviewSelectionSession == nil else { return nil }
    let session = OverviewSelectionSession(
      libraryRevision: libraryRevision, baseline: selectedURLs,
      allowedURLs: Set(assets.map(\.url)), operation: .init(modifiers: modifiers))
    overviewSelectionSession = session
    return session.id
  }

  func updateOverviewSelection(_ id: UUID, hits: Set<URL>) {
    guard let session = overviewSelectionSession, session.id == id,
      session.libraryRevision == libraryRevision, !isLoading,
      batchSheet == nil, !isBatchBusy else { return }
    let selection = session.operation.applying(
      hits: hits.intersection(session.allowedURLs), to: session.baseline)
    // 드래그 중 초점/메타데이터/선읽기를 바꾸지 않아 자동 스크롤과 디코딩 폭주를 막습니다.
    if selectedURLs != selection { selectedURLs = selection }
  }

  func finishOverviewSelection(_ id: UUID) {
    guard overviewSelectionSession?.id == id else { return }
    overviewSelectionSession = nil
    selectionAnchor = assets.firstIndex { selectedURLs.contains($0.url) }
  }

  func cancelOverviewSelection(_ id: UUID) {
    guard let session = overviewSelectionSession, session.id == id else { return }
    overviewSelectionSession = nil
    if session.libraryRevision == libraryRevision { selectedURLs = session.baseline }
  }

  func presentBatchRename() {
    guard canStartBatchOperation, !selectedAssets.contains(where: \.isReadOnly) else { return }
    batchSheet = .rename
  }

  func presentBatchExport() {
    guard canStartBatchOperation, !ExportFormat.available.isEmpty else { return }
    batchSheet = .export
  }

  func renameSelectedFiles(using plan: BatchRenamePlan) async throws {
    guard !isBatchBusy, !isLoading, !isSavingMetadata, !isExporting else { return }
    let targets = Set(plan.entries.map(\.sourceURL).map(\.standardizedFileURL))
    guard !allAssets.contains(where: { $0.isReadOnly && targets.contains($0.url.standardizedFileURL) }) else {
      throw LibraryAccessError.readOnlyArchive
    }
    isRenaming = true
    prefetchTask?.cancel()
    metadataTask?.cancel()
    defer { isRenaming = false }
    // Standardization may change when a file stops existing, so capture keys before any move.
    let sourceKeys = allAssets.map { (original: $0.url, canonical: $0.url.standardizedFileURL) }
    let mapping: [URL: URL]
    do {
      let renamed = try await batchRenamer.apply(plan)
      // Foundation standardizes /private/tmp to /tmp, among other path aliases.
      // Translate the planner's canonical keys back to the URLs used by the open library.
      mapping = Dictionary(uniqueKeysWithValues: sourceKeys.compactMap { source in
        guard let destination = renamed[source.canonical] else { return nil }
        return (source.original, destination)
      })
    } catch {
      refreshMetadata()
      prefetchAroundCurrentPosition()
      throw error
    }
    let focusedURL = currentAsset.map { mapping[$0.url] ?? $0.url }
    let previousAdjustments = adjustments
    for source in mapping.keys { adjustments.removeValue(forKey: source) }
    for (source, destination) in mapping {
      adjustments[destination] = previousAdjustments[source]
    }
    selectedURLs = Set(selectedURLs.map { mapping[$0] ?? $0 })
    // Refresh only the open library so an explicit selection from several folders stays intact.
    allAssets = allAssets.map { asset in
      mapping[asset.url].map { asset.replacingURL($0) } ?? asset
    }
    sourceLocations = sourceLocations.map { location in
      mapping[location.url].map { SessionLocation(url: $0) } ?? location
    }
    let queried = try await queryAssets(allAssets, options: libraryQuery)
    allAssets = queried.all
    assets = queried.visible
    currentIndex = assets.firstIndex { $0.url == focusedURL } ?? 0
    queryFocusID = currentAsset?.sessionID
    pageStartIndex = currentIndex
    selectionAnchor = currentIndex
    await pipeline.purgeCaches()
    await thumbnailPipeline.purgeCache()
    refreshMetadata()
    prefetchAroundCurrentPosition()
    showStatus(L10n.format("%d개 파일 이름 변경 완료", mapping.count))
  }

  func convertSelectedFiles(
    items: [BatchExportItem], format: ExportFormat, quality: Double,
    progress: @escaping @Sendable (Int, Int) -> Void
  ) async -> BatchExportResult {
    isBatchExporting = true
    defer { isBatchExporting = false }
    return await batchExporter.export(
      items: items, format: format, quality: quality, adjustments: adjustments, progress: progress)
  }

  var currentAdjustments: ImageAdjustments {
    guard let currentAsset else { return .identity }
    return adjustments[currentAsset.url, default: .identity]
  }

  var visibleAssets: [ImageAsset] {
    guard !assets.isEmpty else { return [] }
    let end = min(assets.count, pageStartIndex + imagesPerPage)
    return Array(assets[pageStartIndex..<end])
  }

  var canPan: Bool {
    zoom > 1 || baseScaleMode == .actualPixels
  }

  var positionDescription: String {
    guard !assets.isEmpty else { return "0 / 0" }
    let end = min(assets.count, pageStartIndex + imagesPerPage)
    if end == pageStartIndex + 1 {
      return "\(pageStartIndex + 1) / \(assets.count)"
    }
    return "\(pageStartIndex + 1)–\(end) / \(assets.count)"
  }

  var activeFolderName: String {
    if let archive = currentAsset?.archiveOrigin?.archiveURL { return archive.lastPathComponent }
    let folder = currentFolderURL ?? currentAsset?.url.deletingLastPathComponent()
    return folder?.lastPathComponent ?? L10n.text("알맹Re")
  }

  var canOpenFolderFromTree: Bool {
    batchSheet == nil && !isBatchBusy && !isSavingMetadata && !isExporting
      && wallpaperRequest == nil && !isSettingWallpaper
      && (presentationMode != .folderComparison || !folderComparison.pane(folderComparison.activeSide).isLocked)
  }

  func openFolderFromTree(_ folder: URL) {
    guard canOpenFolderFromTree else { return }
    if presentationMode == .folderComparison {
      invalidateSessionRestore()
      folderComparison.open(urls: [folder], for: folderComparison.activeSide)
    } else {
      load(folder: folder, fromTree: true)
    }
  }

  var canEditCurrentEmbeddedMetadata: Bool {
    currentAsset?.isReadOnly != true && ImageMetadataWriter.supportsEmbeddedMetadata(
      typeIdentifier: currentMetadata?.typeIdentifier
    )
  }

  func chooseItems() {
    guard canOpenFolderFromTree else { return }
    if presentationMode == .folderComparison {
      invalidateSessionRestore()
      folderComparison.chooseItems(for: folderComparison.activeSide)
      return
    }
    pauseSlideshow()
    let panel = ImageOpenPanel.make()
    if panel.runModal() == .OK { open(urls: panel.urls) }
  }

  // Keep old call sites and saved shortcut actions compatible with the unified opener.
  func chooseFolder() { chooseItems() }
  func chooseFiles() { chooseItems() }

  func open(urls: [URL]) {
    guard !urls.isEmpty, canOpenFolderFromTree else { return }
    if presentationMode == .folderComparison {
      invalidateSessionRestore()
      folderComparison.open(urls: urls, for: folderComparison.activeSide)
      return
    }
    load(urls: urls)
  }

  func select(asset: ImageAsset, switchToViewer: Bool = false) {
    guard let index = assets.firstIndex(of: asset) else { return }
    select(index: index)
    if switchToViewer { presentationMode = .viewer }
  }

  func select(index: Int) {
    guard assets.indices.contains(index), batchSheet == nil, !isBatchBusy else { return }
    selectedURLs = [assets[index].url]
    selectionAnchor = index
    focus(index: index)
  }

  private func focus(index: Int) {
    queryFocusID = assets[index].sessionID
    let visibleRange = pageStartIndex..<min(assets.count, pageStartIndex + imagesPerPage)
    if !visibleRange.contains(index) {
      pageStartIndex = index
    }
    currentIndex = index
    resetViewport()
    refreshMetadata()
    prefetchAroundCurrentPosition()
    restartSlideshowCountdown()
  }

  func navigatePage(_ direction: Int) {
    if presentationMode == .folderComparison {
      folderComparison.navigateBoth(direction)
      return
    }
    guard !assets.isEmpty, direction != 0, batchSheet == nil, !isBatchBusy else { return }
    let step = max(1, imagesPerPage) * (direction > 0 ? 1 : -1)
    var target = pageStartIndex + step
    let lastFullPageStart = max(0, assets.count - imagesPerPage)

    if wrapsNavigation {
      if target >= assets.count {
        target = 0
      } else if target < 0 {
        target = lastFullPageStart
      }
    } else {
      target = min(max(0, target), lastFullPageStart)
    }
    pageStartIndex = target
    currentIndex = target
    queryFocusID = assets[target].sessionID
    selectedURLs = [assets[target].url]
    selectionAnchor = target
    resetViewport()
    refreshMetadata()
    prefetchAroundCurrentPosition()
    restartSlideshowCountdown()
  }

  func setImagesPerPage(_ count: Int) {
    if count != 1 { pauseSlideshow() }
    imagesPerPage = min(10, max(1, count))
    let visibleRange = pageStartIndex..<min(assets.count, pageStartIndex + imagesPerPage)
    if !visibleRange.contains(currentIndex) {
      pageStartIndex = currentIndex
    }
    resetViewport()
    prefetchAroundCurrentPosition()
  }

  func zoomIn() {
    if presentationMode == .folderComparison { folderComparison.updateZoom(1.25); return }
    zoom = min(16, zoom * 1.25)
  }

  func zoomOut() {
    if presentationMode == .folderComparison { folderComparison.updateZoom(1 / 1.25); return }
    zoom = max(0.1, zoom / 1.25)
    if zoom <= 1 { panOffset = .zero }
  }

  func setFitToWindow() {
    if presentationMode == .folderComparison { folderComparison.setScale(.fit); return }
    baseScaleMode = .fit
    resetViewport()
  }

  func setActualPixels() {
    if presentationMode == .folderComparison { folderComparison.setScale(.actualPixels); return }
    baseScaleMode = .actualPixels
    resetViewport()
  }

  func updateZoom(with magnification: CGFloat) {
    zoom = min(16, max(0.1, zoom * magnification))
    if zoom <= 1 { panOffset = .zero }
  }

  func updatePan(by translation: CGSize) {
    guard canPan else { return }
    panOffset.width += translation.width
    panOffset.height += translation.height
  }

  /// AppKit에서 받은 보조 버튼/트랙패드 입력이 현재 설정과 일치할 때만 팬합니다.
  @discardableResult
  func handlePanInput(_ input: PanInputKind, delta: CGSize) -> Bool {
    guard presentationMode == .viewer, canPan, panInteractionMode.accepts(input) else {
      return false
    }
    updatePan(by: delta)
    return true
  }

  func updateAdjustments(_ change: (inout ImageAdjustments) -> Void) {
    guard let currentAsset else { return }
    pauseSlideshow()
    var value = currentAdjustments
    change(&value)
    adjustments[currentAsset.url] = value
    objectWillChange.send()
  }

  /// A sheet applies to its captured file only; navigation or replacement cannot
  /// accidentally transfer that draft crop to a different image.
  func applyCrop(_ crop: NormalizedCrop?, to asset: ImageAsset,
    relativeToQuarterTurns referenceTurns: Int? = nil)
  {
    guard assets.contains(asset) else { return }
    pauseSlideshow()
    var value = adjustments(for: asset)
    var adjustedCrop = crop?.normalized
    if let referenceTurns {
      let delta = (value.normalizedQuarterTurns - ((referenceTurns % 4 + 4) % 4) + 4) % 4
      for _ in 0..<delta { adjustedCrop = adjustedCrop?.rotatedClockwise() }
    }
    value.crop = adjustedCrop
    adjustments[asset.url] = value
    objectWillChange.send()
  }

  func adjustments(for asset: ImageAsset) -> ImageAdjustments {
    adjustments[asset.url, default: .identity]
  }

  func rotateClockwise() {
    updateAdjustments { $0.rotateClockwise() }
  }

  func rotateCounterclockwise() {
    updateAdjustments { $0.rotateCounterclockwise() }
  }

  func resetAdjustments() {
    guard let currentAsset else { return }
    adjustments[currentAsset.url] = .identity
    objectWillChange.send()
  }

  func toggleOverview() {
    presentationMode = presentationMode == .viewer ? .overview : .viewer
  }

  /// 단일/다중 이미지 뷰어에서 폴더의 몽땅보기 화면으로 명시적으로 돌아갑니다.
  func returnToOverview() {
    isFocusMode = false
    presentationMode = .overview
  }

  func toggleInspector(_ panel: InspectorPanel) {
    pauseSlideshow()
    if panel == .editing, inspectorPanel != .editing, presentationMode == .overview,
      currentAsset != nil
    {
      presentationMode = .viewer
    }
    inspectorPanel = inspectorPanel == panel ? nil : panel
  }

  func openMap(_ service: MapService) {
    guard let location = currentMetadata?.location,
      let url = location.mapURL(for: service)
    else {
      return
    }

    if !NSWorkspace.shared.open(url) {
      alert = ViewerAlert(
        title: L10n.text("지도를 열 수 없음"),
        message: L10n.format(
          "%@를 여는 데 실패했습니다. 기본 브라우저 설정을 확인해 주세요.",
          service.title
        )
      )
    }
  }

  /// i 패널의 편집값을 원본 파일에 기록하고 목록·캐시·메타데이터를 한 번에 갱신합니다.
  func saveMetadataEdits(
    _ draft: ImageMetadataEditDraft,
    replacing originalDraft: ImageMetadataEditDraft
  ) async throws {
    guard let asset = currentAsset else {
      throw ImageMetadataWriterError.noCurrentImage
    }

    guard !asset.isReadOnly else { throw LibraryAccessError.readOnlyArchive }
    let sourceURL = asset.url
    let update = try draft.validated(for: sourceURL)
    let original = try originalDraft.validated(for: sourceURL)
    isSavingMetadata = true
    defer { isSavingMetadata = false }

    let destinationURL = try await metadataWriter.apply(
      update,
      replacing: original,
      to: sourceURL
    )

    if sourceURL != destinationURL,
      let existingAdjustments = adjustments.removeValue(forKey: sourceURL)
    {
      adjustments[destinationURL] = existingAdjustments
    }

    // 같은 URL의 소스·렌더·Quick Look 결과가 남지 않도록 저장 직후 모두 비웁니다.
    await pipeline.purgeCaches()
    await thumbnailPipeline.purgeCache()

    let refreshedAssets = try await library.scan(
      folder: destinationURL.deletingLastPathComponent()
    )
    guard refreshedAssets.contains(where: {
      $0.url.standardizedFileURL == destinationURL.standardizedFileURL
    }) else {
      throw ImageMetadataWriterError.sourceUnavailable(destinationURL)
    }

    let queried = try await queryAssets(refreshedAssets, options: libraryQuery)
    allAssets = queried.all
    assets = queried.visible
    sourceLocations = sourceLocations.map { location in
      location.url.standardizedFileURL == sourceURL.standardizedFileURL
        ? SessionLocation(url: destinationURL) : location
    }
    let visibleIndex = assets.firstIndex { $0.url.standardizedFileURL == destinationURL.standardizedFileURL } ?? 0
    pageStartIndex = visibleIndex
    currentIndex = visibleIndex
    queryFocusID = currentAsset?.sessionID
    selectedURLs = [destinationURL]
    selectionAnchor = assets.isEmpty ? nil : visibleIndex
    refreshMetadata()
    prefetchAroundCurrentPosition()
    showStatus(L10n.format("%@ 정보 저장 완료", destinationURL.lastPathComponent))
  }

  /// Shared keyboard routing keeps explicit shortcuts ahead of convenience gestures.
  func handleViewerKeyDown(_ event: NSEvent, shortcuts: ShortcutStore) -> Bool {
    guard batchSheet == nil, !isBatchBusy, wallpaperRequest == nil,
      !isSettingWallpaper, !showsAIUpscaling else { return false }
    if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      event.charactersIgnoringModifiers?.lowercased() == "a" {
      selectAllAssets()
      return true
    }
    if event.keyCode == 53 { return handleEscapeKey() }
    if let action = shortcuts.action(matching: event) {
      perform(action)
      return true
    }
    return event.keyCode == 49 && canPan && panInteractionMode == .spacePrimaryDrag
      && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
  }

  var canToggleImageFocus: Bool {
    presentationMode == .viewer && currentAsset != nil && !isLoading && !isFiltering
      && batchSheet == nil && !isBatchBusy && !isExporting && !isSavingMetadata
      && wallpaperRequest == nil && !isSettingWallpaper && !showsAIUpscaling && alert == nil
  }

  func toggleImageFocus(on asset: ImageAsset? = nil) {
    guard canToggleImageFocus else { return }
    if let asset, asset.id != currentAsset?.id {
      guard assets.contains(where: { $0.id == asset.id }) else { return }
      select(asset: asset)
    }
    toggleFocusMode()
  }

  func toggleFocusMode() {
    isFocusMode.toggle()
    if isFocusMode {
      presentationMode = .viewer
    }
  }

  /// 집중 모드의 숨겨진 툴바에 의존하지 않고 일반 뷰어로 복귀합니다.
  func exitFocusMode() {
    isFocusMode = false
  }

  // MARK: - 전자 앨범

  var canStartSlideshow: Bool {
    presentationMode != .folderComparison && assets.count > 1 && !isLoading && batchSheet == nil && !isBatchBusy && !isExporting
      && !isSavingMetadata && wallpaperRequest == nil && !isSettingWallpaper && alert == nil
  }

  func toggleSlideshow() {
    if isSlideshowPlaying { pauseSlideshow(); return }
    guard canStartSlideshow else { return }
    setComparisonLayout(.off)
    presentationMode = .viewer
    isFocusMode = true
    setImagesPerPage(1)
    pageStartIndex = currentIndex
    setFitToWindow()
    isSlideshowPlaying = true
    if managesSlideshowDisplaySleep { slideshowActivity = SlideshowDisplayActivity() }
    restartSlideshowCountdown()
  }

  func pauseSlideshow() {
    isSlideshowPlaying = false
    invalidateSlideshowCountdown()
    slideshowActivity = nil
  }

  /// 이미지/미리보기 또는 오류 화면이 실제로 준비된 뒤 표시 시간을 셉니다.
  /// 애니메이션 프레임·정밀 재렌더마다 타이머가 다시 시작되지 않게 중복을 무시합니다.
  func slideshowAssetPresented(_ asset: ImageAsset) {
    guard currentAsset == asset, slideshowPresentedAsset != asset else { return }
    slideshowPresentedAsset = asset
    restartSlideshowCountdown()
  }

  private func invalidateSlideshowCountdown() {
    slideshowGeneration = UUID()
    slideshowTask?.cancel()
    slideshowTask = nil
  }

  private func restartSlideshowCountdown() {
    invalidateSlideshowCountdown()
    guard isSlideshowPlaying, isFocusMode, presentationMode == .viewer,
      let asset = currentAsset, slideshowPresentedAsset == asset else { return }
    let generation = slideshowGeneration
    let interval = slideshowInterval
    slideshowTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(interval)) }
      catch { return }
      guard !Task.isCancelled, let self, self.slideshowGeneration == generation else { return }
      self.advanceSlideshow()
    }
  }

  /// 한 번 깨어날 때 한 장만 넘깁니다. 느린 디코딩이나 잠자기 후 몰아서 넘기지 않습니다.
  func advanceSlideshow() {
    guard isSlideshowPlaying, isFocusMode, presentationMode == .viewer,
      canStartSlideshow, slideshowPresentedAsset == currentAsset else {
      pauseSlideshow()
      return
    }
    guard let next = SlideshowSettings.nextIndex(after: currentIndex, count: assets.count,
      repeats: slideshowRepeats) else {
      pauseSlideshow()
      showStatus(L10n.text("전자 앨범 재생 완료"))
      return
    }
    select(index: next)
  }

  // MARK: - 바탕화면

  var canSetWallpaper: Bool {
    presentationMode != .folderComparison && currentAsset != nil && !isLoading && !isBatchBusy && !isExporting && !isSavingMetadata
      && batchSheet == nil && wallpaperRequest == nil && !isSettingWallpaper
  }

  func presentWallpaperSettings() {
    guard canSetWallpaper, let asset = currentAsset else { return }
    let displays = wallpaperService.displays
    guard let screenID = (NSApp.keyWindow?.screen ?? NSScreen.main)
      .flatMap(WorkspaceWallpaperClient.displayID), displays.contains(where: { $0.id == screenID }) else {
      show(error: WallpaperError.displayUnavailable, title: L10n.text("바탕화면을 설정할 수 없음"))
      return
    }
    wallpaperRequest = WallpaperRequest(asset: asset, adjustments: currentAdjustments,
      displays: displays, currentDisplayID: screenID)
  }

  func applyWallpaper(_ request: WallpaperRequest, displayIDs: Set<UInt32>,
    scaling: WallpaperScaling, appliesAdjustments: Bool) async {
    guard !isSettingWallpaper, wallpaperRequest?.id == request.id else { return }
    pauseSlideshow()
    isSettingWallpaper = true
    defer { isSettingWallpaper = false }
    do {
      let result = try await wallpaperService.apply(request: request, displayIDs: displayIDs,
        scaling: scaling, appliesAdjustments: appliesAdjustments)
      wallpaperRequest = nil
      if result.failures.isEmpty {
        showStatus(L10n.format("%d개 화면의 바탕화면 설정 완료", result.appliedCount))
      } else {
        alert = ViewerAlert(title: L10n.text("바탕화면 설정 결과"),
          message: L10n.format("%d개 화면에 적용했습니다.\n%@", result.appliedCount,
            result.failures.joined(separator: "\n")))
      }
    } catch {
      wallpaperRequest = nil
      show(error: error, title: L10n.text("바탕화면을 설정할 수 없음"))
    }
  }

  /// Esc는 확대 비교, 집중 모드, 일반 뷰어 순서로 한 단계씩 이전 보기로 이동합니다.
  @discardableResult
  func handleEscapeKey() -> Bool {
    if presentationMode == .folderComparison {
      presentationMode = comparisonReturnMode
      return true
    }
    if let session = overviewSelectionSession {
      cancelOverviewSelection(session.id)
      return true
    }
    if presentationMode == .viewer, comparisonLayout != .off {
      setComparisonLayout(.off)
      return true
    }
    if isFocusMode {
      exitFocusMode()
      return true
    }
    if presentationMode == .viewer {
      returnToOverview()
      return true
    }
    return false
  }

  func toggleFullScreen() {
    NSApp.keyWindow?.toggleFullScreen(nil)
  }

  func toggleFolderComparison() {
    guard batchSheet == nil, !isBatchBusy, wallpaperRequest == nil, !isSettingWallpaper else { return }
    if presentationMode == .folderComparison { presentationMode = comparisonReturnMode }
    else { presentationMode = .folderComparison }
  }

  func perform(_ action: ShortcutAction) {
    guard batchSheet == nil, !isBatchBusy, overviewSelectionSession == nil,
      wallpaperRequest == nil, !isSettingWallpaper else { return }
    // 비교 화면에서 내보내기/편집 같은 명령이 뒤에 보존된 일반 폴더를 건드리지 않게 합니다.
    if presentationMode == .folderComparison {
      let allowed: Set<ShortcutAction> = [.previousPage, .nextPage, .zoomIn, .zoomOut,
        .fitToWindow, .actualPixels, .openFolder, .toggleOverview, .toggleFolderComparison,
        .previousFirstFolder, .nextFirstFolder, .previousSecondFolder, .nextSecondFolder,
        .toggleAntialiasing, .panPrimaryDrag, .panSpaceDrag, .panSecondaryDrag, .panMiddleDrag, .panTrackpadScroll]
      guard allowed.contains(action) else { return }
    }
    switch action {
    case .previousPage: navigatePage(-1)
    case .nextPage: navigatePage(1)
    case .zoomIn: zoomIn()
    case .zoomOut: zoomOut()
    case .fitToWindow: setFitToWindow()
    case .actualPixels: setActualPixels()
    case .toggleOverview: toggleOverview()
    case .toggleFocus: toggleFocusMode()
    case .fewerImages: setImagesPerPage(imagesPerPage - 1)
    case .moreImages: setImagesPerPage(imagesPerPage + 1)
    case .openFolder: chooseFolder()
    case .exportImage: exportCurrentImage()
    case .toggleSlideshow: toggleSlideshow()
    case .setWallpaper: presentWallpaperSettings()
    case .toggleFolderComparison: toggleFolderComparison()
    case .previousFirstFolder:
      if presentationMode == .folderComparison { folderComparison.navigate(.first, direction: -1) }
    case .nextFirstFolder:
      if presentationMode == .folderComparison { folderComparison.navigate(.first, direction: 1) }
    case .previousSecondFolder:
      if presentationMode == .folderComparison { folderComparison.navigate(.second, direction: -1) }
    case .nextSecondFolder:
      if presentationMode == .folderComparison { folderComparison.navigate(.second, direction: 1) }
    case .panPrimaryDrag: panInteractionMode = .primaryDrag
    case .panSpaceDrag: panInteractionMode = .spacePrimaryDrag
    case .panSecondaryDrag: panInteractionMode = .secondaryDrag
    case .panMiddleDrag: panInteractionMode = .middleDrag
    case .panTrackpadScroll: panInteractionMode = .trackpadScroll
    case .toggleAntialiasing: isAntialiasingEnabled.toggle()
    case .compareSideBySide: setComparisonLayout(.sideBySide)
    case .compareStacked: setComparisonLayout(.stacked)
    case .endMagnificationComparison: setComparisonLayout(.off)
    }
  }

  func exportCurrentImage() {
    guard let asset = currentAsset, batchSheet == nil, !isBatchBusy, !isSavingMetadata,
      !isExporting else { return }
    pauseSlideshow()

    let selectedFormat =
      ExportFormat.available.contains(exportFormat)
      ? exportFormat
      : (ExportFormat.available.first ?? .jpeg)
    let panel = NSSavePanel()
    panel.title = L10n.text("이미지 내보내기")
    panel.prompt = L10n.text("저장")
    panel.canCreateDirectories = true
    panel.nameFieldStringValue =
      asset.url.deletingPathExtension().lastPathComponent
      + "-edited." + selectedFormat.fileExtension
    if let type = UTType(selectedFormat.typeIdentifier) {
      panel.allowedContentTypes = [type]
    }

    guard panel.runModal() == .OK, let destination = panel.url else { return }
    isExporting = true

    Task { [weak self] in
      guard let self else { return }
      do {
        try await exporter.export(
          sourceURL: asset.url,
          destinationURL: destination,
          format: selectedFormat,
          quality: exportQuality,
          adjustments: adjustments(for: asset)
        )
        isExporting = false
        showStatus(L10n.format("%@ 저장 완료", destination.lastPathComponent))
      } catch {
        isExporting = false
        show(error: error, title: L10n.text("내보내기 실패"))
      }
    }
  }

  func purgeCaches() {
    Task {
      await pipeline.purgeCaches()
      await thumbnailPipeline.purgeCache()
    }
  }

  // MARK: - Search, sorting and format selection

  var hasLibraryQuery: Bool { libraryQuery != LibraryQuery() }

  func resetLibraryQuery() { libraryQuery = LibraryQuery() }

  private func cancelQuery() {
    queryGeneration = UUID()
    queryTask?.cancel()
    queryTask = nil
    isFiltering = false
  }

  private func queryAssets(_ source: [ImageAsset], options: LibraryQuery) async throws
    -> (all: [ImageAsset], visible: [ImageAsset])
  {
    var enriched = source
    switch options.sort {
    case .northToSouth, .southToNorth, .eastToWest, .westToEast:
      enriched = try await library.enrichLocations(source)
    default: break
    }
    try Task.checkCancellation()
    let inputs = enriched
    let work = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      return try RustImageEngine.query(inputs, options: options)
    }
    let visible = try await withTaskCancellationHandler {
      try await work.value
    } onCancel: { work.cancel() }
    try Task.checkCancellation()
    return (enriched, visible)
  }

  private func applyLibraryQuery() {
    cancelQuery()
    // A pending open applies the latest options before committing its new collection.
    guard !isLoading, !isRestoringSession else { return }
    let generation = queryGeneration
    let options = libraryQuery
    let source = allAssets
    isFiltering = true
    queryTask = Task { [weak self] in
      guard let self else { return }
      do {
        // Collapse a burst of keystrokes without starting metadata scans for each letter.
        try await Task.sleep(for: .milliseconds(100))
        let result = try await queryAssets(source, options: options)
        guard !Task.isCancelled, queryGeneration == generation else { return }
        let oldID = currentAsset?.sessionID
        let previousFocus = queryFocusID ?? oldID
        let previousSelected = selectedURLs
        allAssets = result.all
        assets = result.visible
        currentIndex = assets.firstIndex { $0.sessionID == previousFocus } ?? 0
        pageStartIndex = currentIndex
        selectedURLs = previousSelected.intersection(Set(assets.map(\.url)))
        selectionAnchor = assets.firstIndex { selectedURLs.contains($0.url) }
        if currentAsset?.sessionID != oldID { resetViewport() }
        isFiltering = false
        refreshMetadata()
        prefetchAroundCurrentPosition()
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, queryGeneration == generation else { return }
        isFiltering = false
        show(error: error, title: L10n.text("이미지 목록을 정리할 수 없음"))
      }
    }
  }

  // MARK: - Favorite folders

  func isFavoriteFolder(_ url: URL) -> Bool {
    favoriteFolders.contains { $0.location.url.standardizedFileURL == url.standardizedFileURL }
  }

  func toggleFavoriteFolder(_ url: URL) {
    guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
    if let index = favoriteFolders.firstIndex(where: {
      $0.location.url.standardizedFileURL == url.standardizedFileURL
    }) {
      removeFavoriteFolder(favoriteFolders[index].id)
    } else {
      favoriteFolders.append(FavoriteFolder(location: SessionLocation(url: url)))
      sessionPersistence.saveFavorites(favoriteFolders)
    }
  }

  func removeFavoriteFolder(_ id: UUID) {
    favoriteFolders.removeAll { $0.id == id }
    favoriteAccess.removeValue(forKey: id)
    sessionPersistence.saveFavorites(favoriteFolders)
  }

  func openFavoriteFolder(_ favorite: FavoriteFolder) {
    guard canOpenFolderFromTree else { return }
    do {
      let url = try favorite.location.resolve()
      let access = ImageLibraryAccess([url])
      guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
        throw CocoaError(.fileNoSuchFile)
      }
      // Keep this grant alive through async directory reads and any retained comparison pane.
      favoriteAccess[favorite.id] = access
      if let index = favoriteFolders.firstIndex(where: { $0.id == favorite.id }) {
        favoriteFolders[index].location = SessionLocation(url: url)
        sessionPersistence.saveFavorites(favoriteFolders)
      }
      openFolderFromTree(url)
    } catch {
      show(error: error, title: L10n.text("즐겨찾는 폴더를 열 수 없음"))
    }
  }

  // MARK: - Last session

  private func invalidateSessionRestore() {
    restoreGeneration = UUID()
    folderComparison.cancelSessionRestore()
  }

  private func scheduleSessionSave() {
    guard !isRestoringSession else { return }
    sessionSaveTask?.cancel()
    sessionSaveTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
      self?.saveSessionNow()
    }
  }

  func saveSessionNow() {
    sessionSaveTask?.cancel()
    sessionSaveTask = nil
    guard !isRestoringSession, !isLoading, !isFiltering else { return }
    let comparison = folderComparison.captureSession()
    // Empty panes may briefly publish a background matching update at startup. They
    // must not prevent an unrelated viewer session from being saved on close.
    if comparison != nil {
      guard !folderComparison.first.isLoading, !folderComparison.second.isLoading,
        !folderComparison.first.isFiltering, !folderComparison.second.isFiltering,
        !folderComparison.isMatching else { return }
    }
    guard !sourceLocations.isEmpty || comparison != nil else { return }
    sessionPersistence.save(ViewerSession(
      sources: sourceLocations,
      selectedID: queryFocusID ?? currentAsset?.sessionID,
      selectedIDs: Set(assets.filter { selectedURLs.contains($0.url) }.map(\.sessionID)),
      presentationMode: presentationMode.rawValue,
      returnMode: comparisonReturnMode.rawValue,
      zoom: Double(zoom), panX: Double(panOffset.width), panY: Double(panOffset.height),
      actualPixels: baseScaleMode == .actualPixels, imagesPerPage: imagesPerPage,
      query: libraryQuery, comparison: comparison))
  }

  /// Explicit startup only: tests and newly constructed stores do not restore global state.
  func restoreLastSession() async {
    guard !didAttemptSessionRestore else { return }
    didAttemptSessionRestore = true
    guard sourceLocations.isEmpty, assets.isEmpty, !isLoading,
      presentationMode == .viewer, let session = sessionPersistence.loadSession() else { return }
    sessionSaveTask?.cancel()
    cancelQuery()
    isRestoringSession = true
    let generation = restoreGeneration
    let startingQueryRevision = libraryQueryRevision
    var appliedQuery: LibraryQuery?
    defer {
      isApplyingSession = false
      isRestoringSession = false
      // Comparison restoration also suspends. Do not lose typing or sorting changes
      // received after the ordinary collection was committed but before A/B is ready.
      if restoreGeneration == generation, !Task.isCancelled,
        let appliedQuery, libraryQuery != appliedQuery {
        applyLibraryQuery()
      }
    }
    if !session.sources.isEmpty {
      do {
        let urls = try session.sources.map { try $0.resolve() }
        let restoredAccess = ImageLibraryAccess(urls)
        let opened = try await library.open(urls: urls, allowsEmptyFolder: true)
        // Once the user changes search/sort/filter, that choice outranks the saved query.
        var options = libraryQueryRevision == startingQueryRevision ? session.query : libraryQuery
        var result = try await queryAssets(opened.assets, options: options)
        while options != (libraryQueryRevision == startingQueryRevision ? session.query : libraryQuery) {
          try Task.checkCancellation()
          options = libraryQuery
          result = try await queryAssets(result.all, options: options)
        }
        guard !Task.isCancelled, restoreGeneration == generation else { return }
        isApplyingSession = true
        libraryAccess = [restoredAccess] + opened.access
        sourceLocations = urls.map { SessionLocation(url: $0) }
        currentFolderURL = opened.folderURL?.standardizedFileURL
        libraryQuery = options
        allAssets = result.all
        let focused = result.visible.first { $0.sessionID == session.selectedID }?.url
        let mode = PresentationMode(rawValue: session.presentationMode) == .overview
          ? PresentationMode.overview : .viewer
        applyLoadedAssets(result.visible, focusing: focused, mode: mode)
        queryFocusID = session.selectedID ?? currentAsset?.sessionID
        selectedURLs = Set(assets.filter { session.selectedIDs.contains($0.sessionID) }.map(\.url))
        imagesPerPage = min(10, max(1, session.imagesPerPage))
        baseScaleMode = session.actualPixels ? .actualPixels : .fit
        zoom = session.zoom.isFinite ? min(16, max(0.1, session.zoom)) : 1
        panOffset = CGSize(width: session.panX.isFinite ? session.panX : 0,
          height: session.panY.isFinite ? session.panY : 0)
        appliedQuery = options
        isApplyingSession = false
      } catch is CancellationError {
        return
      } catch {
        // The ordinary folder may be on a missing volume while both comparison
        // folders are still available. Keep restoring those independent sources.
        guard !Task.isCancelled, restoreGeneration == generation else { return }
        showStatus(L10n.text("이전 보기를 복원하지 못했습니다. 열기에서 폴더를 다시 선택하세요."))
      }
    }
    guard !Task.isCancelled, restoreGeneration == generation else { return }
    if let comparison = session.comparison {
      await folderComparison.restoreSession(comparison)
    }
    guard !Task.isCancelled, restoreGeneration == generation else { return }
    isApplyingSession = true
    comparisonReturnMode = PresentationMode(rawValue: session.returnMode) == .overview ? .overview : .viewer
    if session.presentationMode == PresentationMode.folderComparison.rawValue,
      !folderComparison.first.assets.isEmpty || !folderComparison.second.assets.isEmpty {
      presentationMode = .folderComparison
      comparisonReturnMode = PresentationMode(rawValue: session.returnMode) == .overview ? .overview : .viewer
    }
  }

  private func cancelLibraryLoad() {
    loadGeneration = UUID()
    loadTask?.cancel()
    loadTask = nil
    isLoading = false
  }

  private func load(folder: URL, fromTree: Bool = false) {
    load(urls: [folder], fromTree: fromTree)
  }

  private func load(urls: [URL], fromTree: Bool = false) {
    invalidateSessionRestore()
    cancelQuery()
    cancelLibraryLoad()
    let generation = loadGeneration
    prefetchTask?.cancel()
    metadataTask?.cancel()
    isLoading = true
    let destinationMode: PresentationMode = fromTree && presentationMode == .overview ? .overview : .viewer

    loadTask = Task { [weak self, library] in
      do {
        let opened = try await library.open(urls: urls, allowsEmptyFolder: fromTree)
        try Task.checkCancellation()
        guard let self, self.loadGeneration == generation else { return }
        var options = self.libraryQuery
        var queried = try await self.queryAssets(opened.assets, options: options)
        while options != self.libraryQuery {
          try Task.checkCancellation()
          options = self.libraryQuery
          queried = try await self.queryAssets(queried.all, options: options)
        }
        try Task.checkCancellation()
        guard self.loadGeneration == generation else { return }
        self.libraryAccess = opened.access
        self.sourceLocations = urls.map { SessionLocation(url: $0) }
        self.currentFolderURL = opened.folderURL?.standardizedFileURL
        self.allAssets = queried.all
        self.applyLoadedAssets(queried.visible, focusing: opened.focusedURL, mode: destinationMode)
      } catch is CancellationError {
        // 사용자가 다른 폴더를 열었을 때 이전 스캔의 결과는 조용히 폐기합니다.
      } catch {
        guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
        self.isLoading = false
        self.show(error: error, title: L10n.text("이미지를 열 수 없음"))
      }
    }
  }

  private func applyLoadedAssets(_ newAssets: [ImageAsset], focusing selectedURL: URL?, mode: PresentationMode = .viewer) {
    metadataTask?.cancel()
    prefetchTask?.cancel()
    assets = newAssets
    let focusedIndex =
      selectedURL.flatMap { selected in
        newAssets.firstIndex(where: { $0.url.standardizedFileURL == selected.standardizedFileURL })
      } ?? 0
    pageStartIndex = focusedIndex
    currentIndex = focusedIndex
    queryFocusID = currentAsset?.sessionID
    selectedURLs = newAssets.indices.contains(focusedIndex) ? [newAssets[focusedIndex].url] : []
    selectionAnchor = newAssets.isEmpty ? nil : focusedIndex
    isLoading = false
    presentationMode = mode
    resetViewport()
    refreshMetadata()
    prefetchAroundCurrentPosition()
  }

  private func resetViewport() {
    zoom = 1
    panOffset = .zero
  }

  private func refreshMetadata() {
    metadataTask?.cancel()
    currentMetadata = nil
    guard let url = currentAsset?.url else { return }

    metadataTask = Task { [weak self] in
      guard let self else { return }
      let metadata = try? await pipeline.metadata(for: url)
      guard !Task.isCancelled, currentAsset?.url == url else { return }
      currentMetadata = metadata
    }
  }

  /// 실제 타일과 같은 미리보기 크기를 써 다음 페이지가 캐시를 그대로 사용하게 합니다.
  func updateViewerPrefetchSize(_ pixelSize: Int) {
    let normalized = ImageLoadingPolicy.previewPixels(
      for: ImageLoadingPolicy.pixelBucket(pixelSize))
    guard normalized != viewerPrefetchPixels else { return }
    viewerPrefetchPixels = normalized
    prefetchAroundCurrentPosition()
  }

  private func prefetchAroundCurrentPosition() {
    prefetchTask?.cancel()
    prefetchTask = nil
    guard presentationMode == .viewer, !assets.isEmpty, !isLoading else { return }
    let pageStart = min(assets.count, max(0, pageStartIndex))
    let pageCount = min(10, max(1, imagesPerPage))
    let visibleEnd = min(assets.count, pageStart + pageCount)
    let nextEnd = min(assets.count, visibleEnd + pageCount)
    let nextAssets = Array(assets[visibleEnd..<nextEnd])
    let previousCount = min(2, 10 - nextAssets.count)
    let previousStart = max(0, pageStart - previousCount)
    // 다음 페이지를 먼저 준비하고, 여유가 있을 때만 직전 이미지도 준비합니다.
    let nearbyAssets = nextAssets + Array(assets[previousStart..<pageStart].reversed())
    guard !nearbyAssets.isEmpty else { return }
    let pixels = viewerPrefetchPixels

    prefetchTask = Task(priority: .background) { [thumbnailPipeline] in
      // 파이프라인의 모드·저장장치별 대기 중 취소되어 마지막 페이지의 이웃만 읽습니다.
      await thumbnailPipeline.prefetch(assets: nearbyAssets, maxPixelSize: pixels)
    }
  }

  private func show(error: Error, title: String) {
    alert = ViewerAlert(
      title: title,
      message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    )
  }

  private func showStatus(_ message: String) {
    statusMessage = message
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(2.5))
      if self?.statusMessage == message {
        self?.statusMessage = nil
      }
    }
  }
}
