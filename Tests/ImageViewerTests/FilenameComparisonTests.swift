import AppKit
import Testing

@testable import ImageViewer

@Suite("파일명으로 자동 맞추는 이미지 비교")
@MainActor
struct FilenameComparisonTests {
  @Test("확장자가 달라도 이름으로 맞추고 중간 누락을 빈칸으로 유지한다")
  func matchingAndMissingRows() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults, alignment: .filename)
    #expect(comparison.alignment == .filename)
    comparison.first.load(fixture.a)
    comparison.second.load(fixture.b)
    try await ready(comparison)
    #expect(comparison.first.currentAsset?.filename == "001.jpg")
    #expect(comparison.second.currentAsset?.filename == "001.png")
    comparison.navigateBoth(1)
    #expect(comparison.first.currentAsset == nil)
    #expect(comparison.first.showsMissingCounterpart)
    #expect(comparison.second.currentAsset?.filename == "002.jpg")
    #expect(comparison.canNavigateBoth(1))
    comparison.navigateBoth(1)
    #expect(comparison.first.currentAsset?.filename == "003.png")
    #expect(comparison.second.currentAsset?.filename == "003.jpg")
    comparison.navigateBoth(1)
    #expect(comparison.first.currentAsset?.filename == "005.png")
    #expect(comparison.second.currentAsset == nil)
    #expect(!comparison.canNavigateBoth(1))
    comparison.navigateBoth(-1)
    #expect(comparison.second.currentAsset?.filename == "003.jpg")
    comparison.jump(.second, number: 1)
    #expect(comparison.matchIndex == 0)
    #expect(comparison.first.currentAsset?.filename == "001.jpg")
  }

  @Test("잠긴 칸의 이미지와 확대 위치를 보존하고 해제하면 현재 짝으로 돌아온다")
  func lockedPaneStaysFixed() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults, alignment: .filename)
    comparison.first.load(fixture.a); comparison.second.load(fixture.b)
    try await ready(comparison)
    comparison.linksViewport = false
    comparison.updateZoom(2, on: .first)
    comparison.pan(CGSize(width: 5, height: 8), on: .first)
    let pan = comparison.first.pan
    comparison.toggleLock(on: .first)
    comparison.navigateBoth(1)
    #expect(comparison.first.currentAsset?.filename == "001.jpg")
    #expect(comparison.first.zoom == 2 && comparison.first.pan == pan)
    #expect(comparison.second.currentAsset?.filename == "002.jpg")
    comparison.toggleLock(on: .first)
    #expect(comparison.first.currentAsset == nil)
    #expect(comparison.first.showsMissingCounterpart)
    comparison.navigate(.first, direction: 1)
    #expect(comparison.first.currentAsset?.filename == "003.png")
    #expect(comparison.second.currentAsset?.filename == "003.jpg")
  }

  @Test("비교 세션은 누락된 칸과 반대편 선택 및 배율을 복원한다")
  func restoresMissingRow() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults, alignment: .filename)
    comparison.first.load(fixture.a); comparison.second.load(fixture.b)
    try await ready(comparison)
    comparison.navigateBoth(1)
    comparison.linksViewport = false
    comparison.updateZoom(3, on: .second)
    let snapshot = try #require(comparison.captureSession())
    let restored = FolderComparisonStore(defaults: fixture.defaults)
    await restored.restoreSession(snapshot)
    #expect(restored.first.currentAsset == nil)
    #expect(restored.second.currentAsset?.filename == "002.jpg")
    #expect(restored.matchIndex == 1)
    #expect(restored.second.zoom == 3)
  }

  @Test("잠긴 참조 사진과 다른 비교 행의 위치를 각각 복원한다")
  func restoresIndependentLockedReference() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults, alignment: .filename)
    comparison.first.load(fixture.a); comparison.second.load(fixture.b)
    try await ready(comparison)
    comparison.linksViewport = false
    comparison.updateZoom(2, on: .first)
    comparison.toggleLock(on: .first)
    comparison.navigateBoth(1)
    comparison.updateZoom(3, on: .second)
    let snapshot = try #require(comparison.captureSession())
    let restored = FolderComparisonStore(defaults: fixture.defaults)
    await restored.restoreSession(snapshot)
    #expect(!restored.isMatching && restored.matchIndex == 1)
    #expect(restored.first.currentAsset?.filename == "001.jpg")
    #expect(restored.first.isLocked && restored.first.zoom == 2)
    #expect(restored.second.currentAsset?.filename == "002.jpg")
    #expect(!restored.second.isLocked && restored.second.zoom == 3)
    restored.toggleLock(on: .first)
    #expect(restored.first.showsMissingCounterpart && restored.first.currentAsset == nil)
  }

  @Test("비교 행에도 역순 정렬이 적용되고 검색 중 잠금은 완료까지 기다린다")
  func sortingAndLockDuringFiltering() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults, alignment: .filename)
    comparison.first.load(fixture.a); comparison.second.load(fixture.b)
    try await ready(comparison)
    comparison.query = LibraryQuery(sort: .nameDescending)
    comparison.toggleLock(on: .first)
    #expect(!comparison.first.isLocked)
    try await wait {
      !comparison.first.isFiltering && !comparison.second.isFiltering && !comparison.isMatching
    }
    comparison.jump(.first, number: 1)
    #expect(comparison.matchIndex == 0 && comparison.first.currentAsset?.filename == "005.png")
    comparison.navigateBoth(1)
    #expect(comparison.first.currentAsset?.filename == "003.png")
    #expect(comparison.second.currentAsset?.filename == "003.jpg")
    comparison.toggleLock(on: .first)
    #expect(comparison.first.isLocked)
  }

  @Test("검색과 형식 필터 이후에도 새 목록 기준으로 짝이 맞는다")
  func filtersThenMatches() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults, alignment: .filename)
    comparison.first.load(fixture.a); comparison.second.load(fixture.b)
    try await ready(comparison)
    comparison.query = LibraryQuery(searchText: "003")
    try await wait {
      !comparison.isMatching && !comparison.first.isFiltering && !comparison.second.isFiltering
        && comparison.pairs.count == 1
    }
    #expect(comparison.first.currentAsset?.filename == "003.png")
    #expect(comparison.second.currentAsset?.filename == "003.jpg")
    comparison.query = LibraryQuery(searchText: "003", formats: [.png])
    try await wait {
      !comparison.isMatching && !comparison.first.isFiltering && !comparison.second.isFiltering
        && comparison.second.assets.isEmpty
    }
    #expect(comparison.first.currentAsset?.filename == "003.png")
    #expect(comparison.second.currentAsset == nil)
    #expect(comparison.second.showsMissingCounterpart)
  }

  private func ready(_ comparison: FolderComparisonStore) async throws {
    try await wait {
      !comparison.first.isLoading && !comparison.second.isLoading
        && !comparison.isMatching && comparison.pairs.count == 4
    }
  }

  private func wait(_ predicate: @MainActor () -> Bool) async throws {
    for _ in 0..<300 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("비교 상태가 제한 시간 내 준비되지 않았습니다.")
  }

  private struct Fixture {
    let root: URL
    let a: URL
    let b: URL
    let suite: String
    let defaults: UserDefaults

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("FilenameComparison-\(UUID())")
      a = root.appendingPathComponent("A"); b = root.appendingPathComponent("B")
      suite = "FilenameComparison.\(UUID())"
      defaults = UserDefaults(suiteName: suite)!
      try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
      let image = bitmap.representation(using: .png, properties: [:])!
      for name in ["001.jpg", "003.png", "005.png"] { try image.write(to: a.appendingPathComponent(name)) }
      for name in ["001.png", "002.jpg", "003.jpg"] { try image.write(to: b.appendingPathComponent(name)) }
    }

    func cleanup() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
