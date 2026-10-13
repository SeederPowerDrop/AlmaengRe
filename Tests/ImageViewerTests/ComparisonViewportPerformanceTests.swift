import AppKit
import Combine
import Testing

@testable import ImageViewer

@Suite("비교 화면의 이동 갱신 범위")
@MainActor
struct ComparisonViewportPerformanceTests {
  @Test("600회 팬과 드래그는 폴더·필름스트립·분류 패널을 다시 갱신하지 않는다")
  func viewportNotificationReplay() async throws {
    let suite = "ComparisonViewportPerformanceTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    await store.photoMarks.waitUntilReady()
    store.isPhotoMarking = true
    let comparison = store.folderComparison
    comparison.updateBaseImageSize(CGSize(width: 400, height: 200), on: .first)
    comparison.updateBaseImageSize(CGSize(width: 200, height: 400), on: .second)
    comparison.updateZoom(2, on: .first)
    var comparisonChanges = 0, paneChanges = 0, appChanges = 0
    var viewportChanges = 0, liveChanges = 0
    let observers = [
      comparison.objectWillChange.sink { comparisonChanges += 1 },
      comparison.first.objectWillChange.sink { paneChanges += 1 },
      comparison.second.objectWillChange.sink { paneChanges += 1 },
      store.objectWillChange.sink { appChanges += 1 },
      comparison.first.viewport.objectWillChange.sink { viewportChanges += 1 },
      comparison.second.viewport.objectWillChange.sink { viewportChanges += 1 },
      comparison.liveInput.objectWillChange.sink { liveChanges += 1 },
    ]
    let start = ContinuousClock.now
    for _ in 0..<600 { comparison.pan(CGSize(width: 1, height: 0.5), on: .first) }
    print("VIEWPORT_REPLAY pointer 600: comparison=\(comparisonChanges), panes=\(paneChanges), app=\(appChanges), duration=\(start.duration(to: .now))")
    #expect(comparisonChanges == 0 && paneChanges == 0 && appChanges == 0)
    #expect(viewportChanges == 1_200 && liveChanges == 0)
    expectNear(comparison.first.pan, CGSize(width: 600, height: 300))
    expectNear(comparison.second.pan, CGSize(width: 300, height: 600))
    viewportChanges = 0
    for step in 1...600 {
      comparison.updateLiveTranslation(CGSize(width: step, height: step / 2), on: .first)
    }
    print("VIEWPORT_REPLAY live 600: comparison=\(comparisonChanges), panes=\(paneChanges), app=\(appChanges)")
    #expect(comparisonChanges == 0 && paneChanges == 0 && appChanges == 0)
    #expect(viewportChanges == 0 && liveChanges == 600)
    let liveFirst = comparison.effectivePan(on: .first)
    let liveSecond = comparison.effectivePan(on: .second)
    expectNear(liveFirst, CGSize(width: 1_200, height: 600))
    expectNear(liveSecond, CGSize(width: 600, height: 1_200))
    comparison.pan(comparison.liveTranslation, on: .first)
    comparison.resetLiveInput()
    #expect(comparisonChanges == 0 && paneChanges == 0 && appChanges == 0)
    #expect(viewportChanges == 2 && liveChanges == 601)
    expectNear(comparison.first.pan, liveFirst)
    expectNear(comparison.second.pan, liveSecond)
    withExtendedLifetime(observers) {}
    store.saveSessionNow()
  }

  @Test("동일한 확대·이동 입력은 재발행하지 않고 활성 칸만 한 번 변경한다")
  func unchangedValuesAndFocus() throws {
    let suite = "ComparisonViewportNoopTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let comparison = FolderComparisonStore(defaults: defaults)
    comparison.updateZoom(2, on: .first)
    comparison.updateLiveTranslation(CGSize(width: 8, height: 4), on: .first)
    var broadChanges = 0, imageChanges = 0, liveChanges = 0
    let observers = [
      comparison.objectWillChange.sink { broadChanges += 1 },
      comparison.first.viewport.objectWillChange.sink { imageChanges += 1 },
      comparison.second.viewport.objectWillChange.sink { imageChanges += 1 },
      comparison.liveInput.objectWillChange.sink { liveChanges += 1 },
    ]
    for _ in 0..<600 {
      comparison.updateZoom(1, on: .first)
      comparison.pan(.zero, on: .first)
      comparison.updateBaseImageSize(CGSize(width: 1, height: 1), on: .first)
      comparison.updateLiveTranslation(CGSize(width: 8, height: 4), on: .first)
      comparison.updateLiveMagnification(1, on: .first)
    }
    #expect(broadChanges == 0 && imageChanges == 0 && liveChanges == 0)
    comparison.updateLiveTranslation(CGSize(width: CGFloat.infinity, height: 1), on: .first)
    #expect(liveChanges == 0)
    for step in 1...600 {
      comparison.updateLiveTranslation(CGSize(width: step, height: step), on: .second)
    }
    #expect(broadChanges == 1 && imageChanges == 0 && liveChanges == 600)
    #expect(comparison.activeSide == .second && comparison.gestureSide == .second)
    comparison.resetLiveInput()
    comparison.resetLiveInput()
    #expect(liveChanges == 601 && broadChanges == 1)
    withExtendedLifetime(observers) {}
  }

