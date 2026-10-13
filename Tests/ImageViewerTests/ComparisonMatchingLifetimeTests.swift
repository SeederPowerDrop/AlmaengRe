import AppKit
import Testing

@testable import ImageViewer

@Suite("비교 화면 전환 시 파일명 매칭 수명")
@MainActor
struct ComparisonMatchingLifetimeTests {
  @Test("비교를 떠나면 칸 취소 콜백도 매칭을 다시 시작하지 않는다")
  func cancellationDoesNotRestartMatching() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults, alignment: .filename)
    defer { comparison.cancelLoads() }
    comparison.first.load(fixture.folder)
    comparison.second.load(fixture.folder)
    try await ready(comparison)
    comparison.jump(.first, number: 2)
    comparison.updateZoom(2, on: .first)
    let selected = comparison.first.currentAsset
    let pairs = comparison.pairs

    comparison.cancelLoads()
    #expect(!comparison.isMatching)
    #expect(!comparison.first.isLoading && !comparison.second.isLoading)
    #expect(comparison.first.currentAsset == selected && comparison.first.zoom == 2)
    #expect(comparison.pairs == pairs)
    for _ in 0..<10 { await Task.yield() }
    #expect(!comparison.isMatching && comparison.pairs == pairs)

    comparison.resumeMatching()
    try await ready(comparison)
    #expect(comparison.first.currentAsset == selected && comparison.first.zoom == 2)
    #expect(comparison.pairs == pairs)
  }

  @Test("중단된 파일명 매칭은 비교 화면으로 돌아오면 다시 완성한다")
  func interruptedMatchingResumes() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults, alignment: .sequence)
    defer { comparison.cancelLoads() }
    comparison.first.load(fixture.folder)
    comparison.second.load(fixture.folder)
    try await ready(comparison)
    comparison.jump(.first, number: 2)
    comparison.alignment = .filename
    #expect(comparison.isMatching && comparison.pairs.isEmpty)
    comparison.cancelLoads()
    #expect(!comparison.isMatching && comparison.pairs.isEmpty)

    comparison.resumeMatching()
    #expect(comparison.isMatching)
    try await ready(comparison)
    #expect(comparison.pairs.count == 3)
    #expect(comparison.first.currentAsset?.filename == "02.qoi")
    #expect(comparison.second.currentAsset?.filename == "02.qoi")
    comparison.navigateBoth(1)
    #expect(comparison.first.currentAsset?.filename == "03.qoi")
    #expect(comparison.second.currentAsset?.filename == "03.qoi")
  }

  @Test("폴더 교체 중 떠나도 복귀 시 남은 목록에 맞춰 짝을 다시 계산한다")
  func changedListsDoNotReuseStalePairs() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults, alignment: .filename)
    defer { comparison.cancelLoads() }
    comparison.first.load(fixture.folder)
    comparison.second.load(fixture.folder)
    try await ready(comparison)
    #expect(comparison.pairs.allSatisfy { $0.firstIndex != nil && $0.secondIndex != nil })

    // Cancel synchronously before the replacement folder has published its list.
    comparison.second.load(fixture.folder)
    #expect(comparison.second.isLoading && comparison.second.assets.isEmpty)
    comparison.cancelLoads()
    #expect(!comparison.isMatching)
    comparison.resumeMatching()
    #expect(comparison.isMatching)
    #expect(!comparison.canNavigateBoth(1))
    try await ready(comparison)
    #expect(comparison.pairs.count == 3)
    #expect(comparison.pairs.allSatisfy { $0.firstIndex != nil && $0.secondIndex == nil })
    #expect(comparison.second.currentAsset == nil)
  }

  private func ready(_ comparison: FolderComparisonStore) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while comparison.first.isLoading || comparison.second.isLoading
      || comparison.first.isFiltering || comparison.second.isFiltering || comparison.isMatching {
      guard ContinuousClock.now < deadline else { throw TestError.timeout }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private enum TestError: Error { case timeout }

  private struct Fixture {
    let folder: URL
    let suite = "ComparisonMatchingLifetimeTests.\(UUID())"
    let defaults: UserDefaults

    init() throws {
      defaults = try #require(UserDefaults(suiteName: suite))
      folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("comparison-matching-lifetime-\(UUID())", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let data = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
        0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
      for name in ["01", "02", "03"] {
        try data.write(to: folder.appendingPathComponent(name + ".qoi"))
      }
    }

    func remove() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }
  }
}
