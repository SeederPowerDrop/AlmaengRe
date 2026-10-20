import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

@Suite("이미지 캐시 용량과 안전한 비우기")
@MainActor
struct ImageCacheManagementTests {
  private func writeSource(in directory: URL) throws -> URL {
    let source = directory.appendingPathComponent("original.png")
    let context = try #require(CGContext(data: nil, width: 320, height: 160,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 320, height: 160))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL,
      "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return source
  }

  @Test("용량은 실제 캐시와 일치하고 HDR 변경은 디스크를 보존하며 명시 비우기는 재생성을 허용한다")
  func usageAndSafeClear() async throws {
    let suite = "ImageCacheManagementTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let source = try writeSource(in: directory)
    let sourceBytes = try Data(contentsOf: source)
    let diskDirectory = directory.appendingPathComponent("cache")
    let disk = ThumbnailDiskCache(directory: diskDirectory)
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: directory.appendingPathComponent("marks.sqlite"),
      thumbnailDiskCache: disk)
    defer { store.folderComparison.cancelLoads() }
    store.imagesPerPage = 4
    store.wrapsNavigation = false
    let asset = ImageAsset(url: source, byteCount: Int64(sourceBytes.count), modificationDate: nil)
    _ = try await store.pipeline.renderFrame(url: source, maxPixelSize: 256,
      adjustments: .identity, prefersHDR: false)
    _ = try await store.thumbnailPipeline.thumbnail(for: asset, maxPixelSize: 128)
    await store.refreshImageCacheUsage()
    let usage = try #require(store.imageCacheUsage)
    #expect(usage.memoryByteCount == (await store.pipeline.cacheSnapshot().byteCount)
      + (await store.thumbnailPipeline.cacheSnapshot().byteCount))
    let diskBytes = await disk.snapshot().byteCount
    let files = try #require(FileManager.default.enumerator(at: diskDirectory,
      includingPropertiesForKeys: [.fileSizeKey]))
    let pngFiles = (files.allObjects as? [URL] ?? []).filter { $0.pathExtension == "png" }
    let actualFileBytes = try pngFiles.reduce(0) { bytes, url in
      bytes + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    #expect(usage.memoryByteCount > 0)
    #expect(usage.isDiskUsageComplete)
    #expect(usage.diskByteCount == diskBytes)
    #expect(usage.diskByteCount == actualFileBytes)
    #expect(diskBytes > 0)

    let ramOnly = try #require(store.purgeCaches(clearDisk: false))
    #expect(store.isPurgingImageCaches)
    #expect(store.purgeCaches() == nil, "Repeated clicks must not launch concurrent clears")
    await ramOnly.value
    #expect(store.imageCacheUsage?.memoryByteCount == 0)
    #expect(store.imageCacheUsage?.diskByteCount == diskBytes)
    #expect(await disk.snapshot().byteCount == diskBytes)

    // Disk restoration works without requiring a source decode before the user
    // explicitly removes both cache tiers.
    _ = try await store.thumbnailPipeline.thumbnail(for: asset, maxPixelSize: 128)
    let clear = try #require(store.purgeCaches())
    await clear.value
    #expect(!store.isPurgingImageCaches)
    #expect(!store.imageCachePurgeFailed)
    #expect(store.imageCacheUsage?.memoryByteCount == 0)
    #expect(store.imageCacheUsage?.diskByteCount == 0)
    #expect(store.imageCacheUsage?.isDiskUsageComplete == true)
    #expect(!FileManager.default.fileExists(atPath: diskDirectory.path))
    #expect(try Data(contentsOf: source) == sourceBytes)
    #expect(store.imagesPerPage == 4)
    #expect(!store.wrapsNavigation)
    _ = try await store.thumbnailPipeline.thumbnail(for: asset, maxPixelSize: 128)
    await store.refreshImageCacheUsage()
    #expect((store.imageCacheUsage?.diskByteCount ?? 0) > 0)
    #expect((store.imageCacheUsage?.memoryByteCount ?? 0) > 0)
    #expect(try Data(contentsOf: source) == sourceBytes)
  }

  @Test("삭제할 수 없는 디스크 캐시는 오류와 남은 용량을 보여준다")
  func failedClearKeepsRemainingSize() async throws {
    let suite = "ImageCacheManagementFailureTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let source = try writeSource(in: directory)
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"),
      removeDirectory: { _ in throw CocoaError(.fileWriteNoPermission) })
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: directory.appendingPathComponent("marks.sqlite"),
      thumbnailDiskCache: disk)
    defer { store.folderComparison.cancelLoads() }
    _ = try await store.thumbnailPipeline.thumbnail(for: ImageAsset(url: source,
      byteCount: nil, modificationDate: nil), maxPixelSize: 128)
    let diskBytes = await disk.snapshot().byteCount
    #expect(diskBytes > 0)
    let clear = try #require(store.purgeCaches())
    await clear.value
    #expect(store.imageCachePurgeFailed)
    #expect(store.imageCacheUsage?.memoryByteCount == 0)
    #expect(store.imageCacheUsage?.diskByteCount == diskBytes)
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  @Test("디스크를 사용하지 않는 상태와 불완전한 0바이트·일부 용량을 구분한다")
  func diskUsageCompletenessIsIndependentOfKnownBytes() {
    let memory = ImageCacheSnapshot(entryCount: 1, byteCount: 4_096, byteLimit: 8_192)
    let thumbnails = ImageCacheSnapshot(entryCount: 0, byteCount: 0, byteLimit: 8_192)
    let disabled = ImageCacheUsage(rendered: memory, thumbnails: thumbnails, disk: nil)
    #expect(disabled.isDiskUsageComplete)
    #expect(disabled.diskByteCount == 0)
    #expect(ImageCacheManagementControls.diskUsageText(for: disabled)
      == L10n.format("cache.diskUsage", disabled.formattedDiskSize))
    let empty = ImageCacheUsage(rendered: memory, thumbnails: thumbnails,
      disk: ThumbnailDiskCacheSnapshot(entryCount: 0, byteCount: 0,
        byteLimit: 4_096, previewBytes: 0, exactBytes: 0, hits: 0, misses: 0))
    #expect(empty.isDiskUsageComplete)
    #expect(ImageCacheManagementControls.diskUsageText(for: empty)
      == L10n.format("cache.diskUsage", empty.formattedDiskSize))
    for bytes in [0, 1_024] {
      let disk = ThumbnailDiskCacheSnapshot(entryCount: 0, byteCount: bytes,
        byteLimit: 4_096, previewBytes: bytes, exactBytes: 0, hits: 0, misses: 0,
        isComplete: false)
      let incomplete = ImageCacheUsage(rendered: memory, thumbnails: thumbnails, disk: disk)
      #expect(!incomplete.isDiskUsageComplete)
      #expect(incomplete.diskByteCount == bytes, "Keep any known accounting without presenting it as the total")
      #expect(incomplete.memoryByteCount == 4_096)
      #expect(ImageCacheManagementControls.diskUsageText(for: incomplete)
        == L10n.format("cache.diskUsage", L10n.text("cache.usageUnknown")))
      #expect(ImageCacheManagementControls.diskUsageText(for: incomplete)
        != L10n.format("cache.diskUsage", incomplete.formattedDiskSize))
    }
  }

  @Test("권한 때문에 처음부터 읽지 못한 캐시는 확인 불가이며 권한 복구 후 새로 고치면 실제 용량을 표시한다",
    .enabled(if: geteuid() != 0))
  func initialUnreadableDiskUsageRecoversThroughRefresh() async throws {
    let suite = "ImageCacheUnknownUsageTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    let diskDirectory = directory.appendingPathComponent("cache")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: diskDirectory.path)
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let source = try writeSource(in: directory)
    let sourceBytes = try Data(contentsOf: source)
    let imageSource = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))
    let bitmap = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
    let asset = ImageAsset(url: source, byteCount: Int64(sourceBytes.count), modificationDate: nil)
    let writer = ThumbnailDiskCache(directory: diskDirectory)
    await writer.store(bitmap, for: ThumbnailCacheKey(asset: asset, pixelSize: 320))
    let expectedBytes = await writer.snapshot().byteCount
    #expect(expectedBytes > 0)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: diskDirectory.path)
    let clock = ImageCacheManagementTestClock()
    let disk = ThumbnailDiskCache(directory: diskDirectory, now: { clock.current() })
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: directory.appendingPathComponent("marks.sqlite"),
      thumbnailDiskCache: disk)
    defer { store.folderComparison.cancelLoads() }
    await store.refreshImageCacheUsage()
    let unavailable = try #require(store.imageCacheUsage)
    #expect(!unavailable.isDiskUsageComplete)
    #expect(unavailable.diskByteCount == 0)
    #expect(ImageCacheManagementControls.diskUsageText(for: unavailable)
      == L10n.format("cache.diskUsage", L10n.text("cache.usageUnknown")))

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: diskDirectory.path)
    clock.advance(seconds: 5)
    await store.refreshImageCacheUsage()
    let restored = try #require(store.imageCacheUsage)
    #expect(restored.isDiskUsageComplete)
    #expect(restored.diskByteCount == expectedBytes)
    #expect(ImageCacheManagementControls.diskUsageText(for: restored)
      == L10n.format("cache.diskUsage", restored.formattedDiskSize))
    #expect(try Data(contentsOf: source) == sourceBytes)
  }

  @Test("용량 확인 불가와 권한 안내는 모든 지원 언어에서 번역하고 서식 인수를 추가하지 않는다")
  func unknownDiskUsageTranslations() {
    for language in L10n.supportedLocalizations {
      for key in ["cache.usageUnknown", "cache.diskUsageUnavailableHelp"] {
        #expect(L10n.keys(localeIdentifier: language).contains(key))
        let text = L10n.text(key, localeIdentifier: language)
        #expect(!text.isEmpty)
        #expect(text != key)
        #expect(!text.contains("%@"))
      }
    }
  }
}

private final class ImageCacheManagementTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date = Date(timeIntervalSince1970: 1_800_000_000)

  func current() -> Date { lock.withLock { date } }
  func advance(seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}
