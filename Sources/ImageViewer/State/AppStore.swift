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
  case rename, export, watermark, fileOperation
  var id: Self { self }
}

/// 앱의 탐색 상태와 비파괴 편집 상태를 소유하는 메인 액터 모델입니다.
@MainActor
final class AppStore: ObservableObject {
  @Published private(set) var showsHome = true
  let videoGridPlayback = VideoGridPlaybackState()
  let frameLayout: ViewerFrameLayoutStore
  let recentPhotos: RecentPhotoStore
  private var recentPreviewTasks: [String: Task<Void, Never>] = [:]
  private var recentPreviewGenerations: [String: UUID] = [:]
  private var recentActivityGeneration = UUID()
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
  @Published private(set) var mapAssets: [ImageAsset] = []
  @Published private(set) var mapCollectionID = UUID()
  // View changes destroy the native map; retain its camera for this collection.
  // Panning deliberately does not publish a change to every image view.
  private(set) var photoMapViewport = PhotoMapViewportState()
  var overviewColumnCount = 1
  var viewerColumnCount = 1
  var viewerViewportSize: CGSize?
  @Published private(set) var isIndexingLocations = false
  @Published private(set) var locationScanCount = 0
  private var locationScanGeneration = UUID()
  @Published var libraryQuery = LibraryQuery() {
    didSet {
      guard oldValue != libraryQuery, !isApplyingSession else { return }
      libraryQueryRevision &+= 1
      applyLibraryQuery()
    }
  }
  @Published private(set) var isFiltering = false
  @Published var showsVideos: Bool {
    didSet {
      guard oldValue != showsVideos else { return }
      preferences.set(showsVideos, forKey: Self.showsVideosDefaultsKey)
      applyLibraryQuery()
    }
  }
  @Published private(set) var videoFullScreenController: VideoFullScreenController?
  var isVideoFullScreenPresented: Bool { videoFullScreenController != nil }

