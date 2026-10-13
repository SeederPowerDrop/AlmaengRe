import CoreGraphics
import Foundation
import ImageIO
import QuickLookThumbnailing
import Testing

@testable import ImageViewer

/// Opt-in: IMAGEVIEWER_THUMBNAIL_BENCHMARK=1 swift test --filter ThumbnailSourceBenchmarkTests
/// Generated JPEGs only. Hardlinked paths share file bytes and filesystem caches;
/// the result does not measure camera RAW, cold storage, or total application launch.
@Suite("합성 썸네일 경로 성능", .serialized)
struct ThumbnailSourceBenchmarkTests {
  private struct Bitmap: @unchecked Sendable { let image: CGImage }

  @Test("24개 합성 JPEG의 Quick Look·직접 읽기·모드 전환 캐시를 비교한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_THUMBNAIL_BENCHMARK"] == "1"),
    .timeLimit(.minutes(2)))
  func generatedPhotoGrid() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ImageViewerThumbnailBenchmark-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("synthetic.jpg")
    try makeFixture(at: source)
    var nativeAssets: [ImageAsset] = [], directAssets: [ImageAsset] = []
    for index in 0..<24 {
      for variant in ["native", "direct"] {
        let url = folder.appendingPathComponent("\(variant)-\(index).jpg")
        try FileManager.default.linkItem(at: source, to: url)
        let asset = ImageAsset(url: url, byteCount: nil, modificationDate: nil)
        if variant == "native" { nativeAssets.append(asset) }
        else { directAssets.append(asset) }
      }
    }
    let snapshot = ImageResourceSnapshot(physicalMemory: 16 * 1_024 * 1_024 * 1_024,
      activeProcessorCount: 8, appleSilicon: true)
    let governor = ImageResourceGovernor(mode: .comfortable, snapshot: snapshot,
      storageOverride: .internalSSD)
    let namespace = UUID()
    try await measure("quicklook_first", assets: nativeAssets) { asset in
      try await governor.value(
        for: ImageResourceWorkKey(namespace: namespace, key: asset.url), url: asset.url
      ) { _ in
        let request = QLThumbnailGenerator.Request(fileAt: asset.url,
          size: CGSize(width: 128, height: 128), scale: 2, representationTypes: .thumbnail)
        let generated: Bitmap = try await withCheckedThrowingContinuation { continuation in
          QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { result, error in
            if let image = result?.cgImage { continuation.resume(returning: Bitmap(image: image)) }
            else {
              continuation.resume(throwing: error ?? ThumbnailPipelineError.generationFailed(asset.url))
            }
          }
        }
        let image = try ThumbnailBitmapDecoder.validatedThumbnail(generated.image,
          sourceURL: asset.url, maxPixelSize: 256)
        return image.bytesPerRow * image.height
      }
    }
    let pipeline = ThumbnailPipeline(governor: governor)
    try await measure("direct_first", assets: directAssets) { asset in
      let image = try await pipeline.thumbnail(for: asset, maxPixelSize: 256)
      return image.bytesPerRow * image.height
    }
    let before = await pipeline.cacheSnapshot()
    try await measure("smaller_cached", assets: directAssets) { asset in
      let image = try await pipeline.thumbnail(for: asset, maxPixelSize: 128)
      return image.bytesPerRow * image.height
    }
    let after = await pipeline.cacheSnapshot()
    #expect(before.entryCount == 24)
    #expect(before.byteCount == after.byteCount)
    #expect(before.entryCount == after.entryCount)
  }

  private func measure(_ phase: String, assets: [ImageAsset],
    operation: @escaping @Sendable (ImageAsset) async throws -> Int
  ) async throws {
    let started = ProcessInfo.processInfo.systemUptime
    let bytes = try await withThrowingTaskGroup(of: Int.self) { group in
      for asset in assets { group.addTask { try await operation(asset) } }
      var bytes = 0
      for try await cost in group { #expect(cost > 0); bytes += cost }
      return bytes
    }
    let seconds = ProcessInfo.processInfo.systemUptime - started
    print(String(format:
      "THUMBNAIL_SOURCE_BENCHMARK phase=%@ count=%d seconds=%.6f bitmapBytes=%d fixture=syntheticJPEG hardlinked=true coldStorage=false",
      phase, assets.count, seconds, bytes))
  }

  private func makeFixture(at url: URL) throws {
    let width = 2400, height = 1600
    let context = try #require(CGContext(data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    for row in stride(from: 0, to: height, by: 8) {
      context.setFillColor(CGColor(red: CGFloat(row) / CGFloat(height), green: 0.35,
        blue: 0.7, alpha: 1))
      context.fill(CGRect(x: 0, y: row, width: width, height: 8))
    }
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
      "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [
      kCGImageDestinationEmbedThumbnail: true,
      kCGImageDestinationLossyCompressionQuality: 0.9,
    ] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
  }
}
