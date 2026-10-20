import CoreGraphics
import Foundation
import Testing

@testable import ImageViewer

@Suite("뷰어의 기존 RAM 미리보기 재사용")
struct ViewerMemoryPreviewReuseTests {
  private actor Classifications {
    private(set) var count = 0
    func storage() -> ImageStorageKind { count += 1; return .internalSSD }
  }

  @Test("RAM 조회는 디스크 복구·원본 읽기·작업 등록 없이 기존 비트맵만 반환한다")
  func memoryLookupNeverRestoresDiskOrAdmitsSourceWork() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ViewerMemoryPreviewTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = try #require(CGContext(data: nil, width: 256, height: 256,
      bitsPerComponent: 8, bytesPerRow: 1_024, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let bitmap = try #require(context.makeImage())
    // This source deliberately never exists. Only a pre-existing disk cache can
    // supply the one normal thumbnail request used to prepare the RAM working set.
    let asset = ImageAsset(url: directory.appendingPathComponent("missing.dng"),
      byteCount: 90_000_000, modificationDate: Date(timeIntervalSince1970: 10))
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    await disk.store(bitmap, for: ThumbnailCacheKey(asset: asset, pixelSize: 256))
    let lookups = Classifications()
    let snapshot = ImageResourceSnapshot(physicalMemory: 16 * 1_024 * 1_024 * 1_024,
      activeProcessorCount: 8, appleSilicon: true, cpuBusyFraction: 0.1)
    let governor = ImageResourceGovernor(snapshot: snapshot,
      storageResolver: { _ in await lookups.storage() }, monitorsMemoryPressure: false)
    let pipeline = ThumbnailPipeline(governor: governor, diskCache: disk)

    #expect(await pipeline.cachedMemoryPreview(for: asset, maxPixelSize: 512) == nil)
    #expect(await lookups.count == 0)
    #expect(await disk.snapshot().hits == 0)
    #expect(await governor.stateSnapshot().runningCount == 0)
    let restored = try await pipeline.thumbnail(for: asset, maxPixelSize: 128)
    let before = await disk.snapshot()
    let memoryBefore = await pipeline.cacheSnapshot()
    let classificationsBefore = await lookups.count
    let reused = try #require(await pipeline.cachedMemoryPreview(for: asset, maxPixelSize: 512))
    #expect(reused === restored)
    #expect(await lookups.count == classificationsBefore)
    #expect(await disk.snapshot().hits == before.hits)
    #expect(await pipeline.cacheSnapshot().byteCount == memoryBefore.byteCount)
    #expect(await pipeline.cacheSnapshot().byteLimit == memoryBefore.byteLimit)

    let replaced = ImageAsset(url: asset.url, byteCount: 90_000_001,
      modificationDate: asset.modificationDate)
    #expect(await pipeline.cachedMemoryPreview(for: replaced, maxPixelSize: 512) == nil)
    await pipeline.purgeCache()
    #expect(await pipeline.cachedMemoryPreview(for: asset, maxPixelSize: 512) == nil)
    #expect(await disk.snapshot().hits == before.hits)
    #expect(await lookups.count == classificationsBefore)
    #expect(await governor.stateSnapshot().runningCount == 0)
    #expect(await governor.stateSnapshot().queuedCount == 0)
    #expect(!FileManager.default.fileExists(atPath: asset.url.path))
  }
}
