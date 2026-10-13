import AppKit
import Combine
import Testing

@testable import ImageViewer

@Suite("비교 사진 넘기기의 갱신 범위")
@MainActor
struct ComparisonNavigationPerformanceTests {
  @Test("600회 양쪽 넘기기는 바뀐 선택만 알리며 폴더를 다시 발행하지 않는다")
  func repeatedNavigationOnlyPublishesChangedSelection() async throws {
    let suite = "ComparisonNavigationPerformanceTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let folder = try fixture()
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    await store.photoMarks.waitUntilReady()
    store.isPhotoMarking = true
    let comparison = store.folderComparison
    comparison.first.load(folder)
    comparison.second.load(folder)
    try await wait { !comparison.first.isLoading && !comparison.second.isLoading }
    #expect(comparison.first.assets.count == 3 && comparison.second.assets.count == 3)

    var paneChanges = 0, comparisonChanges = 0, rootChanges = 0, collectionChanges = 0
    let observers = [
      comparison.first.objectWillChange.sink { paneChanges += 1 },
      comparison.second.objectWillChange.sink { paneChanges += 1 },
      comparison.objectWillChange.sink { comparisonChanges += 1 },
      store.objectWillChange.sink { rootChanges += 1 },
      comparison.first.$assets.dropFirst().sink { _ in collectionChanges += 1 },
      comparison.second.$assets.dropFirst().sink { _ in collectionChanges += 1 },
    ]
    for step in 0..<600 {
      comparison.navigateBoth(step.isMultiple(of: 2) ? 1 : -1)
      let expectedIndex = step.isMultiple(of: 2) ? 1 : 0
      #expect(comparison.first.index == expectedIndex && comparison.second.index == expectedIndex)
      #expect(comparison.first.currentAsset != nil && comparison.second.currentAsset != nil)
    }
    print("COMPARISON_NAVIGATION both 600: panes=\(paneChanges), comparison=\(comparisonChanges), app=\(rootChanges), collections=\(collectionChanges)")
    #expect(paneChanges == 1_200 && comparisonChanges == 1_200 && rootChanges == 1_200)
    #expect(collectionChanges == 0)

    paneChanges = 0; comparisonChanges = 0; rootChanges = 0
    for step in 0..<600 {
      comparison.navigate(.first, direction: step.isMultiple(of: 2) ? 1 : -1)
      #expect(comparison.second.index == 0 && comparison.activeSide == .first)
    }
    print("COMPARISON_NAVIGATION one 600: panes=\(paneChanges), comparison=\(comparisonChanges), app=\(rootChanges)")
    #expect(paneChanges == 600 && comparisonChanges == 600 && rootChanges == 600)
    #expect(collectionChanges == 0)

    // A held pane must neither change photos nor cause a broad notification.
    comparison.toggleLock(on: .second)
    paneChanges = 0; comparisonChanges = 0; rootChanges = 0
    for _ in 0..<600 { comparison.navigate(.second, direction: 1) }
    #expect(paneChanges == 0 && comparisonChanges == 0 && rootChanges == 0)
    #expect(comparison.second.index == 0 && comparison.second.currentAsset != nil)
    withExtendedLifetime(observers) {}
    store.saveSessionNow()
  }

  @Test("같은 사진을 다시 선택해도 목록을 갱신하지 않고 확대·이동 초기화는 유지한다")
  func repeatedSelectionRetainsResetBehavior() async throws {
    let suite = "ComparisonNavigationReselectTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let folder = try fixture()
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }
    let comparison = FolderComparisonStore(defaults: defaults, alignment: .sequence)
    comparison.first.load(folder)
    try await wait { !comparison.first.isLoading }
    let original = try #require(comparison.first.currentAsset)
    comparison.updateZoom(2, on: .first)
    comparison.pan(CGSize(width: 20, height: 10), on: .first)
    var changes = 0
    let observer = comparison.objectWillChange.sink { changes += 1 }
    for _ in 0..<600 { comparison.jump(.first, number: 1) }
    #expect(changes == 0)
    #expect(comparison.first.currentAsset == original)
    #expect(comparison.first.zoom == 1 && comparison.first.pan == .zero)
    withExtendedLifetime(observer) {}
  }

  @Test("필름스트립의 파일 식별자와 이동 번호는 재정렬·폴더 교체 후에도 일치한다")
  func filmstripIndexesFollowStableFileIdentity() {
    var assets = (0..<10_000).map { index in
      ImageAsset(url: URL(fileURLWithPath: "/photos/\(index).qoi"),
        byteCount: nil, modificationDate: nil)
    }
    let originalRows = IndexedImageAssets(assets)
    #expect(originalRows.count == 10_000)
    #expect(originalRows.index(originalRows.startIndex, offsetBy: 9_999) == 9_999)
    assets.swapAt(0, 9_999)
    let reorderedRows = IndexedImageAssets(assets)
    #expect(originalRows[0].asset.id == reorderedRows[9_999].asset.id)
    #expect(reorderedRows[0].index == 0 && reorderedRows[9_999].index == 9_999)
    #expect(reorderedRows[0].asset.id != originalRows[0].asset.id)
    let replacement = ImageAsset(url: URL(fileURLWithPath: "/other/0.qoi"),
      byteCount: nil, modificationDate: nil)
    let replacedRows = IndexedImageAssets([replacement])
    #expect(replacedRows[0].index == originalRows[0].index)
    #expect(replacedRows[0].asset.id != originalRows[0].asset.id)
    #expect(IndexedImageAssets([]).isEmpty)
  }

  private func wait(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
  }

  private func fixture() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("comparison-navigation-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let data = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
      0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    for index in 1...3 {
      try data.write(to: folder.appendingPathComponent("photo\(index).qoi"))
    }
    return folder
  }
}
