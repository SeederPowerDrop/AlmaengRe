import AppKit
import Combine
import Testing

@testable import ImageViewer

@Suite("확대 이미지의 이동 경계")
struct ImagePanBoundsTests {
  @Test("확대된 축은 작은 여유만 허용하고 작은 축은 가운데에 둔다")
  func portraitAndLandscapeEdges() {
    let portrait = ImagePanGeometry(baseImageSize: CGSize(width: 400, height: 800),
      viewportSize: CGSize(width: 1_000, height: 800))
    #expect(portrait.constrained(CGSize(width: 10_000, height: 10_000), zoom: 1.5)
      == CGSize(width: 0, height: 224))
    #expect(portrait.constrained(CGSize(width: -10_000, height: -10_000), zoom: 1.5)
      == CGSize(width: 0, height: -224))
    let landscape = ImagePanGeometry(baseImageSize: CGSize(width: 800, height: 400),
      viewportSize: CGSize(width: 800, height: 1_000))
    #expect(landscape.constrained(CGSize(width: 10_000, height: -10_000), zoom: 1.5)
      == CGSize(width: 224, height: 0))
  }

  @Test("작은 타일은 여유도 줄고 화면 맞춤이나 작은 실제 크기는 중앙에 남는다")
  func smallPanesAndActualPixels() {
    let tile = ImagePanGeometry(baseImageSize: CGSize(width: 100, height: 80),
      viewportSize: CGSize(width: 100, height: 80))
    #expect(tile.constrained(CGSize(width: 1_000, height: -1_000), zoom: 2)
      == CGSize(width: 55, height: -44))
    #expect(tile.constrained(CGSize(width: 1_000, height: -1_000), zoom: 1) == .zero)
    let small = ImagePanGeometry(baseImageSize: CGSize(width: 40, height: 60),
      viewportSize: CGSize(width: 1_000, height: 800))
    #expect(small.constrained(CGSize(width: 1_000, height: 1_000), zoom: 1) == .zero)
  }

  @Test("잘못된 치수나 입력이 화면 좌표로 전파되지 않는다")
  func invalidGeometry() {
    let valid = ImagePanGeometry(baseImageSize: CGSize(width: 800, height: 600),
      viewportSize: CGSize(width: 800, height: 600))
    #expect(valid.constrained(CGSize(width: CGFloat.nan, height: CGFloat.infinity), zoom: 2) == .zero)
    #expect(valid.constrained(CGSize(width: 1, height: 2), zoom: .infinity) == .zero)
    let empty = ImagePanGeometry(baseImageSize: .zero, viewportSize: .zero)
    #expect(empty.constrained(CGSize(width: 1, height: 2), zoom: 2) == .zero)
  }

  @Test("모든 포인터 입력은 같은 경계를 소비하며 반대 방향은 즉시 반응한다")
  @MainActor
  func inputsClampWithoutBroadUpdates() async throws {
    let suite = "PanBoundsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    await store.photoMarks.waitUntilReady()
    let assetID = URL(fileURLWithPath: "/synthetic-pan.jpg")
    store.viewerPan.focus(on: assetID)
    store.viewerPan.setGeometry(ImagePanGeometry(baseImageSize: CGSize(width: 800, height: 600),
      viewportSize: CGSize(width: 800, height: 600)), for: assetID)
    store.zoom = 2
    store.panInteractionMode = .trackpadScroll
    var broad = 0, canvas = 0
    let observers = [store.objectWillChange.sink { broad += 1 },
      store.viewerPan.objectWillChange.sink { canvas += 1 }]
    for _ in 0..<600 {
      #expect(store.handlePanInput(.trackpadScroll, delta: CGSize(width: 1_000, height: -1_000)))
    }
    #expect(store.panOffset == CGSize(width: 424, height: -324))
    #expect(broad == 0 && canvas == 1)
    store.updatePan(by: CGSize(width: -1, height: 1))
    #expect(store.panOffset == CGSize(width: 423, height: -323))
    #expect(broad == 0 && canvas == 2)
    withExtendedLifetime(observers) {}

    let modes: [(PanInteractionMode, PanInputKind)] = [
      (.spacePrimaryDrag, .spacePrimaryDrag), (.secondaryDrag, .secondaryDrag),
      (.middleDrag, .middleDrag), (.trackpadScroll, .trackpadScroll),
    ]
    for (mode, input) in modes {
      store.panInteractionMode = mode
      store.panOffset = .zero
      #expect(store.handlePanInput(input, delta: CGSize(width: 10_000, height: -10_000)))
      #expect(store.panOffset == CGSize(width: 424, height: -324))
      #expect(store.handlePanInput(input, delta: CGSize(width: -1, height: 1)))
      #expect(store.panOffset == CGSize(width: 423, height: -323))
    }

    // A direct binding from the zoom slider must also constrain the stored position.
    store.zoom = 1.5
    #expect(store.panOffset == CGSize(width: 224, height: -174))
    store.viewerPan.setGeometry(ImagePanGeometry(baseImageSize: CGSize(width: 800, height: 600),
      viewportSize: CGSize(width: 1_000, height: 1_000)), for: assetID)
    #expect(store.panOffset == CGSize(width: 124, height: 0))
    store.zoom = 0.5
    #expect(store.panOffset == .zero)
    store.saveSessionNow()
  }

  @Test("새 이미지와 실제 크기의 미확정 치수는 이전 경계를 적용하지 않는다")
  @MainActor
  func pendingGeometryPreservesRestoredPosition() {
    let pan = ViewerPanState()
    let old = URL(fileURLWithPath: "/old.jpg"), next = URL(fileURLWithPath: "/next.dng")
    pan.focus(on: old)
    pan.setZoom(2)
    pan.setGeometry(ImagePanGeometry(baseImageSize: CGSize(width: 100, height: 100),
      viewportSize: CGSize(width: 100, height: 100)), for: old)
    pan.focus(on: next)
    pan.setOffset(CGSize(width: 500, height: -400))
    pan.setGeometry(ImagePanGeometry(baseImageSize: CGSize(width: 2_000, height: 1_500),
      viewportSize: .zero), for: next)
    #expect(pan.offset == CGSize(width: 500, height: -400))
    // A late old frame and no authoritative size for the new RAW must preserve saved 1:1 pan.
    pan.setGeometry(ImagePanGeometry(baseImageSize: CGSize(width: 100, height: 100),
      viewportSize: CGSize(width: 100, height: 100)), for: old)
    #expect(pan.offset == CGSize(width: 500, height: -400))
    pan.setGeometry(ImagePanGeometry(baseImageSize: CGSize(width: 2_000, height: 1_500),
      viewportSize: CGSize(width: 1_000, height: 800)), for: next)
    #expect(pan.offset == CGSize(width: 500, height: -400))
    pan.clearGeometry()
    pan.setZoom(0.5)
    #expect(pan.offset == CGSize(width: 500, height: -400))
  }
}