  @Published var motionMediaAsset: ImageAsset? {
    didSet { if motionMediaAsset != nil { pauseSlideshow() } }
  }
  @Published private(set) var favoriteFolders: [FavoriteFolder] = []
  @Published var showsAIUpscaling = false
  @Published var isPhotoMarking = false {
    didSet {
      folderComparison.isPhotoMarking = isPhotoMarking
      if isPhotoMarking { pauseSlideshow() }
      else if oldValue && photoMarkFilter.isActive { applyLibraryQuery() }
    }
  }
  // Visible slots retain identity only, without image pixels or archive leases.
  var tracksViewerPresentation = false
  var viewerPresentedAssets: [Int: PresentedAssetVersion] = [:]
  @Published var showsPhotoMarkEditor = false {
    didSet { if showsPhotoMarkEditor { pauseSlideshow() } }
  }
  @Published var showsPhotoMarkTrackingReport = false {
    didSet { if showsPhotoMarkTrackingReport { pauseSlideshow() } }
  }
  @Published var photoMarkFilter = PhotoMarkFilter() {
    didSet {
      guard oldValue != photoMarkFilter else { return }
      applyLibraryQuery()
    }
  }
  @Published private(set) var libraryRevision = UUID()
  @Published private(set) var currentFolderURL: URL?
  @Published var showsFolderTree: Bool {
    didSet { preferences.set(showsFolderTree, forKey: Self.folderTreeDefaultsKey) }
  }
  @Published private(set) var overviewSelectionSession: OverviewSelectionSession?
  @Published private(set) var selectedURLs: Set<URL> = []
  @Published var batchSheet: BatchSheet? {
    didSet {
      if batchSheet != nil { pauseSlideshow() }
      else { explicitBatchAssets = nil; fileOperationRequest = nil }
    }
  }
  @Published private(set) var fileOperationRequest: BatchFileOperationRequest?
  @Published private(set) var isManagingFiles = false
  private var explicitBatchAssets: [ImageAsset]?
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
        updateSlideshowVideoPlayback()
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
        frameLayout.isEditing = false
        pauseSlideshow()
        slideshowPresentedAsset = nil
        isFocusMode = false
      }
      normalizeMultiImageScale()
      prefetchAroundCurrentPosition()
      if presentationMode == .map { applyLibraryQuery() }
    }
  }
  @Published var baseScaleMode: BaseScaleMode = .fit {
    didSet { if oldValue != baseScaleMode { viewerPan.clearGeometry() } }
  }
  @Published var imagesPerPage = 1 {
    didSet {
      if oldValue != imagesPerPage { frameLayout.isEditing = false }
      normalizeMultiImageScale()
    }
  }
  @Published var thumbnailSize: CGFloat {
    didSet {
      let normalized = OverviewThumbnailSizing.normalized(thumbnailSize)
      if thumbnailSize != normalized {
        thumbnailSize = normalized
      }
      preferences.set(Double(normalized), forKey: Self.thumbnailSizeDefaultsKey)
    }
  }
  @Published var zoom: CGFloat = 1 {
    didSet { viewerPan.setZoom(zoom) }
  }
  @Published var showsOverviewNumbers: Bool {
    didSet { preferences.set(showsOverviewNumbers, forKey: Self.overviewNumbersDefaultsKey) }
  }
  let viewerPan = ViewerPanState()
  var panOffset: CGSize {
    get { viewerPan.offset }
    set { viewerPan.setOffset(newValue) }
  }
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
  /// Each video play-through has its own identity so late player events cannot
  /// advance a different clip, or the next repeat of the same clip.
  @Published private(set) var slideshowVideoPlaybackID: UUID?
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
  let photoMarks: PhotoMarkStore
  let photoMarkPreferences: PhotoMarkPreferences
  let folderTree = FolderTreeStore()
  private var comparisonReturnMode: PresentationMode = .viewer

  private let preferences: UserDefaults
  private let sessionPersistence: ViewerSessionPersistence
  private var sessionSubscriptions: Set<AnyCancellable> = []
  private var sessionSaveTask: Task<Void, Never>?
  private var restoreGeneration = UUID()
  private var didAttemptSessionRestore = false
  @Published private(set) var isRestoringSession = false
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
  private let batchFileOperator: BatchFileOperator
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
  private static let showsVideosDefaultsKey = "ImageViewer.ShowsVideos.v1"
  private static let folderTreeDefaultsKey = "ImageViewer.ShowsFolderTree.v1"
  private static let thumbnailSizeDefaultsKey = "ImageViewer.OverviewThumbnailSize.v1"
  private static let overviewNumbersDefaultsKey = "ImageViewer.ShowsOverviewNumbers.v1"
  private static let panModeDefaultsKey = "ImageViewer.PanInteractionMode.v1"
  private static let filenameDisplaySizeDefaultsKey = "ImageViewer.FilenameDisplaySize.v1"
  private static let imageLoadingModeDefaultsKey = "ImageViewer.ImageLoadingMode.v1"
  private static let imageInterpolationModeDefaultsKey = "ImageViewer.ImageInterpolationMode.v1"
  private static let slideshowIntervalDefaultsKey = "ImageViewer.SlideshowInterval.v1"
  private static let slideshowRepeatsDefaultsKey = "ImageViewer.SlideshowRepeats.v1"

  init(defaults: UserDefaults = .standard, monitorsSystemResources: Bool = true,
    photoMarkDatabaseURL: URL? = nil, batchFileOperator: BatchFileOperator = BatchFileOperator()) {
    self.batchFileOperator = batchFileOperator
    preferences = defaults
    frameLayout = ViewerFrameLayoutStore(defaults: defaults)
    recentPhotos = RecentPhotoStore(defaults: defaults)
    showsVideos = defaults.object(forKey: Self.showsVideosDefaultsKey) as? Bool ?? true
    photoMarks = PhotoMarkStore(databaseURL: photoMarkDatabaseURL,
      inMemory: photoMarkDatabaseURL == nil && defaults !== UserDefaults.standard)
    photoMarkPreferences = PhotoMarkPreferences(defaults: defaults)
    sessionPersistence = ViewerSessionPersistence(defaults: defaults)
    favoriteFolders = sessionPersistence.loadFavorites()
    showsFolderTree = defaults.bool(forKey: Self.folderTreeDefaultsKey)
    folderComparison = FolderComparisonStore(defaults: defaults, photoMarks: photoMarks)
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
    viewerPan.objectWillChange.sink { [weak self] in self?.scheduleSessionSave() }
      .store(in: &sessionSubscriptions)
    folderComparison.objectWillChange.sink { [weak self] in
      self?.scheduleSessionSave()
      if self?.isPhotoMarking == true { self?.objectWillChange.send() }
    }
      .store(in: &sessionSubscriptions)
    for pane in [folderComparison.first, folderComparison.second] {
      pane.onCollectionOpened = { [weak self] opened, urls in
        self?.recordRecentFolders(opened: opened, sourceURLs: urls)
      }
      // Persist committed transforms without invalidating the root view, marks,
      // or filmstrips for each pointer delta. Live gestures are saved on commit.
      pane.viewport.objectWillChange.sink { [weak self] in self?.scheduleSessionSave() }
        .store(in: &sessionSubscriptions)
    }
    photoMarks.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
      .store(in: &sessionSubscriptions)
    photoMarks.$revision.dropFirst().sink { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.photoMarkFilter.isActive, !self.isPhotoMarking else { return }
        self.applyLibraryQuery()
      }
    }
      .store(in: &sessionSubscriptions)
    photoMarks.$errorMessage.compactMap { $0 }.removeDuplicates().sink { [weak self] message in
      Task { @MainActor [weak self] in
        self?.alert = ViewerAlert(title: PhotoMarkL10n.text("error.title"), message: message)
      }
    }
      .store(in: &sessionSubscriptions)
    for pane in [folderComparison.first, folderComparison.second] {
      pane.$assets.sink { [weak self] assets in
        guard !assets.isEmpty else { return }
        Task { @MainActor [weak self] in
          guard let self else { return }
          await self.photoMarks.waitUntilReady()
          self.photoMarks.reconcileAssets(assets)
        }
      }.store(in: &sessionSubscriptions)
    }
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

  /// Freeze map targets separately from the thumbnail selection, including pins
  /// outside the geographic filter. Retaining assets also retains ZIP leases.
  var batchAssets: [ImageAsset] { explicitBatchAssets ?? selectedAssets }

  func batchTargets(urls: Set<URL>?) -> [ImageAsset] {
    guard let urls else { return selectedAssets }
    return mapAssets.filter { urls.contains($0.url) }
  }

  var isBatchBusy: Bool { isRenaming || isBatchExporting || isManagingFiles }

  var canStartBatchOperation: Bool {
    canStartBatchOperation(urls: nil)
  }

  func canStartBatchOperation(urls: Set<URL>?) -> Bool {
    presentationMode != .folderComparison && !batchTargets(urls: urls).isEmpty && !isLoading && !isFiltering && !isBatchBusy && !isSavingMetadata && !isExporting
      && batchSheet == nil && overviewSelectionSession == nil
      && wallpaperRequest == nil && !isSettingWallpaper && !showsPhotoMarkEditor
      && !showsPhotoMarkTrackingReport && !showsAIUpscaling && motionMediaAsset == nil
  }

  func canExportBatchImages(urls: Set<URL>? = nil) -> Bool {
    canStartBatchOperation(urls: urls) && !batchTargets(urls: urls).contains(where: \.isVideo)
  }

  var canOpenMotionMedia: Bool {
    guard let asset = currentAsset else { return false }
    return canStartBatchOperation(urls: [asset.url])
      && (asset.isVideo || (["gif", "png", "apng", "webp"].contains(asset.fileExtension)
        && (currentMetadata?.frameCount ?? 1) > 1))
  }

  func presentMotionMedia(_ asset: ImageAsset? = nil) {
    guard let target = asset ?? currentAsset,
      canStartBatchOperation(urls: [target.url]) else { return }
    motionMediaAsset = target
  }

  func selectForBatch(index: Int, modifiers: NSEvent.ModifierFlags) {
    guard motionMediaAsset == nil, assets.indices.contains(index), batchSheet == nil, !isBatchBusy,
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

  /// A context menu can outlive the list order that opened it. Resolve its file
  /// again, and never fall back to the previous selection if it has disappeared.
  func prepareBatchContextSelection(url: URL) -> Bool {
    guard canStartBatchOperation(urls: [url]),
      let index = assets.firstIndex(where: { $0.url == url }) else { return false }
    if !selectedURLs.contains(url) {
      selectForBatch(index: index, modifiers: [])
    }
    return true
  }

  func selectAllAssets() {
    guard motionMediaAsset == nil, batchSheet == nil, !isBatchBusy else { return }
    if let session = overviewSelectionSession { finishOverviewSelection(session.id) }
    selectedURLs = Set(assets.map(\.url))
    if selectionAnchor == nil { selectionAnchor = currentIndex }
  }

  func clearSelection() {
    guard motionMediaAsset == nil, batchSheet == nil, !isBatchBusy else { return }
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

  func presentBatchRename(urls: Set<URL>? = nil) {
    let targets = batchTargets(urls: urls)
    guard canStartBatchOperation(urls: urls), !targets.contains(where: \.isReadOnly) else { return }
    explicitBatchAssets = targets
    batchSheet = .rename
  }

  func presentBatchExport(urls: Set<URL>? = nil) {
    guard canExportBatchImages(urls: urls), !ExportFormat.available.isEmpty else { return }
    explicitBatchAssets = batchTargets(urls: urls)
    batchSheet = .export
  }

  func presentWatermark(urls: Set<URL>? = nil) {
    guard canExportBatchImages(urls: urls), !ExportFormat.available.isEmpty else { return }
    pauseSlideshow()
    explicitBatchAssets = batchTargets(urls: urls)
    batchSheet = .watermark
  }

  var savedWatermarkOptions: WatermarkOptions {
    guard let data = preferences.data(forKey: "ImageViewer.Watermark.v1"),
      let options = try? JSONDecoder().decode(WatermarkOptions.self, from: data)
    else { return .disabled }
    return options
  }

  func rememberWatermarkOptions(_ options: WatermarkOptions) {
    guard (try? options.validate()) != nil, let data = try? JSONEncoder().encode(options) else { return }
    preferences.set(data, forKey: "ImageViewer.Watermark.v1")
  }

  func shareSelectedFiles(urls: Set<URL>? = nil) {
    guard canStartBatchOperation(urls: urls) else { return }
    pauseSlideshow()
    let targets = batchTargets(urls: urls)
    FileSharingService.shared.share(urls: targets.map(\.url), retaining: targets)
  }

  func canPerformFileOperation(_ operation: BatchFileOperation, urls: Set<URL>? = nil) -> Bool {
    guard !showsHome, !isVideoFullScreenPresented,
      presentationMode == .viewer || presentationMode == .overview,
      canStartBatchOperation(urls: urls) else { return false }
    let targets = urls.map { urls in assets.filter { urls.contains($0.url) } } ?? selectedAssets
    guard !targets.isEmpty, urls == nil || targets.count == urls?.count else { return false }
    return operation == .copy || !targets.contains(where: \.isReadOnly)
  }

  func presentFileOperation(_ operation: BatchFileOperation, urls: Set<URL>? = nil) {
    guard canPerformFileOperation(operation, urls: urls) else { return }
    let targets = urls.map { urls in assets.filter { urls.contains($0.url) } } ?? selectedAssets
    fileOperationRequest = BatchFileOperationRequest(operation: operation, assets: targets)
    explicitBatchAssets = targets
    batchSheet = .fileOperation
    videoGridPlayback.pauseAll()
  }

  func performFileOperation(_ plan: BatchFileOperationPlan,
    progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> BatchFileOperationResult {
    let sources = Set(plan.entries.map { $0.sourceURL.standardizedFileURL })
    guard !isBatchBusy, batchSheet == .fileOperation, let request = fileOperationRequest,
      request.operation == plan.operation,
      sources == Set(request.assets.map { $0.url.standardizedFileURL }),
      sources.count == plan.entries.count,
      plan.operation == .copy || !request.assets.contains(where: \.isReadOnly) else {
      return BatchFileOperationResult(completed: [], failures: plan.entries.map {
        BatchFileOperationFailure(sourceURL: $0.sourceURL,
          message: FileOperationsL10n.text("error.selectionChanged"))
      }, wasCancelled: false)
    }
    isManagingFiles = true
    cancelQuery()
    prefetchTask?.cancel()
    metadataTask?.cancel()
    defer {
      isManagingFiles = false
      refreshMetadata()
      prefetchAroundCurrentPosition()
      scheduleSessionSave()
    }
    // Freeze inheritance for this operation. A settings change while copying
    // must not give different files in the same batch different policies.
    let preservesClassifications = plan.operation != .copy || photoMarkPreferences.inheritOnCopy
    if preservesClassifications {
      await photoMarks.waitUntilReady()
      // Finish capturing a just-added mark's file reference before moving or
      // trashing its source. That reference also permits later restoration.
      await photoMarks.flushAsync()
    }
    guard !preservesClassifications || photoMarks.isReady else {
      return BatchFileOperationResult(completed: [], failures: plan.entries.map {
        BatchFileOperationFailure(sourceURL: $0.sourceURL,
          message: photoMarks.errorMessage ?? PhotoMarkL10n.text("storage.error"))
      }, wasCancelled: false)
    }
    // Capture aliases before changing the disk. Foundation may standardize a
    // /private path differently once its last file no longer exists.
    let sourceAssets = Dictionary(request.assets.map { ($0.url.standardizedFileURL, $0) },
      uniquingKeysWith: { first, _ in first })
    let canonicalURLs = Dictionary(allAssets.map { ($0.url, $0.url.standardizedFileURL) },
      uniquingKeysWith: { first, _ in first })
    let canonicalLocations = Dictionary(sourceLocations.map { ($0.url, $0.url.standardizedFileURL) },
      uniquingKeysWith: { first, _ in first })
    let recentIDs = request.assets.map { (source: $0.url.standardizedFileURL, id: $0.sessionID) }
    let marks = preservesClassifications
      ? Dictionary(request.assets.map { ($0.url.standardizedFileURL, photoMarks.marks(for: $0)) },
        uniquingKeysWith: { first, _ in first }) : [:]
    let result = await batchFileOperator.execute(plan, progress: progress)
    // Cancelling a batch stops future files. Already committed files must still
    // be reconciled even though the caller's task is now cancelled.
    await Task {
      await reconcileFileOperation(result, request: request, marks: marks,
        preservesClassifications: preservesClassifications,
        sourceAssets: sourceAssets, canonicalURLs: canonicalURLs,
        canonicalLocations: canonicalLocations, recentIDs: recentIDs)
    }.value
    showStatus(FileOperationsL10n.format("status.completed", result.completed.count, result.failures.count))
    if preservesClassifications, !photoMarks.isReady {
      show(error: PhotoMarkPersistenceError(message: photoMarks.errorMessage ?? PhotoMarkL10n.text("storage.error")),
        title: PhotoMarkL10n.text("storage.error"))
    }
    return result
  }

  private func reconcileFileOperation(_ result: BatchFileOperationResult,
    request: BatchFileOperationRequest, marks: [URL: Set<PhotoMarkSlot>],
    preservesClassifications: Bool,
    sourceAssets: [URL: ImageAsset], canonicalURLs: [URL: URL],
    canonicalLocations: [URL: URL], recentIDs: [(source: URL, id: String)]) async {
    guard !result.completed.isEmpty else { return }
    let oldFocus = currentAsset?.url
    let oldIndex = currentIndex
    let completedSources = Set(result.completed.map(\.sourceURL))
    let removedURLs = Set(canonicalURLs.compactMap { completedSources.contains($0.value) ? $0.key : nil })
    var destinations: [ImageAsset] = []
    if request.operation != .trash {
      // A later file can fail after the destination disk disappears. Completed
      // entries carry their verified identity and bookmark, so reconciliation
      // never depends on rereading that disk before saving their classifications.
      let uncapturedURLs = result.completed.filter { $0.destinationAsset == nil }.compactMap(\.destinationURL)
      destinations = result.completed.compactMap(\.destinationAsset)
      if !uncapturedURLs.isEmpty {
        destinations += (try? await library.assets(from: uncapturedURLs, includesVideos: true)) ?? []
      }
      let byURL = Dictionary(destinations.map { ($0.url.standardizedFileURL, $0) },
        uniquingKeysWith: { first, _ in first })
      var markMapping: [String: String] = [:]
      for entry in result.completed where preservesClassifications {
        guard let source = sourceAssets[entry.sourceURL],
          let destinationURL = entry.destinationURL,
          let destination = byURL[destinationURL.standardizedFileURL] else { continue }
        if let reference = entry.destinationReference {
          await photoMarks.commitTransferredMarks(marks[entry.sourceURL] ?? [], from: source,
            to: destination, reference: reference, moving: request.operation == .move)
        } else if request.operation == .move {
          markMapping[source.photoMarkID] = destination.photoMarkID
        } else {
          photoMarks.inheritMarks(marks[entry.sourceURL] ?? [], for: destination)
        }
      }
      if !markMapping.isEmpty { photoMarks.remapAssets(markMapping) }
      await photoMarks.reconcileAssets(destinations)?.wait()
    }
    if request.operation != .copy {
      allAssets.removeAll { removedURLs.contains($0.url) }
      mapAssets.removeAll { removedURLs.contains($0.url) }
      assets.removeAll { removedURLs.contains($0.url) }
      selectedURLs.subtract(removedURLs)
      sourceLocations.removeAll { canonicalLocations[$0.url].map(completedSources.contains) ?? false }
      if sourceLocations.isEmpty, let currentFolderURL {
        sourceLocations = [SessionLocation(url: currentFolderURL)]
      }
      for url in removedURLs { adjustments.removeValue(forKey: url) }
      for recent in recentIDs where completedSources.contains(recent.source) { removeRecentPhoto(recent.id) }
      viewerPresentedAssets.removeAll()
      aiUpscaling.prepare(sourceURL: nil)
      videoGridPlayback.reset()
      await pipeline.purgeCaches()
      await thumbnailPipeline.purgeCache()
    } else if let folder = currentFolderURL {
      // A same-folder copy is immediately available, with the current filters
      // applied. Copying elsewhere leaves the source collection untouched.
      let existing = Set(allAssets.map { $0.url.standardizedFileURL })
      let additions = destinations.filter {
        $0.url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL
          && !existing.contains($0.url.standardizedFileURL)
      }
      if !additions.isEmpty {
        allAssets.append(contentsOf: additions)
        if let queried = try? await queryAssets(allAssets, options: libraryQuery) {
          allAssets = queried.all
          mapAssets = queried.map
          assets = queried.visible
        }
      }
    }
    currentIndex = assets.firstIndex { $0.url == oldFocus } ?? min(oldIndex, max(0, assets.count - 1))
    pageStartIndex = currentIndex
    queryFocusID = currentAsset?.sessionID
    selectedURLs.formIntersection(Set(assets.map(\.url)))
    if selectedURLs.isEmpty, let currentAsset { selectedURLs = [currentAsset.url] }
    selectionAnchor = assets.firstIndex { selectedURLs.contains($0.url) }
    if currentAsset?.url != oldFocus { resetViewport() }
  }

  func renameSelectedFiles(using plan: BatchRenamePlan) async throws {
    guard !isBatchBusy, !isLoading, !isSavingMetadata, !isExporting else { return }
    let recordWork = makeRecentWorkRecorder()
    let targets = Set(plan.entries.map(\.sourceURL).map(\.standardizedFileURL))
    guard !allAssets.contains(where: { $0.isReadOnly && targets.contains($0.url.standardizedFileURL) }) else {
      throw LibraryAccessError.readOnlyArchive
    }
    isRenaming = true
    prefetchTask?.cancel()
    metadataTask?.cancel()
    defer { isRenaming = false }
    await photoMarks.waitUntilReady()
    guard photoMarks.isReady else {
      throw PhotoMarkPersistenceError(message: photoMarks.errorMessage ?? PhotoMarkL10n.text("storage.error"))
    }
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
    let renamedMarkIDs = allAssets.reduce(into: [String: String]()) { result, asset in
      guard let destination = mapping[asset.url] else { return }
      result[asset.photoMarkID] = asset.replacingURL(destination).photoMarkID
    }
    photoMarks.remapAssets(renamedMarkIDs)
    // Refresh only the open library so an explicit selection from several folders stays intact.
    allAssets = allAssets.map { asset in
      mapping[asset.url].map { asset.replacingURL($0) } ?? asset
    }
    sourceLocations = sourceLocations.map { location in
      mapping[location.url].map { SessionLocation(url: $0) } ?? location
    }
    let queried = try await queryAssets(allAssets, options: libraryQuery)
    allAssets = queried.all
    mapAssets = queried.map
    assets = queried.visible
    currentIndex = assets.firstIndex { $0.url == focusedURL } ?? 0
    queryFocusID = currentAsset?.sessionID
    pageStartIndex = currentIndex
    selectionAnchor = currentIndex
    await pipeline.purgeCaches()
    await thumbnailPipeline.purgeCache()
    for source in mapping.keys { discardRecentPhoto(source.standardizedFileURL.absoluteString) }
    recordWork(allAssets.filter { mapping.values.contains($0.url) })
    refreshMetadata()
    prefetchAroundCurrentPosition()
    showStatus(L10n.format("%d개 파일 이름 변경 완료", mapping.count))
  }

  func convertSelectedFiles(
    items: [BatchExportItem], format: ExportFormat, quality: Double,
    resize: BatchResizeOptions = .original,
    watermark: WatermarkOptions = .disabled,
    progress: @escaping @Sendable (Int, Int) -> Void
  ) async -> BatchExportResult {
    let recordWork = makeRecentWorkRecorder()
    let sources = allAssets
    isBatchExporting = true
    defer { isBatchExporting = false }
    let classifications: PhotoMarkExportContext
    do {
      classifications = try await prepareExportPhotoMarks(sourceURLs: items.map(\.sourceURL))
    } catch {
      return BatchExportResult(completed: [], failures: error is CancellationError ? [] : items.map {
        BatchExportFailure(sourceURL: $0.sourceURL, message: error.localizedDescription)
      }, wasCancelled: error is CancellationError)
    }
    let result = await batchExporter.export(
      items: items, format: format, quality: quality, resize: resize, watermark: watermark,
      adjustments: adjustments, photoMarkSourceURLs: Set(classifications.marks.keys), progress: progress)
    do {
      try await classifications.commit(result.completed)
      let completedSources = Set(result.completed.map { $0.sourceURL.standardizedFileURL })
      recordWork(sources.filter { completedSources.contains($0.url.standardizedFileURL) })
    }
    catch { show(error: error, title: PhotoMarkL10n.text("storage.error")) }
    return result
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
    !isEditingViewerFrames && currentAsset?.isVideo != true
      && (zoom > 1 || baseScaleMode.canOverflowAtBaseScale)
  }

  var isMultiImageViewer: Bool { presentationMode == .viewer && imagesPerPage > 1 }
  var isEditingViewerFrames: Bool { isMultiImageViewer && frameLayout.isEditing }

  var positionDescription: String {
    guard !assets.isEmpty else { return "0 / 0" }
    if presentationMode == .overview { return "\(currentIndex + 1) / \(assets.count)" }
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
    !isVideoFullScreenPresented && batchSheet == nil && !isBatchBusy && !isSavingMetadata && !isExporting
      && wallpaperRequest == nil && !isSettingWallpaper && motionMediaAsset == nil
      && !folderComparison.isEditingNames
      && (showsHome || presentationMode != .folderComparison || !folderComparison.pane(folderComparison.activeSide).isLocked)
  }

  func openFolderFromTree(_ folder: URL) {
    guard canOpenFolderFromTree else { return }
    leaveHomeForNewFile()
    if presentationMode == .folderComparison {
      invalidateSessionRestore()
      folderComparison.open(urls: [folder], for: folderComparison.activeSide)
    } else {
      load(folder: folder, fromTree: true)
    }
  }

  var canEditCurrentEmbeddedMetadata: Bool {
    currentAsset?.isVideo != true && currentAsset?.isReadOnly != true && ImageMetadataWriter.supportsEmbeddedMetadata(
      typeIdentifier: currentMetadata?.typeIdentifier
    )
  }

  func chooseItems() {
    guard canOpenFolderFromTree else { return }
    if !showsHome && presentationMode == .folderComparison {
      invalidateSessionRestore()
      folderComparison.chooseItems(for: folderComparison.activeSide)
      return
    }
    pauseSlideshow()
    let panel = ImageOpenPanel.make(includesVideos: true)
    if panel.runModal() == .OK { open(urls: panel.urls) }
  }

  // Keep old call sites and saved shortcut actions compatible with the unified opener.
  func chooseFolder() { chooseItems() }
  func chooseFiles() { chooseItems() }

  func open(urls: [URL]) {
    guard !urls.isEmpty, canOpenFolderFromTree else { return }
    leaveHomeForNewFile()
    if presentationMode == .folderComparison {
      invalidateSessionRestore()
      folderComparison.open(urls: urls, for: folderComparison.activeSide)
      return
    }
    if urls.contains(where: MediaFormatRegistry.isVideo) { showsVideos = true }
    load(urls: urls)
  }

  /// Finder and window drops request a new, simple viewer, independently of
  /// the previous workspace. An explicit comparison-pane opener still uses open.
  @discardableResult
  func openExternally(urls: [URL]) -> Bool {
    guard !urls.isEmpty, urls.allSatisfy(\.isFileURL),
      !isVideoFullScreenPresented, batchSheet == nil, !isBatchBusy,
      !isSavingMetadata, !isExporting, wallpaperRequest == nil, !isSettingWallpaper,
      motionMediaAsset == nil, !folderComparison.isEditingNames else { return false }
    invalidateSessionRestore()
    pauseSlideshow()
    presentationMode = .viewer
    showsHome = false
    resetLibraryQuery()
    isPhotoMarking = false
    showsPhotoMarkEditor = false
    showsPhotoMarkTrackingReport = false
    showsAIUpscaling = false
    inspectorPanel = nil
    overviewSelectionSession = nil
    alert = nil
    videoGridPlayback.reset()
    setComparisonLayout(.off)
    setImagesPerPage(1)
    setFitToWindow()
    isFocusMode = true
    // A folder drop requests its images and videos even if an earlier collection
    // hid videos. Resolve directory identity instead of relying on a trailing slash.
    if urls.contains(where: { url in
      MediaFormatRegistry.isVideo(url)
        || (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }) { showsVideos = true }
    load(urls: urls)
    return true
  }

  func select(asset: ImageAsset, switchToViewer: Bool = false) {
    guard let index = assets.firstIndex(of: asset) else { return }
    select(index: index)
    if switchToViewer { presentationMode = .viewer }
  }

  func select(index: Int) {
    guard motionMediaAsset == nil, assets.indices.contains(index), batchSheet == nil, !isBatchBusy else { return }
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
    guard motionMediaAsset == nil, !folderComparison.isEditingNames else { return }
    if presentationMode == .folderComparison {
      folderComparison.navigateSelection(direction)
      return
    }
    if presentationMode == .overview {
      navigateOverview(by: direction == 0 ? 0 : direction > 0 ? 1 : -1)
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

  /// The grid uses its focused tile, independently of the viewer's page size.
  func navigateOverview(by offset: Int, wraps: Bool? = nil) {
    guard presentationMode == .overview, !assets.isEmpty, offset != 0,
      !isLoading, !isFiltering, !isExporting, !isSavingMetadata,
      motionMediaAsset == nil, batchSheet == nil, !isBatchBusy,
      overviewSelectionSession == nil else { return }
    let target = OverviewGridNavigation.target(from: currentIndex, offset: offset,
      count: assets.count, wraps: wraps ?? wrapsNavigation)
    if target != currentIndex { select(index: target) }
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
    if zoom <= 1, !baseScaleMode.canOverflowAtBaseScale { panOffset = .zero }
  }

  func setFitToWindow() {
    setScaleMode(.fit)
  }

  func setActualPixels() {
    setScaleMode(.actualPixels)
  }

  func setScaleMode(_ mode: BaseScaleMode) {
    if presentationMode == .folderComparison { folderComparison.setScale(mode); return }
    baseScaleMode = isMultiImageViewer ? .fit : mode
    resetViewport()
  }

  /// Bring the image back to the center without discarding its chosen scale.
  func centerImage() {
    if presentationMode == .folderComparison { folderComparison.centerImage(); return }
    panOffset = .zero
  }

  private func normalizeMultiImageScale() {
    guard isMultiImageViewer, baseScaleMode != .fit else { return }
    baseScaleMode = .fit
    resetViewport()
  }

  func updateZoom(with magnification: CGFloat) {
    zoom = min(16, max(0.1, zoom * magnification))
    if zoom <= 1, !baseScaleMode.canOverflowAtBaseScale { panOffset = .zero }
  }

  func updatePan(by translation: CGSize) {
    guard canPan else { return }
    panOffset = CGSize(width: panOffset.width + translation.width,
      height: panOffset.height + translation.height)
  }

  func updateViewerPanGeometry(_ geometry: ImagePanGeometry, for asset: ImageAsset) {
    guard asset.id == currentAsset?.id else { return }
    viewerPan.focus(on: asset.id)
    viewerPan.setGeometry(geometry, for: asset.id)
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
    guard let currentAsset, !currentAsset.isVideo else { return }
    pauseSlideshow()
    var value = currentAdjustments
    change(&value)
    guard value != currentAdjustments else { return }
    adjustments[currentAsset.url] = value
    recordAdjustmentActivity(currentAsset)
    objectWillChange.send()
  }

  /// A sheet applies to its captured file only; navigation or replacement cannot
  /// accidentally transfer that draft crop to a different image.
  func applyCrop(_ crop: NormalizedCrop?, to asset: ImageAsset,
    relativeTo reference: ImageAdjustments? = nil)
  {
    guard !asset.isVideo, assets.contains(asset) else { return }
    pauseSlideshow()
    var value = adjustments(for: asset)
    var adjustedCrop = crop?.normalized
    if let reference {
      // Convert the captured sheet's selection back through its reflections,
      // then into the current orientation without changing the selected subject.
      if reference.isFlippedHorizontally { adjustedCrop = adjustedCrop?.flippedHorizontally() }
      if reference.isFlippedVertically { adjustedCrop = adjustedCrop?.flippedVertically() }
      let delta = (value.normalizedQuarterTurns - reference.normalizedQuarterTurns + 4) % 4
      for _ in 0..<delta { adjustedCrop = adjustedCrop?.rotatedClockwise() }
      if value.isFlippedHorizontally { adjustedCrop = adjustedCrop?.flippedHorizontally() }
      if value.isFlippedVertically { adjustedCrop = adjustedCrop?.flippedVertically() }
    }
    value.crop = adjustedCrop
    guard value != adjustments(for: asset) else { return }
    adjustments[asset.url] = value
    makeRecentWorkRecorder()([asset])
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

  func flipHorizontally() {
    updateAdjustments { $0.flipHorizontally() }
  }

  func flipVertically() {
    updateAdjustments { $0.flipVertically() }
  }

  func resetAdjustments() {
    guard let currentAsset, !currentAsset.isVideo, !currentAdjustments.isIdentity else { return }
    adjustments[currentAsset.url] = .identity
    makeRecentWorkRecorder()([currentAsset])
    objectWillChange.send()
  }

  func toggleOverview() {
    guard !folderComparison.isEditingNames else { return }
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
    guard let asset = currentAsset, !asset.isVideo else {
      throw ImageMetadataWriterError.noCurrentImage
    }

    guard !asset.isReadOnly else { throw LibraryAccessError.readOnlyArchive }
    let recordWork = makeRecentWorkRecorder()
    let sourceURL = asset.url
    let update = try draft.validated(for: sourceURL)
    let original = try originalDraft.validated(for: sourceURL)
    isSavingMetadata = true
    defer { isSavingMetadata = false }
    await photoMarks.waitUntilReady()
    guard photoMarks.isReady else {
      throw PhotoMarkPersistenceError(message: photoMarks.errorMessage ?? PhotoMarkL10n.text("storage.error"))
    }

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
      folder: destinationURL.deletingLastPathComponent(), includesVideos: true
    )
    guard let savedAsset = refreshedAssets.first(where: {
      $0.url.standardizedFileURL == destinationURL.standardizedFileURL
    }) else {
      throw ImageMetadataWriterError.sourceUnavailable(destinationURL)
    }

    // A metadata editor may replace the file atomically. The user explicitly
    // edited this photo, so carry its marks to the fresh identity before filtering.
    photoMarks.remapAssets([asset.photoMarkID: savedAsset.photoMarkID])

    let queried = try await queryAssets(refreshedAssets, options: libraryQuery)
    allAssets = queried.all
    mapAssets = queried.map
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
    if asset.sessionID != savedAsset.sessionID { discardRecentPhoto(asset.sessionID) }
    recordWork([savedAsset])
    showStatus(L10n.format("%@ 정보 저장 완료", destinationURL.lastPathComponent))
  }

  /// Shared keyboard routing keeps explicit shortcuts ahead of convenience gestures.
  func handleViewerKeyDown(_ event: NSEvent, shortcuts: ShortcutStore) -> Bool {
    guard !showsHome, !isVideoFullScreenPresented, motionMediaAsset == nil, batchSheet == nil, !isBatchBusy, wallpaperRequest == nil,
      !isSettingWallpaper, !showsAIUpscaling, !showsPhotoMarkEditor,
      !showsPhotoMarkTrackingReport,
      !folderComparison.isEditingNames, folderComparison.editingPhotoMarkSide == nil,
      alert == nil else { return false }
    if isEditingViewerFrames {
      if event.keyCode == 53 { return handleEscapeKey() }
      return false
    }
    if handlePhotoMarkKeyDown(event) { return true }
    if event.keyCode == 51,
      event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
      presentationMode == .viewer || presentationMode == .overview {
      presentFileOperation(.trash)
      return true
    }
    if presentationMode == .viewer, imagesPerPage > 1,
      let direction = shortcuts.viewerSelectionDirection(matching: event) {
      return navigateViewerSelection(direction)
    }
    if presentationMode != .folderComparison,
      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      event.charactersIgnoringModifiers?.lowercased() == "a" {
      selectAllAssets()
      return true
    }
    if event.keyCode == 53 { return handleEscapeKey() }
    if let action = shortcuts.action(matching: event) {
      perform(action)
      return true
    }
    if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
      event.keyCode == 125 || event.keyCode == 126,
      navigateGridRow(event.keyCode == 126 ? -1 : 1) {
      return true
    }
    return event.keyCode == 49 && canPan && panInteractionMode == .spacePrimaryDrag
      && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
  }

  /// Sheets and a dedicated full-screen player suspend every underlying preview.
  var allowsVideoPlayback: Bool {
    !showsHome && !isVideoFullScreenPresented && !isLoading && !isFiltering
      && motionMediaAsset == nil && batchSheet == nil && !isBatchBusy
      && wallpaperRequest == nil && !isSettingWallpaper && !isExporting && !isSavingMetadata
      && !showsAIUpscaling && !showsPhotoMarkEditor && !showsPhotoMarkTrackingReport
      && alert == nil
  }

  var fullScreenVideoAsset: ImageAsset? { videoFullScreenController?.asset }
  var isFullScreenVideoReadyToMark: Bool {
    videoFullScreenController?.playback.document != nil
      && videoFullScreenController?.playback.player.currentItem?.status == .readyToPlay
  }

  func openVideoFullScreen(_ asset: ImageAsset, at seconds: Double = 0, isMuted: Bool = false) {
    guard allowsVideoPlayback, asset.isVideo, assets.contains(where: { $0.id == asset.id }) else { return }
    pauseSlideshow()
    let controller = VideoFullScreenController(asset: asset, seconds: seconds, isMuted: isMuted, store: self) { [weak self] in
      self?.videoFullScreenController = nil
    }
    videoFullScreenController = controller
    controller.present()
  }

  var canToggleImageFocus: Bool {
    !isEditingViewerFrames && motionMediaAsset == nil && presentationMode == .viewer && currentAsset != nil && !isLoading && !isFiltering
      && batchSheet == nil && !isBatchBusy && !isExporting && !isSavingMetadata
      && wallpaperRequest == nil && !isSettingWallpaper && !showsAIUpscaling
      && !showsPhotoMarkEditor && alert == nil
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
    !showsHome && motionMediaAsset == nil && presentationMode != .folderComparison
      && (assets.count > 1 || assets.first?.isVideo == true)
      && !isLoading && !isFiltering && !isVideoFullScreenPresented && batchSheet == nil && !isBatchBusy && !isExporting
      && !isSavingMetadata && wallpaperRequest == nil && !isSettingWallpaper && alert == nil
      && !isPhotoMarking && !showsPhotoMarkEditor && !showsPhotoMarkTrackingReport && !showsAIUpscaling
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
    updateSlideshowVideoPlayback()
    if managesSlideshowDisplaySleep { slideshowActivity = SlideshowDisplayActivity() }
    restartSlideshowCountdown()
  }

  func pauseSlideshow() {
    isSlideshowPlaying = false
    slideshowVideoPlaybackID = nil
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

  /// Videos advance only at their actual end, never when a poster is displayed.
  func slideshowVideoFinished(_ asset: ImageAsset, playbackID: UUID) {
    guard isSlideshowPlaying, currentAsset == asset, asset.isVideo,
      slideshowVideoPlaybackID == playbackID else { return }
    slideshowPresentedAsset = asset
    advanceSlideshow()
  }

  func slideshowVideoFailed(_ asset: ImageAsset, playbackID: UUID) {
    guard isSlideshowPlaying, currentAsset == asset,
      slideshowVideoPlaybackID == playbackID else { return }
    pauseSlideshow()
    showStatus(L10n.format("%@ 영상을 재생할 수 없어 전자 앨범을 일시정지했습니다.", asset.filename))
  }

  private func updateSlideshowVideoPlayback() {
    slideshowVideoPlaybackID = isSlideshowPlaying && currentAsset?.isVideo == true ? UUID() : nil
  }

  private func invalidateSlideshowCountdown() {
    slideshowGeneration = UUID()
    slideshowTask?.cancel()
    slideshowTask = nil
  }

  private func restartSlideshowCountdown() {
    invalidateSlideshowCountdown()
    guard isSlideshowPlaying, isFocusMode, presentationMode == .viewer,
      let asset = currentAsset, !asset.isVideo, slideshowPresentedAsset == asset else { return }
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
    if next == currentIndex {
      // A one-video album repeats without changing its selected index.
      slideshowPresentedAsset = nil
      updateSlideshowVideoPlayback()
    } else {
      select(index: next)
    }
  }

  // MARK: - 바탕화면

  var canSetWallpaper: Bool {
    presentationMode != .folderComparison && currentAsset != nil && currentAsset?.isVideo != true && motionMediaAsset == nil && !isLoading && !isBatchBusy && !isExporting && !isSavingMetadata
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
    if isEditingViewerFrames {
      frameLayout.isEditing = false
      return true
    }
    if isPhotoMarking {
      isPhotoMarking = false
      return true
    }
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
    guard batchSheet == nil, !isBatchBusy, wallpaperRequest == nil, !isSettingWallpaper,
      !folderComparison.isEditingNames else { return }
    if presentationMode == .folderComparison { presentationMode = comparisonReturnMode }
    else { presentationMode = .folderComparison }
  }

  var canCompareCurrentCollectionByMarks: Bool {
    allAssets.contains(where: { !$0.isVideo }) && !sourceLocations.isEmpty && !isLoading && !isFiltering
      && !isBatchBusy && batchSheet == nil && !isSavingMetadata && !isExporting
      && photoMarks.isReady && !folderComparison.first.isLocked && !folderComparison.second.isLocked
      && !folderComparison.isEditingNames && folderComparison.editingPhotoMarkSide == nil
  }

  func compareCurrentCollectionByMarks() {
    guard canCompareCurrentCollectionByMarks else { return }
    invalidateSessionRestore()
    guard folderComparison.openCollectionForMarkComparison(assets: allAssets,
      folderURL: currentFolderURL, sources: sourceLocations, access: libraryAccess,
      query: libraryQuery, initialFilter: photoMarkFilter) else { return }
    presentationMode = .folderComparison
  }

  func perform(_ action: ShortcutAction) {
    guard !isVideoFullScreenPresented else { return }
    guard !showsHome || action == .openFolder else { return }
    guard batchSheet == nil, !isBatchBusy, overviewSelectionSession == nil,
      wallpaperRequest == nil, !isSettingWallpaper, motionMediaAsset == nil,
      !folderComparison.isEditingNames, folderComparison.editingPhotoMarkSide == nil else { return }
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
    guard let asset = currentAsset, !asset.isVideo, motionMediaAsset == nil, batchSheet == nil, !isBatchBusy, !isSavingMetadata,
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
        try await exportEditedImage(asset, to: destination, format: selectedFormat,
          quality: exportQuality, adjustments: adjustments(for: asset))
        isExporting = false
        showStatus(L10n.format("%@ 저장 완료", destination.lastPathComponent))
      } catch {
        isExporting = false
        show(error: error, title: L10n.text("내보내기 실패"))
      }
    }
  }

  func exportEditedImage(_ asset: ImageAsset, to destination: URL, format: ExportFormat,
    quality: Double, adjustments: ImageAdjustments) async throws {
    let recordWork = makeRecentWorkRecorder()
    let classifications = try await prepareExportPhotoMarks(for: [asset])
    try await exporter.export(sourceURL: asset.url, destinationURL: destination,
      format: format, quality: quality, adjustments: adjustments)
    try await classifications.commit([BatchExportItem(sourceURL: asset.url, destinationURL: destination)])
    recordWork([asset])
  }

  func purgeCaches() {
    Task {
      await pipeline.purgeCaches()
      await thumbnailPipeline.purgeCache()
    }
  }

  // MARK: - Search, sorting and format selection

  var hasLibraryQuery: Bool { libraryQuery != LibraryQuery() || photoMarkFilter.isActive }

  func resetLibraryQuery() {
    photoMarkFilter = PhotoMarkFilter()
    libraryQuery = LibraryQuery()
  }

  private func cancelQuery() {
    queryGeneration = UUID()
    queryTask?.cancel()
    queryTask = nil
    isFiltering = false
    locationScanGeneration = UUID()
    isIndexingLocations = false
  }

  private func queryAssets(_ source: [ImageAsset], options: LibraryQuery,
    retryUnavailable: Bool = true, includesVideos: Bool? = nil) async throws
    -> (all: [ImageAsset], visible: [ImageAsset], map: [ImageAsset])
  {
    // Match the load/restore loop's visibility snapshot across every suspension.
    let showsQueryVideos = includesVideos ?? showsVideos
    await photoMarks.waitUntilReady()
    try Task.checkCancellation()
    await photoMarks.reconcileAssets(source, retryUnavailable: retryUnavailable)?.wait()
    try Task.checkCancellation()
    var enriched = source
    let scanToken = UUID()
    let needsLocations = options.sort.requiresLocation || options.geographicSelection != nil
      || presentationMode == .map
    if needsLocations {
      locationScanGeneration = scanToken
      isIndexingLocations = true
      locationScanCount = 0
    }
    defer {
      if locationScanGeneration == scanToken { isIndexingLocations = false }
    }
    if needsLocations {
      enriched = try await library.enrichLocations(source) { [weak self] count in
        await self?.updateLocationProgress(count, generation: scanToken)
      }
    }
    try Task.checkCancellation()
    var inputs = showsQueryVideos ? enriched : enriched.filter { !$0.isVideo }
    if options.requiresMetadata {
      inputs = try await library.enrichQueryMetadata(inputs, for: options, governor: loadingGovernor)
      let metadataByURL = Dictionary(inputs.map { ($0.url, $0) },
        uniquingKeysWith: { _, newest in newest })
      enriched = enriched.map { asset in
        var updated = asset
        if let prepared = metadataByURL[asset.url] {
          updated.sortMetadata = prepared.sortMetadata
          updated.sortMetadataVersion = prepared.sortMetadataVersion
        }
        return updated
      }
    }
    let preparedInputs = inputs
    let work = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let visible = try RustImageEngine.query(preparedInputs, options: options)
      var mapOptions = options
      mapOptions.geographicSelection = nil
      let map = options.geographicSelection == nil ? visible
        : try RustImageEngine.query(preparedInputs, options: mapOptions)
      return (visible, map)
    }
    let result = try await withTaskCancellationHandler {
      try await work.value
    } onCancel: { work.cancel() }
    try Task.checkCancellation()
    // Use the latest marks after suspended image work. A keypress or filter change
    // during folder loading must not commit a stale classification result.
    guard photoMarkFilter.isActive else { return (enriched, result.0, result.1) }
    let filter = photoMarkFilter
    return (enriched,
      result.0.filter { filter.matches(photoMarks.marks(for: $0)) },
      result.1.filter { filter.matches(photoMarks.marks(for: $0)) })
  }

  private func updateLocationProgress(_ count: Int, generation: UUID) {
    guard locationScanGeneration == generation else { return }
    locationScanCount = count
  }

  func openAssetFromMap(_ asset: ImageAsset) {
    guard !isFiltering, !isLoading else { return }
    queryFocusID = asset.sessionID
    if assets.contains(where: { $0.id == asset.id }) {
      select(asset: asset, switchToViewer: true)
    } else {
      // Opening an unselected pin clears only the geographic restriction.
      libraryQuery.geographicSelection = nil
      presentationMode = .viewer
    }
  }

  func showMapSelection(in mode: PresentationMode = .overview) {
    guard mode == .viewer || mode == .overview,
      !isFiltering, !isLoading, !assets.isEmpty else { return }
    // The geographic query remains active when leaving the map, so arrows,
    // thumbnails, and the overview all browse the same selected collection.
    presentationMode = mode
  }

  private func applyLibraryQuery() {
    cancelQuery()
    // A pending open applies the latest options before committing its new collection.
    guard !isLoading, !isRestoringSession, !isManagingFiles else { return }
    let generation = queryGeneration
    let options = libraryQuery
    let source = allAssets
    isFiltering = true
    queryTask = Task { [weak self] in
      guard let self else { return }
      do {
        // Collapse a burst of keystrokes without starting metadata scans for each letter.
        try await Task.sleep(for: .milliseconds(100))
        let result = try await queryAssets(source, options: options, retryUnavailable: false)
        guard !Task.isCancelled, queryGeneration == generation else { return }
        let oldID = currentAsset?.sessionID
        let previousFocus = queryFocusID ?? oldID
        let previousSelected = selectedURLs
        allAssets = result.all
        mapAssets = result.map
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

  // MARK: - Home and recently opened folders

  var canShowHome: Bool {
    !isVideoFullScreenPresented && !isLoading && !isFiltering && !isRestoringSession && batchSheet == nil && !isBatchBusy
      && !isSavingMetadata && !isExporting && wallpaperRequest == nil && !isSettingWallpaper
      && motionMediaAsset == nil && !showsAIUpscaling && !showsPhotoMarkEditor
      && !folderComparison.isEditingNames && folderComparison.editingPhotoMarkSide == nil
  }

  private var hasLoadedWorkspace: Bool {
    !sourceLocations.isEmpty || !folderComparison.first.sourceURLs.isEmpty
      || !folderComparison.second.sourceURLs.isEmpty
  }

  var canResumeWorkspace: Bool {
    hasLoadedWorkspace || sessionPersistence.loadSession() != nil
  }

  func showHome() {
    guard canShowHome else { return }
    pauseSlideshow()
    saveSessionNow()
    showsHome = true
  }

  func resumeWorkspace() async {
    guard showsHome, canShowHome, canResumeWorkspace else { return }
    if hasLoadedWorkspace {
      if presentationMode == .folderComparison {
        let pane = folderComparison.pane(folderComparison.activeSide)
        recordRecentFolders(opened: OpenedImageLibrary(assets: pane.assets, folderURL: pane.folderURL,
          focusedURL: pane.currentAsset?.url, access: []), sourceURLs: pane.sourceURLs)
      } else {
        recordRecentFolders(opened: OpenedImageLibrary(assets: allAssets, folderURL: currentFolderURL,
          focusedURL: currentAsset?.url, access: []), sourceURLs: sourceLocations.map(\.url))
      }
      showsHome = false
    } else {
      // A deliberate retry can succeed after reconnecting a missing volume.
      didAttemptSessionRestore = false
      let generation = restoreGeneration
      await restoreLastSession()
      guard generation == restoreGeneration else { return }
      showsHome = !hasLoadedWorkspace
      if showsHome {
        alert = ViewerAlert(title: L10n.text("home.resume"),
          message: L10n.text("이전 보기를 복원하지 못했습니다. 열기에서 폴더를 다시 선택하세요."))
      }
    }
  }

  private func leaveHomeForNewFile() {
    guard showsHome else { return }
    showsHome = false
    isFocusMode = false
    isPhotoMarking = false
    presentationMode = .viewer
    resetLibraryQuery()
  }

  func openRecentFolder(_ folder: RecentFolder) async {
    guard canOpenFolderFromTree, !isLoading else { return }
    invalidateSessionRestore()
    cancelQuery()
    cancelLibraryLoad()
    let generation = loadGeneration
    isLoading = true
    pauseSlideshow()
    do {
      let url = try folder.location.resolve().standardizedFileURL
      let access = ImageLibraryAccess([url])
      // A missing folder must not fall through to the single-file opener.
      if !folder.isArchive {
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
          throw CocoaError(.fileNoSuchFile)
        }
      }
      let opened = try await library.open(urls: [url], allowsEmptyFolder: true, includesVideos: true)
      try Task.checkCancellation()
      guard loadGeneration == generation else { return }
      let lastPhoto = folder.photos.first
      let target = opened.assets.first { asset in
        guard let lastPhoto else { return false }
        if let entry = lastPhoto.archiveEntryPath { return asset.archiveOrigin?.entryPath == entry }
        return asset.archiveOrigin == nil && asset.filename == lastPhoto.filename
      }
      isApplyingSession = true
      libraryQuery = LibraryQuery()
      photoMarkFilter = PhotoMarkFilter()
      isApplyingSession = false
      isPhotoMarking = false
      isFocusMode = false
      libraryAccess = [access] + opened.access
      sourceLocations = [SessionLocation(url: url)]
      currentFolderURL = opened.folderURL?.standardizedFileURL
      allAssets = opened.assets
      let visible = opened.assets.filter { showsVideos || !$0.isVideo }
      mapAssets = visible
      applyLoadedAssets(visible, focusing: target?.url)
      showsHome = false
      if folder.id != url.absoluteString { removeRecentFolder(folder.id) }
      recentPhotos.recordFolder(url: url, isArchive: folder.isArchive)
      pruneRecentPreviewTasks()
    } catch {
      guard loadGeneration == generation else { return }
      isLoading = false
      if error is CancellationError { return }
      alert = ViewerAlert(title: L10n.text("home.folder.failed"),
        message: "\(folder.name)\n\(L10n.text("home.folder.missing"))")
    }
  }

  func openRecentPhoto(_ photo: RecentPhoto) async {
    guard canOpenFolderFromTree, !isLoading else { return }
    invalidateSessionRestore()
    cancelQuery()
    cancelLibraryLoad()
    let generation = loadGeneration
    isLoading = true
    pauseSlideshow()
    do {
      let url = try photo.resolvedSourceURL()
      let opened = try await library.open(urls: [url], includesVideos: true)
      try Task.checkCancellation()
      guard loadGeneration == generation else { return }
      guard let target = opened.assets.first(where: { photo.matches($0, sourceURL: url) }),
        !target.isVideo else { throw CocoaError(.fileNoSuchFile) }

      // Opening a recent photo is an explicit selection, independent of an old
      // search, map area, classification filter or active comparison pane.
      isApplyingSession = true
      libraryQuery = LibraryQuery()
      photoMarkFilter = PhotoMarkFilter()
      isApplyingSession = false
      isPhotoMarking = false
      isFocusMode = false
      libraryAccess = opened.access
      sourceLocations = [SessionLocation(url: url)]
      currentFolderURL = opened.folderURL?.standardizedFileURL
      allAssets = opened.assets
      let visible = opened.assets.filter { showsVideos || !$0.isVideo }
      mapAssets = visible
      applyLoadedAssets(visible, focusing: target.url)
      showsHome = false
      if target.sessionID != photo.id { removeRecentPhoto(photo.id) }
      recordRecentFolders(opened: opened, sourceURLs: [url])
    } catch {
      guard loadGeneration == generation else { return }
      isLoading = false
      if error is CancellationError { return }
      alert = ViewerAlert(title: L10n.text("home.open.failed"),
        message: "\(photo.filename)\n\(L10n.text("home.open.missing"))")
    }
  }

  /// Called only when a viewer/comparison tile has actually displayed pixels.
  /// Browsing thumbnails, prefetches and late teardown callbacks are not visits.
  func recordRecentlyViewed(_ asset: ImageAsset) {
    guard !showsHome, !asset.isVideo else { return }
    let isPresented = presentationMode == .viewer ? visibleAssets.contains(where: { $0.id == asset.id })
      : presentationMode == .folderComparison
        && [folderComparison.first.currentAsset, folderComparison.second.currentAsset]
          .contains(where: { $0?.id == asset.id })
    guard isPresented else { return }
    recordRecentActivity(asset)
  }

  /// Explicit work can target overview/off-page selections. Capturing this at
  /// action time prevents a late save from restoring cleared history or taking
  /// precedence over a newer visit after the save started.
  func makeRecentWorkRecorder() -> @MainActor ([ImageAsset]) -> Void {
    let generation = recentActivityGeneration
    let libraryGeneration = loadGeneration
    let date = Date()
    return { [weak self] workedAssets in
      guard let self, !self.showsHome, self.recentActivityGeneration == generation,
        self.loadGeneration == libraryGeneration else { return }
      let available = Set((self.allAssets + self.folderComparison.first.assets
        + self.folderComparison.second.assets).map(PresentedAssetVersion.init))
      let retainedFolders = Set(self.recentPhotos.folders.map(\.id))
      let previousDates = Dictionary(self.recentPhotos.items.map { ($0.id, $0.lastViewed) },
        uniquingKeysWith: max)
      var seen: Set<String> = []
      var folderCounts: [String: Int] = [:]
      var retained: [ImageAsset] = []
      for asset in workedAssets where !asset.isVideo {
        guard available.contains(PresentedAssetVersion(asset)),
          seen.insert(asset.sessionID).inserted,
          previousDates[asset.sessionID].map({ $0 <= date }) ?? true else { continue }
        let folderID = (asset.archiveOrigin?.archiveURL ?? asset.url.deletingLastPathComponent())
          .standardizedFileURL.absoluteString
        guard retainedFolders.contains(folderID),
          folderCounts[folderID, default: 0] < RecentPhotoStore.maximumPhotosPerFolder else { continue }
        folderCounts[folderID, default: 0] += 1
        retained.append(asset)
      }
      // Batch classification may contain thousands of images. Persist only the
      // handful that can survive the existing per-folder history bound.
      for asset in retained.reversed() { self.recordRecentActivity(asset, at: date) }
    }
  }

  private func recordAdjustmentActivity(_ asset: ImageAsset) {
    // Slider bindings can send dozens of values per drag. Pixels still update
    // on every value; an unchanged recent-history leader needs no new bookmark,
    // defaults write, or thumbnail request more than once per second.
    if let latest = recentPhotos.items.first, latest.hasSameVersion(as: asset),
      (0..<1).contains(Date().timeIntervalSince(latest.lastViewed)) { return }
    makeRecentWorkRecorder()([asset])
  }

  private func recordRecentActivity(_ asset: ImageAsset, at date: Date = Date()) {
    // A comparison pane can outlive its history entry. Redisplaying its pixels
    // must not resurrect a removed/evicted folder or replace the last opened one.
    let collectionURL = (asset.archiveOrigin?.archiveURL ?? asset.url.deletingLastPathComponent())
      .standardizedFileURL
    guard recentPhotos.folders.contains(where: { $0.id == collectionURL.absoluteString }) else { return }
    recentPhotos.record(asset, at: date)
    pruneRecentPreviewTasks()
    guard let entry = recentPhotos.items.first(where: { $0.id == asset.sessionID }),
      entry.thumbnailData == nil else { return }
    let id = entry.id
    recentPreviewTasks[id]?.cancel()
    let generation = UUID()
    recentPreviewGenerations[id] = generation
    // Keep the bookmark's grant alive if the user opens another collection while
    // this small preview waits for a decoder. Archive assets also retain their lease.
    let previewAccess = (try? entry.location.resolve()).map { ImageLibraryAccess([$0]) }
    recentPreviewTasks[id] = Task { [weak self, thumbnailPipeline, pipeline, previewAccess] in
      defer {
        withExtendedLifetime(previewAccess) {}
        if self?.recentPreviewGenerations[id] == generation {
          self?.recentPreviewTasks.removeValue(forKey: id)
          self?.recentPreviewGenerations.removeValue(forKey: id)
        }
      }
      do {
        let image: CGImage
        do { image = try await thumbnailPipeline.thumbnail(for: asset, maxPixelSize: 384) }
        catch {
          try Task.checkCancellation()
          image = try await pipeline.renderFrame(url: asset.url, maxPixelSize: 384,
            adjustments: .identity, prefersHDR: false).image
        }
        try Task.checkCancellation()
        // The shared pipeline can reuse a larger cached bitmap. Bound the
        // persisted preview explicitly before encoding it for recent history.
        guard let bounded = ThumbnailBitmapDecoder.rasterized(image,
          maxPixelSize: RecentPhotoStore.maximumThumbnailPixelDimension)?.image,
          let data = NSBitmapImageRep(cgImage: bounded).representation(using: .jpeg,
            properties: [.compressionFactor: 0.72]) else { return }
        self?.recentPhotos.setThumbnail(data, for: id, matchingLastViewed: entry.lastViewed)
      } catch { /* A recent item remains openable even when its preview is unavailable. */ }
    }
  }

  private func pruneRecentPreviewTasks() {
    let retained = Set(recentPhotos.items.map(\.id))
    for id in Array(recentPreviewTasks.keys) where !retained.contains(id) {
      recentPreviewTasks.removeValue(forKey: id)?.cancel()
      recentPreviewGenerations.removeValue(forKey: id)
    }
  }

  private func recordRecentFolders(opened: OpenedImageLibrary, sourceURLs: [URL]) {
    // This runs only after an explicit open has committed. Home reads cached
    // history and never scans directories or resolves bookmarks to draw cards.
    for source in sourceURLs.prefix(RecentPhotoStore.maximumFolderCount).reversed() {
      let url = source.standardizedFileURL
      if opened.folderURL?.standardizedFileURL == url
        || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        recentPhotos.recordFolder(url: url)
      } else if url.pathExtension.lowercased() == "zip" {
        recentPhotos.recordFolder(url: url, isArchive: true)
      } else {
        recentPhotos.recordFolder(url: url.deletingLastPathComponent())
      }
    }
    pruneRecentPreviewTasks()
  }

  func removeRecentFolder(_ id: String) {
    recentActivityGeneration = UUID()
    recentPhotos.removeFolder(id: id)
    pruneRecentPreviewTasks()
  }

  func removeRecentPhoto(_ id: String) {
    recentActivityGeneration = UUID()
    discardRecentPhoto(id)
  }

  private func discardRecentPhoto(_ id: String) {
    recentPreviewTasks.removeValue(forKey: id)?.cancel()
    recentPreviewGenerations.removeValue(forKey: id)
    recentPhotos.remove(id: id)
  }

  func clearRecentPhotos() {
    recentActivityGeneration = UUID()
    recentPreviewTasks.values.forEach { $0.cancel() }
    recentPreviewTasks.removeAll()
    recentPreviewGenerations.removeAll()
    recentPhotos.clear()
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
      self?.saveSessionNow(flushPhotoMarks: false)
    }
  }

  func saveSessionNow(flushPhotoMarks: Bool = true) {
    // Mark writes already commit on their serial queue. Routine viewport/session
    // saves must not block the main actor behind bookmark or SQLite work. Explicit
    // lifecycle saves still drain that queue before the app can close.
    if flushPhotoMarks { photoMarks.flush() }
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
      actualPixels: baseScaleMode == .actualPixels, scaleMode: baseScaleMode.rawValue,
      imagesPerPage: imagesPerPage,
      query: libraryQuery, comparison: comparison))
  }

  /// Explicit resume only: constructing the store keeps startup on Home.
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
    var appliedShowsVideos: Bool?
    defer {
      isApplyingSession = false
      isRestoringSession = false
      // Comparison restoration also suspends. Do not lose query or video-visibility changes
      // received after the ordinary collection was committed but before A/B is ready.
      if restoreGeneration == generation, !Task.isCancelled,
        let appliedQuery, let appliedShowsVideos,
        libraryQuery != appliedQuery || showsVideos != appliedShowsVideos || presentationMode == .map {
        applyLibraryQuery()
      }
    }
    if !session.sources.isEmpty {
      do {
        let urls = try session.sources.map { try $0.resolve() }
        let restoredAccess = ImageLibraryAccess(urls)
        let opened = try await library.open(urls: urls, allowsEmptyFolder: true, includesVideos: true)
        // Once the user changes search/sort/filter, that choice outranks the saved query.
        var options = libraryQueryRevision == startingQueryRevision ? session.query : libraryQuery
        var videos = showsVideos
        var result = try await queryAssets(opened.assets, options: options, includesVideos: videos)
        while options != (libraryQueryRevision == startingQueryRevision ? session.query : libraryQuery) || videos != showsVideos {
          try Task.checkCancellation()
          options = libraryQueryRevision == startingQueryRevision ? session.query : libraryQuery
          videos = showsVideos
          result = try await queryAssets(result.all, options: options,
            retryUnavailable: false, includesVideos: videos)
        }
        guard !Task.isCancelled, restoreGeneration == generation else { return }
        isApplyingSession = true
        libraryAccess = [restoredAccess] + opened.access
        sourceLocations = urls.map { SessionLocation(url: $0) }
        currentFolderURL = opened.folderURL?.standardizedFileURL
        libraryQuery = options
        allAssets = result.all
        mapAssets = result.map
        let focused = result.visible.first { $0.sessionID == session.selectedID }?.url
        let restoredMode = PresentationMode(rawValue: session.presentationMode) ?? .viewer
        let mode: PresentationMode = [.overview, .map].contains(restoredMode) ? restoredMode : .viewer
        applyLoadedAssets(result.visible, focusing: focused, mode: mode)
        recordRecentFolders(opened: opened, sourceURLs: urls)
        queryFocusID = session.selectedID ?? currentAsset?.sessionID
        selectedURLs = Set(assets.filter { session.selectedIDs.contains($0.sessionID) }.map(\.url))
        imagesPerPage = min(10, max(1, session.imagesPerPage))
        let savedScale = BaseScaleMode.restored(rawValue: session.scaleMode,
          actualPixels: session.actualPixels)
        let resetsScale = imagesPerPage > 1 && savedScale != .fit
        baseScaleMode = resetsScale ? .fit : savedScale
        zoom = resetsScale ? 1 : session.zoom.isFinite ? min(16, max(0.1, session.zoom)) : 1
        panOffset = resetsScale ? .zero : CGSize(width: session.panX.isFinite ? session.panX : 0,
          height: session.panY.isFinite ? session.panY : 0)
        appliedQuery = options
        appliedShowsVideos = videos
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
      !folderComparison.first.sourceURLs.isEmpty || !folderComparison.second.sourceURLs.isEmpty {
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
    isLoading = true
    if libraryQuery.geographicSelection != nil { libraryQuery.geographicSelection = nil }
    prefetchTask?.cancel()
    metadataTask?.cancel()
    let destinationMode: PresentationMode = fromTree
      && [.overview, .map].contains(presentationMode) ? presentationMode : .viewer

    loadTask = Task { [weak self, library] in
      do {
        let opened = try await library.open(urls: urls, allowsEmptyFolder: fromTree, includesVideos: true)
        try Task.checkCancellation()
        guard let self, self.loadGeneration == generation else { return }
        var options = self.libraryQuery
        var videos = self.showsVideos
        var queried = try await self.queryAssets(opened.assets, options: options, includesVideos: videos)
        while options != self.libraryQuery || videos != self.showsVideos {
          try Task.checkCancellation()
          options = self.libraryQuery
          videos = self.showsVideos
          queried = try await self.queryAssets(queried.all, options: options,
            retryUnavailable: false, includesVideos: videos)
        }
        try Task.checkCancellation()
        guard self.loadGeneration == generation else { return }
        self.libraryAccess = opened.access
        self.sourceLocations = urls.map { SessionLocation(url: $0) }
        self.currentFolderURL = opened.folderURL?.standardizedFileURL
        self.allAssets = queried.all
        self.mapAssets = queried.map
        self.applyLoadedAssets(queried.visible, focusing: opened.focusedURL, mode: destinationMode)
        self.recordRecentFolders(opened: opened, sourceURLs: urls)
      } catch is CancellationError {
        // 사용자가 다른 폴더를 열었을 때 이전 스캔의 결과는 조용히 폐기합니다.
      } catch {
        guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
        self.isLoading = false
        if !self.hasLoadedWorkspace { self.showsHome = true }
        self.show(error: error, title: L10n.text("이미지를 열 수 없음"))
      }
    }
  }

  private func applyLoadedAssets(_ newAssets: [ImageAsset], focusing selectedURL: URL?, mode: PresentationMode = .viewer) {
    // Replace the object so late teardown of an old map cannot overwrite the new collection.
    photoMapViewport = PhotoMapViewportState()
    mapCollectionID = UUID()
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
    viewerPan.focus(on: currentAsset?.id)
    zoom = 1
    panOffset = .zero
  }

  private func refreshMetadata() {
    metadataTask?.cancel()
    currentMetadata = nil
    guard let url = currentAsset?.url else { return }

    metadataTask = Task { [weak self] in
      guard let self else { return }
      // Key repeat should spend shared decoder slots on visible pixels first.
      do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
      guard !Task.isCancelled else { return }
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
