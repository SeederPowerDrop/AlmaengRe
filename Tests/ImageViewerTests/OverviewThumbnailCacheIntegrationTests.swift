import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

@Suite("몽땅보기 선읽기와 지속 썸네일 통합")
struct OverviewThumbnailCacheIntegrationTests {
  private actor StorageLookups {
    var count = 0
    func classify() -> ImageStorageKind { count += 1; return .internalSSD }
  }

  private var machine: ImageResourceSnapshot {
    ImageResourceSnapshot(physicalMemory: 16 * 1_024 * 1_024 * 1_024,
      activeProcessorCount: 8, appleSilicon: true, cpuBusyFraction: 0.1)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("OverviewThumbnailCacheTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func bitmap(side: Int) throws -> CGImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let context = try #require(CGContext(data: nil, width: side, height: side,
      bitsPerComponent: 8, bytesPerRow: side * 4,
      space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    for row in stride(from: 0, to: side, by: 8) {
      context.setFillColor(CGColor(red: CGFloat(row) / CGFloat(side),
        green: 0.35, blue: 0.7, alpha: 1))
      context.fill(CGRect(x: 0, y: row, width: side, height: min(8, side - row)))
    }
    return try #require(context.makeImage())
  }

  private func fixture(in directory: URL, name: String = "source", side: Int = 1_024)
    throws -> ImageAsset {
    let url = directory.appendingPathComponent("\(name).png")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
      "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try bitmap(side: side), nil)
    #expect(CGImageDestinationFinalize(destination))
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return ImageAsset(url: url,
      byteCount: try #require((attributes[.size] as? NSNumber)?.int64Value),
      modificationDate: attributes[.modificationDate] as? Date)
  }

  @Test("다른 앱으로 이동해 RAM 예산이 줄어도 남는 썸네일은 재디코딩하지 않는다")
  func nonzeroBudgetShrinkKeepsFittingEntries() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let governor = ImageResourceGovernor(snapshot: machine, storageOverride: .internalSSD)
    let pipeline = ThumbnailPipeline(governor: governor, diskCache: nil)
    let assets = try (0..<3).map { try fixture(in: directory, name: "small-\($0)", side: 32) }
    var images: [CGImage] = []
    for asset in assets {
      images.append(try await pipeline.thumbnail(for: asset, maxPixelSize: 128))
    }
    let before = await pipeline.cacheSnapshot()
    #expect(before.entryCount == assets.count)
    var inactive = machine
    inactive.isAppActive = false
    await governor.update(inactive)
    let after = await pipeline.cacheSnapshot()
    #expect(after.byteLimit > 0)
    #expect(after.byteLimit < before.byteLimit)
    #expect(after.byteCount == before.byteCount)
    #expect(after.entryCount == before.entryCount)
    // Immutable asset versions plus absent originals make an accidental cache
    // purge fail instead of silently passing after another source decode.
    for asset in assets { try FileManager.default.removeItem(at: asset.url) }
    for (index, asset) in assets.enumerated() {
      let cached = try await pipeline.thumbnail(for: asset, maxPixelSize: 128)
      #expect(cached === images[index])
    }
  }

