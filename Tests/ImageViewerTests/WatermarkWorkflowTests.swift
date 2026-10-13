import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

@Suite("워터마크 선택 범위와 메타데이터 정렬 연결")
@MainActor
struct WatermarkWorkflowTests {
  @Test("명시한 사진만 고정해 워터마크 사본을 만들고 원본과 선택을 보존한다")
  func capturedTargetsAndExport() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store()
    store.open(urls: [fixture.folder])
    try await ready(store)
    store.selectAllAssets()
    let before = store.selectedURLs
    let target = try #require(store.assets.first)
    let original = try Data(contentsOf: target.url)
    store.presentWatermark(urls: [target.url])
    #expect(store.batchSheet == .watermark)
    #expect(store.batchAssets.map(\.url) == [target.url])
    #expect(store.selectedURLs == before)
    store.select(index: 1)
    store.open(urls: [fixture.output])
    #expect(store.batchAssets.map(\.url) == [target.url])
    #expect(!store.isLoading)
    var watermark = WatermarkOptions()
    watermark.isEnabled = true
    watermark.text = "SYNTHETIC"
    watermark.metadataFields = [.cameraModel]
    watermark.opacity = 1
    store.rememberWatermarkOptions(watermark)
    #expect(fixture.store().savedWatermarkOptions == watermark)
    let items = try BatchImageExporter.plan(urls: [target.url], destinationFolder: fixture.output, format: .png)
    let result = await store.convertSelectedFiles(items: items, format: .png, quality: 1,
      resize: .percentage(50), watermark: watermark) { _, _ in }
    #expect(result.completed.count == 1 && result.failures.isEmpty && !result.wasCancelled)
    #expect(try Data(contentsOf: target.url) == original)
    let source = try #require(CGImageSourceCreateWithURL(items[0].destinationURL as CFURL, nil))
    let output = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(output.width == 160 && output.height == 100)
    #expect(!store.isBatchExporting)
    store.batchSheet = nil
    store.saveSessionNow()
  }

  @Test("새 정렬은 일반·비교·재실행에서 순서와 현재 선택을 유지한다")
  func metadataSortAcrossViewsAndRestore() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store()
    store.open(urls: [fixture.folder])
    try await ready(store)
    let focus = try #require(store.currentAsset).url
    #expect(store.allAssets.allSatisfy { $0.sortMetadata == nil })
    store.libraryQuery.sort = .widthDescending
    try await ready(store)
    #expect(store.assets.map(\.filename) == ["B.jpg", "A.jpg"])
    #expect(store.currentAsset?.url == focus)
    store.libraryQuery.sort = .capturedNewest
    try await ready(store)
    #expect(store.assets.map(\.filename) == ["B.jpg", "A.jpg"])
    store.saveSessionNow()
    let reopened = fixture.store()
    await reopened.restoreLastSession()
    try await ready(reopened)
    #expect(reopened.libraryQuery.sort == .capturedNewest)
    #expect(reopened.assets.map(\.filename) == ["B.jpg", "A.jpg"])
    #expect(reopened.currentAsset?.url.resolvingSymlinksInPath() == focus.resolvingSymlinksInPath())
    reopened.folderComparison.open(urls: [fixture.folder], for: .first)
    let pane = reopened.folderComparison.first
    let deadline = ContinuousClock.now + .seconds(10)
    while pane.isLoading || pane.isFiltering {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
    pane.query.sort = .widthDescending
    while pane.isFiltering {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(pane.assets.map(\.filename) == ["B.jpg", "A.jpg"])
    #expect(reopened.alert == nil)
    reopened.folderComparison.cancelLoads()
    reopened.saveSessionNow()
  }

  @Test("워터마크 번역 키와 글꼴·위치·메타데이터 선택을 모든 언어에 제공한다")
  func localizations() throws {
    let base = Bundle.module.resourceURL!
    var expected: Set<String>?
    for locale in L10n.supportedLocalizations {
      let path = base.appendingPathComponent(locale + ".lproj/Watermark.strings")
      let dictionary = try #require(NSDictionary(contentsOf: path) as? [String: String])
      let keys = Set(dictionary.keys)
      if let expected { #expect(keys == expected) } else { expected = keys }
      #expect(dictionary.values.allSatisfy { !$0.isEmpty })
      for field in WatermarkMetadataField.allCases { #expect(dictionary["field." + field.rawValue] != nil) }
      for position in WatermarkPosition.allCases { #expect(dictionary["position." + position.rawValue] != nil) }
    }
  }

  private func ready(_ store: AppStore) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while store.isLoading || store.isFiltering {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(store.assets.count == 2)
  }

  private struct Fixture {
    let root: URL
    let folder: URL
    let output: URL
    let suite = "WatermarkWorkflowTests.\(UUID())"
    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("watermark-workflow-\(UUID())")
      folder = root.appendingPathComponent("input")
      output = root.appendingPathComponent("output")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      for (index, name) in ["A", "B"].enumerated() {
        let context = try #require(CGContext(data: nil, width: 320 + index * 80, height: 200,
          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let image = try #require(context.makeImage())
        let url = folder.appendingPathComponent(name + ".jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
          kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:0\(index+1) 12:00:00"],
          kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "DEMO \(index+1)"],
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
      }
    }
    @MainActor func store() -> AppStore {
      AppStore(defaults: UserDefaults(suiteName: suite)!, monitorsSystemResources: false)
    }
    func remove() {
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
