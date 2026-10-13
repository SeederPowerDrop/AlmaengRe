import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

@Suite("썸네일 메모리 예산과 취소")
struct ThumbnailPipelineTests {
  private func image(side: Int) throws -> CGImage {
    let context = try #require(CGContext(
      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return try #require(context.makeImage())
  }

  private func key(_ index: Int) -> ThumbnailCacheKey {
    ThumbnailCacheKey(
      asset: ImageAsset(
        url: URL(fileURLWithPath: "/test/\(index).jpg"), byteCount: 10,
        modificationDate: Date(timeIntervalSinceReferenceDate: 0)),
      pixelSize: 128)
  }

  @Test("메모리 한도를 지키고 최근에 본 썸네일을 보존한다")
  func exactBudgetAndLeastRecentlyUsedEviction() throws {
    let image = try image(side: 16)
    let cost = image.bytesPerRow * image.height
    var cache = ThumbnailMemoryCache(byteLimit: cost * 2)
    cache.insert(image, for: key(0))
    cache.insert(image, for: key(1))
    #expect(cache.image(for: key(0)) != nil)
    cache.insert(image, for: key(2))

    #expect(cache.totalBytes == cost * 2)
    #expect(cache.image(for: key(1)) == nil)
    #expect(cache.image(for: key(0)) != nil)
    #expect(cache.image(for: key(2)) != nil)
  }

  @Test("예산보다 큰 이미지는 캐시에 넣지 않으며 교체와 비우기의 비용이 정확하다")
  func oversizedInsertionAndReplacement() throws {
    let small = try image(side: 16)
    let large = try image(side: 64)
    let cost = small.bytesPerRow * small.height
    var cache = ThumbnailMemoryCache(byteLimit: cost * 2)
    cache.insert(small, for: key(0))
    cache.insert(small, for: key(0))
    #expect(cache.totalBytes == cost)
    cache.insert(large, for: key(1))
    #expect(cache.totalBytes == cost)
    #expect(cache.image(for: key(0)) != nil)
    #expect(cache.image(for: key(1)) == nil)
    cache.removeAll()
    #expect(cache.totalBytes == 0)
    #expect(cache.image(for: key(0)) == nil)
  }

