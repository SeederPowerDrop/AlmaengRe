import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

/// Read-only, fixed-size sampling. All generated PNGs belong to a fresh temporary
/// cache; neither production caches nor source image contents are modified.
@Suite("실제 RAW 몽땅보기 작은 미리보기 품질", .serialized)
struct RealRAWOverviewPreviewParityTests {
  @Test("초기 15 RAW의 기존 표시 디코더와 내장 전용 경로 비용을 읽기 전용으로 비교한다",
    .enabled(if: ProcessInfo.processInfo.environment["OVERVIEW_NATIVE_DECODE_COST"] == "1"
      && ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_DIRECTORY"] != nil),
    .timeLimit(.minutes(3)))
  func initialVisibleNativeDecodeCostAndParity() async throws {
    let files = FileManager.default
    let folder = URL(fileURLWithPath: try #require(
      ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_DIRECTORY"]))
    let scanned = try await ImageLibrary().scan(folder: folder, includesVideos: true)
    let ordered = try RustImageEngine.query(scanned, options: LibraryQuery())
    let selected = Array(ordered.enumerated().filter {
      $0.element.fileExtension == "dng" && ($0.element.byteCount ?? 0) > 0
    }.prefix(15))
    try #require(selected.count == 15)
    var sourceVersions: [URL: (bytes: Int64?, modified: Date?)] = [:]
    for asset in scanned {
      let attributes = try files.attributesOfItem(atPath: asset.url.path)
      sourceVersions[asset.url] = ((attributes[.size] as? NSNumber)?.int64Value,
        attributes[.modificationDate] as? Date)
    }

    func measure(_ operation: () throws -> CGImage?) throws
      -> (image: CGImage?, wall: Double, cpu: Double?) {
      let wallBefore = ProcessInfo.processInfo.systemUptime
      let cpuBefore = OverviewWarmCPUCost.processCPUSeconds()
      let image = try operation()
      let cpuAfter = OverviewWarmCPUCost.processCPUSeconds()
      let wall = ProcessInfo.processInfo.systemUptime - wallBefore
      let cpu: Double?
      if let cpuBefore, let cpuAfter, cpuAfter >= cpuBefore { cpu = cpuAfter - cpuBefore }
      else { cpu = nil }
      return (image, wall, cpu)
    }

    func result(_ value: (image: CGImage?, wall: Double, cpu: Double?)) -> [String: Any] {
      ["succeeded": value.image != nil,
        "width": value.image?.width ?? 0, "height": value.image?.height ?? 0,
        "wallSeconds": value.wall, "cpuSeconds": value.cpu.map { $0 as Any } ?? NSNull()]
    }

    var rows: [[String: Any]] = []
    for (sample, entry) in selected.enumerated() {
      let asset = entry.element
      let sourceHash = SHA256.hash(data: Data(asset.url.standardizedFileURL.absoluteString.utf8))
        .map { String(format: "%02x", $0) }.joined()
      for size in [256, 768] {
        try autoreleasepool {
          let old: (image: CGImage?, wall: Double, cpu: Double?)
          let fast: (image: CGImage?, wall: Double, cpu: Double?)
          let oldOperation = {
            try size == 256
              ? ThumbnailBitmapDecoder.browsingThumbnail(sourceURL: asset.url, maxPixelSize: size)
              : ThumbnailBitmapDecoder.directThumbnail(sourceURL: asset.url, maxPixelSize: size)
          }
          let fastOperation = {
            try ThumbnailBitmapDecoder.embeddedOverviewThumbnail(sourceURL: asset.url, maxPixelSize: size)
          }
          // Alternate execution order to expose OS/native cache ordering bias.
          // No global file or Quick Look cache is flushed by this experiment.
          if sample.isMultiple(of: 2) {
            old = try measure(oldOperation)
            fast = try measure(fastOperation)
          } else {
            fast = try measure(fastOperation)
            old = try measure(oldOperation)
          }
          var parity: Bool?
          if let lhs = old.image, let rhs = fast.image {
            // Both production helpers return the same detached P3 RGBA layout.
            // Compare all pixels at the actual output size, including 768px.
            let lhsPixels = try #require(lhs.dataProvider?.data)
            let rhsPixels = try #require(rhs.dataProvider?.data)
            parity = lhs.width == rhs.width && lhs.height == rhs.height
              && lhs.bitsPerComponent == rhs.bitsPerComponent && lhs.bitsPerPixel == rhs.bitsPerPixel
              && lhs.colorSpace?.copyICCData() == rhs.colorSpace?.copyICCData()
              && lhsPixels == rhsPixels
            #expect(parity == true)
          }
          rows.append(["sample": sample, "galleryIndex": entry.offset, "sourceURLSHA256": sourceHash,
            "pixelSize": size, "order": sample.isMultiple(of: 2) ? "old_then_fast" : "fast_then_old",
            "old": result(old), "fastEmbeddedOnly": result(fast),
            "pixelColorOrientationParity": parity.map { $0 as Any } ?? NSNull(),
            "unchangedFallbackStillRequired": fast.image == nil])
        }
      }
    }
    var unchangedSources = 0
    for asset in scanned {
      let attributes = try files.attributesOfItem(atPath: asset.url.path)
      let before = try #require(sourceVersions[asset.url])
      let unchanged = (attributes[.size] as? NSNumber)?.int64Value == before.bytes
        && attributes[.modificationDate] as? Date == before.modified
      #expect(unchanged)
      if unchanged { unchangedSources += 1 }
    }
    let report: [String: Any] = [
      "scope": "serial_decoder_microbenchmark_not_actual_UI_or_preload; OS_and_native_caches_uncontrolled",
      "selection": "first_15_nonempty_DNGs_in_production_name_ascending_gallery_order",
      "matchesInitialGalleryIndices0Through14": selected.map(\.offset) == Array(0..<15),
      "fallbackScope": "fast_nil_is_not_a_replacement_or_speedup; existing_fallback_would_still_run_unchanged",
      "cpuScope": "getrusage_SELF_user_plus_system_including_other_work_in_this_test_process",
      "sourceMetadataUnchanged": unchangedSources == scanned.count,
      "sourceMetadataCheckedCount": scanned.count, "rows": rows,
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print("RAW_OVERVIEW_NATIVE_DECODE_COST " + String(decoding: data, as: UTF8.self))
  }

  @Test("내장 미리보기와 원본 보완은 기존 픽셀·색·방향을 유지한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_DIRECTORY"] != nil),
    .timeLimit(.minutes(3)))
  func embeddedAndFallbackParity() async throws {
    let files = FileManager.default
    let folder = URL(fileURLWithPath: try #require(
      ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_DIRECTORY"]))
    let urls = try files.contentsOfDirectory(at: folder,
      includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      .filter { $0.pathExtension.lowercased() == "dng" }
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    let assets = try urls.compactMap { url -> ImageAsset? in
      let attributes = try files.attributesOfItem(atPath: url.path)
      guard let bytes = (attributes[.size] as? NSNumber)?.int64Value, bytes > 0 else { return nil }
      return ImageAsset(url: url, byteCount: bytes,
        modificationDate: attributes[.modificationDate] as? Date)
    }
    try #require(assets.count >= 2)
    var indices: Set<Int> = []
    for point in 0..<10 {
      indices.insert(Int((Double(point) * Double(assets.count - 1) / 9).rounded()))
    }
    var missing: [ImageAsset] = []
    var searchedForFallback = 0
    // The absence of embedded pixels is a property of the actual container,
    // not its filename or sorted position. Bound fixture discovery to 64 RAWs.
    for index in 0..<min(64, assets.count) {
      let hasEmbedded = try autoreleasepool {
        try ThumbnailBitmapDecoder.embeddedOverviewThumbnail(sourceURL: assets[index].url) != nil
      }
      searchedForFallback += 1
      if !hasEmbedded {
        missing.append(assets[index])
        indices.insert(index)
        if missing.count == 2 { break }
      }
    }
    try #require(missing.count == 2,
      "Two RAWs without sufficient embedded previews are required within the first 64 nonempty DNGs")
    var embeddedCount = 0
    for index in indices.sorted() {
      let asset = assets[index]
      try autoreleasepool {
        let embedded = try ThumbnailBitmapDecoder.embeddedOverviewThumbnail(sourceURL: asset.url)
        guard let embedded else { return }
        let previous = try #require(try ThumbnailBitmapDecoder.directThumbnail(
          sourceURL: asset.url, maxPixelSize: 256))
        #expect(embedded.width == previous.width)
        #expect(embedded.height == previous.height)
        #expect(embedded.bitsPerComponent == previous.bitsPerComponent)
        #expect(embedded.bitsPerPixel == previous.bitsPerPixel)
        #expect(embedded.colorSpace?.copyICCData() == previous.colorSpace?.copyICCData())
        #expect(embedded.dataProvider?.data == previous.dataProvider?.data)
        embeddedCount += 1
      }
    }
    try #require(embeddedCount > 0)
    let temporary = files.temporaryDirectory.appendingPathComponent(
      "RealRAWOverviewPreviewParity-\(UUID())", isDirectory: true)
    try files.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: temporary) }
    let disk = ThumbnailDiskCache(directory: temporary.appendingPathComponent("thumbnails"))
    let snapshot = ImageResourceSnapshot(physicalMemory: 16 * 1_024 * 1_024 * 1_024,
      activeProcessorCount: 8, appleSilicon: true, isAppActive: false,
      cpuBusyFraction: 0.1)
    let governor = ImageResourceGovernor(snapshot: snapshot, storageOverride: .internalSSD,
      monitorsMemoryPressure: false)
    let pipeline = ThumbnailPipeline(governor: governor, diskCache: disk)
    #expect(await disk.snapshot().entryCount == 0)
    #expect(await pipeline.warmOverviewPreviews(assets: missing))
    #expect(await disk.snapshot().entryCount == missing.count)
    var maximumRGBDifference = 0
    var maximumAlphaDifference = 0
    for asset in missing {
      let restored = try #require(await disk.image(for: ThumbnailCacheKey(asset: asset,
        pixelSize: 256, isBrowsingPreview: true)))
      try autoreleasepool {
        let previous = try #require(try ThumbnailBitmapDecoder.directThumbnail(
          sourceURL: asset.url, maxPixelSize: 256))
        #expect(restored.width == previous.width)
        #expect(restored.height == previous.height)
        #expect(restored.colorSpace?.copyICCData() == previous.colorSpace?.copyICCData())
        // Normalize PNG decoder byte order and premultiplication to the same P3
        // RGBA layout; the lossless storage round trip permits one RGB rounding unit.
        let lhs = try rgba(restored)
        let rhs = try rgba(previous)
        try #require(lhs.count == rhs.count)
        for offset in lhs.indices {
          let difference = abs(Int(lhs[offset]) - Int(rhs[offset]))
          if offset % 4 == 3 {
            maximumAlphaDifference = max(maximumAlphaDifference, difference)
          } else {
            maximumRGBDifference = max(maximumRGBDifference, difference)
          }
        }
      }
    }
    #expect(maximumRGBDifference <= 1)
    #expect(maximumAlphaDifference == 0)
    let memory = await pipeline.cacheSnapshot()
    #expect(memory.entryCount == 0)
    #expect(memory.byteCount == 0)
    #expect(await governor.stateSnapshot().runningCount == 0)
    #expect(await governor.stateSnapshot().queuedCount == 0)
    var unchangedSources = 0
    for asset in assets {
      let attributes = try files.attributesOfItem(atPath: asset.url.path)
      let unchanged = (attributes[.size] as? NSNumber)?.int64Value == asset.byteCount
        && attributes[.modificationDate] as? Date == asset.modificationDate
      #expect(unchanged)
      if unchanged { unchangedSources += 1 }
    }
    print("RAW_OVERVIEW_PREVIEW_PARITY total=\(assets.count) sampled=\(indices.count) "
      + "embedded=\(embeddedCount) fallback=\(missing.count) fallbackSearch=\(searchedForFallback) "
      + "rgbMax=\(maximumRGBDifference) "
      + "alphaMax=\(maximumAlphaDifference) ramEntries=\(memory.entryCount) "
      + "sourceMetadataUnchanged=\(unchangedSources)")
  }

  private func rgba(_ image: CGImage) throws -> [UInt8] {
    let normalized = try #require(ThumbnailBitmapDecoder.rasterized(image,
      maxPixelSize: 256)?.image)
    let data = try #require(normalized.dataProvider?.data)
    return Array(data as Data)
  }
}
