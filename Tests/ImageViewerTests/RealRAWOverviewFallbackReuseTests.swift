import CoreGraphics
import CryptoKit
import Foundation
import Testing

@testable import ImageViewer

@Suite("실제 RAW 몽땅보기 단일 디코드 정밀 품질", .serialized)
struct RealRAWOverviewFallbackReuseTests {
  @Test("실제 RAW의 compact·정밀 재사용은 전체 픽셀과 원본 버전 구분을 유지한다",
    .enabled(if: ProcessInfo.processInfo.environment["OVERVIEW_RAW_FALLBACK_REUSE"] == "1"
      && ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_DIRECTORY"] != nil),
    .timeLimit(.minutes(3)))
  func preciseFallbackPreservesRealRAWAndVersionIdentity() async throws {
    let files = FileManager.default
    let folder = URL(fileURLWithPath: try #require(
      ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_DIRECTORY"]))
    let scanned = try await ImageLibrary().scan(folder: folder, includesVideos: true)
    let ordered = try RustImageEngine.query(scanned, options: LibraryQuery())
    var before: [URL: (bytes: Int64?, modified: Date?)] = [:]
    for asset in scanned {
      let attributes = try files.attributesOfItem(atPath: asset.url.path)
      before[asset.url] = ((attributes[.size] as? NSNumber)?.int64Value,
        attributes[.modificationDate] as? Date)
    }
    var selected: [ImageAsset] = []
    for asset in ordered.filter({ $0.fileExtension == "dng" && ($0.byteCount ?? 0) > 0 }).prefix(64) {
      let missing = try autoreleasepool {
        try ThumbnailBitmapDecoder.browsingThumbnail(sourceURL: asset.url, maxPixelSize: 256) == nil
      }
      if missing { selected.append(asset) }
      if selected.count == 3 { break }
    }
    try #require(selected.count == 3, "Three RAWs without embedded browsing pixels are required")
    let temporary = files.temporaryDirectory.appendingPathComponent(
      "RealRAWOverviewFallbackReuse-\(UUID())", isDirectory: true)
    try files.createDirectory(at: temporary, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? files.removeItem(at: temporary) }
    var rows: [[String: Any]] = []
    for (index, original) in selected.enumerated() {
      let directory = temporary.appendingPathComponent("sample-\(index)", isDirectory: true)
      try files.createDirectory(at: directory, withIntermediateDirectories: true)
      let copiedURL = directory.appendingPathComponent("owned-source.dng")
      try files.copyItem(at: original.url, to: copiedURL)
      let asset = try sourceAsset(copiedURL)
      let baseline = try autoreleasepool {
        try #require(try ThumbnailBitmapDecoder.directThumbnail(sourceURL: copiedURL, maxPixelSize: 768))
      }
      let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
      let machine = ImageResourceSnapshot(physicalMemory: 16 * 1_024 * 1_024 * 1_024,
        activeProcessorCount: 8, appleSilicon: true, isAppActive: false, cpuBusyFraction: 0.1)
      let governor = ImageResourceGovernor(snapshot: machine, storageOverride: .internalSSD,
        monitorsMemoryPressure: false)
      let pipeline = ThumbnailPipeline(governor: governor, diskCache: disk)
      #expect(await disk.snapshot().entryCount == 0)
      let compact = try await pipeline.browsingThumbnail(for: asset, maxPixelSize: 256,
        preciseRAWFallbackPixelSize: 768)
      #expect(max(compact.width, compact.height) == 256)
      let exactKey = ThumbnailCacheKey(asset: asset, pixelSize: 768)
      let compactKey = ThumbnailCacheKey(asset: asset, pixelSize: 256, isBrowsingPreview: true)
      #expect(await disk.contains(for: exactKey))
      #expect(await disk.contains(for: compactKey))
      #expect(await disk.snapshot().entryCount == 2)
      let memoryExact = try await pipeline.thumbnail(for: asset, maxPixelSize: 768)
      try expectIdentical(baseline, memoryExact)
      await pipeline.purgeCache()
      #expect(await pipeline.cacheSnapshot().byteCount == 0)
      // Only this test's private copy is removed. A successful precise result
      // now proves disk reuse rather than another source/native RAW decode.
      try files.removeItem(at: copiedURL)
      let diskExact = try await pipeline.thumbnail(for: asset, maxPixelSize: 768)
      try expectIdentical(baseline, diskExact)
      #expect(await disk.snapshot().hits > 0)

      if index == 0 {
        // Poison both old-version tiers with visibly different pixels. Changing
        // the private copy's mtime must exclude those entries at the same URL.
        try files.copyItem(at: original.url, to: copiedURL)
        let marker = try markerImage()
        await pipeline.purgeCache()
        await disk.store(marker, for: exactKey)
        await disk.store(marker, for: compactKey)
        let oldDate = try #require(asset.modificationDate)
        try files.setAttributes([.modificationDate: oldDate.addingTimeInterval(2)],
          ofItemAtPath: copiedURL.path)
        let changed = try sourceAsset(copiedURL)
        try #require(changed.modificationDate != asset.modificationDate)
        let changedCompact = try await pipeline.browsingThumbnail(for: changed,
          maxPixelSize: 256, preciseRAWFallbackPixelSize: 768)
        #expect(max(changedCompact.width, changedCompact.height) == 256)
        let changedExact = try await pipeline.thumbnail(for: changed, maxPixelSize: 768)
        try expectIdentical(baseline, changedExact)
        await pipeline.purgeCache()
        try files.removeItem(at: copiedURL)
        let changedDiskExact = try await pipeline.thumbnail(for: changed, maxPixelSize: 768)
        try expectIdentical(baseline, changedDiskExact)
      }
      let memory = await pipeline.cacheSnapshot()
      let diskState = await disk.snapshot()
      #expect(memory.byteLimit == 16 * 1_024 * 1_024)
      #expect(memory.byteCount <= memory.byteLimit)
      #expect(diskState.byteLimit == 512 * 1_024 * 1_024)
      #expect(diskState.byteCount <= diskState.byteLimit)
      #expect(await governor.stateSnapshot().runningCount == 0)
      #expect(await governor.stateSnapshot().queuedCount == 0)
      let sourceHash = SHA256.hash(data: Data(original.url.standardizedFileURL.absoluteString.utf8))
        .map { String(format: "%02x", $0) }.joined()
      rows.append(["sample": index, "sourceURLSHA256": sourceHash,
        "compactMaximumDimension": max(compact.width, compact.height),
        "preciseMaximumDimension": max(diskExact.width, diskExact.height),
        "memoryBytes": memory.byteCount, "memoryLimit": memory.byteLimit,
        "diskBytes": diskState.byteCount, "diskLimit": diskState.byteLimit,
        "sourceVersionPoisonChecked": index == 0])
    }
    var unchanged = 0
    for asset in scanned {
      let attributes = try files.attributesOfItem(atPath: asset.url.path)
      let original = try #require(before[asset.url])
      let same = (attributes[.size] as? NSNumber)?.int64Value == original.bytes
        && attributes[.modificationDate] as? Date == original.modified
      #expect(same)
      if same { unchanged += 1 }
    }
    let report: [String: Any] = ["scope": "private_source_copies_and_fresh_private_cache_only",
      "pixelComparison": "all_768px_RGBA_bytes_ICC_alpha_and_dimensions_exact",
      "sourceMetadataCheckedCount": scanned.count, "sourceMetadataUnchanged": unchanged == scanned.count,
      "rows": rows]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print("RAW_OVERVIEW_FALLBACK_REUSE " + String(decoding: data, as: UTF8.self))
  }

  private func sourceAsset(_ url: URL) throws -> ImageAsset {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return ImageAsset(url: url, byteCount: try #require((attributes[.size] as? NSNumber)?.int64Value),
      modificationDate: attributes[.modificationDate] as? Date)
  }

  private func expectIdentical(_ baseline: CGImage, _ actual: CGImage) throws {
    #expect(max(actual.width, actual.height) == 768)
    #expect(actual.width == baseline.width && actual.height == baseline.height)
    #expect(actual.colorSpace?.copyICCData() == baseline.colorSpace?.copyICCData())
    // Normalize channel order/premultiplication without reducing output size.
    // Every RGBA byte, including alpha, is checked; no image sampling/tolerance.
    let lhs = try #require(ThumbnailBitmapDecoder.rasterized(baseline, maxPixelSize: 768)?.image)
    let rhs = try #require(ThumbnailBitmapDecoder.rasterized(actual, maxPixelSize: 768)?.image)
    #expect(lhs.bitsPerComponent == rhs.bitsPerComponent && lhs.bitsPerPixel == rhs.bitsPerPixel)
    #expect(lhs.alphaInfo == rhs.alphaInfo)
    let lhsBytes = try #require(lhs.dataProvider?.data)
    let rhsBytes = try #require(rhs.dataProvider?.data)
    #expect(lhsBytes == rhsBytes)
  }

  private func markerImage() throws -> CGImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let context = try #require(CGContext(data: nil, width: 16, height: 16,
      bitsPerComponent: 8, bytesPerRow: 64, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    context.setFillColor(try #require(CGColor(colorSpace: space, components: [1, 0, 1, 1])))
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    return try #require(context.makeImage())
  }
}