  @Test("continuation 등록 전 취소도 네이티브 콜백 없이 즉시 완료된다")
  func cancellationBeforeRegistration() async {
    let completion = ThumbnailRequestCompletion<Int>()
    #expect(completion.finish(.failure(CancellationError())))
    await #expect(throws: CancellationError.self) {
      try await withCheckedThrowingContinuation { continuation in
        #expect(!completion.install(continuation))
      }
    }
    #expect(!completion.isPending)
    #expect(!completion.finish(.success(10)))
  }

  @Test("빠른 탐색은 다른 크기의 캐시를 재사용하고 파일 버전은 구별한다")
  func browsingCacheReusesNearestSizeWithoutDuplicatingBytes() throws {
    let asset = ImageAsset(url: URL(fileURLWithPath: "/test/browsing.jpg"), byteCount: 10,
      modificationDate: Date(timeIntervalSinceReferenceDate: 0))
    let small = try image(side: 16)
    let large = try image(side: 32)
    let cost = small.bytesPerRow * small.height + large.bytesPerRow * large.height
    var cache = ThumbnailMemoryCache(byteLimit: cost)
    cache.insert(small, for: ThumbnailCacheKey(asset: asset, pixelSize: 128))
    cache.insert(large, for: ThumbnailCacheKey(asset: asset, pixelSize: 1024))
    #expect(cache.browsingImage(for: ThumbnailCacheKey(asset: asset, pixelSize: 512)) === large)
    #expect(cache.browsingImage(for: ThumbnailCacheKey(asset: asset, pixelSize: 2048)) === large)
    #expect(cache.browsingImage(for: ThumbnailCacheKey(asset: asset, pixelSize: 128)) === small)
    #expect(cache.totalBytes == cost)
    let replacement = ImageAsset(url: asset.url, byteCount: 11,
      modificationDate: Date(timeIntervalSinceReferenceDate: 1))
    #expect(cache.browsingImage(for: ThumbnailCacheKey(asset: replacement, pixelSize: 512)) == nil)
  }

  @Test("작은 탐색용 내장 미리보기가 정밀 썸네일의 크기 캐시를 채우지 않는다")
  func browsingPreviewDoesNotImpersonateFullQualityThumbnail() throws {
    let asset = ImageAsset(url: URL(fileURLWithPath: "/test/embedded-preview.jpg"),
      byteCount: 10, modificationDate: nil)
    let small = try image(side: 16)
    let cost = small.bytesPerRow * small.height
    var cache = ThumbnailMemoryCache(byteLimit: cost)
    let browsing = ThumbnailCacheKey(asset: asset, pixelSize: 512, isBrowsingPreview: true)
    let regular = ThumbnailCacheKey(asset: asset, pixelSize: 512)
    cache.insert(small, for: browsing)
    #expect(cache.image(for: regular) == nil)
    #expect(cache.browsingImage(for: browsing) === small)
    #expect(cache.totalBytes == cost)

    cache.removeAll()
    cache.insert(small, for: regular)
    #expect(cache.browsingImage(for: browsing) === small)
    #expect(cache.totalBytes == cost)
  }

  @Test("지도·몽땅보기 사이 크기가 줄면 충분한 썸네일을 중복 디코딩 없이 재사용한다")
  func exactThumbnailReusesLargerCacheWithoutAcceptingBrowsingPreview() throws {
    let asset = ImageAsset(url: URL(fileURLWithPath: "/test/map-overview.dng"),
      byteCount: 10, modificationDate: Date(timeIntervalSinceReferenceDate: 0))
    let detailed = try image(side: 512)
    let preview = try image(side: 64)
    var cache = ThumbnailMemoryCache(byteLimit: 2_000_000)
    cache.insert(detailed, for: ThumbnailCacheKey(asset: asset, pixelSize: 512))
    cache.insert(preview, for: ThumbnailCacheKey(asset: asset, pixelSize: 1024,
      isBrowsingPreview: true))
    let bytes = cache.totalBytes
    for size in [128, 256, 384, 512] {
      #expect(cache.image(for: ThumbnailCacheKey(asset: asset, pixelSize: size)) === detailed)
    }
    #expect(cache.image(for: ThumbnailCacheKey(asset: asset, pixelSize: 768)) == nil)
    #expect(cache.totalBytes == bytes)
    #expect(cache.count == 2)
    let replaced = ImageAsset(url: asset.url, byteCount: 11,
      modificationDate: Date(timeIntervalSinceReferenceDate: 1))
    #expect(cache.image(for: ThumbnailCacheKey(asset: replaced, pixelSize: 128)) == nil)
  }

  @Test("continuation 등록 뒤 취소도 늦은 성공 콜백과 중복 완료하지 않는다")
  func cancellationAfterRegistration() async {
    let completion = ThumbnailRequestCompletion<Int>()
    await #expect(throws: CancellationError.self) {
      try await withCheckedThrowingContinuation { continuation in
        #expect(completion.install(continuation))
        #expect(completion.finish(.failure(CancellationError())))
        #expect(!completion.finish(.success(10)))
      }
    }
  }

  @Test("성공과 취소가 동시에 도착하면 정확히 하나만 완료한다")
  func cancellationCompletionRace() async throws {
    for _ in 0..<100 {
      let completion = ThumbnailRequestCompletion<Int>()
      let result = Task {
        try await withCheckedThrowingContinuation { continuation in
          completion.install(continuation)
        }
      }
      let accepted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        group.addTask { completion.finish(.success(42)) }
        group.addTask { completion.finish(.failure(CancellationError())) }
        var count = 0
        for await won in group where won { count += 1 }
        return count
      }
      #expect(accepted == 1)
      do {
        let value = try await result.value
        #expect(value == 42)
      } catch is CancellationError {
        #expect(!completion.isPending)
      }
    }
  }
}

