import CoreGraphics
import Foundation
import ImageIO
import QuickLookThumbnailing
import Testing

@testable import ImageViewer

/// Opt-in read-only comparison of overview decoding work. Filenames and image
/// pixels are never exported. This is not a cold-disk or end-to-end UI benchmark:
/// macOS's filesystem and Quick Look caches are intentionally left untouched.
@Suite("실제 RAW 몽땅보기 읽기 성능", .serialized)
struct RealRAWOverviewPerformanceTests {
  private struct Bitmap: @unchecked Sendable { let image: CGImage }

  @Test("같은 RAW의 중복 정밀 디코딩을 없애고 재방문 캐시를 재사용한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_OVERVIEW_BENCHMARK"] == "1"),
    .timeLimit(.minutes(3)))
  func overviewDecodeWorkload() async throws {
    let environment = ProcessInfo.processInfo.environment
    let directory = URL(fileURLWithPath: try #require(environment["IMAGEVIEWER_RAW_DIRECTORY"]))
    let limit = max(1, Int(environment["IMAGEVIEWER_RAW_LIMIT"] ?? "36") ?? 36)
    let listingStarted = ProcessInfo.processInfo.systemUptime
    let urls = try FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles])
      .filter { ImageFormatRegistry.cameraRAWExtensions.contains($0.pathExtension.lowercased()) }
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    let allAssets = try urls.compactMap { url -> ImageAsset? in
      let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      guard let size = values.fileSize, size > 0 else { return nil }
      return ImageAsset(url: url, byteCount: Int64(size), modificationDate: values.contentModificationDate)
    }
    let listingElapsed = ProcessInfo.processInfo.systemUptime - listingStarted
    print(String(format: "RAW_OVERVIEW_BENCHMARK phase=listing count=%d seconds=%.6f readOnly=true coldStorage=false",
      allAssets.count, listingElapsed))
    let assets = Array(allAssets.prefix(limit))
    try #require(!assets.isEmpty)
    let governor = ImageResourceGovernor(mode: .comfortable, storageOverride: .internalSSD)
    let baselineFrames = ImagePipeline(governor: governor)
    let baselineNamespace = UUID()
    try await measure("previous_quicklook_then_precise", assets: assets) { asset in
      let _: Bitmap = try await governor.value(
        for: ImageResourceWorkKey(namespace: baselineNamespace, key: asset.url), url: asset.url
      ) { _ in
        try await Self.previousThumbnail(for: asset, pixelSize: 512)
      }
      // The previous large overview path decoded the RAW a second time after its
      // quick thumbnail. Its 90ms UI delay is omitted from this decode-only probe.
      let frame = try await baselineFrames.renderFrame(url: asset.url, maxPixelSize: 512,
        adjustments: .identity, prefersHDR: false)
      return frame.image.bytesPerRow * frame.image.height
    }
    await baselineFrames.purgeCaches()

    let thumbnails = ThumbnailPipeline(governor: governor)
    try await measure("revised_source_thumbnail", assets: assets) { asset in
      let request = ThumbnailRequest(asset: asset, maxPixelSize: 512,
        adjustments: .identity, prefersHDR: false, prefersPreciseImage: true)
      #expect(!request.needsPreciseImage)
      let image = try await thumbnails.thumbnail(for: asset, maxPixelSize: 512)
      return image.bytesPerRow * image.height
    }
    let before = await thumbnails.cacheSnapshot()
    printCache("before_revisit", snapshot: before)
    try await measure("revised_revisit", assets: assets) { asset in
      let image = try await thumbnails.thumbnail(for: asset, maxPixelSize: 512)
      return image.bytesPerRow * image.height
    }
    let after = await thumbnails.cacheSnapshot()
    printCache("after_revisit", snapshot: after)
    // macOS memory pressure may reduce the production budget or purge images at
    // any point. The benchmark must report that condition instead of requiring
    // all files to remain resident or weakening the governor to obtain timings.
    #expect(before.entryCount <= assets.count)
    #expect(after.entryCount <= assets.count)
    #expect(before.byteCount <= before.byteLimit)
    #expect(after.byteCount <= after.byteLimit)
    await thumbnails.purgeCache()
  }

  private func printCache(_ phase: String, snapshot: ImageCacheSnapshot) {
    print("RAW_OVERVIEW_CACHE phase=\(phase) entries=\(snapshot.entryCount) "
      + "bytes=\(snapshot.byteCount) byteLimit=\(snapshot.byteLimit)")
  }

  private static func previousThumbnail(for asset: ImageAsset, pixelSize: Int) async throws -> Bitmap {
    let embedded: CGImage? = try autoreleasepool {
      guard let source = CGImageSourceCreateWithURL(asset.url as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary)
      else { return nil }
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
      let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
      let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
      let sourceSize = max(width, height)
      let size = sourceSize > 0 ? min(sourceSize, pixelSize) : pixelSize
      guard let image = try ThumbnailBitmapDecoder.embeddedThumbnail(in: source, maxPixelSize: size),
        max(image.width, image.height) >= size
      else { return nil }
      return ThumbnailBitmapDecoder.rasterized(image, maxPixelSize: pixelSize)?.image
    }
    if let embedded { return Bitmap(image: embedded) }
    let request = QLThumbnailGenerator.Request(fileAt: asset.url,
      size: CGSize(width: CGFloat(pixelSize) / 2, height: CGFloat(pixelSize) / 2), scale: 2,
      representationTypes: .thumbnail)
    let quick: Bitmap = try await withCheckedThrowingContinuation { continuation in
      QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
        if let image = representation?.cgImage { continuation.resume(returning: Bitmap(image: image)) }
        else {
          continuation.resume(throwing: error ?? ThumbnailPipelineError.generationFailed(asset.url))
        }
      }
    }
    return Bitmap(image: try ThumbnailBitmapDecoder.validatedThumbnail(quick.image,
      sourceURL: asset.url, maxPixelSize: pixelSize))
  }

  private func measure(_ phase: String, assets: [ImageAsset],
    operation: @escaping @Sendable (ImageAsset) async throws -> Int
  ) async throws {
    let started = ProcessInfo.processInfo.systemUptime
    let bytes = try await withThrowingTaskGroup(of: Int.self) { group in
      for asset in assets { group.addTask { try await operation(asset) } }
      var total = 0
      for try await cost in group { #expect(cost > 0); total += cost }
      return total
    }
    print(String(format:
      "RAW_OVERVIEW_BENCHMARK phase=%@ count=%d seconds=%.6f bitmapBytes=%d readOnly=true coldStorage=false",
      phase, assets.count, ProcessInfo.processInfo.systemUptime - started, bytes))
  }
}
