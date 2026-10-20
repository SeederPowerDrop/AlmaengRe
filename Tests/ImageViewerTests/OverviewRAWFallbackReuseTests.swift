import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

@Suite("몽땅보기 RAW 원본 보완의 정밀 캐시 재사용")
struct OverviewRAWFallbackReuseTests {
  private func fixture(extensionName: String = "dng") throws -> (URL, ImageAsset) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "OverviewRAWFallbackReuse-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("synthetic-route.\(extensionName)")
    let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let context = try #require(CGContext(data: nil, width: 1_200, height: 900,
      bitsPerComponent: 8, bytesPerRow: 1_200 * 4, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    context.setFillColor(try #require(CGColor(colorSpace: space, components: [0.9, 0.3, 0.2, 1])))
    context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 900))
    let output = try #require(CGImageDestinationCreateWithURL(url as CFURL,
      "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(output, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(output))
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    // A synthetic PNG container exercises RAW filename routing deterministically.
    // Actual sensor RAW color/orientation parity is covered by the opt-in suite.
    return (directory, ImageAsset(url: url,
      byteCount: try #require((attributes[.size] as? NSNumber)?.int64Value),
      modificationDate: attributes[.modificationDate] as? Date))
  }

  private func pipeline(disk: ThumbnailDiskCache) -> ThumbnailPipeline {
    let machine = ImageResourceSnapshot(physicalMemory: 16 * 1_024 * 1_024 * 1_024,
      activeProcessorCount: 8, appleSilicon: true, isAppActive: true, cpuBusyFraction: 0.1)
    return ThumbnailPipeline(governor: ImageResourceGovernor(snapshot: machine,
      storageOverride: .internalSSD, monitorsMemoryPressure: false), diskCache: disk)
  }

  @Test("내장 픽셀이 없는 compact 보완 뒤 원본이 없어도 정밀 PNG를 복구한다")
  func preciseFallbackSurvivesSourceRemovalAndMemoryPurge() async throws {
    let (directory, asset) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(try ThumbnailBitmapDecoder.browsingThumbnail(sourceURL: asset.url,
      maxPixelSize: 256) == nil)
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    let first = pipeline(disk: disk)
    let compact = try await first.browsingThumbnail(for: asset, maxPixelSize: 256,
      preciseRAWFallbackPixelSize: 768)
    #expect(max(compact.width, compact.height) == 256)
    #expect(await disk.contains(for: ThumbnailCacheKey(asset: asset, pixelSize: 768)))
    #expect(await disk.contains(for: ThumbnailCacheKey(asset: asset, pixelSize: 256,
      isBrowsingPreview: true)))
    #expect(await disk.snapshot().entryCount == 2)
    try FileManager.default.removeItem(at: asset.url)
    let memoryExact = try await first.thumbnail(for: asset, maxPixelSize: 768)
    #expect(max(memoryExact.width, memoryExact.height) == 768)
    await first.purgeCache()
    let restored = try await first.thumbnail(for: asset, maxPixelSize: 768)
    #expect(restored.width == memoryExact.width && restored.height == memoryExact.height)
    #expect(restored.colorSpace?.copyICCData() == memoryExact.colorSpace?.copyICCData())
    #expect(await disk.snapshot().entryCount == 2)
  }

  @Test("표시용 RAW 보완은 1024px 안에서만 준비한다")
  func preciseFallbackIsBounded() async throws {
    let (directory, asset) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    let pipeline = pipeline(disk: disk)
    let compact = try await pipeline.browsingThumbnail(for: asset, maxPixelSize: 256,
      preciseRAWFallbackPixelSize: 4_096)
    #expect(max(compact.width, compact.height) == 256)
    #expect(await disk.contains(for: ThumbnailCacheKey(asset: asset, pixelSize: 1_024)))
    #expect(!(await disk.contains(for: ThumbnailCacheKey(asset: asset, pixelSize: 4_096))))
    #expect(await disk.snapshot().entryCount == 2)
  }

  @Test("일반 이미지에는 RAW 보완 힌트를 적용하지 않는다")
  func nonRAWKeepsOriginalCompactPath() async throws {
    let (directory, asset) = try fixture(extensionName: "png")
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    let pipeline = pipeline(disk: disk)
    let compact = try await pipeline.browsingThumbnail(for: asset, maxPixelSize: 256,
      preciseRAWFallbackPixelSize: 768)
    #expect(max(compact.width, compact.height) == 256)
    #expect(!(await disk.contains(for: ThumbnailCacheKey(asset: asset, pixelSize: 768))))
    #expect(await disk.snapshot().entryCount == 1)
  }
}