  @Test("배율과 위치는 한 번에 갱신하며 기본 표시 크기는 서로 독립적이다")
  func coherentViewportSnapshots() throws {
    let suite = "ComparisonViewportSnapshotTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let comparison = FolderComparisonStore(defaults: defaults)
    comparison.updateBaseImageSize(CGSize(width: 400, height: 200), on: .first)
    comparison.updateBaseImageSize(CGSize(width: 200, height: 400), on: .second)
    comparison.updateZoom(2, on: .first)
    comparison.pan(CGSize(width: 40, height: 20), on: .first)
    var a: [FolderComparisonViewport.Snapshot] = [], b: [FolderComparisonViewport.Snapshot] = []
    let observers = [
      comparison.first.viewport.$snapshot.dropFirst().sink { a.append($0) },
      comparison.second.viewport.$snapshot.dropFirst().sink { b.append($0) },
    ]
    comparison.updateZoom(0.5, on: .first)
    #expect(a.count == 1 && b.count == 1)
    #expect(a.last?.zoom == 1 && a.last?.normalizedPan == .zero)
    #expect(b.last?.zoom == 1 && b.last?.normalizedPan == .zero)
    #expect(a.last?.baseImageSize == CGSize(width: 400, height: 200))
    #expect(b.last?.baseImageSize == CGSize(width: 200, height: 400))
    comparison.setScale(.actualPixels)
    #expect(a.count == 2 && b.count == 2)
    #expect(a.last?.scaleMode == .actualPixels && b.last?.scaleMode == .actualPixels)
    withExtendedLifetime(observers) {}
  }

  @Test("분리된 뷰포트도 자동 저장되며 진행 중인 드래그는 저장하지 않는다")
  func committedViewportStillSavesSession() async throws {
    let suite = "ComparisonViewportSessionTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("comparison-viewport-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }
    let data = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
      0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    try data.write(to: folder.appendingPathComponent("photo.qoi"))
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    await store.photoMarks.waitUntilReady()
    store.presentationMode = .folderComparison
    let comparison = store.folderComparison
    comparison.first.load(folder)
    comparison.second.load(folder)
    for _ in 0..<300 {
      if !comparison.first.isLoading && !comparison.second.isLoading { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!comparison.first.isLoading && !comparison.second.isLoading)
    comparison.updateBaseImageSize(CGSize(width: 400, height: 200), on: .first)
    comparison.updateZoom(2, on: .first)
    store.saveSessionNow()
    let persistence = ViewerSessionPersistence(defaults: defaults)
    #expect(persistence.loadSession()?.comparison?.first.panX == 0)
    comparison.pan(CGSize(width: 40, height: 20), on: .first)
    // Neither the comparison nor AppStore publishes this pan. Its viewport must
    // still schedule the existing debounced save through the separate subscriber.
    let saveDeadline = ContinuousClock.now + .seconds(5)
    while persistence.loadSession()?.comparison?.first.panX != 0.05,
      ContinuousClock.now < saveDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let saved = try #require(persistence.loadSession()?.comparison)
    #expect(saved.first.zoom == 2 && saved.first.panX == 0.05 && saved.first.panY == 0.05)
    #expect(saved.second.zoom == 2 && saved.second.panX == 0.05 && saved.second.panY == 0.05)
    comparison.updateLiveTranslation(CGSize(width: 80, height: 40), on: .first)
    comparison.updateLiveMagnification(1.5, on: .first)
    try await Task.sleep(for: .milliseconds(700))
    #expect(persistence.loadSession()?.comparison == saved)
    comparison.updateZoom(1.5, on: .first)
    comparison.resetLiveInput()
    let zoomSaveDeadline = ContinuousClock.now + .seconds(5)
    while persistence.loadSession()?.comparison?.first.zoom != 3,
      ContinuousClock.now < zoomSaveDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(persistence.loadSession()?.comparison?.first.zoom == 3)
    store.saveSessionNow()
  }

  private func expectNear(_ actual: CGSize, _ expected: CGSize) {
    #expect(abs(actual.width - expected.width) < 0.000_001)
    #expect(abs(actual.height - expected.height) < 0.000_001)
  }
}
