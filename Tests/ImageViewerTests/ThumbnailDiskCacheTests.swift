import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

private final class ThumbnailDiskCacheTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) { self.date = date }

  func current() -> Date { lock.withLock { date } }
  func set(_ date: Date) { lock.withLock { self.date = date } }
}

private final class ThumbnailDiskCacheTouchRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var failuresRemaining: Int
  private var touches = 0

  init(failures: Int = 0) { failuresRemaining = failures }

  var touchCount: Int { lock.withLock { touches } }

  func performTouch(at url: URL, date: Date) throws {
    let shouldFail = lock.withLock {
      touches += 1
      guard failuresRemaining > 0 else { return false }
      failuresRemaining -= 1
      return true
    }
    if shouldFail { throw CocoaError(.fileWriteNoPermission) }
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
  }
}

private final class ThumbnailDiskCacheRemovalController: @unchecked Sendable {
  private let lock = NSLock()
  private var denied = false
  private var attempts = 0

  var attemptCount: Int { lock.withLock { attempts } }
  func denyRemovals(_ denied: Bool) { lock.withLock { self.denied = denied } }

  func remove(_ url: URL) throws {
    let shouldDeny = lock.withLock { attempts += 1; return denied }
    if shouldDeny { throw CocoaError(.fileWriteNoPermission) }
    try FileManager.default.removeItem(at: url)
  }
}

private final class ThumbnailDiskCacheMetadataController: @unchecked Sendable {
  private let lock = NSLock()
  private var mode = 0

  func setMode(_ mode: Int) { lock.withLock { self.mode = mode } }

  func values(_ url: URL, keys: Set<URLResourceKey>) throws -> URLResourceValues {
    let mode = lock.withLock { self.mode }
    if url.pathExtension == "png" {
      if mode == 1 { throw CocoaError(.fileReadNoPermission) }
      if mode == 2 { return URLResourceValues() }
    }
    return try url.resourceValues(forKeys: keys)
  }
}

@Suite("썸네일 디스크 캐시")
struct ThumbnailDiskCacheTests {
  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ThumbnailDiskCacheTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func key(_ index: Int, pixelSize: Int = 128, preview: Bool = false,
    bytes: Int64 = 1_000, modified: TimeInterval = 0
  ) -> ThumbnailCacheKey {
    ThumbnailCacheKey(asset: ImageAsset(
      url: URL(fileURLWithPath: "/private/photos/secret-camera-image-\(index).dng"),
      byteCount: bytes, modificationDate: Date(timeIntervalSinceReferenceDate: modified)),
      pixelSize: pixelSize, isBrowsingPreview: preview)
  }

