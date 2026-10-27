import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

@Suite("비교 메타데이터 정렬과 복원 대기")
@MainActor
struct ComparisonMetadataSortTests {
  @Test("형식 선택지는 사진 이동·검색에서 재사용하고 폴더 교체 때 갱신한다")
  func extensionChoicesFollowSourceCollection() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let pane = FolderComparisonPane()
    defer { pane.cancelLoad() }
    #expect(pane.availableExtensions.isEmpty)
    pane.open(urls: [fixture.first])
    await pane.waitUntilLoaded()
    let extensions = pane.availableExtensions
    #expect(extensions == ["jpg"])
    let sourceStorage = extensions.withUnsafeBufferPointer { $0.baseAddress }
    for step in 0..<600 {
      pane.select(number: step.isMultiple(of: 2) ? 2 : 1)
      #expect(pane.availableExtensions.withUnsafeBufferPointer { $0.baseAddress } == sourceStorage)
    }
    pane.query.searchText = "missing"
    await pane.waitUntilLoaded()
    #expect(pane.assets.isEmpty && pane.availableExtensions == extensions)
    #expect(pane.availableExtensions.withUnsafeBufferPointer { $0.baseAddress } == sourceStorage)
    pane.query = LibraryQuery()
    pane.open(urls: [fixture.second])
    #expect(pane.availableExtensions.isEmpty)
    await pane.waitUntilLoaded()
    #expect(pane.availableExtensions == ["png"])
    #expect(pane.errorMessage == nil)
  }

  @Test("대기 중 정렬 작업이 교체되면 마지막 작업의 완료까지 기다린다")
  func waitsForSupersedingQuery() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let pane = FolderComparisonPane()
    defer { pane.cancelLoad() }
    pane.open(urls: [fixture.first])
    await pane.waitUntilLoaded()
    pane.select(number: 2)
    let selected = try #require(pane.currentAsset).sessionID
    var replaced = false
    // A completion observer starts the successor before the awaited task returns.
    // This exercises the handoff deterministically without a timing-based delay.
    pane.onContentsChanged = { [weak pane] in
      guard let pane, !pane.isLoading, !pane.isFiltering,
        pane.query.sort == .widthDescending, !replaced else { return }
      replaced = true
      pane.query.sort = .heightDescending
    }
    pane.query.sort = .widthDescending
    await pane.waitUntilLoaded()
    #expect(replaced)
    #expect(!pane.isLoading && !pane.isFiltering)
    #expect(pane.query.sort == .heightDescending)
    #expect(pane.assets.map(\.filename) == ["A.jpg", "B.jpg"])
    #expect(pane.currentAsset?.sessionID == selected)
    #expect(pane.errorMessage == nil)
  }

  @Test("비교 복원 중 공유 정렬을 바꿔도 최신 두 목록에서 저장된 선택을 복원한다")
  func restoresSelectionAfterSharedQuerySupersession() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let original = FolderComparisonStore(defaults: fixture.defaults, alignment: .sequence)
    let restored = FolderComparisonStore(defaults: fixture.defaults, alignment: .sequence)
    defer { original.cancelLoads(); restored.cancelLoads() }
    original.query.sort = .widthDescending
    original.open(urls: [fixture.first], for: .first)
    original.open(urls: [fixture.second], for: .second)
    try await ready(original)
    original.jump(.first, number: 1)
    original.jump(.second, number: 2)
    let saved = try #require(original.captureSession())
    let firstID = saved.first.selectedID
    let secondID = saved.second.selectedID
    var replaced = false
    let notify = restored.second.onContentsChanged
    restored.second.onContentsChanged = { [weak restored] in
      notify?()
      guard let restored, !restored.second.isLoading, !restored.second.isFiltering,
        !restored.second.assets.isEmpty, restored.query.sort == .widthDescending,
        !replaced else { return }
      replaced = true
      restored.query.sort = .heightDescending
    }
    await restored.restoreSession(saved)
    #expect(replaced)
    #expect(!restored.first.isFiltering && !restored.second.isFiltering)
    #expect(restored.query.sort == .heightDescending)
    #expect(restored.first.query.sort == .heightDescending && restored.second.query.sort == .heightDescending)
    #expect(restored.first.assets.map(\.filename) == ["A.jpg", "B.jpg"])
    #expect(restored.second.assets.map(\.filename) == ["C.png", "A.png"])
    #expect(restored.first.currentAsset?.sessionID == firstID)
    #expect(restored.second.currentAsset?.sessionID == secondID)
    #expect(restored.alert == nil)
  }

  @Test("공유 정렬은 파일명 맞춤 행과 누락된 짝 및 비교 세션에 함께 적용된다")
  func sharedSortFilenamePairsAndSession() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults, alignment: .filename)
    let restored = FolderComparisonStore(defaults: fixture.defaults)
    defer { comparison.cancelLoads(); restored.cancelLoads() }
    // Setting the shared query before opening covers initial nondefault enrichment.
    comparison.query.sort = .widthDescending
    comparison.open(urls: [fixture.first], for: .first)
    comparison.open(urls: [fixture.second], for: .second)
    try await ready(comparison)
    #expect(comparison.first.assets.map(\.filename) == ["B.jpg", "A.jpg"])
    #expect(comparison.second.assets.map(\.filename) == ["A.png", "C.png"])
    // A contributes its dimensions for a pair; a B-only row uses B dimensions.
    #expect(rowNames(comparison) == ["B.jpg|—", "—|C.png", "A.jpg|A.png"])
    comparison.jump(.second, number: 2)
    #expect(comparison.first.currentAsset == nil && comparison.second.currentAsset?.filename == "C.png")
    let saved = try #require(comparison.captureSession())
    #expect(saved.query.sort == .widthDescending)
    await restored.restoreSession(saved)
    #expect(!restored.first.isFiltering && !restored.second.isFiltering && !restored.isMatching)
    #expect(restored.query.sort == .widthDescending)
    #expect(rowNames(restored) == rowNames(comparison))
    #expect(restored.first.currentAsset == nil && restored.second.currentAsset?.filename == "C.png")
    restored.query.sort = .widthAscending
    try await ready(restored)
    #expect(rowNames(restored) == ["A.jpg|A.png", "—|C.png", "B.jpg|—"])
    #expect(restored.first.currentAsset == nil && restored.second.currentAsset?.filename == "C.png")
  }

  private func rowNames(_ comparison: FolderComparisonStore) -> [String] {
    comparison.pairs.map { pair in
      let first = pair.firstIndex.map { comparison.first.assets[$0].filename } ?? "—"
      let second = pair.secondIndex.map { comparison.second.assets[$0].filename } ?? "—"
      return first + "|" + second
    }
  }

  @Test("빈 짝의 복원은 정렬 변경이나 파일 추가 뒤에도 남아 있는 사진을 기준으로 한다",
    arguments: [false, true])
  func missingRowFollowsIdentityAfterOrderChanges(changesSort: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let original = FolderComparisonStore(defaults: fixture.defaults, alignment: .filename)
    let restored = FolderComparisonStore(defaults: fixture.defaults, alignment: .filename)
    defer { original.cancelLoads(); restored.cancelLoads() }
    original.query.sort = .widthDescending
    original.open(urls: [fixture.first], for: .first)
    original.open(urls: [fixture.second], for: .second)
    try await ready(original)
    original.jump(.second, number: 2)
    let saved = try #require(original.captureSession())
    try #require(saved.matchIndex == 1 && saved.first.selectedID == nil)
    try #require(original.second.currentAsset?.filename == "C.png")
    var changedQuery = false
    if changesSort {
      let notify = restored.second.onContentsChanged
      restored.second.onContentsChanged = { [weak restored] in
        notify?()
        guard let restored, !restored.second.isLoading, !restored.second.isFiltering,
          !restored.second.assets.isEmpty, restored.query.sort == .widthDescending,
          !changedQuery else { return }
        changedQuery = true
        restored.query.sort = .heightDescending
      }
    } else {
      try FileManager.default.copyItem(at: fixture.first.appendingPathComponent("B.jpg"),
        to: fixture.first.appendingPathComponent("X.jpg"))
    }
    await restored.restoreSession(saved)
    #expect(!restored.first.isFiltering && !restored.second.isFiltering && !restored.isMatching)
    #expect(restored.first.currentAsset == nil && restored.first.showsMissingCounterpart)
    #expect(restored.second.currentAsset?.sessionID == saved.second.selectedID)
    #expect(restored.second.currentAsset?.filename == "C.png")
    #expect(restored.matchIndex == (changesSort ? 0 : 2))
    if changesSort {
      #expect(changedQuery && restored.query.sort == .heightDescending)
    }
  }

  private func ready(_ comparison: FolderComparisonStore) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while comparison.first.isLoading || comparison.first.isFiltering
      || comparison.second.isLoading || comparison.second.isFiltering || comparison.isMatching {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(comparison.first.errorMessage == nil && comparison.second.errorMessage == nil)
  }

  private struct Fixture {
    let root: URL
    let first: URL
    let second: URL
    let suite = "ComparisonMetadataSortTests.\(UUID())"
    let defaults: UserDefaults

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("comparison-metadata-\(UUID())")
      first = root.appendingPathComponent("first")
      second = root.appendingPathComponent("second")
      defaults = try #require(UserDefaults(suiteName: suite))
      try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
      for (folder, name, width, height) in [(first, "A.jpg", 120, 200), (first, "B.jpg", 240, 100),
        (second, "A.png", 480, 80), (second, "C.png", 180, 300)] {
        let context = try #require(CGContext(data: nil, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let type = name.hasSuffix("png") ? UTType.png.identifier : UTType.jpeg.identifier
        let destination = try #require(CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL,
          type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
      }
    }

    func remove() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
