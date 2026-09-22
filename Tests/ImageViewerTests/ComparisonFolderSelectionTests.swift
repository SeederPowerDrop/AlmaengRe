import AppKit
import Testing

@testable import ImageViewer

@Suite("이미지 비교 폴더 순차 선택")
@MainActor
struct ComparisonFolderSelectionTests {
  @Test("각 단계는 폴더 하나와 선택 버튼을 표시한다", arguments: FolderComparisonSide.allCases)
  func folderPanelConfiguration(side: FolderComparisonSide) {
    let folder = FileManager.default.temporaryDirectory
    let panel = ComparisonFolderOpenPanel.make(for: side, directoryURL: folder)
    #expect(panel.canChooseDirectories && !panel.canChooseFiles && !panel.allowsMultipleSelection)
    #expect(panel.title == L10n.text(side == .first ? "A 폴더 선택 (1/2)" : "B 폴더 선택 (2/2)"))
    #expect(panel.prompt == L10n.text("이 폴더 선택"))
    #expect(panel.message == L10n.text(side == .first
      ? "첫 번째로 비교할 폴더를 연 뒤 ‘이 폴더 선택’을 누르세요."
      : "두 번째로 비교할 폴더를 연 뒤 ‘이 폴더 선택’을 누르세요."))
    #expect(panel.directoryURL?.standardizedFileURL == folder.standardizedFileURL)
  }

  @Test("서로 다른 상위 폴더의 A와 B를 차례로 고르면 두 목록을 함께 연다")
  func sequentialFoldersFromDifferentParents() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = try album(root, path: "left/A", count: 2)
    let b = try album(root, path: "right/B", count: 3)
    let comparison = makeStore()
    comparison.activeSide = .second
    comparison.gestureSide = .second
    comparison.liveMagnification = 1.5
    comparison.liveTranslation = CGSize(width: 30, height: 40)
    var calls: [FolderComparisonSide] = []
    comparison.choosePair { side, directory in
      calls.append(side)
      #expect(comparison.first.assets.isEmpty && comparison.second.assets.isEmpty)
      #expect(!comparison.first.isLoading && !comparison.second.isLoading)
      if side == .first {
        #expect(directory == nil)
        return a
      }
      #expect(directory == a.deletingLastPathComponent())
      return b
    }
    try await waitForLoads(comparison)
    #expect(calls == [.first, .second])
    #expect(comparison.first.folderURL == a && comparison.second.folderURL == b)
    #expect(comparison.first.assets.count == 2 && comparison.second.assets.count == 3)
    #expect(comparison.activeSide == .first && comparison.gestureSide == nil)
    #expect(comparison.liveMagnification == 1 && comparison.liveTranslation == .zero)
    #expect(comparison.alert == nil)
  }

  @Test("A 또는 B 단계에서 취소하면 기존 목록·선택·확대 상태를 유지한다",
    arguments: FolderComparisonSide.allCases)
  func cancellationPreservesBothPanes(at cancelledSide: FolderComparisonSide) async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let oldA = try album(root, path: "old/A", count: 3)
    let oldB = try album(root, path: "old/B", count: 4)
    let replacement = try album(root, path: "new/A", count: 2)
    let comparison = makeStore()
    comparison.first.load(oldA)
    comparison.second.load(oldB)
    try await waitForLoads(comparison)
    comparison.jump(.first, number: 2)
    comparison.jump(.second, number: 3)
    comparison.updateZoom(2, on: .second)
    comparison.pan(CGSize(width: 25, height: 30), on: .second)
    comparison.gestureSide = .second
    comparison.liveMagnification = 1.25
    comparison.liveTranslation = CGSize(width: 5, height: 10)
    let firstAsset = comparison.first.currentAsset
    let secondAsset = comparison.second.currentAsset
    let firstPan = comparison.first.normalizedPan
    let secondPan = comparison.second.normalizedPan
    var calls: [FolderComparisonSide] = []
    comparison.choosePair { side, directory in
      calls.append(side)
      #expect(directory == (side == .first ? oldA : oldB))
      return side == cancelledSide ? nil : replacement
    }
    #expect(calls == (cancelledSide == .first ? [.first] : [.first, .second]))
    #expect(!comparison.first.isLoading && !comparison.second.isLoading)
    #expect(comparison.first.folderURL == oldA && comparison.second.folderURL == oldB)
    #expect(comparison.first.currentAsset == firstAsset && comparison.second.currentAsset == secondAsset)
    #expect(comparison.first.zoom == 2 && comparison.second.zoom == 2)
    #expect(comparison.first.normalizedPan == firstPan && comparison.second.normalizedPan == secondPan)
    #expect(comparison.activeSide == .second && comparison.gestureSide == .second)
    #expect(comparison.liveMagnification == 1.25)
    #expect(comparison.liveTranslation == CGSize(width: 5, height: 10))
    #expect(comparison.alert == nil)
  }

  @Test("어느 한쪽이 잠겨 있으면 폴더 선택을 시작하지 않는다",
    arguments: FolderComparisonSide.allCases)
  func lockedPanePreventsSelection(side: FolderComparisonSide) {
    let comparison = makeStore()
    comparison.toggleLock(on: side)
    var called = false
    comparison.choosePair { _, _ in
      called = true
      return nil
    }
    #expect(!called && comparison.pane(side).isLocked)
    #expect(comparison.first.assets.isEmpty && comparison.second.assets.isEmpty)
  }

  @Test("선택 창을 연 도중 잠금이 바뀌어도 두 목록을 교체하지 않는다",
    arguments: FolderComparisonSide.allCases)
  func lockChangedDuringSelection(at changedSide: FolderComparisonSide) async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let oldA = try album(root, path: "old/A", count: 2)
    let oldB = try album(root, path: "old/B", count: 3)
    let replacement = try album(root, path: "new/A", count: 4)
    let comparison = makeStore()
    comparison.first.load(oldA)
    comparison.second.load(oldB)
    try await waitForLoads(comparison)
    var calls: [FolderComparisonSide] = []
    comparison.choosePair { side, _ in
      calls.append(side)
      if side == changedSide { comparison.toggleLock(on: .first) }
      return replacement
    }
    #expect(calls == (changedSide == .first ? [.first] : [.first, .second]))
    #expect(comparison.first.folderURL == oldA && comparison.second.folderURL == oldB)
    #expect(comparison.first.assets.count == 2 && comparison.second.assets.count == 3)
    #expect(!comparison.first.isLoading && !comparison.second.isLoading)
    #expect(comparison.first.isLocked && comparison.alert == nil)
  }

  private func makeStore() -> FolderComparisonStore {
    FolderComparisonStore(defaults: UserDefaults(suiteName: "ComparisonFolderSelectionTests.\(UUID())")!)
  }

  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComparisonFolderSelectionTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func album(_ root: URL, path: String, count: Int) throws -> URL {
    let folder = root.appendingPathComponent(path, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let data = Data(base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=")!
    for number in 1...count {
      try data.write(to: folder.appendingPathComponent("\(number).png"))
    }
    return folder
  }

  private func waitForLoads(_ comparison: FolderComparisonStore) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while (comparison.first.isLoading || comparison.second.isLoading), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!comparison.first.isLoading && !comparison.second.isLoading)
    #expect(comparison.first.errorMessage == nil && comparison.second.errorMessage == nil)
  }
}
