import AppKit
import Testing

@testable import ImageViewer

@Suite("다른 이름의 두 폴더 열기")
@MainActor
struct ComparisonOpeningRegressionTests {
  @Test("기본 비교는 어느 칸부터 열어도 먼저 고른 사진과 폴더·확대 위치를 유지한다")
  func openingOtherPanePreservesSelection() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    for firstSide in FolderComparisonSide.allCases {
      let otherSide: FolderComparisonSide = firstSide == .first ? .second : .first
      let comparison = FolderComparisonStore(defaults: fixture.defaults)
      #expect(comparison.alignment == .sequence)
      comparison.linksViewport = false
      comparison.open(urls: [fixture.a], for: firstSide)
      try await ready(comparison)
      comparison.jump(firstSide, number: 2)
      comparison.updateZoom(2, on: firstSide)
      comparison.pan(CGSize(width: 12, height: -18), on: firstSide)
      let pane = comparison.pane(firstSide)
      let asset = try #require(pane.currentAsset)
      let sources = pane.sourceURLs
      let assets = pane.assets
      let pan = pane.pan

      comparison.open(urls: [fixture.b], for: otherSide)
      #expect(pane.currentAsset == asset && pane.assets == assets)
      try await ready(comparison)

      #expect(pane.currentAsset == asset && pane.index == 1)
      #expect(pane.sourceURLs == sources && pane.assets == assets)
      #expect(pane.zoom == 2 && pane.pan == pan)
      #expect(!pane.showsMissingCounterpart)
      #expect(comparison.pane(otherSide).currentAsset?.filename == "beta1.png")
      #expect(comparison.pane(otherSide).assets.count == 3)
    }
  }

  @Test("파일명이 달라 빈칸이 생겨도 순서 비교로 바꾸면 다시 열지 않고 두 사진을 보여준다")
  func sequenceRecoversMissingCounterpart() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults, alignment: .filename)
    comparison.open(urls: [fixture.a], for: .first)
    try await ready(comparison)
    comparison.jump(.first, number: 2)
    let selectedA = try #require(comparison.first.currentAsset)
    comparison.open(urls: [fixture.b], for: .second)
    try await ready(comparison)
    #expect(comparison.first.showsMissingCounterpart && comparison.first.currentAsset == nil)
    let selectedB = try #require(comparison.second.currentAsset)
    let assetsA = comparison.first.assets, assetsB = comparison.second.assets
    let sourcesA = comparison.first.sourceURLs, sourcesB = comparison.second.sourceURLs

    comparison.alignment = .sequence

    #expect(comparison.first.currentAsset == selectedA && comparison.first.index == 1)
    #expect(comparison.second.currentAsset == selectedB)
    #expect(!comparison.first.showsMissingCounterpart && !comparison.second.showsMissingCounterpart)
    #expect(comparison.first.assets == assetsA && comparison.second.assets == assetsB)
    #expect(comparison.first.sourceURLs == sourcesA && comparison.second.sourceURLs == sourcesB)
    #expect(!comparison.first.isLoading && !comparison.second.isLoading && !comparison.isMatching)
  }

  @Test("기본값과 알 수 없는 설정은 순서 비교를 쓰고 직접 고른 파일명 비교는 기억한다")
  func alignmentPreferencesRespectExplicitChoice() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    #expect(FolderComparisonStore(defaults: fixture.defaults).alignment == .sequence)
    fixture.defaults.set("unknown", forKey: "ImageViewer.ComparisonAlignment.v1")
    let comparison = FolderComparisonStore(defaults: fixture.defaults)
    #expect(comparison.alignment == .sequence)
    comparison.alignment = .filename
    #expect(FolderComparisonStore(defaults: fixture.defaults).alignment == .filename)
    comparison.alignment = .sequence
    #expect(FolderComparisonStore(defaults: fixture.defaults).alignment == .sequence)
  }

  @Test("순서 비교 세션은 파일명이 다른 두 폴더와 각 사진 선택을 복원한다")
  func restoresIndependentSequenceSelections() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults)
    comparison.open(urls: [fixture.a], for: .first)
    comparison.open(urls: [fixture.b], for: .second)
    try await ready(comparison)
    comparison.jump(.first, number: 2)
    comparison.jump(.second, number: 3)
    var session = try #require(comparison.captureSession())
    // This regression tests comparison state; bookmark permission handling has separate coverage.
    session.first.sources = session.first.sources.map { var source = $0; source.bookmark = nil; return source }
    session.second.sources = session.second.sources.map { var source = $0; source.bookmark = nil; return source }
    comparison.alignment = .filename
    let restored = FolderComparisonStore(defaults: fixture.defaults)
    #expect(restored.alignment == .filename)

    await restored.restoreSession(session)

    #expect(restored.alert == nil && restored.alignment == .sequence)
    #expect(restored.first.currentAsset?.filename == "alpha2.png")
    #expect(restored.second.currentAsset?.filename == "beta3.png")
    #expect(restored.first.assets.count == 3 && restored.second.assets.count == 3)
    #expect(!restored.first.showsMissingCounterpart && !restored.second.showsMissingCounterpart)
  }

  private func ready(_ comparison: FolderComparisonStore) async throws {
    for _ in 0..<300 {
      if !comparison.first.isLoading && !comparison.second.isLoading
        && !comparison.first.isFiltering && !comparison.second.isFiltering && !comparison.isMatching { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.loadingTimedOut
  }

  private enum FixtureError: Error { case loadingTimedOut }

  private struct Fixture {
    let root: URL
    let a: URL
    let b: URL
    let suite: String
    let defaults: UserDefaults

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("ComparisonOpening-\(UUID())")
      a = root.appendingPathComponent("A")
      b = root.appendingPathComponent("B")
      suite = "ComparisonOpening.\(UUID())"
      defaults = UserDefaults(suiteName: suite)!
      try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
      let image = bitmap.representation(using: .png, properties: [:])!
      for index in 1...3 {
        try image.write(to: a.appendingPathComponent("alpha\(index).png"))
        try image.write(to: b.appendingPathComponent("beta\(index).png"))
      }
    }

    func cleanup() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
