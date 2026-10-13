import CoreGraphics
import Foundation
import Testing

@testable import ImageViewer

@Suite("지도 사진 썸네일")
struct PhotoMapThumbnailTests {
  private func asset(_ path: String, version: Int64 = 1) -> ImageAsset {
    ImageAsset(url: URL(fileURLWithPath: path), byteCount: version, modificationDate: nil)
  }

  private func image() throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: 2, height: 2,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return try #require(context.makeImage())
  }

  @Test("클러스터 재정렬과 같은 이름의 다른 파일에도 대표 사진이 안정적이다")
  func stableClusterRepresentatives() {
    let photos = [asset("/b/IMG_2.jpg"), asset("/a/IMG_10.jpg"),
      asset("/a/IMG_2.jpg"), asset("/a/IMG_1.jpg")]
    let expected = [photos[3], photos[2], photos[0]]
    #expect(PhotoMapThumbnailRepresentatives.assets(from: photos) == expected)
    #expect(PhotoMapThumbnailRepresentatives.assets(from: Array(photos.reversed())) == expected)
    #expect(PhotoMapThumbnailRepresentatives.assets(from: []) == [])
  }

  @MainActor @Test("보이는 카드만 요청하며 화면 밖으로 나가면 취소하고 픽셀을 해제한다")
  func requestsFollowVisibility() async throws {
    let requests = ControlledRequests()
    let loader = PhotoMapThumbnailLoader { try await requests.load($0) }
    defer { loader.invalidate() }
    loader.configure(assets: [asset("/photos/one.jpg")])
    #expect(requests.assets.isEmpty)
    loader.setVisible(true)
    try await waitUntil { requests.assets.count == 1 }
    loader.setVisible(false)
    requests.complete(0, with: try image())
    try await waitUntil { requests.cancelled[0] != nil }
    #expect(requests.cancelled[0] == true)
    #expect(loader.images.count == 1)
    #expect(loader.images[0] == nil)

    loader.setVisible(true)
    try await waitUntil { requests.assets.count == 2 }
    let pixels = try image()
    requests.complete(1, with: pixels)
    try await waitUntil { loader.images.first.flatMap { $0 } === pixels }
    loader.setVisible(false)
    #expect(loader.images[0] == nil)
  }

  @MainActor @Test("재사용과 같은 경로의 파일 교체 후 늦은 결과가 새 사진을 덮지 않는다")
  func reusedCardRejectsOldFileVersion() async throws {
    let requests = ControlledRequests()
    let loader = PhotoMapThumbnailLoader { try await requests.load($0) }
    defer { loader.invalidate() }
    loader.configure(assets: [asset("/photos/replaced.jpg", version: 1)])
    loader.setVisible(true)
    try await waitUntil { requests.assets.count == 1 }
    loader.configure(assets: [asset("/photos/replaced.jpg", version: 2)])
    try await waitUntil { requests.assets.count == 2 }
    let current = try image()
    requests.complete(1, with: current)
    try await waitUntil { loader.images.first.flatMap { $0 } === current }
    // Simulate a native thumbnail callback arriving after its request was cancelled.
    requests.complete(0, with: try image())
    try await waitUntil { requests.cancelled[0] != nil }
    await Task.yield()
    #expect(requests.cancelled[0] == true)
    #expect(loader.images[0] === current)
    loader.invalidate()
    #expect(loader.images.isEmpty)
  }

  @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition())
  }

  /// Deliberately ignores cancellation until completed, like a late native callback.
  @MainActor private final class ControlledRequests {
    var assets: [ImageAsset] = []
    var cancelled: [Int: Bool] = [:]
    private var pending: [Int: CheckedContinuation<CGImage, any Error>] = [:]

    func load(_ asset: ImageAsset) async throws -> CGImage {
      let id = assets.count
      assets.append(asset)
      let image = try await withCheckedThrowingContinuation { pending[id] = $0 }
      cancelled[id] = Task.isCancelled
      return image
    }

    func complete(_ id: Int, with image: CGImage) {
      pending.removeValue(forKey: id)?.resume(returning: image)
    }
  }
}
