import AppKit
import Testing

@testable import ImageViewer

@Suite("지도 사진의 독립 맞춤·확대·이동")
@MainActor
struct PhotoMapPreviewStateTests {
  private let first = URL(fileURLWithPath: "/synthetic/map-first.png")
  private let second = URL(fileURLWithPath: "/synthetic/map-second.png")

  @Test("선택 변경은 맞춤 방식을 유지하고 확대와 이동을 초기화한다")
  func selectionLifecycle() {
    let state = PhotoMapPreviewState()
    state.setScaleMode(.fitHeight)
    state.zoomIn()
    state.setPanOffset(CGSize(width: 50, height: 80))
    #expect(!state.hasSelection && !state.canPan)
    #expect(state.baseScaleMode == .fit && state.zoom == 1 && state.panOffset == .zero)
    state.focus(on: first)
    state.setScaleMode(.fitHeight)
    state.setZoom(2)
    state.setPanOffset(CGSize(width: 50, height: 80))
    state.focus(on: first)
    #expect(state.zoom == 2 && state.panOffset == CGSize(width: 50, height: 80))
    state.focus(on: second)
    #expect(state.assetID == second && state.baseScaleMode == .fitHeight)
    #expect(state.zoom == 1 && state.panOffset == .zero)
    state.clearSelection()
    state.zoomOut()
    state.setScaleMode(.actualPixels)
    state.setPanOffset(CGSize(width: 30, height: 60))
    #expect(!state.hasSelection && !state.canPan)
    #expect(state.baseScaleMode == .fitHeight && state.zoom == 1 && state.panOffset == .zero)
  }

  @Test("가로·세로 맞춤은 사진 비율을 유지하고 넘치는 축만 이동한다",
    arguments: [BaseScaleMode.fitWidth, .fitHeight])
  func axisFitBounds(mode: BaseScaleMode) {
    let state = PhotoMapPreviewState()
    let viewport = CGSize(width: 402, height: 302)
    let source = mode == .fitWidth ? CGSize(width: 1_000, height: 4_000)
      : CGSize(width: 4_000, height: 1_000)
    let size = ImageScaleGeometry.baseImageSize(mode: mode, pixelSize: source,
      viewportSize: viewport)
    near(size, mode == .fitWidth ? CGSize(width: 400, height: 1_600)
      : CGSize(width: 1_200, height: 300))
    #expect(abs(size.width / size.height - source.width / source.height) < 0.000_001)
    state.focus(on: first)
    state.setScaleMode(mode)
    state.setGeometry(ImagePanGeometry(baseImageSize: size, viewportSize: viewport), for: first)
    #expect(state.canPan && state.zoom == 1)
    state.setPanOffset(CGSize(width: 10_000, height: 10_000))
    let limit = mode == .fitWidth ? CGSize(width: 0, height: 664.1)
      : CGSize(width: 419.1, height: 0)
    near(state.panOffset, limit)
    state.setPanOffset(CGSize(width: -10_000, height: -10_000))
    near(state.panOffset, CGSize(width: -limit.width, height: -limit.height))
    state.setZoom(0.1)
    near(state.panOffset, .zero)
  }

  @Test("같은 맞춤을 다시 적용해도 표시 크기 정보가 남아 팬 한도를 지킨다")
  func repeatedFitRetainsGeometry() {
    let state = PhotoMapPreviewState()
    state.focus(on: first)
    state.setScaleMode(.fitWidth)
    state.setGeometry(ImagePanGeometry(baseImageSize: CGSize(width: 400, height: 1_200),
      viewportSize: CGSize(width: 400, height: 300)), for: first)
    state.setZoom(2)
    state.setPanOffset(CGSize(width: 100, height: 200))
    state.setScaleMode(.fitWidth)
    #expect(state.zoom == 1 && state.panOffset == .zero)
    state.setPanOffset(CGSize(width: 10_000, height: 10_000))
    near(state.panOffset, CGSize(width: 0, height: 465))
    state.setZoom(2)
    state.setPanOffset(CGSize(width: 10_000, height: 10_000))
    near(state.panOffset, CGSize(width: 220, height: 1_065))
  }

  @Test("가운데로 이동은 맞춤 방식과 확대율을 보존한다", arguments: [CGFloat(0.5), 2])
  func centeringPreservesScale(zoom: CGFloat) {
    let state = PhotoMapPreviewState()
    state.focus(on: first)
    state.setScaleMode(.fitHeight)
    state.setGeometry(ImagePanGeometry(baseImageSize: CGSize(width: 1_200, height: 300),
      viewportSize: CGSize(width: 400, height: 300)), for: first)
    state.setZoom(zoom)
    state.setPanOffset(CGSize(width: 80, height: 0))
    #expect(state.panOffset.width == 80)
    state.centerImage()
    #expect(state.zoom == zoom && state.baseScaleMode == .fitHeight && state.panOffset == .zero)
  }

