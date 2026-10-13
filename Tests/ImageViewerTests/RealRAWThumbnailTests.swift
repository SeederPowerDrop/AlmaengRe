import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

/// Opt-in read-only pixel check for an existing RAW folder. Never exports photos
/// or records filenames/metadata. Unlike dimension-only smoke tests, this catches
/// opaque black Quick Look results when the source actually contains an image.
@Suite("실제 RAW 썸네일 픽셀 복구", .serialized)
struct RealRAWThumbnailTests {
  @Test("비교 필름스트립과 빠른 탐색의 검은 썸네일을 복구하고 방향과 캐시를 유지한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_DIRECTORY"] != nil),
    .timeLimit(.minutes(3)))
  func readOnlyThumbnailPixels() async throws {
    let environment = ProcessInfo.processInfo.environment
    let directory = URL(fileURLWithPath: try #require(environment["IMAGEVIEWER_RAW_DIRECTORY"]))
    let limit = Int(environment["IMAGEVIEWER_RAW_LIMIT"] ?? "18") ?? 18
    let urls = try FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles])
      .filter { ImageFormatRegistry.cameraRAWExtensions.contains($0.pathExtension.lowercased()) }
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    let assets = try urls.compactMap { url -> ImageAsset? in
      let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      guard let size = values.fileSize, size > 0 else { return nil }
      return ImageAsset(url: url, byteCount: Int64(size), modificationDate: values.contentModificationDate)
    }.prefix(max(1, limit))
    try #require(!assets.isEmpty)
    let governor = ImageResourceGovernor(mode: .comfortable, storageOverride: .internalSSD)
    let filmstrip = ThumbnailPipeline(governor: governor)
    let browsing = ThumbnailPipeline(governor: governor)
    var withoutEmbeddedPreview = 0
    for (index, asset) in assets.enumerated() {
      let reference = try autoreleasepool {
        let source = try #require(CGImageSourceCreateWithURL(asset.url as CFURL,
          [kCGImageSourceShouldCache: false] as CFDictionary))
        if try ThumbnailBitmapDecoder.embeddedThumbnail(in: source, maxPixelSize: 256) == nil {
          withoutEmbeddedPreview += 1
        }
        let decoded = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 256,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary))
        return try #require(ThumbnailBitmapDecoder.rasterized(decoded, maxPixelSize: 256))
      }
      // Filmstrip requests 160px; the shared pipeline rounds that to 256px.
      let thumbnail = try await filmstrip.thumbnail(for: asset, maxPixelSize: 160)
      let preview = try await browsing.browsingThumbnail(for: asset, maxPixelSize: 256)
      for image in [thumbnail, preview] {
        let bitmap = try #require(ThumbnailBitmapDecoder.rasterized(image, maxPixelSize: 256))
        #expect(bitmap.hasVisiblePixels == reference.hasVisiblePixels, "RAW index \(index + 1)")
        #expect(bitmap.hasNonBlackPixels == reference.hasNonBlackPixels, "RAW index \(index + 1)")
        // Browsing previews may intentionally be smaller, but must retain orientation.
        #expect((image.width < image.height) == (reference.image.width < reference.image.height))
      }
      #expect(thumbnail.width == reference.image.width)
      #expect(thumbnail.height == reference.image.height)
      #expect(try await filmstrip.thumbnail(for: asset, maxPixelSize: 160) === thumbnail)
      #expect(try await browsing.browsingThumbnail(for: asset, maxPixelSize: 256) === preview)
    }
    print("RAW_THUMBNAIL_PIXELS checked=\(assets.count) missingEmbedded=\(withoutEmbeddedPreview) readOnly=true")
    await filmstrip.purgeCache()
    await browsing.purgeCache()
  }
}
