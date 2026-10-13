import CoreGraphics
import Foundation
import Testing

@testable import ImageViewer

@MainActor
@Suite("이미지 실패 원인 조회와 표시 수명")
struct ViewerFrameFailureTests {
  @Test("빈 원본은 디코더의 일반 오류 대신 0바이트 원인을 표시한다")
  func emptySourceHasSpecificCause() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("empty-viewer-\(UUID().uuidString).dng")
    try Data().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let loader = ViewerFrameLoader(settleDelay: .zero)
    defer { loader.stop() }
    let destination = request(url)

    loader.load(destination, preview: { _ in throw FailureFixtureError.decode },
      render: { _, _ in throw FailureFixtureError.decode })
    try await waitUntil { loader.errorMessage != nil }
    #expect(loader.errorMessage == MediaLoadFailure.text("empty"))
    #expect(loader.presentation == nil)
  }

  @Test("이전 이미지의 늦은 원인 조회 결과가 새 이미지를 덮지 않는다")
  func lateCauseCannotReplaceNewImage() async throws {
    let reason = ControlledFailureReason()
    let loader = ViewerFrameLoader(settleDelay: .zero,
      failureReason: { _, _ in await reason.run() })
    defer { loader.stop() }
    let failed = request(URL(fileURLWithPath: "/failure-fixture/old.png"))
    let latest = request(URL(fileURLWithPath: "/failure-fixture/latest.png"))
    let frame = try frame()

    loader.load(failed, preview: { _ in throw FailureFixtureError.decode },
      render: { _, _ in throw FailureFixtureError.decode })
    try await waitUntil { await reason.started }
    loader.load(latest, preview: { _ in frame }, render: { _, _ in frame })
    try await waitUntil { loader.presentation?.request == latest }
    await reason.finish("Obsolete failure")
    try await waitUntil { await reason.finished }
    await drainTasks()

    #expect(loader.presentation?.request == latest)
    #expect(loader.presentation?.frame.image === frame.image)
    #expect(loader.errorMessage == nil)
  }

  @Test("원인을 조회하는 동안 도착한 미리보기는 오류로 바뀌지 않는다")
  func previewArrivingDuringCauseLookupRemainsVisible() async throws {
    let reason = ControlledFailureReason()
    let preview = ControlledFailurePreview()
    let loader = ViewerFrameLoader(settleDelay: .zero,
      failureReason: { _, _ in await reason.run() })
    defer { loader.stop() }
    let destination = request(URL(fileURLWithPath: "/failure-fixture/image.png"))
    let frame = try frame()

    loader.load(destination, preview: { _ in await preview.run() },
      render: { _, _ in throw FailureFixtureError.decode })
    try await waitUntil {
      let reasonStarted = await reason.started
      let previewStarted = await preview.started
      return reasonStarted && previewStarted
    }
    await preview.finish(frame)
    try await waitUntil { loader.presentation?.request == destination }
    await reason.finish("Precise decoder failed")
    try await waitUntil { await reason.finished }
    await drainTasks()

    #expect(loader.presentation?.frame.image === frame.image)
    #expect(loader.errorMessage == nil)
  }

  @Test("원인 조회 중 타일을 해제해도 조회 작업이 타일을 보유하지 않는다")
  func discardedLoaderReleasesDuringCauseLookup() async throws {
    let reason = ControlledFailureReason()
    var loader: ViewerFrameLoader? = ViewerFrameLoader(settleDelay: .zero,
      failureReason: { _, _ in await reason.run() })
    weak var reference = loader
    loader?.load(request(URL(fileURLWithPath: "/failure-fixture/image.png")),
      preview: { _ in throw FailureFixtureError.decode },
      render: { _, _ in throw FailureFixtureError.decode })
    try await waitUntil { await reason.started }

    loader = nil
    #expect(reference == nil)
    await reason.finish("No longer visible")
    try await waitUntil { await reason.finished }
    #expect(await reason.wasCancelled)
  }

  private func request(_ url: URL) -> ViewerFrameRequest {
    ViewerFrameRequest(asset: ImageAsset(url: url, byteCount: nil, modificationDate: nil),
      maxPixelSize: 1_024, adjustments: .identity, prefersHDR: false)
  }

  private func frame() throws -> RenderedFrame {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: 4, height: 4,
      bitsPerComponent: 8, bytesPerRow: 16, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return RenderedFrame(image: try #require(context.makeImage()), frameIndex: 0,
      frameCount: 1, duration: nil)
  }

  private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    throw FailureFixtureError.timeout
  }

  private func drainTasks() async {
    for _ in 0..<20 { await Task.yield() }
  }
}

private enum FailureFixtureError: Error { case decode, timeout }

private actor ControlledFailureReason {
  private(set) var started = false
  private(set) var finished = false
  private(set) var wasCancelled = false
  private var continuation: CheckedContinuation<String?, Never>?

  func run() async -> String? {
    started = true
    let result = await withCheckedContinuation { continuation = $0 }
    wasCancelled = Task.isCancelled
    finished = true
    return result
  }

  func finish(_ reason: String?) {
    continuation?.resume(returning: reason)
    continuation = nil
  }
}

private actor ControlledFailurePreview {
  private(set) var started = false
  private var continuation: CheckedContinuation<RenderedFrame, Never>?

  func run() async -> RenderedFrame {
    started = true
    return await withCheckedContinuation { continuation = $0 }
  }

  func finish(_ frame: RenderedFrame) {
    continuation?.resume(returning: frame)
    continuation = nil
  }
}
