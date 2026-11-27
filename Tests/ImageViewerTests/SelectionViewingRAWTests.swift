import Foundation
import Testing
@testable import ImageViewer

@Suite("실제 RAW 선택 범위 왕복", .serialized)
@MainActor
struct SelectionViewingRAWTests {
  @Test("대량 RAW 목록을 왕복해도 기존 미리보기 비트맵과 원본 목록을 재사용한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_SELECTION_RAW_DIRECTORY"] != nil))
  func selectedScopeReusesWarmRAWPreview() async throws {
    let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["IMAGEVIEWER_SELECTION_RAW_DIRECTORY"]))
    let suite = "SelectionViewingRAW.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: temporary) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: temporary.appendingPathComponent("marks.sqlite"), thumbnailDiskCache: nil)
    store.presentationMode = .overview
    store.openFolderFromTree(folder)
    let deadline = ContinuousClock.now + .seconds(30)
    while store.isLoading || store.isFiltering {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
    let original = store.assets
    try #require(original.count > 500)
    store.returnToOverview()
    let versions = original.map { ImageFileVersion(url: $0.url) }
    let rawIndex = try #require(original.firstIndex { $0.fileExtension == "dng" && ($0.byteCount ?? 0) > 0 })
    let raw = original[rawIndex]
    let bitmap = try await store.thumbnailPipeline.browsingThumbnail(for: raw, maxPixelSize: 256)
    store.selectForBatch(index: rawIndex, modifiers: [])
    for index in stride(from: rawIndex + 1, to: min(rawIndex + 20, original.count), by: 1) {
      store.selectForBatch(index: index, modifiers: .command)
    }
    let selected = store.selectedURLs
    var entryMS: [Double] = [], returnMS: [Double] = []
    for _ in 0..<5 {
      try #require(store.canViewSelectedFiles)
      var start = ProcessInfo.processInfo.systemUptime
      store.viewSelectedFiles(together: true)
      entryMS.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
      let scopedSelectionMatches = Set(store.assets.map(\.url)) == selected
      #expect(scopedSelectionMatches)
      start = ProcessInfo.processInfo.systemUptime
      store.returnToOverview()
      returnMS.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
      #expect(store.assets == original && store.selectedURLs == selected)
    }
    let reused = await store.thumbnailPipeline.cachedMemoryPreview(for: raw, maxPixelSize: 256)
    #expect(reused === bitmap)
    #expect(original.map { ImageFileVersion(url: $0.url) } == versions)
    let report: [String: Any] = ["assets": original.count, "selected": selected.count,
      "entryCommitMilliseconds": entryMS, "returnCommitMilliseconds": returnMS,
      "bitmapIdentityReused": reused === bitmap, "sourceMetadataUnchanged": true,
      "measurement": "synchronous scope commits; excludes cold loading and decoding"]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print("SELECTION_RAW_ROUNDTRIP \(String(decoding: data, as: UTF8.self))")
    if let output = ProcessInfo.processInfo.environment["IMAGEVIEWER_SELECTION_NATIVE_OUTPUT"] {
      let directory = URL(fileURLWithPath: output)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: directory.appendingPathComponent("raw-scope-commit.json"))
    }
  }
}
