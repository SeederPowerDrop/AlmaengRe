import AppKit
import Testing

@testable import ImageViewer

@Suite("이미지 화면·가로·세로 맞춤")
struct ImageFitTests {
  @Test("가로와 세로 사진을 비율 손상 없이 전체 또는 한 축에 맞춘다")
  func landscapeAndPortraitGeometry() {
    let viewport = CGSize(width: 1_002, height: 802)
    let wide = CGSize(width: 4_000, height: 1_000)
    let tall = CGSize(width: 1_000, height: 4_000)
    #expect(ImageScaleGeometry.baseImageSize(mode: .fit, pixelSize: wide,
      viewportSize: viewport) == CGSize(width: 1_000, height: 250))
    #expect(ImageScaleGeometry.baseImageSize(mode: .fit, pixelSize: tall,
      viewportSize: viewport) == CGSize(width: 200, height: 800))
    #expect(ImageScaleGeometry.baseImageSize(mode: .fitWidth, pixelSize: tall,
      viewportSize: viewport) == CGSize(width: 1_000, height: 4_000))
    #expect(ImageScaleGeometry.baseImageSize(mode: .fitHeight, pixelSize: wide,
      viewportSize: viewport) == CGSize(width: 3_200, height: 800))

    // An A/B pane and a multi-view tile fit their own frame, not the full window.
    let pane = CGSize(width: 502, height: 402)
    #expect(ImageScaleGeometry.baseImageSize(mode: .fit, pixelSize: wide,
      viewportSize: pane) == CGSize(width: 500, height: 125))
    #expect(ImageScaleGeometry.baseImageSize(mode: .fitHeight, pixelSize: tall,
      viewportSize: pane) == CGSize(width: 100, height: 400))
  }

  @Test("실제 크기는 원본과 Retina 배율을 쓰며 미리보기는 전체 맞춤으로 시작한다")
  func actualPixelsAndInvalidInputs() {
    let preview = CGSize(width: 400, height: 200)
    let viewport = CGSize(width: 1_002, height: 802)
    #expect(ImageScaleGeometry.baseImageSize(mode: .actualPixels, pixelSize: preview,
      sourcePixelSize: CGSize(width: 6_000, height: 3_000), viewportSize: viewport,
      displayScale: 2) == CGSize(width: 3_000, height: 1_500))
    #expect(ImageScaleGeometry.baseImageSize(mode: .actualPixels, pixelSize: preview,
      viewportSize: viewport, displayScale: 2) == CGSize(width: 1_000, height: 500))
    #expect(ImageScaleGeometry.baseImageSize(mode: .fitWidth, pixelSize: .zero,
      viewportSize: viewport) == .zero)
    #expect(ImageScaleGeometry.baseImageSize(mode: .fitHeight, pixelSize: preview,
      viewportSize: CGSize(width: CGFloat.infinity, height: 500)) == .zero)
  }

  @Test("잘린 긴 축의 해상도도 요청하되 기존 메모리 한도를 지킨다")
  func fittedAxisResolution() {
    let viewport = CGSize(width: 1_000, height: 800)
    let memory: UInt64 = 8 * 1_024 * 1_024 * 1_024
    func pixels(_ mode: BaseScaleMode, _ size: CGSize?) -> Int {
      ImageScaleGeometry.requestedPixels(mode: mode, pixelSize: size,
        viewportSize: viewport, displayScale: 2, zoom: 1, itemCount: 2,
        physicalMemory: memory)
    }
    let wide = CGSize(width: 20_000, height: 1_000)
    let tall = CGSize(width: 1_000, height: 20_000)
    let normal = pixels(.fit, wide)
    let cap = ImageLoadingPolicy.maximumTilePixels(itemCount: 2, physicalMemory: memory)
    #expect(pixels(.fitHeight, wide) > normal)
    #expect(pixels(.fitWidth, tall) > normal)
    #expect(pixels(.fitHeight, wide) <= cap)
    #expect(pixels(.fitWidth, tall) <= cap)
    #expect(pixels(.fitWidth, nil) == normal)
    #expect(pixels(.fitWidth, .zero) == normal)
    // Once the source dimensions arrive, subsequent decode sizes do not alter it.
    #expect(pixels(.fitHeight, wide) == pixels(.fitHeight, CGSize(width: 2_000, height: 100)))
  }

  @Test("한 축 맞춤은 100% 이하에서도 넘친 부분을 이동하고 중앙 맞춤은 배율을 보존한다")
  @MainActor
  func fitPanAndCenter() async throws {
    let suite = "ImageFitTests.Pan.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    await store.photoMarks.waitUntilReady()
    store.setScaleMode(.fitWidth)
    let id = URL(fileURLWithPath: "/synthetic-tall-image.png")
    store.viewerPan.focus(on: id)
    store.viewerPan.setGeometry(ImagePanGeometry(baseImageSize: CGSize(width: 998, height: 3_992),
      viewportSize: CGSize(width: 1_000, height: 800)), for: id)
    #expect(store.canPan && store.zoom == 1)
    store.updatePan(by: CGSize(width: 100, height: 200))
    #expect(store.panOffset == CGSize(width: 0, height: 200))
    store.zoomOut()
    #expect(store.zoom == 0.8 && store.panOffset.height == 200)
    store.updateZoom(with: 0.5)
    #expect(store.zoom == 0.4 && store.panOffset.height == 200)
    store.centerImage()
    #expect(store.panOffset == .zero && store.zoom == 0.4 && store.baseScaleMode == .fitWidth)
    store.setFitToWindow()
    #expect(store.zoom == 1 && store.baseScaleMode == .fit && !store.canPan)
    store.saveSessionNow()
  }

  @Test("다중 뷰어는 진입·직접 페이지 변경·맞춤 명령 모두 프레임 맞춤으로 제한한다")
  @MainActor
  func multiViewerLimits() async throws {
    let suite = "ImageFitTests.Multi.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    await store.photoMarks.waitUntilReady()
    for mode in [BaseScaleMode.fitWidth, .fitHeight, .actualPixels] {
      store.setImagesPerPage(1)
      store.setScaleMode(mode)
      store.zoom = 2
      store.panOffset = CGSize(width: 25, height: 50)
      store.setImagesPerPage(4)
      #expect(store.isMultiImageViewer && store.baseScaleMode == .fit)
      #expect(store.zoom == 1 && store.panOffset == .zero)
      store.setScaleMode(mode)
      #expect(store.baseScaleMode == .fit)
    }
    store.setActualPixels()
    #expect(store.baseScaleMode == .fit)
    store.imagesPerPage = 1
    store.setActualPixels()
    #expect(store.baseScaleMode == .actualPixels)
    store.imagesPerPage = 6
    #expect(store.baseScaleMode == .fit)
    store.presentationMode = .overview
    store.setScaleMode(.fitHeight)
    store.presentationMode = .viewer
    #expect(store.baseScaleMode == .fit)
    store.saveSessionNow()
  }

  @Test("새 맞춤 모드와 이전 실제 크기 세션을 함께 복원한다")
  func oldAndNewSessionCoding() throws {
    let session = ViewerSession(sources: [], actualPixels: true)
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session))
      as? [String: Any])
    legacy.removeValue(forKey: "scaleMode")
    let decoded = try JSONDecoder().decode(ViewerSession.self,
      from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.scaleMode == nil)
    #expect(BaseScaleMode.restored(rawValue: decoded.scaleMode, actualPixels: decoded.actualPixels)
      == .actualPixels)
    #expect(BaseScaleMode.restored(rawValue: "future-mode", actualPixels: false) == .fit)
    #expect(BaseScaleMode.restored(rawValue: "fitHeight", actualPixels: true) == .fitHeight)
    let pane = ComparisonPaneSession(sources: [], selectedID: nil, actualPixels: true)
    let decodedPane = try JSONDecoder().decode(ComparisonPaneSession.self,
      from: JSONEncoder().encode(pane))
    #expect(decodedPane.scaleMode == nil && decodedPane.actualPixels)
  }
}
