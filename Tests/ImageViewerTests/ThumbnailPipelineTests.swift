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
  private func bitmap(width: Int = 40, height: Int = 20, opaque: Bool) throws -> CGImage {
    let context = try #require(CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    if opaque {
      context.setFillColor(CGColor(gray: 0, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    return try #require(context.makeImage())
  }

  private func writeSource(_ image: CGImage, type: String = "public.png", orientation: Int = 1)
    throws -> URL
  {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("thumbnail-source-\(UUID().uuidString)")
      .appendingPathExtension(type == "public.jpeg" ? "jpeg" : "png")
    let destination = try #require(CGImageDestinationCreateWithURL(
      url as CFURL, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [
      kCGImagePropertyOrientation: orientation,
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
