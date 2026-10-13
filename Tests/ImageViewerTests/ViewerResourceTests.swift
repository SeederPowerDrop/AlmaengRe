import AppKit
import Combine
import Testing

@testable import ImageViewer

@Suite("뷰어 반복 입력과 비교 검색의 자원 사용")
@MainActor
struct ViewerResourceTests {
  @Test("일반 뷰어의 600회 이동은 주변 UI를 갱신하지 않고 좌표는 유지한다")
  func panUpdatesOnlyCanvas() async throws {
    let suite = "ViewerResourceTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    await store.photoMarks.waitUntilReady()
    store.zoom = 2
    store.isPhotoMarking = true
    store.panInteractionMode = .trackpadScroll
    var broadChanges = 0, canvasChanges = 0
    let observers = [
      store.objectWillChange.sink { broadChanges += 1 },
      store.viewerPan.objectWillChange.sink { canvasChanges += 1 },
    ]
    for _ in 0..<600 {
      #expect(store.handlePanInput(.trackpadScroll,
        delta: CGSize(width: 1, height: -0.5)))
    }
    #expect(broadChanges == 0 && canvasChanges == 600)
    #expect(store.panOffset == CGSize(width: 600, height: -300))
    for _ in 0..<600 { store.updatePan(by: .zero) }
    store.updatePan(by: CGSize(width: CGFloat.infinity, height: 1))
    #expect(broadChanges == 0 && canvasChanges == 600)
    #expect(store.panOffset == CGSize(width: 600, height: -300))
    store.setFitToWindow()
    #expect(store.panOffset == .zero)
    #expect(canvasChanges == 601)
    withExtendedLifetime(observers) {}
    store.saveSessionNow()
  }

  @Test("분리된 일반 뷰어 이동도 자동 저장하고 재실행 시 복원한다")
  func panAutosavesAndRestores() async throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let suite = "ViewerPanSessionTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    store.open(urls: [folder])
    try await wait { !store.isLoading }
    store.zoom = 2
    store.saveSessionNow()
    store.updatePan(by: CGSize(width: 31, height: -19))
    let persistence = ViewerSessionPersistence(defaults: defaults)
    try await wait {
      persistence.loadSession()?.panX == 31 && persistence.loadSession()?.panY == -19
    }
    let restored = AppStore(defaults: defaults, monitorsSystemResources: false)
    await restored.restoreLastSession()
    #expect(restored.assets.count == 3)
    #expect(restored.zoom == 2 && restored.panOffset == CGSize(width: 31, height: -19))
    store.saveSessionNow()
    restored.saveSessionNow()
  }

  @Test("비교 검색의 연속 입력은 마지막 결과만 게시하고 취소한 검색은 적용하지 않는다")
  func comparisonQueryBurstAndCancellation() async throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let pane = FolderComparisonPane()
    pane.load(folder)
    try await wait { !pane.isLoading }
    #expect(pane.assets.count == 3)
    var results: [[String]] = []
    let observer = pane.$assets.dropFirst().sink { results.append($0.map(\.filename)) }
    for text in ["0", "01", "02", "03", "01"] {
      pane.query.searchText = text
      await Task.yield()
    }
    try await wait { !pane.isFiltering }
    #expect(results == [["01.qoi"]])
    pane.query.searchText = "02"
    pane.cancelLoad()
    try await Task.sleep(for: .milliseconds(200))
    #expect(pane.assets.map(\.filename) == ["01.qoi"])
    #expect(!pane.isFiltering && results.count == 1)
    pane.query = LibraryQuery(sort: .nameDescending)
    try await wait { !pane.isFiltering }
    #expect(pane.assets.map(\.filename) == ["03.qoi", "02.qoi", "01.qoi"])
    withExtendedLifetime(observer) {}
  }

  @Test("검색 대기 중인 비교 칸은 선택을 받지 않고 다른 칸은 독립적으로 이동한다")
  func comparisonSelectionWaitsForItsQuery() async throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let suite = "ComparisonSelectionQueryTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let comparison = FolderComparisonStore(defaults: defaults, alignment: .sequence)
    comparison.first.load(folder)
    comparison.second.load(folder)
    try await wait { !comparison.first.isLoading && !comparison.second.isLoading }
    comparison.linksViewport = false
    comparison.updateZoom(2, on: .first)
    comparison.activeSide = .second

    // The state is set synchronously; no timing assumption about the worker is needed.
    comparison.first.query.sort = .nameDescending
    #expect(comparison.first.isFiltering)
    comparison.first.select(number: 2)
    comparison.jump(.first, number: 2)
    #expect(comparison.first.index == 0 && comparison.first.zoom == 2)
    #expect(comparison.activeSide == .second)

    comparison.jump(.second, number: 2)
    #expect(comparison.second.currentAsset?.filename == "02.qoi")
    try await wait { !comparison.first.isFiltering }
    #expect(comparison.first.currentAsset?.filename == "01.qoi")
    #expect(comparison.first.index == 2)
    comparison.jump(.first, number: 2)
    #expect(comparison.first.currentAsset?.filename == "02.qoi")
    #expect(comparison.activeSide == .first && comparison.first.zoom == 1)
  }

  @Test("파일명 비교는 다른 칸의 검색·읽기·짝맞춤이 끝나기 전 이전 짝을 선택하지 않는다")
  func matchedSelectionWaitsForBothListsAndPairs() async throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let suite = "ComparisonMatchingQueryTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let comparison = FolderComparisonStore(defaults: defaults, alignment: .filename)
    comparison.first.load(folder)
    comparison.second.load(folder)
    try await wait {
      !comparison.first.isLoading && !comparison.second.isLoading && !comparison.isMatching
    }
    #expect(comparison.pairs.count == 3)
    comparison.activeSide = .second

    comparison.second.query.sort = .nameDescending
    #expect(comparison.second.isFiltering && comparison.isMatching)
    comparison.jump(.first, number: 2)
    #expect(comparison.first.currentAsset?.filename == "01.qoi")
    #expect(comparison.activeSide == .second)
    try await wait { !comparison.second.isFiltering && !comparison.isMatching }

    comparison.alignment = .sequence
    comparison.alignment = .filename
    #expect(comparison.isMatching)
    comparison.jump(.first, number: 2)
    #expect(comparison.first.currentAsset?.filename == "01.qoi")
    #expect(comparison.activeSide == .second)
    try await wait { !comparison.isMatching }

    comparison.second.open(urls: [folder])
    #expect(comparison.second.isLoading && comparison.isMatching)
    comparison.jump(.first, number: 2)
    #expect(comparison.first.currentAsset?.filename == "01.qoi")
    #expect(comparison.activeSide == .second)
    try await wait {
      !comparison.second.isLoading && !comparison.second.isFiltering && !comparison.isMatching
    }
    comparison.jump(.first, number: 2)
    #expect(comparison.first.currentAsset?.filename == "02.qoi")
    #expect(comparison.second.currentAsset?.filename == "02.qoi")
    #expect(comparison.activeSide == .first)
  }

  private func fixture() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("viewer-resource-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let data = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
      0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    for name in ["01", "02", "03"] { try data.write(to: folder.appendingPathComponent(name + ".qoi")) }
    return folder
  }

  private func wait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
  }
}
