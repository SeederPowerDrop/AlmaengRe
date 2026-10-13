import CoreGraphics
import Foundation
import Testing

@testable import ImageViewer

@MainActor
@Suite("이미지 타일을 해제하면 대기 중 작업과 애니메이션도 종료")
struct ViewerFrameLoaderLifetimeTests {
  @Test("느린 미리보기가 사라진 타일을 계속 보유하지 않는다")
  func discardedLoaderReleasesDuringPreview() async throws {
    let preview = LifetimeFrameOperation()
    let bitmap = try frame()
    var loader: ViewerFrameLoader? = ViewerFrameLoader(settleDelay: .seconds(3_600))
    weak var reference = loader
    defer { reference?.stop() }
    loader?.load(request, preview: { _ in await preview.run() }, render: { _, _ in bitmap })
    try await waitUntil { await preview.started }

    loader = nil
    #expect(reference == nil)
    await preview.finish(bitmap)
    try await waitUntil { await preview.finished }
    #expect(await preview.wasCancelled)
  }

  @Test("정밀 프레임을 기다리는 타일이 사라지면 작업을 취소한다")
  func discardedLoaderCancelsPendingRender() async throws {
    let render = LifetimeFrameOperation()
    let bitmap = try frame()
    var loader: ViewerFrameLoader? = ViewerFrameLoader(settleDelay: .zero)
    weak var reference = loader
    defer { reference?.stop() }
    loader?.load(request, preview: { _ in throw LifetimeFrameError.noPreview },
      render: { _, _ in await render.run() })
    try await waitUntil { await render.started }
    for _ in 0..<20 { await Task.yield() }

    loader = nil
    #expect(reference == nil)
    await render.finish(bitmap)
    try await waitUntil { await render.finished }
    #expect(await render.wasCancelled)
  }

  @Test("긴 프레임 지연 시간도 사라진 애니메이션 타일을 보유하지 않는다")
  func discardedLoaderReleasesDuringAnimationDelay() async throws {
    let bitmap = try frame(count: 2, duration: 3_600)
    var loader: ViewerFrameLoader? = ViewerFrameLoader(settleDelay: .zero)
    weak var reference = loader
    defer { reference?.stop() }
    loader?.load(request, preview: { _ in throw LifetimeFrameError.noPreview },
      render: { _, _ in bitmap })
    try await waitUntil { reference?.presentation?.frame.frameCount == 2 }
    for _ in 0..<20 { await Task.yield() }

    loader = nil
    #expect(reference == nil)
  }

  private var request: ViewerFrameRequest {
    ViewerFrameRequest(asset: ImageAsset(
      url: URL(fileURLWithPath: "/frame-lifetime/image.png"), byteCount: nil, modificationDate: nil),
      maxPixelSize: 1_024, adjustments: .identity, prefersHDR: false)
  }

  private func frame(count: Int = 1, duration: TimeInterval? = nil) throws -> RenderedFrame {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: 4, height: 4,
      bitsPerComponent: 8, bytesPerRow: 16, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return RenderedFrame(image: try #require(context.makeImage()), frameIndex: 0,
      frameCount: count, duration: duration)
  }

  private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    throw LifetimeFrameError.timeout
  }
}

private enum LifetimeFrameError: Error { case noPreview, timeout }

/// Mimics a native decode that cannot stop until its current operation returns.
private actor LifetimeFrameOperation {
  private(set) var started = false
  private(set) var finished = false
  private(set) var wasCancelled = false
  private var continuation: CheckedContinuation<RenderedFrame, Never>?

  func run() async -> RenderedFrame {
    started = true
    let frame = await withCheckedContinuation { continuation = $0 }
    wasCancelled = Task.isCancelled
    finished = true
    return frame
  }

  func finish(_ frame: RenderedFrame) {
    continuation?.resume(returning: frame)
    continuation = nil
  }
}