@Suite("Quick Look 빈 썸네일 복구")
struct ThumbnailBitmapDecoderTests {
  private struct SharedImage: @unchecked Sendable {
    let image: CGImage
  }

  private actor FirstStorageLookupGate {
    private var count = 0
    private var blocked: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func resolve() async -> ImageStorageKind {
      count += 1
      if count == 1 {
        await withCheckedContinuation { continuation in
          blocked = continuation
          observer?.resume()
          observer = nil
        }
      }
      return .internalSSD
    }

    func waitUntilBlocked() async {
      if blocked != nil { return }
      await withCheckedContinuation { observer = $0 }
    }

    func release() {
      blocked?.resume()
      blocked = nil
    }
  }

  private func bitmap(width: Int = 40, height: Int = 20, opaque: Bool,
    color: CGColor? = nil) throws -> CGImage {
    let context = try #require(CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    if opaque {
      context.setFillColor(color ?? CGColor(gray: 0, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    return try #require(context.makeImage())
  }

  private func writeSource(_ image: CGImage, type: String = "public.png", orientation: Int = 1,
    embedsThumbnail: Bool = false, fileExtension: String? = nil)
    throws -> URL
  {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("thumbnail-source-\(UUID().uuidString)")
      .appendingPathExtension(fileExtension ?? (type == "public.jpeg" ? "jpeg" : "png"))
    let destination = try #require(CGImageDestinationCreateWithURL(
      url as CFURL, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [
      kCGImagePropertyOrientation: orientation,
      kCGImageDestinationEmbedThumbnail: embedsThumbnail,
    ] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return url
  }

  @Test("완전히 검은 불투명 사진은 빈 이미지로 오인하지 않는다")
  func opaqueBlackQuickLookImageIsValid() throws {
    let image = try bitmap(opaque: true)
    let result = try ThumbnailBitmapDecoder.validatedThumbnail(
      image, sourceURL: URL(fileURLWithPath: "/nonexistent/unused-source.jpg"), maxPixelSize: 256)
    #expect(result.width == 40)
    #expect(result.height == 20)
    #expect(ThumbnailBitmapDecoder.rasterized(result, maxPixelSize: 256)?.hasVisiblePixels == true)
  }

  @Test("검은 RAW Quick Look 결과는 원본에서 방향과 색을 복구한다")
  func opaqueBlackRAWQuickLookIsRepairedFromOrientedSource() throws {
    // JPEG content with a DNG suffix isolates camera-RAW fallback routing. It is
    // not a RAW codec fixture and makes no claim about macOS camera support.
    let source = try writeSource(bitmap(opaque: true,
      color: CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1)),
      type: "public.jpeg", orientation: 6, fileExtension: "dng")
    defer { try? FileManager.default.removeItem(at: source) }
    let result = try ThumbnailBitmapDecoder.validatedThumbnail(
      bitmap(opaque: true), sourceURL: source, maxPixelSize: 16)
    #expect(result.width == 8)
    #expect(result.height == 16)
    let decoded = try #require(ThumbnailBitmapDecoder.rasterized(result, maxPixelSize: 16))
    #expect(decoded.hasVisiblePixels)
    #expect(decoded.hasNonBlackPixels)
  }

  @Test("RAW 원본을 다시 읽어도 실제로 검으면 정상 썸네일로 유지한다")
  func genuinelyBlackRAWSourceRemainsValid() throws {
    // As above, this exercises RAW-specific validation, not actual RAW decoding.
    let source = try writeSource(bitmap(opaque: true), type: "public.jpeg",
      orientation: 6, fileExtension: "dng")
    defer { try? FileManager.default.removeItem(at: source) }
    let result = try ThumbnailBitmapDecoder.validatedThumbnail(
      bitmap(opaque: true), sourceURL: source, maxPixelSize: 16)
    // Rotation and bounds prove the source was regenerated before being accepted.
    #expect(result.width == 8)
    #expect(result.height == 16)
    let decoded = try #require(ThumbnailBitmapDecoder.rasterized(result, maxPixelSize: 16))
    #expect(decoded.hasVisiblePixels)
    #expect(!decoded.hasNonBlackPixels)
  }

  @Test("읽을 수 없는 RAW의 검은 Quick Look 결과는 성공으로 반환하지 않는다")
  func unavailableRAWSourceDoesNotAcceptOpaqueBlackQuickLookImage() throws {
    let black = try bitmap(opaque: true)
    #expect(throws: ThumbnailPipelineError.self) {
      try ThumbnailBitmapDecoder.validatedThumbnail(
        black, sourceURL: URL(fileURLWithPath: "/nonexistent/thumbnail-source.dng"),
        maxPixelSize: 256)
    }
  }

