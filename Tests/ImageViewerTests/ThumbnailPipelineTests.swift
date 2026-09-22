import CoreGraphics
import Foundation
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
