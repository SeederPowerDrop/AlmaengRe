import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct ViewerAlert: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

/// 앱의 탐색 상태와 비파괴 편집 상태를 소유하는 메인 액터 모델입니다.
@MainActor
final class AppStore: ObservableObject {
  @Published private(set) var assets: [ImageAsset] = []
  /// 현재 다중 보기 페이지의 첫 번째 이미지입니다.
  @Published private(set) var pageStartIndex = 0
  /// 조정 패널과 테두리가 가리키는 활성 이미지입니다.
  @Published private(set) var currentIndex = 0
  @Published var presentationMode: PresentationMode = .viewer
  @Published var baseScaleMode: BaseScaleMode = .fit
  @Published var imagesPerPage = 1
  @Published var thumbnailSize: CGFloat = 150
  @Published var zoom: CGFloat = 1
  @Published var panOffset: CGSize = .zero
  @Published var showsSidebar = true
  @Published var showsInspector = false
  @Published var isFocusMode = false
  @Published var prefersHDR = true
  @Published var wrapsNavigation = true
  @Published private(set) var isLoading = false
  @Published private(set) var isExporting = false
  @Published private(set) var currentMetadata: ImageMetadata?
  @Published var exportFormat: ExportFormat = ExportFormat.available.first ?? .jpeg
  @Published var exportQuality = 0.92
  @Published var alert: ViewerAlert?
  @Published var statusMessage: String?

  let pipeline: ImagePipeline

  private let library = ImageLibrary()
  private let exporter: ImageExporter
  private var adjustments: [URL: ImageAdjustments] = [:]
  private var loadTask: Task<Void, Never>?
  private var metadataTask: Task<Void, Never>?
  private var securityScopedURL: URL?

  init() {
    let pipeline = ImagePipeline()
    self.pipeline = pipeline
    exporter = ImageExporter(pipeline: pipeline)
  }