  @Test("취소된 검은 RAW 요청은 원본을 읽거나 결과를 반환하지 않는다")
  func cancelledBlackRAWRequestDoesNotRepairOrReturnImage() async throws {
    let task = Task {
      let black = try bitmap(opaque: true)
      withUnsafeCurrentTask { $0?.cancel() }
      return try ThumbnailBitmapDecoder.validatedThumbnail(
        black, sourceURL: URL(fileURLWithPath: "/nonexistent/thumbnail-source.dng"),
        maxPixelSize: 256).width
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test("빠른 JPEG 미리보기는 방향을 적용하고 작은 SDR 픽셀로 만든다")
  func browsingDecodeIsOrientedAndBounded() throws {
    let source = try writeSource(bitmap(width: 800, height: 400, opaque: true),
      type: "public.jpeg", orientation: 6)
    defer { try? FileManager.default.removeItem(at: source) }
    let result = try #require(try ThumbnailBitmapDecoder.browsingThumbnail(
      sourceURL: source, maxPixelSize: 256))
    #expect(result.width == 128)
    #expect(result.height == 256)
    #expect(result.bitsPerComponent == 8)
    #expect(result.bitsPerPixel == 32)
    #expect(ThumbnailBitmapDecoder.rasterized(result, maxPixelSize: 256)?.hasVisiblePixels == true)
  }