  @Test("RAM 비우기 후 원본이 없어도 저장된 정밀 PNG에서 복구한다")
  func explicitMemoryPurgeRestoresExactFromDisk() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let asset = try fixture(in: directory)
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    let pipeline = ThumbnailPipeline(governor: ImageResourceGovernor(snapshot: machine,
      storageOverride: .internalSSD), diskCache: disk)
    let first = try await pipeline.thumbnail(for: asset, maxPixelSize: 768)
    #expect(first.width == 768)
    #expect(await disk.snapshot().entryCount == 2)
    try FileManager.default.removeItem(at: asset.url)
    await pipeline.purgeCache()
    #expect(await pipeline.cacheSnapshot().byteCount == 0)
    #expect(await disk.snapshot().entryCount == 2)
    let restored = try await pipeline.thumbnail(for: asset, maxPixelSize: 768)
    #expect(restored.width == first.width)
    #expect(restored.height == first.height)
    #expect(await disk.snapshot().hits == 1)
    #expect(await pipeline.cacheSnapshot().entryCount == 1)
    await pipeline.purgeAllCaches()
    #expect(await pipeline.cacheSnapshot().byteCount == 0)
    #expect(await disk.snapshot().byteCount == 0)
    #expect(await pipeline.cachedPreview(for: asset, maxPixelSize: 768) == nil)
  }

  @Test("비활성 중 256px 선읽기는 디스크만 쓰고 표시 후 768px로 정밀 보완한다")
  func compactIdleWarmIsDiskOnlyAndDoesNotImpersonateExactPixels() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let asset = try fixture(in: directory)
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    var inactive = machine
    inactive.isAppActive = false
    let governor = ImageResourceGovernor(snapshot: inactive, storageOverride: .internalSSD)
    let pipeline = ThumbnailPipeline(governor: governor, diskCache: disk)
    #expect(await pipeline.warmOverviewPreviews(assets: [asset]))
    #expect(await pipeline.cacheSnapshot().entryCount == 0)
    let warmed = await disk.snapshot()
    #expect(warmed.entryCount == 1)
    #expect(warmed.previewBytes > 0)
    #expect(warmed.exactBytes == 0)
    let exactKey = ThumbnailCacheKey(asset: asset, pixelSize: 768)
    #expect(await disk.contains(for: exactKey) == false)
    let preview = try #require(await pipeline.cachedPreview(for: asset, maxPixelSize: 768))
    #expect(preview.width == 256)
    #expect(await pipeline.cacheSnapshot().entryCount == 1)
    let exact = try await pipeline.thumbnail(for: asset, maxPixelSize: 768)
    #expect(exact.width == 768)
    #expect(exact.width > preview.width)
    #expect(await disk.contains(for: exactKey))
    #expect(await disk.snapshot().exactBytes > 0)
  }

  @Test("화면에 있는 썸네일을 보호하고 넘치는 추측 선읽기를 버린다")
  func visibleSourcesSurviveSpeculativeInsertion() throws {
    let image = try bitmap(side: 16)
    let cost = image.bytesPerRow * image.height
    let assets = (0..<3).map {
      ImageAsset(url: URL(fileURLWithPath: "/private/overview-visible-\($0).dng"),
        byteCount: 1_000, modificationDate: Date(timeIntervalSinceReferenceDate: 0))
    }
    let keys = assets.map { ThumbnailCacheKey(asset: $0, pixelSize: 128) }
    var cache = ThumbnailMemoryCache(byteLimit: cost * 2)
    cache.insert(image, for: keys[0])
    cache.insert(image, for: keys[1])
    cache.protectVisibleAssets(Array(assets.prefix(2)))
    cache.insert(image, for: keys[2], isSpeculative: true)
    #expect(cache.image(for: keys[0]) != nil)
    #expect(cache.image(for: keys[1]) != nil)
    #expect(cache.image(for: keys[2]) == nil)
    #expect(cache.totalBytes == cost * 2)

    cache.protectVisibleAssets([assets[0]])
    cache.insert(image, for: keys[2], isSpeculative: true)
    #expect(cache.image(for: keys[0]) != nil)
    #expect(cache.image(for: keys[1]) == nil)
    #expect(cache.image(for: keys[2]) != nil)
    #expect(cache.totalBytes == cost * 2)
  }

  @Test("경고·CPU 경합에서는 작은 선읽기를 늦추고 위험·절전·외부 저장장치는 중단한다")
  func idleWarmPolicyPacesContentionAndRejectsUnsafeSources() async throws {
    let url = URL(fileURLWithPath: "/private/idle-overview.png")
    var inactive = machine
    inactive.isAppActive = false
    let allowed = ImageResourceGovernor(snapshot: inactive, storageOverride: .internalSSD)
    #expect(await allowed.overviewWarmDelay(for: url) != nil)
    let accepted = try await allowed.value(
      for: ImageResourceWorkKey(namespace: UUID(), key: 0), url: url,
      priority: .idleThumbnail) { _ in true }
    #expect(accepted)

    var busy = inactive
    busy.cpuBusyFraction = 0.8
    var lowPower = inactive
    lowPower.lowPowerMode = true
    var warning = inactive
    warning.memoryPressure = .warning
    var unknownCPU = inactive
    unknownCPU.cpuBusyFraction = nil
    var hot = inactive
    hot.thermal = .serious
    var critical = inactive
    critical.memoryPressure = .critical
    for snapshot in [busy, warning, unknownCPU] {
      let governor = ImageResourceGovernor(snapshot: snapshot, storageOverride: .internalSSD,
        monitorsMemoryPressure: false)
      #expect(await governor.overviewWarmDelay(for: url) != nil)
      let accepted = try await governor.value(
        for: ImageResourceWorkKey(namespace: UUID(), key: 0), url: url,
        priority: .idleThumbnail) { _ in true }
      #expect(accepted)
    }
    let cases: [(ImageResourceSnapshot, ImageLoadingMode, ImageStorageKind)] = [
      (lowPower, .comfortable, .internalSSD),
      (critical, .comfortable, .internalSSD),
      (hot, .comfortable, .internalSSD),
      (inactive, .comfortable, .removable),
      (inactive, .comfortable, .external),
      (inactive, .comfortable, .network),
      (inactive, .slow, .internalSSD),
    ]
    for (snapshot, mode, storage) in cases {
      let governor = ImageResourceGovernor(mode: mode, snapshot: snapshot, storageOverride: storage)
      #expect(await governor.overviewWarmDelay(for: url) == nil)
      await #expect(throws: CancellationError.self) {
        _ = try await governor.value(for: ImageResourceWorkKey(namespace: UUID(), key: 0),
          url: url, priority: .idleThumbnail) { _ in true }
      }
    }
  }

  @Test("캐시 미리보기 실패는 없는 RAW나 저장장치 분류를 시작하지 않는다")
  func cacheOnlyMissDoesNotTouchOriginalOrStorageClassifier() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lookups = StorageLookups()
    let governor = ImageResourceGovernor(snapshot: machine,
      storageResolver: { _ in await lookups.classify() })
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    let pipeline = ThumbnailPipeline(governor: governor, diskCache: disk)
    let missing = ImageAsset(url: directory.appendingPathComponent("missing.dng"),
      byteCount: 80_000_000, modificationDate: Date(timeIntervalSinceReferenceDate: 0))
    #expect(await pipeline.cachedPreview(for: missing, maxPixelSize: 768) == nil)
    #expect(await lookups.count == 0)
    #expect(await pipeline.cacheSnapshot().entryCount == 0)
    #expect(await disk.snapshot().entryCount == 0)
    #expect(await governor.stateSnapshot().runningCount == 0)
  }
}