  var currentAsset: ImageAsset? {
    assets.indices.contains(currentIndex) ? assets[currentIndex] : nil
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

  var positionDescription: String {
    guard !assets.isEmpty else { return "0 / 0" }
    let end = min(assets.count, pageStartIndex + imagesPerPage)
    if end == pageStartIndex + 1 {
      return "\(pageStartIndex + 1) / \(assets.count)"
    }
    return "\(pageStartIndex + 1)–\(end) / \(assets.count)"
  }

  var activeFolderName: String {
    guard let currentAsset else { return "이미지뷰어" }
    return currentAsset.url.deletingLastPathComponent().lastPathComponent
  }

  func chooseFolder() {
    let panel = NSOpenPanel()
    panel.title = "이미지 폴더 열기"
    panel.prompt = "열기"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false

    if panel.runModal() == .OK, let url = panel.url {
      load(folder: url)
    }
  }

  func chooseFiles() {
    let panel = NSOpenPanel()
    panel.title = "이미지 열기"
    panel.prompt = "열기"
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    // QOI/PCX처럼 시스템에 등록되지 않은 이미지도 선택할 수 있게 data를 포함합니다.
    panel.allowedContentTypes = [.image, .data]

    if panel.runModal() == .OK {
      open(urls: panel.urls)
    }
  }

  func open(urls: [URL]) {
    guard !urls.isEmpty else { return }

    if let folder = urls.first(where: { $0.hasDirectoryPath }) {
      load(folder: folder)
    } else if urls.count == 1, let selected = urls.first {
      load(folder: selected.deletingLastPathComponent(), focusing: selected)
    } else {
      load(explicitFiles: urls)
    }
  }

  func select(asset: ImageAsset, switchToViewer: Bool = false) {
    guard let index = assets.firstIndex(of: asset) else { return }
    select(index: index)
    if switchToViewer { presentationMode = .viewer }
  }

  func select(index: Int) {
    guard assets.indices.contains(index) else { return }
    let visibleRange = pageStartIndex..<min(assets.count, pageStartIndex + imagesPerPage)
    if !visibleRange.contains(index) {
      pageStartIndex = index
    }
    currentIndex = index
    resetViewport()
    refreshMetadata()
    prefetchAroundCurrentPosition()
  }

  func navigatePage(_ direction: Int) {
    guard !assets.isEmpty, direction != 0 else { return }
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
    resetViewport()
    refreshMetadata()
    prefetchAroundCurrentPosition()
  }

  func setImagesPerPage(_ count: Int) {
    imagesPerPage = min(10, max(1, count))
    let visibleRange = pageStartIndex..<min(assets.count, pageStartIndex + imagesPerPage)
    if !visibleRange.contains(currentIndex) {
      pageStartIndex = currentIndex
    }
    resetViewport()
    prefetchAroundCurrentPosition()
  }

  func zoomIn() {
    zoom = min(16, zoom * 1.25)
  }

  func zoomOut() {
    zoom = max(0.1, zoom / 1.25)
    if zoom <= 1 { panOffset = .zero }
  }

  func setFitToWindow() {
    baseScaleMode = .fit
    resetViewport()
  }

  func setActualPixels() {
    baseScaleMode = .actualPixels
    resetViewport()
  }

  func updateZoom(with magnification: CGFloat) {
    zoom = min(16, max(0.1, zoom * magnification))
    if zoom <= 1 { panOffset = .zero }
  }

  func updatePan(by translation: CGSize) {
    guard zoom > 1 || baseScaleMode == .actualPixels else { return }
    panOffset.width += translation.width
    panOffset.height += translation.height
  }

  func updateAdjustments(_ change: (inout ImageAdjustments) -> Void) {
    guard let currentAsset else { return }
    var value = currentAdjustments
    change(&value)
    adjustments[currentAsset.url] = value
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

  func toggleFocusMode() {
    isFocusMode.toggle()
    if isFocusMode {
      presentationMode = .viewer
    }
  }

  func toggleFullScreen() {
    NSApp.keyWindow?.toggleFullScreen(nil)
  }

  func perform(_ action: ShortcutAction) {
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
    }
  }

  func exportCurrentImage() {
    guard let asset = currentAsset else { return }

    let selectedFormat =
      ExportFormat.available.contains(exportFormat)
      ? exportFormat
      : (ExportFormat.available.first ?? .jpeg)
    let panel = NSSavePanel()
    panel.title = "이미지 내보내기"
    panel.prompt = "저장"
    panel.canCreateDirectories = true
    panel.nameFieldStringValue =
      asset.url.deletingPathExtension().lastPathComponent
      + "." + selectedFormat.fileExtension
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
        showStatus("\(destination.lastPathComponent) 저장 완료")
      } catch {
        isExporting = false
        show(error: error, title: "내보내기 실패")
      }
    }
  }

  func purgeCaches() {
    Task { await pipeline.purgeCaches() }
  }

  private func load(folder: URL, focusing selectedURL: URL? = nil) {
    retainSecurityScope(for: folder)
    loadTask?.cancel()
    isLoading = true

    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        let scanned = try await library.scan(folder: folder)
        try Task.checkCancellation()
        applyLoadedAssets(scanned, focusing: selectedURL)
      } catch is CancellationError {
        // 사용자가 다른 폴더를 열었을 때 이전 스캔의 결과는 조용히 폐기합니다.
      } catch {
        isLoading = false
        show(error: error, title: "폴더를 열 수 없음")
      }
    }
  }

  private func load(explicitFiles urls: [URL]) {
    loadTask?.cancel()
    isLoading = true

    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        let loaded = try await library.assets(from: urls)
        try Task.checkCancellation()
        applyLoadedAssets(loaded, focusing: urls.first)
      } catch is CancellationError {
        // 새 열기 작업으로 대체되었습니다.
      } catch {
        isLoading = false
        show(error: error, title: "이미지를 열 수 없음")
      }
    }
  }

  private func applyLoadedAssets(_ newAssets: [ImageAsset], focusing selectedURL: URL?) {
    assets = newAssets
    let focusedIndex =
      selectedURL.flatMap { selected in
        newAssets.firstIndex(where: { $0.url.standardizedFileURL == selected.standardizedFileURL })
      } ?? 0
    pageStartIndex = focusedIndex
    currentIndex = focusedIndex
    isLoading = false
    presentationMode = .viewer
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

  private func prefetchAroundCurrentPosition() {
    guard !assets.isEmpty else { return }
    let lower = max(0, pageStartIndex - 2)
    let upper = min(assets.count, pageStartIndex + imagesPerPage + 4)
    let urls = assets[lower..<upper].map(\.url)
    let hdr = prefersHDR

    Task(priority: .utility) { [pipeline] in
      await pipeline.prefetch(urls: urls, maxPixelSize: 2_048, prefersHDR: hdr)
    }
  }

  private func retainSecurityScope(for url: URL) {
    securityScopedURL?.stopAccessingSecurityScopedResource()
    securityScopedURL = url
    _ = url.startAccessingSecurityScopedResource()
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
