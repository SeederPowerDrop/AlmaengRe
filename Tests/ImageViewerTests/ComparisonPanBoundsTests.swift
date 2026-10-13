import AppKit
import Combine
import Testing

@testable import ImageViewer

@Suite("비교 이미지 이동 경계")
@MainActor
struct ComparisonPanBoundsTests {
  private let landscape = ImagePanGeometry(baseImageSize: CGSize(width: 400, height: 200),
    viewportSize: CGSize(width: 400, height: 300))
  private let portrait = ImagePanGeometry(baseImageSize: CGSize(width: 200, height: 400),
    viewportSize: CGSize(width: 300, height: 400))

  @Test("트랙패드가 경계에 도달하면 값을 더 쌓지 않고 반대 방향으로 바로 이동한다")
  func committedPanStopsAtEdgeAndReversesImmediately() throws {
    let (comparison, defaults, suite) = try makeComparison()
    defer { defaults.removePersistentDomain(forName: suite) }
    comparison.linksViewport = false
    comparison.updatePanGeometry(landscape, on: .first)
    comparison.updateZoom(2, on: .first)
    comparison.pan(CGSize(width: 10_000, height: -10_000), on: .first)
    near(comparison.first.pan, CGSize(width: 220, height: -65))
    var notifications = 0
    let observation = comparison.first.viewport.objectWillChange.sink { notifications += 1 }
    for _ in 0..<100 {
      #expect(comparison.handlePointerPan(.trackpadScroll,
        delta: CGSize(width: 100, height: -100), on: .first, preferredMode: .primaryDrag))
    }
    #expect(notifications == 0)
    comparison.pan(CGSize(width: -10, height: 10), on: .first)
    near(comparison.first.pan, CGSize(width: 210, height: -55))
    #expect(notifications == 1)
    withExtendedLifetime(observation) {}
  }

  @Test("연결된 칸은 상대 좌표를 공유하며 각 칸의 크기에 맞는 끝에서 멈춘다")
  func linkedPanesClampIndependentlyAndCommitWithoutJumping() throws {
    let (comparison, defaults, suite) = try makeComparison()
    defer { defaults.removePersistentDomain(forName: suite) }
    comparison.updatePanGeometry(landscape, on: .first)
    comparison.updatePanGeometry(portrait, on: .second)
    comparison.updateZoom(2, on: .first)
    comparison.pan(CGSize(width: 200, height: 40), on: .first)
    near(comparison.first.pan, CGSize(width: 200, height: 40))
    near(comparison.second.pan, CGSize(width: 65, height: 80))
    comparison.updateLiveTranslation(CGSize(width: 20, height: 10), on: .first)
    near(comparison.effectivePan(on: .first), CGSize(width: 220, height: 50))
    near(comparison.effectivePan(on: .second), CGSize(width: 65, height: 100))
    comparison.endLiveTranslation(CGSize(width: 20, height: 10), on: .first)
    near(comparison.first.pan, CGSize(width: 220, height: 50))
    near(comparison.second.pan, CGSize(width: 65, height: 100))
  }

  @Test("드래그 중 경계를 많이 넘어도 조금 되돌리면 바로 움직이며 손을 떼도 유지한다")
  func liveOvershootDoesNotCreateReverseDeadZone() throws {
    let (comparison, defaults, suite) = try makeComparison()
    defer { defaults.removePersistentDomain(forName: suite) }
    comparison.updatePanGeometry(landscape, on: .first)
    comparison.updatePanGeometry(portrait, on: .second)
    comparison.updateZoom(2, on: .first)
    comparison.updateLiveTranslation(CGSize(width: 10_000, height: 10_000), on: .first)
    near(comparison.effectivePan(on: .first), CGSize(width: 220, height: 65))
    comparison.updateLiveTranslation(CGSize(width: 9_990, height: 9_990), on: .first)
    near(comparison.effectivePan(on: .first), CGSize(width: 210, height: 55))
    let second = comparison.effectivePan(on: .second)
    // Repeating the last total translation at onEnded must not add it again.
    comparison.endLiveTranslation(CGSize(width: 9_990, height: 9_990), on: .first)
    near(comparison.first.pan, CGSize(width: 210, height: 55))
    near(comparison.second.pan, second)
  }

  @Test("축소와 창 크기 변경은 저장된 이동도 줄이고 작은 축은 중앙에 둔다")
  func zoomAndResizeReconcileCommittedPosition() throws {
    let (comparison, defaults, suite) = try makeComparison()
    defer { defaults.removePersistentDomain(forName: suite) }
    comparison.linksViewport = false
    comparison.updatePanGeometry(landscape, on: .first)
    comparison.updateZoom(2, on: .first)
    comparison.pan(CGSize(width: 1_000, height: 1_000), on: .first)
    comparison.updatePanGeometry(ImagePanGeometry(baseImageSize: landscape.baseImageSize,
      viewportSize: CGSize(width: 700, height: 300)), on: .first)
    near(comparison.first.pan, CGSize(width: 74, height: 65))
    comparison.updateZoom(0.75, on: .first)
    near(comparison.first.pan, .zero)
    comparison.setScale(.actualPixels)
    #expect(comparison.first.viewport.snapshot.viewportSize == nil)
    comparison.updatePanGeometry(ImagePanGeometry(baseImageSize: CGSize(width: 800, height: 100),
      viewportSize: CGSize(width: 400, height: 300)), on: .first)
    comparison.pan(CGSize(width: -1_000, height: 1_000), on: .first)
    near(comparison.first.pan, CGSize(width: -220, height: 0))
    comparison.updateLiveMagnification(0.5, on: .first)
    near(comparison.effectivePan(on: .first), .zero)
    comparison.updateZoom(0.5, on: .first)
    comparison.resetLiveInput()
    near(comparison.first.pan, .zero)
  }

  @Test("잠긴 칸의 입력과 다른 칸의 연동은 기준 위치를 바꾸지 않는다")
  func lockedPaneAndStaleGeometry() throws {
    let (comparison, defaults, suite) = try makeComparison()
    defer { defaults.removePersistentDomain(forName: suite) }
    comparison.updatePanGeometry(landscape, on: .first)
    comparison.updatePanGeometry(portrait, on: .second)
    comparison.updateZoom(2, on: .first)
    comparison.pan(CGSize(width: 40, height: 20), on: .first)
    comparison.toggleLock(on: .first)
    comparison.pan(CGSize(width: 1_000, height: 1_000), on: .first)
    comparison.updateZoom(3, on: .second)
    comparison.pan(CGSize(width: 1_000, height: 1_000), on: .second)
    near(comparison.first.pan, CGSize(width: 40, height: 20))
    comparison.updatePanGeometry(portrait, on: .first,
      assetID: URL(fileURLWithPath: "/obsolete-presented-image.jpg"))
    #expect(comparison.first.baseImageSize == landscape.baseImageSize)
  }

  @Test("이전 버전의 과도한 저장 위치는 실제 이미지 크기를 받은 뒤 제한된다")
  func restoredOffsetsWaitForAuthoritativeGeometry() async throws {
    let (comparison, defaults, suite) = try makeComparison()
    defer { defaults.removePersistentDomain(forName: suite) }
    comparison.linksViewport = false
    let pane = ComparisonPaneSession(sources: [], selectedID: nil, zoom: 2,
      panX: 1_000, panY: -1_000, actualPixels: true)
    await comparison.restoreSession(ComparisonSession(first: pane, second: pane))
    #expect(comparison.first.normalizedPan == CGSize(width: 1_000, height: -1_000))
    #expect(comparison.first.viewport.snapshot.viewportSize == nil)
    comparison.updatePanGeometry(landscape, on: .first)
    near(comparison.first.pan, CGSize(width: 220, height: -65))
    near(comparison.first.normalizedPan, CGSize(width: 0.275, height: -0.1625))
    comparison.pan(CGSize(width: -10, height: 10), on: .first)
    near(comparison.first.pan, CGSize(width: 210, height: -55))
  }

  @Test("동시에 확대하고 드래그할 때 어느 제스처를 먼저 끝내도 위치가 튀지 않는다",
    arguments: [false, true])
  func simultaneousGesturesCommitWithoutDoubleApplying(dragEndsFirst: Bool) throws {
    let (comparison, defaults, suite) = try makeComparison()
    defer { defaults.removePersistentDomain(forName: suite) }
    comparison.updatePanGeometry(landscape, on: .first)
    comparison.updatePanGeometry(portrait, on: .second)
    comparison.updateZoom(2, on: .first)
    comparison.pan(CGSize(width: 80, height: 40), on: .first)
    comparison.updateLiveMagnification(1.5, on: .first)
    comparison.updateLiveTranslation(CGSize(width: 30, height: 10), on: .first)
    let first = comparison.effectivePan(on: .first)
    let second = comparison.effectivePan(on: .second)
    if dragEndsFirst {
      comparison.endLiveTranslation(CGSize(width: 30, height: 10), on: .first)
      near(comparison.effectivePan(on: .first), first)
      near(comparison.effectivePan(on: .second), second)
      comparison.updateLiveMagnification(1.6, on: .first)
      #expect(abs(comparison.effectiveZoom(on: .first) - 3.2) < 0.000_001)
      let endFirst = comparison.effectivePan(on: .first)
      let endSecond = comparison.effectivePan(on: .second)
      comparison.endLiveMagnification(1.6, on: .first)
      near(comparison.first.pan, endFirst)
      near(comparison.second.pan, endSecond)
    } else {
      comparison.endLiveMagnification(1.5, on: .first)
      near(comparison.effectivePan(on: .first), first)
      near(comparison.effectivePan(on: .second), second)
      comparison.updateLiveTranslation(CGSize(width: 40, height: 15), on: .first)
      near(comparison.effectivePan(on: .first),
        CGSize(width: first.width + 10, height: first.height + 5))
      let endSecond = comparison.effectivePan(on: .second)
      comparison.endLiveTranslation(CGSize(width: 40, height: 15), on: .first)
      near(comparison.first.pan, CGSize(width: first.width + 10, height: first.height + 5))
      near(comparison.second.pan, endSecond)
    }
    #expect(comparison.gestureSide == nil)
  }

  @Test("같은 사진 초기화는 경계를 보존하고 새 사진은 이전 크기로 제한하지 않는다")
  func geometryInvalidationFollowsImageIdentity() async throws {
    let (comparison, defaults, suite) = try makeComparison()
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("comparison-pan-identity-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }
    let pixel = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
      0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    for name in ["a.qoi", "b.qoi"] { try pixel.write(to: folder.appendingPathComponent(name)) }
    comparison.first.load(folder)
    await comparison.first.waitUntilLoaded()
    let original = try #require(comparison.first.currentAsset)
    comparison.updatePanGeometry(landscape, on: .first, assetID: original.id)
    comparison.first.select(number: 1)
    #expect(comparison.first.viewport.snapshot.viewportSize == landscape.viewportSize)
    comparison.first.select(number: 2)
    #expect(comparison.first.viewport.snapshot.viewportSize == nil)
    comparison.updatePanGeometry(landscape, on: .first, assetID: original.id)
    #expect(comparison.first.viewport.snapshot.viewportSize == nil)
    let next = try #require(comparison.first.currentAsset)
    comparison.updatePanGeometry(portrait, on: .first, assetID: next.id)
    #expect(comparison.first.viewport.snapshot.viewportSize == portrait.viewportSize)
  }

  @Test("핀치로 100% 아래가 된 뒤 드래그를 끝내도 다음 드래그에 이전 입력이 남지 않는다")
  func dragEndsAfterPinchDisablesPanning() throws {
    let (comparison, defaults, suite) = try makeComparison()
    defer { defaults.removePersistentDomain(forName: suite) }
    comparison.updatePanGeometry(landscape, on: .first)
    comparison.updatePanGeometry(portrait, on: .second)
    comparison.updateZoom(2, on: .first)
    comparison.updateLiveTranslation(CGSize(width: 100, height: 50), on: .first)
    comparison.updateLiveMagnification(0.4, on: .first)
    comparison.endLiveMagnification(0.4, on: .first)
    #expect(!comparison.canPan(on: .first))
    comparison.endLiveTranslation(CGSize(width: 110, height: 60), on: .first)
    #expect(comparison.gestureSide == nil)
    #expect(comparison.liveTranslation == .zero && comparison.liveMagnification == 1)
    comparison.updateZoom(2.5, on: .first)
    near(comparison.first.pan, .zero)
    comparison.updateLiveTranslation(CGSize(width: 10, height: 5), on: .first)
    near(comparison.effectivePan(on: .first), CGSize(width: 10, height: 5))
    comparison.endLiveTranslation(CGSize(width: 10, height: 5), on: .first)
    near(comparison.first.pan, CGSize(width: 10, height: 5))
    #expect(comparison.gestureSide == nil)
  }

  private func makeComparison() throws -> (FolderComparisonStore, UserDefaults, String) {
    let suite = "ComparisonPanBoundsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    return (FolderComparisonStore(defaults: defaults, alignment: .sequence), defaults, suite)
  }

  private func near(_ actual: CGSize, _ expected: CGSize) {
    #expect(abs(actual.width - expected.width) < 0.000_001)
    #expect(abs(actual.height - expected.height) < 0.000_001)
  }
}
