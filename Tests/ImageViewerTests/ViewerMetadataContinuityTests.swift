import AppKit
import Testing
@testable import ImageViewer

@Suite("다중 뷰어 메타데이터와 표시 픽셀 연속성", .serialized)
@MainActor
struct ViewerMetadataContinuityTests {
  @Test("위치·분류·설명 갱신은 같은 픽셀 요청이며 파일 버전·색·화질 변경은 다른 요청이다")
  func identityTracksPixels() {
    let a = ImageAsset(url: URL(fileURLWithPath: "/fixture/photo.dng"), byteCount: 10,
      modificationDate: Date(timeIntervalSince1970: 100))
    var metadata = a
    metadata.location = ImageLocation(latitude: 1, longitude: 2)
    metadata.hasReadLocation = true
    metadata.photoMarkIdentity = "updated-mark"
    metadata.creationDate = Date(timeIntervalSince1970: 50)
    let original = request(a), enriched = request(metadata)
    #expect(a != metadata)
    #expect(original == enriched)
    #expect(Set([original, enriched]).count == 1)
    var version = ImageAsset(url: a.url, byteCount: a.byteCount, modificationDate: Date(timeIntervalSince1970: 101))
    #expect(original != request(version))
    version = ImageAsset(url: a.url, byteCount: 11, modificationDate: a.modificationDate)
    #expect(original != request(version))
    #expect(original != request(metadata, pixels: 128))
    #expect(original != request(metadata, hdr: true))
    #expect(original != request(metadata, policy: .responsive))
    var edited = ImageAdjustments.identity; edited.exposure = 1
    #expect(original != ViewerFrameRequest(asset: metadata, maxPixelSize: 64,
      adjustments: edited, prefersHDR: false))
  }

  @Test("표시 중 메타데이터 반복 갱신은 디코딩을 다시 시작하지 않으며 원본 변경은 다시 읽는다")
  func acceptedFrameSurvivesMetadataOnlyChanges() async throws {
    let context = try #require(CGContext(data: nil, width: 64, height: 64,
      bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let frame = RenderedFrame(image: try #require(context.makeImage()), frameIndex: 0,
      frameCount: 1, duration: nil, sourcePixelSize: CGSize(width: 64, height: 64))
    let counter = MetadataFrameCounter(frame: frame)
    let loader = ViewerFrameLoader(settleDelay: .zero)
    defer { loader.stop() }
    let a = ImageAsset(url: URL(fileURLWithPath: "/fixture/photo.dng"), byteCount: 10,
      modificationDate: Date(timeIntervalSince1970: 100))
    func load(_ asset: ImageAsset) {
      loader.load(request(asset), preview: { _ in await counter.preview() },
        render: { _, _ in await counter.render() })
    }
    load(a)
    for _ in 0..<100 {
      if await counter.renderCount == 1, loader.presentation != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(await counter.renderCount == 1)
    let before = await counter.counts
    let displayed = try #require(loader.presentation?.frame.image)
    for index in 0..<40 {
      var enriched = a
      enriched.hasReadLocation = true
      enriched.location = ImageLocation(latitude: Double(index), longitude: 0)
      enriched.photoMarkIdentity = "mark-\(index)"
      load(enriched)
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await counter.counts == before)
    #expect(loader.presentation?.frame.image === displayed)
    let changed = ImageAsset(url: a.url, byteCount: a.byteCount, modificationDate: Date(timeIntervalSince1970: 101))
    load(changed)
    for _ in 0..<100 {
      if await counter.renderCount == 2 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await counter.renderCount == 2)
  }

  private func request(_ asset: ImageAsset, pixels: Int = 64, hdr: Bool = false,
    policy: ViewerFrameLoadingPolicy = .quality) -> ViewerFrameRequest {
    ViewerFrameRequest(asset: asset, maxPixelSize: pixels, adjustments: .identity,
      prefersHDR: hdr, loadingPolicy: policy)
  }
}
private actor MetadataFrameCounter {
  let frame: RenderedFrame
  private var previews = 0
  private(set) var renderCount = 0
  var counts: [Int] { [previews, renderCount] }
  init(frame: RenderedFrame) { self.frame = frame }
  func preview() -> RenderedFrame { previews += 1; return frame }
  func render() -> RenderedFrame { renderCount += 1; return frame }
}