  @Test("이전 사진의 늦은 크기 응답과 잘못된 입력은 현재 사진에 영향을 주지 않는다")
  func staleGeometryAndInvalidInput() {
    let state = PhotoMapPreviewState()
    state.focus(on: first)
    state.setScaleMode(.fitWidth)
    state.focus(on: second)
    state.setGeometry(ImagePanGeometry(baseImageSize: CGSize(width: 400, height: 1_200),
      viewportSize: CGSize(width: 400, height: 300)), for: second)
    let small = ImagePanGeometry(baseImageSize: CGSize(width: 10, height: 10),
      viewportSize: CGSize(width: 400, height: 300))
    state.setGeometry(small, for: first)
    state.setGeometry(ImagePanGeometry(baseImageSize: .zero, viewportSize: .zero), for: second)
    state.setPanOffset(CGSize(width: 10_000, height: 10_000))
    near(state.panOffset, CGSize(width: 0, height: 465))
    state.setZoom(.infinity)
    state.setZoom(.nan)
    state.setPanOffset(CGSize(width: CGFloat.nan, height: 0))
    #expect(state.zoom == 1)
    near(state.panOffset, CGSize(width: 0, height: 465))
    state.setZoom(1_000)
    #expect(state.zoom == 16)
    state.setZoom(-1)
    #expect(state.zoom == 0.1 && state.panOffset == .zero)
  }

  @Test("지도 맞춤 명령과 화면 전환은 뷰어 상태와 지도 카메라를 보존한다",
    arguments: [1, 4])
  func mapCommandsAreIsolated(imagesPerPage: Int) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await fixture.open(fixture.media)
    let store = fixture.store
    store.setImagesPerPage(imagesPerPage)
    let mainMode: BaseScaleMode = imagesPerPage == 1 ? .fitHeight : .fit
    store.setScaleMode(mainMode)
    store.zoom = 2.5
    store.panOffset = CGSize(width: 17, height: -23)
    let selection = store.selectedURLs
    let current = store.currentIndex
    let page = store.pageStartIndex
    let camera = store.photoMapViewport
    store.presentationMode = .map
    try await fixture.ready()
    let preview = store.photoMapPreview
    preview.focus(on: store.assets[1].id)
    store.setScaleMode(.fitWidth)
    store.zoomIn()
    #expect(preview.zoom == 1.25)
    store.zoomOut()
    #expect(preview.zoom == 1)
    store.updateZoom(with: 2)
    preview.setPanOffset(CGSize(width: 60, height: 80))
    store.centerImage()
    #expect(preview.zoom == 2 && preview.panOffset == .zero)
    store.setActualPixels()
    #expect(preview.baseScaleMode == .actualPixels && preview.zoom == 1)
    store.setFitToWindow()
    #expect(preview.baseScaleMode == .fit)
    preview.clearSelection()
    store.zoomIn()
    store.setScaleMode(.fitHeight)
    #expect(preview.zoom == 1 && preview.baseScaleMode == .fit)
    preview.focus(on: store.assets[1].id)
    store.presentationMode = .viewer
    #expect(!preview.hasSelection)
    #expect(store.photoMapViewport === camera)
    #expect(store.baseScaleMode == mainMode && store.zoom == 2.5)
    near(store.panOffset, CGSize(width: 17, height: -23))
    #expect(store.currentIndex == current && store.pageStartIndex == page)
    #expect(store.selectedURLs == selection)
  }

  @Test("다른 폴더를 열면 이전 지도 사진 선택을 지운다")
  func newLibraryClearsPreview() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await fixture.open(fixture.media)
    let store = fixture.store
    store.presentationMode = .map
    try await fixture.ready()
    store.photoMapPreview.focus(on: store.assets[1].id)
    store.setScaleMode(.fitWidth)
    store.zoomIn()
    let previousCamera = store.photoMapViewport
    try await fixture.open(fixture.otherMedia)
    #expect(!store.photoMapPreview.hasSelection && store.photoMapPreview.zoom == 1)
    #expect(store.photoMapPreview.panOffset == .zero)
    #expect(store.photoMapPreview.baseScaleMode == .fitWidth)
    #expect(store.photoMapViewport !== previousCamera)
    #expect(store.assets.allSatisfy { $0.url.deletingLastPathComponent() == fixture.otherMedia })
  }

  private func near(_ actual: CGSize, _ expected: CGSize) {
    #expect(abs(actual.width - expected.width) < 0.000_001)
    #expect(abs(actual.height - expected.height) < 0.000_001)
  }

  @MainActor private struct Fixture {
    let suite = "PhotoMapPreviewStateTests.\(UUID())"
    let defaults: UserDefaults
    let root: URL
    let media: URL
    let otherMedia: URL
    let store: AppStore

    init() throws {
      defaults = try #require(UserDefaults(suiteName: suite))
      root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
      media = root.appendingPathComponent("First", isDirectory: true)
      otherMedia = root.appendingPathComponent("Second", isDirectory: true)
      let qoi = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
        0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
      for folder in [media, otherMedia] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<4 {
          try qoi.write(to: folder.appendingPathComponent("synthetic-\(index).qoi"))
        }
      }
      store = AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: root.appendingPathComponent("marks.sqlite"))
    }

    func open(_ folder: URL) async throws {
      await store.photoMarks.waitUntilReady()
      store.open(urls: [folder])
      try await ready()
      try #require(store.assets.count == 4 && store.alert == nil)
    }

    func ready() async throws {
      let deadline = ContinuousClock.now + .seconds(8)
      while store.isLoading || store.isFiltering {
        try #require(ContinuousClock.now < deadline, "Map preview fixture did not load")
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    func cleanup() {
      store.endTrackingViewerPresentation()
      store.folderComparison.cancelLoads()
      store.photoMarks.flush()
      store.saveSessionNow()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