  private func image(side: Int = 64) throws -> CGImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let context = try #require(CGContext(data: nil, width: side, height: side,
      bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue))
    // Include transparent, translucent, opaque and wide-gamut pixels.
    context.clear(CGRect(x: 0, y: 0, width: side, height: side))
    context.setFillColor(try #require(CGColor(colorSpace: space, components: [0.9, 0.2, 0.4, 0.5])))
    context.fill(CGRect(x: 0, y: 0, width: side / 2, height: side))
    context.setFillColor(try #require(CGColor(colorSpace: space, components: [1, 0, 0, 1])))
    context.fill(CGRect(x: side / 2, y: side / 2, width: side / 2, height: side / 2))
    return try #require(context.makeImage())
  }

  private func pixels(_ image: CGImage, space: CGColorSpace) throws -> [UInt8] {
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue))
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data)
    return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
      count: image.width * image.height * 4))
  }

  private func pngFiles(in directory: URL) -> [URL] {
    let enumerator = FileManager.default.enumerator(at: directory,
      includingPropertiesForKeys: nil)
    return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "png" }
  }

  private func actualCacheFileBytes(in directory: URL) throws -> Int {
    let enumerator = FileManager.default.enumerator(at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
    return try (enumerator?.allObjects as? [URL] ?? []).reduce(0) { result, url in
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      return result + (values.isRegularFile == true ? values.fileSize ?? 0 : 0)
    }
  }

  private func modificationDate(of file: URL) throws -> Date {
    try #require(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
  }

  private func setModificationDate(_ date: Date, of file: URL) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
  }

  private static func missingFileError(_ kind: Int) -> NSError {
    switch kind {
    case 0: NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileNoSuchFile.rawValue)
    case 1: NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileReadNoSuchFile.rawValue)
    case 2: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
    default: NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteUnknown.rawValue,
      userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))])
    }
  }

  @Test("재실행한 캐시는 원본을 읽지 않고 썸네일을 복구하며 경로를 저장하지 않는다")
  func restartReuseAndPrivateNames() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = try image()
    let first = ThumbnailDiskCache(directory: directory)
    await first.store(original, for: key(1))
    #expect(await first.snapshot().entryCount == 1)

    let restarted = ThumbnailDiskCache(directory: directory)
    #expect(await restarted.contains(for: key(1)))
    let restored = try #require(await restarted.image(for: key(1)))
    #expect(restored.width == original.width)
    #expect(restored.height == original.height)
    #expect(await restarted.snapshot().hits == 1)
    let files = pngFiles(in: directory)
    #expect(files.count == 1)
    let file = try #require(files.first)
    #expect(file.deletingLastPathComponent().lastPathComponent.count == 64)
    #expect(!file.path.contains("secret-camera-image"))
    #expect(file.lastPathComponent == "exact-128.png")
    #expect(!FileManager.default.fileExists(atPath: key(1).fileURL.path))
  }

  @Test("PNG 재사용은 Display P3 프로필과 알파 및 보이는 픽셀을 보존한다")
  func losslessColorAndTransparency() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = try image()
    let cache = ThumbnailDiskCache(directory: directory)
    await cache.store(original, for: key(2))
    let restored = try #require(await cache.image(for: key(2)))
    let originalSpace = try #require(original.colorSpace)
    let restoredSpace = try #require(restored.colorSpace)
    let originalICC = try #require(originalSpace.copyICCData()) as Data
    let restoredICC = try #require(restoredSpace.copyICCData()) as Data
    #expect(restoredICC == originalICC)
    let before = try pixels(original, space: originalSpace)
    let after = try pixels(restored, space: originalSpace)
    #expect(before.count == after.count)
    // PNG uses straight alpha. Premultiplying its 8-bit channels again may round
    // a component by one unit; alpha itself must remain exactly unchanged.
    #expect(zip(before, after).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    #expect(stride(from: 3, to: before.count, by: 4).allSatisfy { before[$0] == after[$0] })
    #expect(after.contains(0))
    #expect(after.contains(128))
    #expect(after.contains(255))
  }

  @Test("파일 크기·수정 시각·경로가 바뀌면 이전 썸네일을 반환하지 않는다")
  func sourceVersionInvalidation() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThumbnailDiskCache(directory: directory)
    await cache.store(try image(), for: key(3))
    #expect(await cache.image(for: key(3)) != nil)
    #expect(await cache.image(for: key(3, bytes: 1_001)) == nil)
    #expect(await cache.image(for: key(3, modified: 1)) == nil)
    #expect(await cache.image(for: key(4)) == nil)
    #expect(await cache.snapshot().misses == 3)
    #expect(await cache.snapshot().entryCount == 1)
  }

  @Test("정밀 요청은 작은 탐색 미리보기를 받지 않고 탐색 중에는 재사용한다")
  func qualityAndNearestSizeLookup() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThumbnailDiskCache(directory: directory)
    await cache.store(try image(side: 16), for: key(5, pixelSize: 512, preview: true))
    #expect(await cache.image(for: key(5, pixelSize: 512)) == nil)
    #expect(await cache.contains(for: key(5, pixelSize: 512), allowsSmaller: true))
    #expect(await cache.image(for: key(5, pixelSize: 512), allowsSmaller: true)?.width == 16)

    await cache.store(try image(side: 256), for: key(5, pixelSize: 256))
    await cache.store(try image(side: 128), for: key(5, pixelSize: 128))
    #expect(await cache.image(for: key(5, pixelSize: 96))?.width == 128)
    #expect(await cache.image(for: key(5, pixelSize: 192))?.width == 256)
    #expect(await cache.image(for: key(5, pixelSize: 384)) == nil)
    #expect(await cache.image(for: key(5, pixelSize: 384), allowsSmaller: true)?.width == 16)
    #expect(await cache.image(for: key(5, pixelSize: 128, preview: true))?.width == 128)
    #expect(await cache.snapshot().entryCount == 3)
  }

  @Test("바이트 한도와 재실행 후 LRU를 지키며 탐색·정밀 예산을 분리한다")
  func tierBudgetsAndPersistentLeastRecentlyUsed() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bitmap = try image()
    let calibration = ThumbnailDiskCache(directory: directory.appendingPathComponent("calibration"))
    await calibration.store(bitmap, for: key(0))
    let cost = await calibration.snapshot().exactBytes
    #expect(cost > 0)

    let cacheDirectory = directory.appendingPathComponent("bounded")
    let writer = ThumbnailDiskCache(directory: cacheDirectory,
      previewByteLimit: cost, exactByteLimit: cost * 2)
    await writer.store(bitmap, for: key(1))
    let firstFile = try #require(pngFiles(in: cacheDirectory).first)
    await writer.store(bitmap, for: key(2))
    let secondFile = try #require(pngFiles(in: cacheDirectory).first { $0 != firstFile })
    // Persisted LRU is coalesced to one touch per minute. Age the entries by
    // explicit file dates so this restart test does not depend on tiny sleeps.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = ThumbnailDiskCacheTestClock(now)
    try setModificationDate(now.addingTimeInterval(-120), of: firstFile)
    try setModificationDate(now.addingTimeInterval(-90), of: secondFile)
    let cache = ThumbnailDiskCache(directory: cacheDirectory,
      previewByteLimit: cost, exactByteLimit: cost * 2, now: { clock.current() })
    #expect(await cache.image(for: key(1)) != nil)
    let restarted = ThumbnailDiskCache(directory: cacheDirectory,
      previewByteLimit: cost, exactByteLimit: cost * 2, now: { clock.current() })
    await restarted.store(bitmap, for: key(3))
    #expect(await restarted.image(for: key(1)) != nil)
    #expect(await restarted.image(for: key(2)) == nil)
    #expect(await restarted.image(for: key(3)) != nil)
    clock.set(now.addingTimeInterval(1))
    await restarted.store(bitmap, for: key(4, preview: true))
    clock.set(now.addingTimeInterval(2))
    await restarted.store(bitmap, for: key(5, preview: true))
    #expect(await restarted.image(for: key(4, preview: true)) == nil)
    #expect(await restarted.image(for: key(5, preview: true)) != nil)
    let snapshot = await restarted.snapshot()
    #expect(snapshot.exactBytes == cost * 2)
    #expect(snapshot.previewBytes == cost)
    #expect(snapshot.byteCount == snapshot.byteLimit)
    #expect(snapshot.entryCount == 3)
  }

  @Test("반복 복구는 파일 mtime 쓰기를 합치면서 현재 실행의 LRU를 계속 갱신한다")
  func repeatedRestoresCoalesceDiskTouchesAndPreserveMemoryLRU() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bitmap = try image()
    let writer = ThumbnailDiskCache(directory: directory)
    await writer.store(bitmap, for: key(1))
    let cost = await writer.snapshot().exactBytes
    let firstFile = try #require(pngFiles(in: directory).first)
    await writer.store(bitmap, for: key(2))
    let secondFile = try #require(pngFiles(in: directory).first { $0 != firstFile })
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let firstDate = start.addingTimeInterval(-2)
    try setModificationDate(firstDate, of: firstFile)
    try setModificationDate(start.addingTimeInterval(-1), of: secondFile)
    let clock = ThumbnailDiskCacheTestClock(start)
    let files = ThumbnailDiskCacheTouchRecorder()
    let cache = ThumbnailDiskCache(directory: directory, exactByteLimit: cost * 2,
      persistAccessDate: { try files.performTouch(at: $0, date: $1) }, now: { clock.current() })
    for second in 0..<20 {
      clock.set(start.addingTimeInterval(TimeInterval(second)))
      #expect(await cache.image(for: key(1)) != nil)
    }
    #expect(files.touchCount == 0)
    #expect(try modificationDate(of: firstFile) == firstDate)
    await cache.store(bitmap, for: key(3))
    #expect(await cache.contains(for: key(1)))
    #expect(!(await cache.contains(for: key(2))))
    #expect(await cache.contains(for: key(3)))
    #expect(await cache.snapshot().hits == 20)
  }

  @Test("오래된 항목은 즉시 mtime을 갱신하고 60초 경계와 재실행에서도 재사용한다")
  func agedRestorePersistsAtMinuteBoundaryAndSurvivesRestart() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = ThumbnailDiskCache(directory: directory)
    await writer.store(try image(), for: key(1))
    let file = try #require(pngFiles(in: directory).first)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    try setModificationDate(start.addingTimeInterval(-120), of: file)
    let clock = ThumbnailDiskCacheTestClock(start)
    let files = ThumbnailDiskCacheTouchRecorder()
    let cache = ThumbnailDiskCache(directory: directory,
      persistAccessDate: { try files.performTouch(at: $0, date: $1) },
      now: { clock.current() })
    #expect(await cache.image(for: key(1)) != nil)
    #expect(try modificationDate(of: file) == start)
    #expect(files.touchCount == 1)
    clock.set(start.addingTimeInterval(59))
    #expect(await cache.image(for: key(1)) != nil)
    #expect(try modificationDate(of: file) == start)
    #expect(files.touchCount == 1)
    clock.set(start.addingTimeInterval(60))
    #expect(await cache.image(for: key(1)) != nil)
    #expect(try modificationDate(of: file) == start.addingTimeInterval(60))
    #expect(files.touchCount == 2)
    clock.set(start.addingTimeInterval(61))
    let restarted = ThumbnailDiskCache(directory: directory,
      persistAccessDate: { try files.performTouch(at: $0, date: $1) },
      now: { clock.current() })
    #expect(await restarted.image(for: key(1)) != nil)
    #expect(await restarted.snapshot().entryCount == 1)
    #expect(files.touchCount == 2)
  }

  @Test("시계가 뒤로 이동하면 mtime 간격을 새로 시작한다")
  func backwardsClockResetsPersistedAccessWindow() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = ThumbnailDiskCache(directory: directory)
    await writer.store(try image(), for: key(1))
    let file = try #require(pngFiles(in: directory).first)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    try setModificationDate(start.addingTimeInterval(10), of: file)
    let clock = ThumbnailDiskCacheTestClock(start)
    let files = ThumbnailDiskCacheTouchRecorder()
    let cache = ThumbnailDiskCache(directory: directory,
      persistAccessDate: { try files.performTouch(at: $0, date: $1) },
      now: { clock.current() })
    #expect(await cache.image(for: key(1)) != nil)
    #expect(files.touchCount == 1)
    #expect(try modificationDate(of: file) == start)
    clock.set(start.addingTimeInterval(5))
    #expect(await cache.image(for: key(1)) != nil)
    #expect(files.touchCount == 1)
    clock.set(start.addingTimeInterval(-2))
    #expect(await cache.image(for: key(1)) != nil)
    #expect(files.touchCount == 2)
    #expect(try modificationDate(of: file) == start.addingTimeInterval(-2))
  }

  @Test("mtime 저장 실패는 복구를 방해하지 않고 다음 적중에서 다시 시도한다")
  func failedPersistedTouchRetriesOnNextHit() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = ThumbnailDiskCache(directory: directory)
    await writer.store(try image(), for: key(1))
    let file = try #require(pngFiles(in: directory).first)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let old = start.addingTimeInterval(-120)
    try setModificationDate(old, of: file)
    let files = ThumbnailDiskCacheTouchRecorder(failures: 1)
    let cache = ThumbnailDiskCache(directory: directory,
      persistAccessDate: { try files.performTouch(at: $0, date: $1) }, now: { start })
    #expect(await cache.image(for: key(1)) != nil)
    #expect(files.touchCount == 1)
    #expect(try modificationDate(of: file) == old)
    #expect(await cache.image(for: key(1)) != nil)
    #expect(files.touchCount == 2)
    #expect(try modificationDate(of: file) == start)
    #expect(await cache.image(for: key(1)) != nil)
    #expect(files.touchCount == 2)
    #expect(await cache.snapshot().hits == 3)
  }

  @Test("손상된 PNG는 삭제하고 다시 생성한 썸네일로 복구할 수 있다")
  func corruptEntryIsRemovedAndRepaired() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThumbnailDiskCache(directory: directory)
    let bitmap = try image()
    await cache.store(bitmap, for: key(8))
    let file = try #require(pngFiles(in: directory).first)
    try Data("broken PNG".utf8).write(to: file, options: .atomic)
    #expect(await cache.image(for: key(8)) == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(await cache.snapshot().entryCount == 0)
    #expect(await cache.snapshot().byteCount == 0)
    await cache.store(bitmap, for: key(8))
    #expect(await cache.image(for: key(8)) != nil)
  }

  @Test("단일 파일이 예산을 넘거나 저장이 불가능하면 캐시 없이 계속한다")
  func oversizedAndUnavailableCache() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThumbnailDiskCache(directory: directory.appendingPathComponent("tiny"),
      previewByteLimit: 1, exactByteLimit: 1)
    let bitmap = try image()
    await cache.store(bitmap, for: key(9))
    await cache.store(bitmap, for: key(9, preview: true))
    #expect(await cache.snapshot().entryCount == 0)
    #expect(await cache.snapshot().byteCount == 0)
    #expect(pngFiles(in: directory).isEmpty)

    let blocked = directory.appendingPathComponent("ordinary-file")
    try Data([0]).write(to: blocked)
    let unavailable = ThumbnailDiskCache(directory: blocked)
    await unavailable.store(bitmap, for: key(9))
    #expect(await unavailable.image(for: key(9)) == nil)
    #expect(await unavailable.snapshot().entryCount == 0)
    #expect(try Data(contentsOf: blocked) == Data([0]))
  }

  @Test("비우기는 두 계층과 통계를 지우고 이후 재사용을 허용한다")
  func clearAndReuse() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThumbnailDiskCache(directory: directory)
    let bitmap = try image()
    await cache.store(bitmap, for: key(10))
    await cache.store(bitmap, for: key(10, preview: true))
    #expect(await cache.image(for: key(10)) != nil)
    await cache.removeAll()
    let snapshot = await cache.snapshot()
    #expect(snapshot.entryCount == 0)
    #expect(snapshot.byteCount == 0)
    #expect(snapshot.isComplete)
    #expect(snapshot.hits == 0)
    #expect(snapshot.misses == 0)
    #expect(pngFiles(in: directory).isEmpty)
    #expect(await cache.image(for: key(10)) == nil)
    await cache.store(bitmap, for: key(10))
    #expect(await cache.image(for: key(10)) != nil)
    let restarted = ThumbnailDiskCache(directory: directory)
    #expect(await restarted.snapshot().entryCount == 1)
  }

  @Test("비우기 전에 시작한 쓰기는 폴더와 PNG를 다시 만들지 않는다")
  func staleWritesCannotRepopulateAfterClear() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThumbnailDiskCache(directory: directory)
    let bitmap = try image()
    let beforeClear = await cache.generationToken()
    await cache.store(bitmap, for: key(1), generation: beforeClear)
    #expect(await cache.removeAll())
    await cache.store(bitmap, for: key(2), generation: beforeClear)
    await cache.store(bitmap, for: key(2, preview: true), generation: beforeClear)
    #expect(await cache.snapshot().byteCount == 0)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    let current = await cache.generationToken()
    #expect(current != beforeClear)
    await cache.store(bitmap, for: key(3), generation: current)
    #expect(await cache.image(for: key(3)) != nil)
    #expect(await cache.snapshot().entryCount == 1)
  }

  @Test("디스크 삭제 실패는 남은 용량을 숨기지 않고 이전 쓰기를 무효화한다")
  func failedClearReportsRemainingBytes() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThumbnailDiskCache(directory: directory, removeDirectory: { _ in
      throw CocoaError(.fileWriteNoPermission)
    }, removeFile: { _ in throw CocoaError(.fileWriteNoPermission) })
    let bitmap = try image()
    let generation = await cache.generationToken()
    await cache.store(bitmap, for: key(1), generation: generation)
    let before = await cache.snapshot()
    #expect(before.byteCount > 0)
    #expect(!(await cache.removeAll()))
    await cache.store(bitmap, for: key(2), generation: generation)
    let after = await cache.snapshot()
    #expect(after.entryCount == before.entryCount)
    #expect(after.byteCount == before.byteCount)
    #expect(await cache.image(for: key(1)) != nil)
    #expect(await cache.image(for: key(2)) == nil)
  }

  @Test("LRU 삭제 실패는 실제 용량을 유지하고 새 PNG를 쓰지 않으며 권한 복구 뒤 재시도한다")
  func deniedEvictionPreservesBytesAndBlocksWritesUntilRetry() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bitmap = try image()
    let calibration = ThumbnailDiskCache(directory: directory.appendingPathComponent("calibration"))
    await calibration.store(bitmap, for: key(0))
    let cost = await calibration.snapshot().exactBytes
    let cacheDirectory = directory.appendingPathComponent("bounded")
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = ThumbnailDiskCacheTestClock(start)
    let removals = ThumbnailDiskCacheRemovalController()
    let cache = ThumbnailDiskCache(directory: cacheDirectory, exactByteLimit: cost,
      now: { clock.current() }, removeFile: { try removals.remove($0) })
    await cache.store(bitmap, for: key(1))
    removals.denyRemovals(true)
    await cache.store(bitmap, for: key(2))
    #expect(await cache.contains(for: key(1)))
    #expect(!(await cache.contains(for: key(2))))
    #expect(await cache.snapshot().byteCount == cost)
    #expect(await cache.snapshot().isComplete, "Denied deletion is still measurable when file metadata is readable")
    #expect(try actualCacheFileBytes(in: cacheDirectory) == cost)
    #expect(pngFiles(in: cacheDirectory).count == 1)
    let failedAttempts = removals.attemptCount
    for index in 3..<20 { await cache.store(bitmap, for: key(index)) }
    #expect(removals.attemptCount == failedAttempts, "Hot scrolling must not retry denied IO for every file")
    #expect(try actualCacheFileBytes(in: cacheDirectory) == cost)

    removals.denyRemovals(false)
    clock.set(start.addingTimeInterval(5))
    await cache.store(bitmap, for: key(2))
    #expect(!(await cache.contains(for: key(1))))
    #expect(await cache.image(for: key(2)) != nil)
    #expect(await cache.snapshot().byteCount == cost)
    #expect(try actualCacheFileBytes(in: cacheDirectory) == cost)
  }

  @Test("손상 PNG 삭제 실패는 바뀐 실제 크기를 세고 재사용을 막은 뒤 안전하게 복구한다")
  func corruptDeniedEntryKeepsActualBytesWithoutRepeatedDecode() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = ThumbnailDiskCacheTestClock(start)
    let removals = ThumbnailDiskCacheRemovalController()
    let cache = ThumbnailDiskCache(directory: directory, now: { clock.current() },
      removeFile: { try removals.remove($0) })
    let bitmap = try image()
    await cache.store(bitmap, for: key(8))
    let file = try #require(pngFiles(in: directory).first)
    let broken = Data("broken PNG".utf8)
    try broken.write(to: file, options: .atomic)
    removals.denyRemovals(true)
    #expect(await cache.image(for: key(8)) == nil)
    #expect(!(await cache.contains(for: key(8))))
    #expect(await cache.snapshot().byteCount == broken.count)
    #expect(await cache.snapshot().isComplete)
    #expect(try actualCacheFileBytes(in: directory) == broken.count)
    let attempts = removals.attemptCount
    for _ in 0..<5 { #expect(await cache.image(for: key(8)) == nil) }
    await cache.store(bitmap, for: key(9))
    #expect(removals.attemptCount == attempts)
    #expect(pngFiles(in: directory).count == 1)

    removals.denyRemovals(false)
    clock.set(start.addingTimeInterval(5))
    await cache.store(bitmap, for: key(8))
    #expect(await cache.image(for: key(8)) != nil)
    #expect(await cache.snapshot().byteCount == (try actualCacheFileBytes(in: directory)))
  }

  @Test("재시작 시 한도를 넘는 잠긴 PNG를 버린 것으로 세지 않고 추가 쓰기를 막는다")
  func restartScanRetainsOverBudgetDeniedFiles() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bitmap = try image()
    let writer = ThumbnailDiskCache(directory: directory)
    for index in 0..<3 { await writer.store(bitmap, for: key(index)) }
    let actual = try actualCacheFileBytes(in: directory)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = ThumbnailDiskCacheTestClock(start)
    let removals = ThumbnailDiskCacheRemovalController()
    removals.denyRemovals(true)
    let restarted = ThumbnailDiskCache(directory: directory, previewByteLimit: 0,
      exactByteLimit: actual / 3, now: { clock.current() },
      removeFile: { try removals.remove($0) })
    let overBudget = await restarted.snapshot()
    #expect(overBudget.isComplete)
    #expect(overBudget.byteCount == actual)
    #expect(overBudget.byteCount > overBudget.byteLimit)
    #expect(overBudget.entryCount == 3)
    await restarted.store(bitmap, for: key(4))
    #expect(try actualCacheFileBytes(in: directory) == actual)
    #expect(pngFiles(in: directory).count == 3)
    removals.denyRemovals(false)
    clock.set(start.addingTimeInterval(5))
    #expect(await restarted.snapshot().byteCount == 0)
    await restarted.store(bitmap, for: key(4))
    #expect(await restarted.image(for: key(4)) != nil)
    #expect(await restarted.snapshot().byteCount == (try actualCacheFileBytes(in: directory)))
  }

  @Test("인덱스를 넘는 삭제 불가 파일은 경로 메타데이터를 늘리지 않고 잔여 바이트를 보존한다")
  func deniedMetadataOverflowRemainsByteAccountedAndRecoverable() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bitmap = try image()
    let writer = ThumbnailDiskCache(directory: directory)
    for index in 0..<7 { await writer.store(bitmap, for: key(index)) }
    let actual = try actualCacheFileBytes(in: directory)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = ThumbnailDiskCacheTestClock(start)
    let removals = ThumbnailDiskCacheRemovalController()
    removals.denyRemovals(true)
    let restarted = ThumbnailDiskCache(directory: directory, now: { clock.current() },
      removeFile: { try removals.remove($0) }, maximumEntriesPerTier: 2)
    let overflow = await restarted.snapshot()
    #expect(overflow.isComplete, "Bounded path metadata must not turn a known byte aggregate into an unknown size")
    #expect(overflow.entryCount == 2)
    #expect(overflow.byteCount == actual)
    #expect(overflow.exactBytes == actual)
    for index in 7..<15 { await restarted.store(bitmap, for: key(index)) }
    #expect(pngFiles(in: directory).count == 7)
    #expect(await restarted.snapshot().entryCount == 2)
    removals.denyRemovals(false)
    clock.set(start.addingTimeInterval(5))
    let recovered = await restarted.snapshot()
    #expect(recovered.entryCount == 2)
    #expect(pngFiles(in: directory).count == 2)
    #expect(recovered.byteCount == (try actualCacheFileBytes(in: directory)))
    await restarted.store(bitmap, for: key(20))
    #expect(await restarted.image(for: key(20)) != nil)
    #expect(await restarted.snapshot().entryCount == 2)
    #expect(pngFiles(in: directory).count == 2)
  }

  @Test("삭제할 수 없는 임시·잘못된 파일도 용량에 포함하고 재시도 후 정상 캐시를 보존한다")
  func abandonedAndInvalidFilesStayAccountedUntilRemovalSucceeds() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bitmap = try image()
    let writer = ThumbnailDiskCache(directory: directory)
    await writer.store(bitmap, for: key(1))
    let sourceDirectory = try #require(pngFiles(in: directory).first).deletingLastPathComponent()
    try Data("partial".utf8).write(to: sourceDirectory.appendingPathComponent("pending-aborted.tmp"))
    try Data("bad size".utf8).write(to: sourceDirectory.appendingPathComponent("exact-8192.png"))
    try Data("unknown".utf8).write(to: sourceDirectory.appendingPathComponent("unknown.png"))
    try Data(repeating: 3, count: 32).write(to: sourceDirectory.appendingPathComponent("preview-128.png"))
    let actual = try actualCacheFileBytes(in: directory)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = ThumbnailDiskCacheTestClock(start)
    let removals = ThumbnailDiskCacheRemovalController()
    removals.denyRemovals(true)
    let restarted = ThumbnailDiskCache(directory: directory, previewByteLimit: 16,
      now: { clock.current() },
      removeFile: { try removals.remove($0) })
    #expect(await restarted.snapshot().byteCount == actual)
    #expect(await restarted.image(for: key(1)) != nil)
    await restarted.store(bitmap, for: key(2))
    #expect(try actualCacheFileBytes(in: directory) == actual)
    removals.denyRemovals(false)
    clock.set(start.addingTimeInterval(5))
    let recovered = await restarted.snapshot()
    #expect(recovered.entryCount == 1)
    #expect(recovered.byteCount == (try actualCacheFileBytes(in: directory)))
    #expect(await restarted.image(for: key(1)) != nil)
    await restarted.store(bitmap, for: key(2))
    #expect(await restarted.image(for: key(2)) != nil)
  }

  @Test("전체 비우기가 일부 파일만 지운 뒤 실패해도 잔여량과 세대 무효화·재시도가 유지된다")
  func partialClearPreservesRemainingAccountingAndRetries() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = ThumbnailDiskCacheTestClock(start)
    let removals = ThumbnailDiskCacheRemovalController()
    let cache = ThumbnailDiskCache(directory: directory, now: { clock.current() },
      removeDirectory: { root in
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let first = (files?.allObjects as? [URL] ?? []).first { $0.pathExtension == "png" }
        if let first { try FileManager.default.removeItem(at: first) }
        throw CocoaError(.fileWriteNoPermission)
      }, removeFile: { try removals.remove($0) })
    let bitmap = try image()
    for index in 0..<3 { await cache.store(bitmap, for: key(index)) }
    let oldGeneration = await cache.generationToken()
    removals.denyRemovals(true)
    #expect(!(await cache.removeAll()))
    let remaining = try actualCacheFileBytes(in: directory)
    #expect(remaining > 0)
    #expect(pngFiles(in: directory).count == 2)
    #expect(await cache.snapshot().byteCount == remaining)
    #expect(await cache.snapshot().entryCount == 2)
    await cache.store(bitmap, for: key(3), generation: oldGeneration)
    #expect(try actualCacheFileBytes(in: directory) == remaining)
    removals.denyRemovals(false)
    clock.set(start.addingTimeInterval(5))
    #expect(await cache.snapshot().byteCount == 0)
    let newGeneration = await cache.generationToken()
    #expect(newGeneration != oldGeneration)
    await cache.store(bitmap, for: key(4), generation: newGeneration)
    #expect(await cache.image(for: key(4)) != nil)
    #expect(await cache.snapshot().byteCount == (try actualCacheFileBytes(in: directory)))
  }

  @Test("커밋 실패 뒤 지워지지 않은 임시 PNG도 용량을 세고 반복 쓰기를 막는다")
  func failedCommitAndDeniedTemporaryCleanupStaysAccounted() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bitmap = try image()
    let seed = ThumbnailDiskCache(directory: directory)
    await seed.store(bitmap, for: key(1))
    let destination = try #require(pngFiles(in: directory).first)
    try FileManager.default.removeItem(at: destination)
    // rename cannot replace a directory with a regular PNG. This forces an
    // actual failed commit, rather than just mocking a return value.
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = ThumbnailDiskCacheTestClock(start)
    let removals = ThumbnailDiskCacheRemovalController()
    removals.denyRemovals(true)
    let cache = ThumbnailDiskCache(directory: directory, now: { clock.current() },
      removeFile: { try removals.remove($0) })
    await cache.store(bitmap, for: key(1))
    let residual = try actualCacheFileBytes(in: directory)
    #expect(residual > 0)
    #expect(await cache.snapshot().byteCount == residual)
    #expect(!(await cache.contains(for: key(1))))
    for index in 2..<10 { await cache.store(bitmap, for: key(index)) }
    #expect(try actualCacheFileBytes(in: directory) == residual)
    removals.denyRemovals(false)
    clock.set(start.addingTimeInterval(5))
    #expect(await cache.snapshot().byteCount == 0)
    try FileManager.default.removeItem(at: destination)
    await cache.store(bitmap, for: key(1))
    #expect(await cache.image(for: key(1)) != nil)
    #expect(await cache.snapshot().byteCount == (try actualCacheFileBytes(in: directory)))
  }

  @Test("이미 사라진 항목은 Cocoa·POSIX ENOENT·중첩 오류 모두 비용을 회수하고 원본을 보존한다",
    arguments: [0, 1, 2, 3])
  func staleIndexAcceptsMissingFileErrorsAndPreservesSource(kind: Int) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("original.dng")
    let original = Data("synthetic-original-content-must-be-preserved".utf8)
    try original.write(to: source)
    let directory = root.appendingPathComponent("cache")
    let cache = ThumbnailDiskCache(directory: directory, removeDirectory: { url in
      try FileManager.default.removeItem(at: url)
      throw Self.missingFileError(kind)
    }, removeFile: { _ in throw Self.missingFileError(kind) })
    let bitmap = try image()
    let sourceKey = ThumbnailCacheKey(asset: ImageAsset(url: source,
      byteCount: Int64(original.count), modificationDate: nil), pixelSize: 128)
    await cache.store(bitmap, for: sourceKey)
    let file = try #require(pngFiles(in: directory).first)
    // A different process has already removed the actual file. The decoder's
    // stale index must handle either family of native missing-file errors.
    try FileManager.default.removeItem(at: file)
    #expect(await cache.image(for: sourceKey) == nil)
    #expect(await cache.snapshot().entryCount == 0)
    #expect(await cache.snapshot().byteCount == 0)
    await cache.store(bitmap, for: sourceKey)
    #expect(await cache.image(for: sourceKey) != nil)
    let generation = await cache.generationToken()
    #expect(await cache.removeAll())
    #expect(await cache.snapshot().byteCount == 0)
    await cache.store(bitmap, for: sourceKey, generation: generation)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    #expect(try Data(contentsOf: source) == original)
  }

  @Test("실제 읽기 전용 하위 폴더에서 부분 비우기는 잔여 파일을 세고 권한 복구 후 지운다",
    .enabled(if: geteuid() != 0))
  func partialClearThroughReadOnlyDirectoryPreservesSourceAndRetries() async throws {
    let root = try temporaryDirectory()
    let directory = root.appendingPathComponent("cache")
    var lockedDirectory: URL?
    defer {
      if let lockedDirectory {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDirectory.path)
      }
      try? FileManager.default.removeItem(at: root)
    }
    let source = root.appendingPathComponent("original.dng")
    let original = Data("synthetic-original-outside-cache".utf8)
    try original.write(to: source)
    let writer = ThumbnailDiskCache(directory: directory)
    let bitmap = try image()
    await writer.store(bitmap, for: key(1))
    let locked = try #require(pngFiles(in: directory).first)
    await writer.store(bitmap, for: key(2))
    let removable = try #require(pngFiles(in: directory).first { $0 != locked })
    lockedDirectory = locked.deletingLastPathComponent()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = ThumbnailDiskCacheTestClock(start)
    let cache = ThumbnailDiskCache(directory: directory, now: { clock.current() },
      removeDirectory: { _ in
        guard Darwin.unlink(removable.path) == 0 else {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard Darwin.unlink(locked.path) == 0 else {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
      }, removeFile: { url in
        guard Darwin.unlink(url.path) == 0 else {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
      })
    #expect(await cache.snapshot().entryCount == 2)
    try FileManager.default.setAttributes([.posixPermissions: 0o555],
      ofItemAtPath: locked.deletingLastPathComponent().path)
    #expect(!(await cache.removeAll()))
    #expect(!FileManager.default.fileExists(atPath: removable.path))
    #expect(FileManager.default.fileExists(atPath: locked.path))
    #expect(await cache.snapshot().byteCount == (try actualCacheFileBytes(in: directory)))
    #expect(await cache.snapshot().byteCount > 0)
    await cache.store(bitmap, for: key(3))
    #expect(pngFiles(in: directory).count == 1)
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
      ofItemAtPath: locked.deletingLastPathComponent().path)
    clock.set(start.addingTimeInterval(5))
    #expect(await cache.snapshot().byteCount == 0)
    #expect(pngFiles(in: directory).isEmpty)
    await cache.store(bitmap, for: key(3))
    #expect(await cache.image(for: key(3)) != nil)
    #expect(try Data(contentsOf: source) == original)
  }

  @Test("부분 비우기 후 읽기 권한까지 사라진 하위 폴더는 마지막 잔여량을 숨기지 않는다",
    .enabled(if: geteuid() != 0))
  func unreadableSubdirectoryKeepsConservativeKnownAccounting() async throws {
    let root = try temporaryDirectory()
    let directory = root.appendingPathComponent("cache")
    var inaccessible: URL?
    defer {
      if let inaccessible {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inaccessible.path)
      }
      try? FileManager.default.removeItem(at: root)
    }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = ThumbnailDiskCacheTestClock(start)
    let cache = ThumbnailDiskCache(directory: directory, now: { clock.current() },
      removeDirectory: { _ in throw CocoaError(.fileWriteNoPermission) })
    let bitmap = try image()
    await cache.store(bitmap, for: key(1))
    inaccessible = try #require(pngFiles(in: directory).first).deletingLastPathComponent()
    await cache.store(bitmap, for: key(2))
    let before = await cache.snapshot().byteCount
    let hiddenDirectory = try #require(inaccessible)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: hiddenDirectory.path)
    #expect(!(await cache.removeAll()))
    #expect(await cache.snapshot().byteCount >= before)
    #expect(!(await cache.snapshot().isComplete))
    await cache.store(bitmap, for: key(3))
    #expect(!(await cache.contains(for: key(3))))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hiddenDirectory.path)
    clock.set(start.addingTimeInterval(5))
    #expect(await cache.snapshot().byteCount == 0)
    #expect(await cache.snapshot().isComplete)
    #expect(pngFiles(in: directory).isEmpty)
    await cache.store(bitmap, for: key(3))
    #expect(await cache.image(for: key(3)) != nil)
  }

  @Test("부분 삭제의 ENOENT가 아직 남은 PNG나 캐시 폴더 전체를 지운 것으로 오인되지 않는다")
  func missingErrorDoesNotHideFilesThatStillExist() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ThumbnailDiskCache(directory: directory,
      removeDirectory: { _ in throw Self.missingFileError(3) },
      removeFile: { _ in throw Self.missingFileError(2) })
    await cache.store(try image(), for: key(1))
    let file = try #require(pngFiles(in: directory).first)
    let broken = Data("invalid PNG".utf8)
    try broken.write(to: file)
    #expect(await cache.image(for: key(1)) == nil)
    #expect(await cache.snapshot().byteCount == broken.count)
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(!(await cache.removeAll()))
    #expect(await cache.snapshot().byteCount == broken.count)
    #expect(FileManager.default.fileExists(atPath: file.path))
  }

  @Test("캐시 루트나 상위 폴더가 아직 없으면 재시도 대기 없이 첫 PNG를 즉시 저장한다",
    arguments: [false, true])
  func firstStoreIntoMissingRootSucceedsImmediately(missingParent: Bool) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent(missingParent ? "new-parent/cache" : "cache")
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let cache = ThumbnailDiskCache(directory: directory, now: { start })
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    let bitmap = try image()
    await cache.store(bitmap, for: key(1))
    #expect(await cache.snapshot().entryCount == 1)
    #expect(await cache.snapshot().isComplete)
    #expect(await cache.image(for: key(1)) != nil)
    #expect(await cache.snapshot().byteCount == (try actualCacheFileBytes(in: directory)))
    #expect(await cache.snapshot().byteCount > 0)
    await cache.store(bitmap, for: key(2))
    #expect(await cache.image(for: key(2)) != nil)
    #expect(await cache.snapshot().entryCount == 2)
  }

  @Test("처음부터 읽을 수 없는 캐시 루트는 없는 폴더로 오인하지 않고 신규 저장을 막는다",
    .enabled(if: geteuid() != 0))
  func initiallyUnreadableRootRemainsBlockedUntilPermissionsRecover() async throws {
    let root = try temporaryDirectory()
    let directory = root.appendingPathComponent("cache")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
      try? FileManager.default.removeItem(at: root)
    }
    let seed = ThumbnailDiskCache(directory: directory)
    await seed.store(try image(), for: key(1))
    let before = try actualCacheFileBytes(in: directory)
    #expect(before > 0)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = ThumbnailDiskCacheTestClock(start)
    let cache = ThumbnailDiskCache(directory: directory, now: { clock.current() })
    let bitmap = try image()
    await cache.store(bitmap, for: key(2))
    #expect(!(await cache.snapshot().isComplete), "An inaccessible existing root has unknown size, not a measured zero")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    #expect(try actualCacheFileBytes(in: directory) == before)
    #expect(!(await cache.contains(for: key(2))))
    clock.set(start.addingTimeInterval(5))
    await cache.store(bitmap, for: key(2))
    #expect(await cache.image(for: key(1)) != nil)
    #expect(await cache.image(for: key(2)) != nil)
    #expect(await cache.snapshot().isComplete)
    #expect(await cache.snapshot().byteCount == (try actualCacheFileBytes(in: directory)))
  }

  @Test("실제 존재하는 PNG의 메타데이터 접근 실패·필드 누락은 미확인 용량이며 복구 후 정확해진다",
    arguments: [1, 2])
  func unknownExistingFileMetadataReportsIncompleteUntilReadable(mode: Int) async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bitmap = try image()
    let writer = ThumbnailDiskCache(directory: directory)
    await writer.store(bitmap, for: key(1))
    let actual = try actualCacheFileBytes(in: directory)
    #expect(actual > 0)
    let metadata = ThumbnailDiskCacheMetadataController()
    metadata.setMode(mode)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = ThumbnailDiskCacheTestClock(start)
    let cache = ThumbnailDiskCache(directory: directory, now: { clock.current() },
      readResourceValues: { try metadata.values($0, keys: $1) })
    let unknown = await cache.snapshot()
    #expect(!unknown.isComplete)
    #expect(unknown.byteCount == 0, "Unknown counters may be zero internally but must never be labeled as a measured size")
    await cache.store(bitmap, for: key(2))
    #expect(try actualCacheFileBytes(in: directory) == actual)
    metadata.setMode(0)
    clock.set(start.addingTimeInterval(5))
    let measured = await cache.snapshot()
    #expect(measured.isComplete)
    #expect(measured.byteCount == actual)
    #expect(await cache.image(for: key(1)) != nil)
    await cache.store(bitmap, for: key(2))
    #expect(await cache.image(for: key(2)) != nil)
    #expect(await cache.snapshot().isComplete)
    #expect(await cache.snapshot().byteCount == (try actualCacheFileBytes(in: directory)))
  }

  @Test("손상 파일 삭제 실패 후 크기도 읽을 수 없으면 이전 수치를 확정 용량으로 표시하지 않는다",
    arguments: [1, 2])
  func unreadableChangedFileSizeMarksConservativeAccountingIncomplete(mode: Int) async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = ThumbnailDiskCacheTestClock(start)
    let metadata = ThumbnailDiskCacheMetadataController()
    let removals = ThumbnailDiskCacheRemovalController()
    let cache = ThumbnailDiskCache(directory: directory, now: { clock.current() },
      removeFile: { try removals.remove($0) },
      readResourceValues: { try metadata.values($0, keys: $1) })
    let bitmap = try image()
    await cache.store(bitmap, for: key(1))
    let before = await cache.snapshot()
    #expect(before.isComplete)
    let file = try #require(pngFiles(in: directory).first)
    let broken = Data("bad PNG".utf8)
    try broken.write(to: file)
    metadata.setMode(mode)
    removals.denyRemovals(true)
    #expect(await cache.image(for: key(1)) == nil)
    let unknown = await cache.snapshot()
    #expect(!unknown.isComplete)
    #expect(unknown.byteCount == before.byteCount)
    #expect(unknown.byteCount > broken.count, "The conservative retained number is not a lower bound on actual bytes")
    await cache.store(bitmap, for: key(2))
    #expect(try actualCacheFileBytes(in: directory) == broken.count)
    metadata.setMode(0)
    removals.denyRemovals(false)
    clock.set(start.addingTimeInterval(5))
    let recovered = await cache.snapshot()
    #expect(recovered.isComplete && recovered.byteCount == 0)
    await cache.store(bitmap, for: key(1))
    #expect(await cache.image(for: key(1)) != nil)
    #expect(await cache.snapshot().isComplete)
  }
}
