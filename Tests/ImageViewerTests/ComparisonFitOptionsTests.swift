import AppKit
import Testing

@testable import ImageViewer

@Suite("비교 이미지 화면 맞춤")
@MainActor
struct ComparisonFitOptionsTests {
  @Test("가로·세로 맞춤은 각 칸의 경계를 지키며 100%에서도 넘치는 축을 이동한다",
    arguments: [BaseScaleMode.fitWidth, .fitHeight])
  func axisFitUsesEachPaneBounds(mode: BaseScaleMode) throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let comparison = fixture.comparison
    comparison.setScale(mode)
    let firstSize = mode == .fitWidth ? CGSize(width: 400, height: 1_200)
      : CGSize(width: 1_200, height: 300)
    let secondSize = mode == .fitWidth ? CGSize(width: 300, height: 100)
      : CGSize(width: 100, height: 400)
    comparison.updatePanGeometry(ImagePanGeometry(baseImageSize: firstSize,
      viewportSize: CGSize(width: 400, height: 300)), on: .first)
    comparison.updatePanGeometry(ImagePanGeometry(baseImageSize: secondSize,
      viewportSize: CGSize(width: 300, height: 400)), on: .second)
    #expect(comparison.first.scaleMode == mode && comparison.second.scaleMode == mode)
    #expect(comparison.first.zoom == 1 && comparison.second.zoom == 1)
    #expect(comparison.canPan(on: .first))
    comparison.pan(CGSize(width: 120, height: 120), on: .first)
    near(comparison.first.pan, mode == .fitWidth ? CGSize(width: 0, height: 120)
      : CGSize(width: 120, height: 0))
    near(comparison.second.pan, .zero)
    comparison.updateZoom(0.75)
    #expect(comparison.first.zoom == 0.75)
    #expect(comparison.canPan(on: .first))
    near(comparison.first.pan, mode == .fitWidth ? CGSize(width: 0, height: 90)
      : CGSize(width: 90, height: 0))
  }

  @Test("맞춤은 진행 중인 확대·이동을 비우고 가운데 정렬은 현재 확대율을 보존한다")
  func explicitCommandsResolveLiveInput() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let comparison = fixture.comparison
    comparison.setScale(.fitWidth)
    let geometry = ImagePanGeometry(baseImageSize: CGSize(width: 400, height: 1_200),
      viewportSize: CGSize(width: 400, height: 300))
    comparison.updatePanGeometry(geometry, on: .first)
    comparison.updatePanGeometry(geometry, on: .second)
    comparison.updateLiveMagnification(1.5, on: .first)
    comparison.updateLiveTranslation(CGSize(width: 20, height: 80), on: .first)
    comparison.centerImage()
    for side in FolderComparisonSide.allCases {
      #expect(comparison.pane(side).scaleMode == .fitWidth)
      #expect(comparison.pane(side).zoom == 1.5)
      near(comparison.effectivePan(on: side), .zero)
    }
    #expect(comparison.gestureSide == nil)
    comparison.updateLiveMagnification(2, on: .first)
    comparison.updateLiveTranslation(CGSize(width: 20, height: 80), on: .first)
    comparison.setScale(.fitHeight)
    for side in FolderComparisonSide.allCases {
      #expect(comparison.pane(side).scaleMode == .fitHeight)
      #expect(comparison.effectiveZoom(on: side) == 1)
      near(comparison.effectivePan(on: side), .zero)
    }
    #expect(comparison.gestureSide == nil)
    #expect(comparison.liveMagnification == 1 && comparison.liveTranslation == .zero)
  }

  @Test("연결을 끄거나 기준 칸을 잠그면 맞춤과 가운데 정렬은 조작 대상만 바꾼다")
  func independentAndLockedPanesKeepTheirTransforms() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let comparison = fixture.comparison
    comparison.linksViewport = false
    comparison.setScale(.fitWidth)
    comparison.updatePanGeometry(ImagePanGeometry(baseImageSize: CGSize(width: 400, height: 1_200),
      viewportSize: CGSize(width: 400, height: 300)), on: .first)
    comparison.pan(CGSize(width: 0, height: 120), on: .first)
    comparison.activeSide = .second
    comparison.setScale(.fitHeight)
    comparison.updatePanGeometry(ImagePanGeometry(baseImageSize: CGSize(width: 1_200, height: 300),
      viewportSize: CGSize(width: 400, height: 300)), on: .second)
    comparison.updateZoom(2)
    comparison.pan(CGSize(width: 150, height: 0), on: .second)
    comparison.centerImage()
    #expect(comparison.second.scaleMode == .fitHeight && comparison.second.zoom == 2)
    near(comparison.second.pan, .zero)
    near(comparison.first.pan, CGSize(width: 0, height: 120))
    comparison.toggleLock(on: .first)
    let locked = comparison.first.viewport.snapshot
    comparison.linksViewport = true
    comparison.setScale(.fitWidth)
    comparison.updatePanGeometry(ImagePanGeometry(baseImageSize: CGSize(width: 400, height: 1_200),
      viewportSize: CGSize(width: 400, height: 300)), on: .second)
    comparison.pan(CGSize(width: 0, height: 150), on: .second)
    comparison.centerImage()
    #expect(comparison.first.viewport.snapshot == locked)
    near(comparison.second.pan, .zero)
    comparison.activeSide = .first
    comparison.setScale(.fit)
    comparison.centerImage()
    #expect(comparison.first.viewport.snapshot == locked)
  }

  @Test("새 맞춤 방식과 이동 위치는 세션에 저장되며 잠긴 기준 칸도 그대로 복원한다")
  func roundTripsAxisFitAndLockedReference() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let comparison = fixture.comparison
    try await fixture.openImages()
    comparison.linksViewport = false
    comparison.activeSide = .first
    comparison.setScale(.fitWidth)
    comparison.updatePanGeometry(ImagePanGeometry(baseImageSize: CGSize(width: 400, height: 1_200),
      viewportSize: CGSize(width: 400, height: 300)), on: .first)
    comparison.pan(CGSize(width: 0, height: 120))
    comparison.toggleLock(on: .first)
    comparison.setScale(.fitHeight)
    comparison.updatePanGeometry(ImagePanGeometry(baseImageSize: CGSize(width: 1_200, height: 300),
      viewportSize: CGSize(width: 400, height: 300)), on: .second)
    comparison.updateZoom(1.5)
    comparison.pan(CGSize(width: 180, height: 0))
    let saved = try #require(comparison.captureSession())
    let decoded = try JSONDecoder().decode(ComparisonSession.self,
      from: JSONEncoder().encode(saved))
    let restored = FolderComparisonStore(defaults: fixture.defaults, alignment: .sequence)
    defer { restored.cancelLoads() }
    await restored.restoreSession(decoded)
    #expect(restored.first.scaleMode == .fitWidth && restored.first.isLocked)
    #expect(restored.second.scaleMode == .fitHeight && !restored.second.isLocked)
    #expect(restored.first.zoom == 1 && restored.second.zoom == 1.5)
    near(restored.first.normalizedPan, comparison.first.normalizedPan)
    near(restored.second.normalizedPan, comparison.second.normalizedPan)
    #expect(restored.activeSide == .second)
    #expect(restored.first.currentAsset?.sessionID == comparison.first.currentAsset?.sessionID)
    #expect(restored.second.currentAsset?.sessionID == comparison.second.currentAsset?.sessionID)
  }

  @Test("이전 세션과 알 수 없는 맞춤 값은 기존 실제 크기 설정으로 복원한다")
  func restoresLegacyAndUnknownModes() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try await fixture.openImages()
    let saved = try #require(fixture.comparison.captureSession())
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))
      as? [String: Any])
    var first = try #require(object["first"] as? [String: Any])
    var second = try #require(object["second"] as? [String: Any])
    first.removeValue(forKey: "scaleMode")
    first["actualPixels"] = true
    second["scaleMode"] = "future-scaling-mode"
    second["actualPixels"] = false
    object["first"] = first
    object["second"] = second
    let legacy = try JSONDecoder().decode(ComparisonSession.self,
      from: JSONSerialization.data(withJSONObject: object))
    let restored = FolderComparisonStore(defaults: fixture.defaults, alignment: .sequence)
    defer { restored.cancelLoads() }
    await restored.restoreSession(legacy)
    #expect(restored.first.scaleMode == .actualPixels)
    #expect(restored.second.scaleMode == .fit)
  }

  private func near(_ actual: CGSize, _ expected: CGSize) {
    #expect(abs(actual.width - expected.width) < 0.000_001)
    #expect(abs(actual.height - expected.height) < 0.000_001)
  }

  @MainActor private struct Fixture {
    let suite = "ComparisonFitOptionsTests.\(UUID())"
    let defaults: UserDefaults
    let comparison: FolderComparisonStore
    let root: URL

    init() throws {
      defaults = try #require(UserDefaults(suiteName: suite))
      comparison = FolderComparisonStore(defaults: defaults, alignment: .sequence)
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("comparison-fit-options-\(UUID())", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func openImages() async throws {
      let pixel = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
        0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
      for side in FolderComparisonSide.allCases {
        let file = root.appendingPathComponent("\(side.rawValue).qoi")
        try pixel.write(to: file)
        comparison.open(urls: [file], for: side)
      }
      await comparison.first.waitUntilLoaded()
      await comparison.second.waitUntilLoaded()
      #expect(comparison.first.currentAsset != nil && comparison.second.currentAsset != nil)
    }

    func remove() {
      comparison.cancelLoads()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