  @Test("빠른 PNG 미리보기는 투명 원본도 유지한다")
  func browsingDecodePreservesTransparentPixels() throws {
    let source = try writeSource(bitmap(width: 800, height: 400, opaque: false))
    defer { try? FileManager.default.removeItem(at: source) }
    let result = try #require(try ThumbnailBitmapDecoder.browsingThumbnail(
      sourceURL: source, maxPixelSize: 256))
    #expect(result.width == 256)
    #expect(result.height == 128)
    #expect(ThumbnailBitmapDecoder.rasterized(result, maxPixelSize: 256)?.hasVisiblePixels == false)
  }

  @Test("RAW에 사용하는 내장 전용 읽기는 미리보기가 없으면 원본을 디코딩하지 않는다")
  func embeddedOnlyDoesNotGenerateMissingThumbnail() throws {
    // A real JPEG container is intentional: this verifies Image I/O's embedded-only
    // operation, not macOS camera support or a disguised RAW/performance claim.
    let url = try writeSource(bitmap(width: 800, height: 400, opaque: true), type: "public.jpeg")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL,
      [kCGImageSourceShouldCache: false] as CFDictionary))
    #expect(try ThumbnailBitmapDecoder.embeddedThumbnail(in: source, maxPixelSize: 512) == nil)
    let reduced = try #require(try ThumbnailBitmapDecoder.directThumbnail(sourceURL: url,
      maxPixelSize: 512))
    #expect(reduced.width == 512)
    #expect(reduced.height == 256)
    #expect(try ThumbnailBitmapDecoder.directThumbnail(
      sourceURL: URL(fileURLWithPath: "/nonexistent/missing-camera-preview.dng"),
      maxPixelSize: 256) == nil)
  }

  @Test("작은 내장 미리보기는 즉시 표시하되 정밀 썸네일은 원본 해상도로 보강한다")
  func embeddedPreviewKeepsOrientationAndExactThumbnailQuality() throws {
    let url = try writeSource(bitmap(width: 800, height: 400, opaque: true),
      type: "public.jpeg", orientation: 6, embedsThumbnail: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let embedded = try #require(try ThumbnailBitmapDecoder.embeddedThumbnail(in: source,
      maxPixelSize: 512))
    #expect(embedded.width < embedded.height)
    #expect(embedded.height < 512)
    let browsing = try #require(try ThumbnailBitmapDecoder.browsingThumbnail(sourceURL: url,
      maxPixelSize: 512))
    #expect(browsing.width == embedded.width)
    #expect(browsing.height == embedded.height)
    let detailed = try #require(try ThumbnailBitmapDecoder.directThumbnail(sourceURL: url,
      maxPixelSize: 512))
    #expect(detailed.width == 256)
    #expect(detailed.height == 512)
    #expect(detailed.bitsPerComponent == 8)
  }

  @Test("내장 미리보기가 없는 RAW 썸네일은 원본을 직접 읽고 탐색용은 계속 가볍게 유지한다")
  func regularRAWThumbnailDecodesSourceWithoutChangingBrowsingPolicy() throws {
    // JPEG bytes with a DNG suffix exercise RAW routing and EXIF transforms,
    // independently of installed camera codecs. Real RAW coverage is opt-in.
    let url = try writeSource(bitmap(width: 800, height: 400, opaque: true,
      color: CGColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1)),
      type: "public.jpeg", orientation: 6, fileExtension: "dng")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try ThumbnailBitmapDecoder.browsingThumbnail(sourceURL: url,
      maxPixelSize: 512) == nil)
    let image = try #require(try ThumbnailBitmapDecoder.directThumbnail(sourceURL: url,
      maxPixelSize: 512))
    #expect(image.width == 256)
    #expect(image.height == 512)
    #expect(image.bitsPerComponent == 8)
    #expect(ThumbnailBitmapDecoder.rasterized(image, maxPixelSize: 512)?.hasNonBlackPixels == true)
  }

  @Test("직접 읽은 RAW 원본이 실제 검은 사진이면 정상 썸네일로 반환한다")
  func directRAWSourceKeepsGenuinelyBlackPixels() throws {
    let url = try writeSource(bitmap(width: 800, height: 400, opaque: true),
      type: "public.jpeg", fileExtension: "dng")
    defer { try? FileManager.default.removeItem(at: url) }
    let image = try #require(try ThumbnailBitmapDecoder.directThumbnail(sourceURL: url,
      maxPixelSize: 512))
    let result = try #require(ThumbnailBitmapDecoder.rasterized(image, maxPixelSize: 512))
    #expect(result.hasVisiblePixels)
    #expect(!result.hasNonBlackPixels)
    #expect(image.width == 512)
    #expect(image.height == 256)
  }

  @Test("일반 썸네일은 작은 보기로 돌아올 때 캐시를 공유하고 파일 교체는 구별한다")
  func regularPipelineReusesLargerCachedBitmap() async throws {
    let url = try writeSource(bitmap(width: 1600, height: 800, opaque: true))
    defer { try? FileManager.default.removeItem(at: url) }
    let governor = ImageResourceGovernor(mode: .priority, storageOverride: .internalSSD)
    let pipeline = ThumbnailPipeline(governor: governor)
    let asset = ImageAsset(url: url, byteCount: 1, modificationDate: nil)
    let detailed = try await pipeline.thumbnail(for: asset, maxPixelSize: 768)
    let initial = await pipeline.cacheSnapshot()
    let map = try await pipeline.thumbnail(for: asset, maxPixelSize: 128)
    let overview = try await pipeline.thumbnail(for: asset, maxPixelSize: 256)
    #expect(map === detailed)
    #expect(overview === detailed)
    #expect(await pipeline.cacheSnapshot().byteCount == initial.byteCount)
    #expect(await pipeline.cacheSnapshot().entryCount == 1)
    let replaced = ImageAsset(url: url, byteCount: 2, modificationDate: nil)
    let fresh = try await pipeline.thumbnail(for: replaced, maxPixelSize: 128)
    #expect(fresh !== detailed)
    #expect(fresh.width == 128)
  }

  @Test("빠른 탐색의 중복 요청은 비트맵을 공유하고 다른 크기로 재사용한다")
  func browsingPipelineSharesBitmapAndReusesCache() async throws {
    let source = try writeSource(bitmap(width: 1600, height: 800, opaque: true))
    defer { try? FileManager.default.removeItem(at: source) }
    let governor = ImageResourceGovernor(mode: .priority, storageOverride: .internalSSD)
    let pipeline = ThumbnailPipeline(governor: governor)
    let asset = ImageAsset(url: source, byteCount: nil, modificationDate: nil)
    let images = try await withThrowingTaskGroup(of: SharedImage.self) { group in
      for _ in 0..<8 {
        group.addTask {
          SharedImage(image: try await pipeline.browsingThumbnail(for: asset, maxPixelSize: 512))
        }
      }
      var images: [CGImage] = []
      for try await image in group { images.append(image.image) }
      return images
    }
    let first = try #require(images.first)
    #expect(images.count == 8)
    #expect(images.allSatisfy { $0 === first })
    #expect(first.width == 512)
    #expect(first.height == 256)
    let otherSize = try await pipeline.browsingThumbnail(for: asset, maxPixelSize: 256)
    #expect(otherSize === first)
    await pipeline.purgeCache()
    let fresh = try await pipeline.browsingThumbnail(for: asset, maxPixelSize: 512)
    #expect(fresh !== first)
  }

  @Test("저장장치 판별이 늦은 동일 요청도 먼저 완성된 비트맵을 공유한다", arguments: [false, true])
  func delayedAdmissionRechecksCache(browsing: Bool) async throws {
    let source = try writeSource(bitmap(width: 800, height: 400, opaque: true))
    defer { try? FileManager.default.removeItem(at: source) }
    let gate = FirstStorageLookupGate()
    let governor = ImageResourceGovernor(mode: .priority,
      storageResolver: { _ in await gate.resolve() })
    let pipeline = ThumbnailPipeline(governor: governor)
    let asset = ImageAsset(url: source, byteCount: nil, modificationDate: nil)
    let load: @Sendable () async throws -> SharedImage = {
      let image: CGImage
      if browsing { image = try await pipeline.browsingThumbnail(for: asset, maxPixelSize: 512) }
      else { image = try await pipeline.thumbnail(for: asset, maxPixelSize: 512) }
      return SharedImage(image: image)
    }
    // Both callers miss the cache, but the first remains suspended before the
    // governor can submit its work. The second completely finishes its decode.
    let delayed = Task { try await load() }
    defer { Task { await gate.release() } }
    await gate.waitUntilBlocked()
    let completed = try await load()
    await gate.release()
    let resumed = try await delayed.value
    #expect(resumed.image === completed.image)
    #expect(await pipeline.cacheSnapshot().entryCount == 1)
    let again = try await load()
    #expect(again.image === completed.image)
  }

  @Test("취소한 빠른 탐색과 정밀 전용 포맷은 네이티브 요청을 시작하지 않는다")
  func browsingCancellationAndCustomFormats() async throws {
    let pipeline = ThumbnailPipeline()
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await pipeline.browsingThumbnail(for: ImageAsset(
        url: URL(fileURLWithPath: "/nonexistent/browsing.jpg"),
        byteCount: nil, modificationDate: nil)).width
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    for extensionName in ["qoi", "pcx"] {
      await #expect(throws: ThumbnailPipelineError.self) {
        try await pipeline.browsingThumbnail(for: ImageAsset(
          url: URL(fileURLWithPath: "/nonexistent/browsing.\(extensionName)"),
          byteCount: nil, modificationDate: nil))
      }
    }
  }

  @Test("성공으로 반환된 투명 Quick Look 결과는 원본에서 방향과 크기를 적용해 복구한다")
  func transparentQuickLookIsRepairedFromOrientedSource() throws {
    let source = try writeSource(bitmap(opaque: true), type: "public.jpeg", orientation: 6)
    defer { try? FileManager.default.removeItem(at: source) }
    let result = try ThumbnailBitmapDecoder.validatedThumbnail(
      bitmap(opaque: false), sourceURL: source, maxPixelSize: 16)
    #expect(result.width == 8)
    #expect(result.height == 16)
    #expect(result.bitsPerComponent == 8)
    #expect(ThumbnailBitmapDecoder.rasterized(result, maxPixelSize: 16)?.hasVisiblePixels == true)
  }

  @Test("원본이 실제로 투명한 PNG면 정상 썸네일로 유지한다")
  func genuinelyTransparentSourceRemainsValid() throws {
    let transparent = try bitmap(opaque: false)
    let source = try writeSource(transparent)
    defer { try? FileManager.default.removeItem(at: source) }
    let result = try ThumbnailBitmapDecoder.validatedThumbnail(
      transparent, sourceURL: source, maxPixelSize: 256)
    #expect(result.width == 40)
    #expect(result.height == 20)
    #expect(ThumbnailBitmapDecoder.rasterized(result, maxPixelSize: 256)?.hasVisiblePixels == false)
  }

  @Test("16비트 Quick Look 결과를 별도 8비트 픽셀 메모리로 변환한다")
  func highBitDepthQuickLookIsDetachedAndNormalized() throws {
    let channels: [UInt16] = [0, 0, 0, .max, .max, 0, 0, .max]
    let data = channels.withUnsafeBytes { Data($0) }
    let provider = try #require(CGDataProvider(data: data as CFData))
    let original = try #require(CGImage(
      width: 2, height: 1, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: 16,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        .union(.byteOrder16Little),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let result = try #require(ThumbnailBitmapDecoder.rasterized(original, maxPixelSize: 256))
    #expect(result.hasVisiblePixels)
    #expect(result.image.bitsPerComponent == 8)
    #expect(result.image.bitsPerPixel == 32)
    #expect(result.image.width == 2)
    #expect(result.image.height == 1)
  }

  @Test("빈 Quick Look 결과와 읽을 수 없는 원본은 정밀 디코더로 넘긴다")
  func unavailableSourceDoesNotAcceptEmptyQuickLookImage() throws {
    let transparent = try bitmap(opaque: false)
    #expect(throws: ThumbnailPipelineError.self) {
      try ThumbnailBitmapDecoder.validatedThumbnail(
        transparent, sourceURL: URL(fileURLWithPath: "/nonexistent/thumbnail-source.jpg"),
        maxPixelSize: 256)
    }
  }

  @Test("취소된 요청은 원본 재생성을 시작하지 않는다")
  func cancelledRequestDoesNotRepairOrReturnImage() async throws {
    let task = Task {
      let transparent = try bitmap(opaque: false)
      withUnsafeCurrentTask { $0?.cancel() }
      return try ThumbnailBitmapDecoder.validatedThumbnail(
        transparent, sourceURL: URL(fileURLWithPath: "/nonexistent/thumbnail-source.jpg"),
        maxPixelSize: 256).width
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }
}
