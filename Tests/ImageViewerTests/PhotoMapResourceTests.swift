import CoreGraphics
import Foundation
import MapKit
import Testing

@testable import ImageViewer

@Suite("지도 반복 작업과 수명")
struct PhotoMapResourceTests {
  private func asset(_ path: String) -> ImageAsset {
    ImageAsset(url: URL(fileURLWithPath: path), byteCount: 1, modificationDate: nil)
  }

  @Test("대규모 클러스터에서도 기존 정렬과 같은 세 장만 선택한다")
  func boundedCoversPreserveNaturalOrder() {
    let photos = (0..<2_048).map { index in
      let number = (index * 719) % 2_048
      return asset("/photos/\(number % 7)/사진_\(number / 7).jpg")
    }
    let expected = Array(photos.sorted {
      let order = $0.filename.localizedStandardCompare($1.filename)
      if order != .orderedSame { return order == .orderedAscending }
      return $0.url.standardizedFileURL.absoluteString < $1.url.standardizedFileURL.absoluteString
    }.prefix(3))
    #expect(PhotoMapThumbnailRepresentatives.assets(from: photos) == expected)
    #expect(PhotoMapThumbnailRepresentatives.assets(from: Array(photos.reversed())) == expected)
  }

  @MainActor @Test("영역 강조는 클러스터 중 한 장만 포함되어도 유지된다")
  func selectionHighlightMatchesAnyClusterMember() {
    let coordinator = NativePhotoMapView.Coordinator()
    let first = PhotoMapAnnotation(asset: asset("/photos/first.jpg"))
    let second = PhotoMapAnnotation(asset: asset("/photos/second.jpg"))
    let cluster = MKClusterAnnotation(memberAnnotations: [first, second])
    #expect(coordinator.matchesSelection(cluster))
    coordinator.selection = .radius(center: GeoCoordinate(latitude: 0, longitude: 0), meters: 100)
    #expect(!coordinator.matchesSelection(cluster))
    coordinator.matchingAssetURLs = [second.asset.id]
    #expect(!coordinator.matchesSelection(first))
    #expect(coordinator.matchesSelection(second))
    #expect(coordinator.matchesSelection(cluster))
    coordinator.selection = nil
    #expect(coordinator.matchesSelection(first))
  }

  @MainActor @Test("대기 중인 썸네일 요청이 사라진 카드의 로더를 붙잡지 않는다")
  func pendingRequestDoesNotRetainLoader() async throws {
    let request = PendingRequest()
    var loader: PhotoMapThumbnailLoader? = PhotoMapThumbnailLoader { _ in try await request.load() }
    weak var weakLoader = loader
    loader?.configure(assets: [asset("/photos/one.jpg")])
    loader?.setVisible(true)
    try await waitUntil { request.continuation != nil }
    loader = nil
    #expect(weakLoader == nil)
    request.continuation?.resume(throwing: CancellationError())
    request.continuation = nil
    try await waitUntil { request.wasCancelled != nil }
    #expect(request.wasCancelled == true)
  }

  @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition())
  }

  @MainActor private final class PendingRequest {
    var continuation: CheckedContinuation<CGImage, any Error>?
    var wasCancelled: Bool?

    func load() async throws -> CGImage {
      defer { wasCancelled = Task.isCancelled }
      return try await withCheckedThrowingContinuation { continuation = $0 }
    }
  }
}
