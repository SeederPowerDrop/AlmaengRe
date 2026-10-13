import CoreGraphics
import Foundation
import Testing

@testable import ImageViewer

@MainActor
@Suite("빠른 이미지 이동 중 표시 유지와 비동기 프레임 교체")
struct ViewerFrameLoaderTests {
  @Test("100번씩 연속 이동해도 진행 중 미리보기를 표시하고 마지막 목적지만 이어 읽는다")
  func samplesDuringContinuousNavigationWithoutQueueingEveryDestination() async throws {
    let loader = ViewerFrameLoader(settleDelay: .seconds(3_600))
    defer { loader.stop() }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let requests = (0...200).map(request)
    let firstFrame = try frame(width: 10)
    let middleFrame = try frame(width: 20)
    let lastFrame = try frame(width: 30)
    var ready: [ImageAsset] = []

    load(requests[0], into: loader, previews: previews, renders: renders) { ready.append($0) }
    try await waitUntil { await previews.starts.count == 1 }
    for destination in requests[1...100] {
      load(destination, into: loader, previews: previews, renders: renders) { ready.append($0) }
    }
    #expect(await previews.starts.map(\.request) == [requests[0]])

    await previews.succeed(0, with: firstFrame)
    try await waitUntil { await previews.starts.count == 2 }
    #expect(await previews.starts.map(\.request) == [requests[0], requests[100]])
    #expect(loader.presentation?.request == requests[0])
    #expect(loader.presentation?.frame.image === firstFrame.image)
    #expect(ready.isEmpty)

    for destination in requests[101...200] {
      load(destination, into: loader, previews: previews, renders: renders) { ready.append($0) }
      #expect(loader.presentation?.request == requests[0])
    }
    await previews.succeed(1, with: middleFrame)
    try await waitUntil { await previews.starts.count == 3 }
    #expect(await previews.starts.map(\.request) == [requests[0], requests[100], requests[200]])
    #expect(loader.presentation?.request == requests[100])
    #expect(loader.presentation?.frame.image === middleFrame.image)
    #expect(ready.isEmpty)

    await previews.succeed(2, with: lastFrame)
    try await waitUntil { loader.presentation?.request == requests[200] }
    #expect(loader.presentation?.frame.image === lastFrame.image)
    #expect(ready == [requests[200].asset])
    #expect(await previews.maximumRunning == 1)
    #expect(await previews.cancelledCompletions.isEmpty)
    #expect(await renders.starts.isEmpty)
  }

  @Test("다음 이미지가 완성될 때까지 기존 이미지와 그 이미지의 파일 정보를 함께 유지한다")
  func retainsDisplayedImageAndItsOwnRequestWhileNavigating() async throws {
    let loader = ViewerFrameLoader(settleDelay: .seconds(3_600))
    defer { loader.stop() }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let first = request(1)
    let second = request(2)
    let firstFrame = try frame(width: 11)
    let secondFrame = try frame(width: 22)
    var ready: [ImageAsset] = []

    load(first, into: loader, previews: previews, renders: renders) { ready.append($0) }
    try await waitUntil { await previews.starts.count == 1 }
    await previews.succeed(0, with: firstFrame)
    try await waitUntil { loader.presentation?.request == first }

    load(second, into: loader, previews: previews, renders: renders) { ready.append($0) }
    try await waitUntil { await previews.starts.count == 2 }
    #expect(loader.presentation?.request.asset == first.asset)
    #expect(loader.presentation?.frame.image === firstFrame.image)
    #expect(loader.errorMessage == nil)
    #expect(ready == [first.asset])

    await previews.succeed(1, with: secondFrame)
    try await waitUntil { loader.presentation?.request == second }
    #expect(loader.presentation?.request.asset.filename == second.asset.filename)
    #expect(loader.presentation?.frame.image === secondFrame.image)
    #expect(ready == [first.asset, second.asset])
  }

  @Test("미리보기가 끝나도 입력 안정화 대기 전에는 정밀 디코딩을 시작하지 않는다")
  func doesNotRenderBeforeSettling() async throws {
    // An intentionally distant deadline tests the gate without measuring speed.
    let loader = ViewerFrameLoader(settleDelay: .seconds(3_600))
    defer { loader.stop() }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let destination = request(1)
    let preview = try frame(width: 8)

    load(destination, into: loader, previews: previews, renders: renders)
    try await waitUntil { await previews.starts.count == 1 }
    await previews.succeed(0, with: preview)
    try await waitUntil { loader.presentation?.request == destination }
    await drainResumedTasks()
    #expect(await renders.starts.isEmpty)
    #expect(loader.presentation?.frame.image === preview.image)
  }

  @Test("늦게 완성된 이전 정밀 디코딩이 새 이미지의 정밀 프레임을 덮지 않는다")
  func rejectsLateRefinementAfterNavigation() async throws {
    let loader = ViewerFrameLoader(settleDelay: .zero)
    defer { loader.stop() }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let first = request(1)
    let second = request(2)
    let preview = try frame(width: 8)
    let outdatedFull = try frame(width: 40)
    let latestFull = try frame(width: 80)

    load(first, into: loader, previews: previews, renders: renders)
    try await waitUntil { await previews.starts.count == 1 }
    await previews.succeed(0, with: preview)
    try await waitUntil { loader.presentation?.request == first }
    try await waitUntil { await renders.starts.count == 1 }

    load(second, into: loader, previews: previews, renders: renders)
    try await waitUntil { await previews.starts.count == 2 }
    await previews.succeed(1, with: preview)
    try await waitUntil { loader.presentation?.request == second }
    try await waitUntil { await renders.starts.count == 2 }
    await renders.succeed(1, with: latestFull)
    try await waitUntil { loader.presentation?.frame.image === latestFull.image }

    await renders.succeed(0, with: outdatedFull)
    try await waitUntil { await renders.completions.count == 2 }
    await drainResumedTasks()
    #expect(loader.presentation?.request == second)
    #expect(loader.presentation?.frame.image === latestFull.image)
    #expect(await renders.cancelledCompletions == [0])
    #expect(loader.errorMessage == nil)
  }

  @Test("미리보기가 멈춰 있어도 최신 정밀 이미지를 표시하고 뒤늦은 이전 미리보기를 무시한다")
  func latestFullFrameCanOvertakeBlockedPreview() async throws {
    let loader = ViewerFrameLoader(settleDelay: .zero)
    defer { loader.stop() }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let first = request(1)
    let latest = request(2)
    let latePreview = try frame(width: 8)
    let lateFull = try frame(width: 40)
    let latestFull = try frame(width: 80)
    var ready: [ImageAsset] = []

    load(first, into: loader, previews: previews, renders: renders) { ready.append($0) }
    try await waitUntil { await previews.starts.count == 1 }
    try await waitUntil { await renders.starts.count == 1 }
    load(latest, into: loader, previews: previews, renders: renders) { ready.append($0) }
    try await waitUntil { await renders.starts.count == 2 }
    #expect(await previews.starts.count == 1)
    await renders.succeed(1, with: latestFull)
    try await waitUntil { loader.presentation?.request == latest }

    await previews.succeed(0, with: latePreview)
    await renders.succeed(0, with: lateFull)
    try await waitUntil { await previews.completions.count == 1 }
    try await waitUntil { await renders.completions.count == 2 }
    await drainResumedTasks()
    #expect(loader.presentation?.request == latest)
    #expect(loader.presentation?.frame.image === latestFull.image)
    #expect(await previews.starts.map(\.request) == [first])
    #expect(ready == [latest.asset])
  }

  @Test("같은 이미지의 정밀 디코딩이 먼저 끝나면 늦은 미리보기로 화질이 떨어지지 않는다")
  func latePreviewDoesNotDowngradeSameRequestFullFrame() async throws {
    let loader = ViewerFrameLoader(settleDelay: .zero)
    defer { loader.stop() }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let destination = request(1)
    let preview = try frame(width: 8)
    let full = try frame(width: 80)
    var readyCount = 0

    load(destination, into: loader, previews: previews, renders: renders) { _ in readyCount += 1 }
    try await waitUntil { await previews.starts.count == 1 }
    try await waitUntil { await renders.starts.count == 1 }
    await renders.succeed(0, with: full)
    try await waitUntil { loader.presentation?.frame.image === full.image }
    await previews.succeed(0, with: preview)
    try await waitUntil { await previews.completions.count == 1 }
    await drainResumedTasks()
    #expect(loader.presentation?.frame.image === full.image)
    #expect(readyCount == 1)
  }

  @Test("최신 이미지의 오류를 이전 미리보기로 가리지 않고 최신 미리보기 성공 시 복구한다")
  func preservesLatestErrorUntilItsOwnPreviewRecovers() async throws {
    let loader = ViewerFrameLoader(settleDelay: .zero)
    defer { loader.stop() }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let previous = request(1)
    let latest = request(2)
    let oldFrame = try frame(width: 8)
    let recoveredFrame = try frame(width: 16)
    var ready: [ImageAsset] = []

    load(previous, into: loader, previews: previews, renders: renders) { ready.append($0) }
    try await waitUntil { await previews.starts.count == 1 }
    try await waitUntil { await renders.starts.count == 1 }
    load(latest, into: loader, previews: previews, renders: renders) { ready.append($0) }
    try await waitUntil { await renders.starts.count == 2 }
    await renders.fail(1)
    try await waitUntil { loader.errorMessage != nil }

    await previews.succeed(0, with: oldFrame)
    try await waitUntil { await previews.starts.count == 2 }
    #expect(loader.presentation == nil)
    #expect(loader.errorMessage == MediaLoadFailure.text("missing"))
    #expect(ready == [latest.asset])
    await previews.succeed(1, with: recoveredFrame)
    try await waitUntil { loader.presentation?.request == latest }
    #expect(loader.presentation?.frame.image === recoveredFrame.image)
    #expect(loader.errorMessage == nil)
    #expect(ready == [latest.asset, latest.asset])
    await renders.fail(0)
    try await waitUntil { await renders.completions.count == 2 }
    await drainResumedTasks()
    #expect(loader.errorMessage == nil)
    #expect(loader.presentation?.request == latest)
  }

  @Test("확대나 창 크기 변경은 기존 정밀 프레임을 유지하며 작은 미리보기를 다시 읽지 않는다")
  func keepsDetailedFrameAcrossResolutionChange() async throws {
    let loader = ViewerFrameLoader(settleDelay: .zero)
    defer { loader.stop() }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let original = request(1)
    let enlarged = ViewerFrameRequest(asset: original.asset, maxPixelSize: 2_048,
      adjustments: original.adjustments, prefersHDR: original.prefersHDR)
    let preview = try frame(width: 8)
    let originalFull = try frame(width: 40)
    let enlargedFull = try frame(width: 80)

    load(original, into: loader, previews: previews, renders: renders)
    try await waitUntil { await previews.starts.count == 1 }
    await previews.succeed(0, with: preview)
    try await waitUntil { loader.presentation?.request == original }
    try await waitUntil { await renders.starts.count == 1 }
    await renders.succeed(0, with: originalFull)
    try await waitUntil { loader.presentation?.frame.image === originalFull.image }

    load(enlarged, into: loader, previews: previews, renders: renders)
    try await waitUntil { await renders.starts.count == 2 }
    #expect(loader.presentation?.request == original)
    #expect(loader.presentation?.frame.image === originalFull.image)
    #expect(await previews.starts.count == 1)
    await renders.succeed(1, with: enlargedFull)
    try await waitUntil { loader.presentation?.request == enlarged }
    #expect(loader.presentation?.frame.image === enlargedFull.image)
    #expect(await previews.starts.count == 1)
  }

  @Test("중단한 세션의 늦은 미리보기가 재시작한 세션을 덮지 않는다")
  func rejectsLatePreviewAcrossStopAndRestart() async throws {
    let loader = ViewerFrameLoader(settleDelay: .seconds(3_600))
    defer { loader.stop() }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let oldRequest = request(1)
    let newRequest = request(2)
    let oldFrame = try frame(width: 10)
    let newFrame = try frame(width: 20)
    var ready: [ImageAsset] = []

    load(oldRequest, into: loader, previews: previews, renders: renders) { ready.append($0) }
    try await waitUntil { await previews.starts.count == 1 }
    loader.stop()
    #expect(loader.presentation == nil)
    load(newRequest, into: loader, previews: previews, renders: renders) { ready.append($0) }
    try await waitUntil { await previews.starts.count == 2 }
    await previews.succeed(1, with: newFrame)
    try await waitUntil { loader.presentation?.request == newRequest }

    await previews.succeed(0, with: oldFrame)
    try await waitUntil { await previews.completions.count == 2 }
    await drainResumedTasks()
    #expect(loader.presentation?.request == newRequest)
    #expect(loader.presentation?.frame.image === newFrame.image)
    #expect(ready == [newRequest.asset])
    #expect(await previews.cancelledCompletions == [0])
  }

  @Test("중단 뒤 완료된 정밀 디코딩은 화면과 준비 알림을 다시 활성화하지 않는다")
  func rejectsLateFullFrameAfterStop() async throws {
    let loader = ViewerFrameLoader(settleDelay: .zero)
    defer { loader.stop() }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let destination = request(1)
    let preview = try frame(width: 10)
    let full = try frame(width: 20)
    var ready: [ImageAsset] = []

    load(destination, into: loader, previews: previews, renders: renders) { ready.append($0) }
    try await waitUntil { await previews.starts.count == 1 }
    await previews.succeed(0, with: preview)
    try await waitUntil { loader.presentation?.request == destination }
    try await waitUntil { await renders.starts.count == 1 }
    #expect(ready == [destination.asset])
    loader.stop()
    await renders.succeed(0, with: full)
    try await waitUntil { await renders.completions.count == 1 }
    await drainResumedTasks()
    #expect(loader.presentation == nil)
    #expect(loader.errorMessage == nil)
    #expect(ready == [destination.asset])
    #expect(await renders.cancelledCompletions == [0])
  }

  @Test("미리보기를 읽지 못하는 형식도 정밀 디코더가 성공하면 표시한다")
  func fallsBackToFullFrameAfterPreviewFailure() async throws {
    let loader = ViewerFrameLoader(settleDelay: .zero)
    defer { loader.stop() }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let destination = request(1)
    let full = try frame(width: 30)
    var ready: [ImageAsset] = []

    load(destination, into: loader, previews: previews, renders: renders) { ready.append($0) }
    try await waitUntil { await previews.starts.count == 1 }
    await previews.fail(0)
    try await waitUntil { await renders.starts.count == 1 }
    #expect(loader.errorMessage == nil)
    await renders.succeed(0, with: full)
    try await waitUntil { loader.presentation?.request == destination }
    #expect(loader.presentation?.frame.image === full.image)
    #expect(loader.errorMessage == nil)
    #expect(ready == [destination.asset])
  }

  @Test("미리보기와 정밀 디코딩이 모두 실패하면 오류를 표시하고 다음 요청에서 복구한다")
  func reportsBothFailuresAndRecoversOnNextImage() async throws {
    let loader = ViewerFrameLoader(settleDelay: .zero)
    defer { loader.stop() }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let failed = request(1)
    let recovered = request(2)
    let goodFrame = try frame(width: 30)
    var ready: [ImageAsset] = []

    load(failed, into: loader, previews: previews, renders: renders) { ready.append($0) }
    try await waitUntil { await previews.starts.count == 1 }
    await previews.fail(0)
    try await waitUntil { await renders.starts.count == 1 }
    await renders.fail(0)
    try await waitUntil { loader.errorMessage != nil }
    #expect(loader.presentation == nil)
    #expect(loader.errorMessage == MediaLoadFailure.text("missing"))
    #expect(ready == [failed.asset])

    load(recovered, into: loader, previews: previews, renders: renders) { ready.append($0) }
    #expect(loader.errorMessage == nil)
    try await waitUntil { await previews.starts.count == 2 }
    await previews.succeed(1, with: goodFrame)
    try await waitUntil { loader.presentation?.request == recovered }
    try await waitUntil { await renders.starts.count == 2 }
    await renders.succeed(1, with: goodFrame)
    try await waitUntil { ready.count == 3 }
    #expect(loader.presentation?.request == recovered)
    #expect(loader.presentation?.frame.image === goodFrame.image)
    #expect(loader.errorMessage == nil)
  }

  @Test("정밀 디코딩만 실패하면 이미 읽은 미리보기는 계속 표시한다")
  func retainsUsablePreviewWhenRefinementFails() async throws {
    let loader = ViewerFrameLoader(settleDelay: .zero)
    defer { loader.stop() }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let destination = request(1)
    let preview = try frame(width: 10)
    var readyCount = 0

    load(destination, into: loader, previews: previews, renders: renders) { _ in readyCount += 1 }
    try await waitUntil { await previews.starts.count == 1 }
    await previews.succeed(0, with: preview)
    try await waitUntil { loader.presentation?.request == destination }
    try await waitUntil { await renders.starts.count == 1 }
    await renders.fail(0)
    try await waitUntil { readyCount == 2 }
    #expect(loader.presentation?.request == destination)
    #expect(loader.presentation?.frame.image === preview.image)
    #expect(loader.errorMessage == nil)
  }

  @Test("애니메이션 재생 도중 이동하면 이전 프레임을 취소하고 새 이미지로 교체한다")
  func replacesAnimationAndRejectsItsLateNextFrame() async throws {
    let loader = ViewerFrameLoader(settleDelay: .zero)
    defer { loader.stop() }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let animated = request(1)
    let replacement = request(2)
    let preview = try frame(width: 8)
    let animationStart = try frame(width: 10, index: 0, count: 3, duration: 0)
    let lateAnimation = try frame(width: 11, index: 1, count: 3, duration: 0)
    let replacementFull = try frame(width: 20)

    load(animated, into: loader, previews: previews, renders: renders)
    try await waitUntil { await previews.starts.count == 1 }
    await previews.succeed(0, with: preview)
    try await waitUntil { await renders.starts.count == 1 }
    await renders.succeed(0, with: animationStart)
    try await waitUntil { await renders.starts.count == 2 }
    #expect(await renders.starts.map(\.frameIndex) == [0, 1])
    #expect(loader.presentation?.frame.image === animationStart.image)

    load(replacement, into: loader, previews: previews, renders: renders)
    try await waitUntil { await previews.starts.count == 2 }
    await previews.succeed(1, with: preview)
    try await waitUntil { await renders.starts.count == 3 }
    #expect(await renders.starts.last?.request == replacement)
    #expect(await renders.starts.last?.frameIndex == 0)
    await renders.succeed(2, with: replacementFull)
    try await waitUntil { loader.presentation?.frame.image === replacementFull.image }

    await renders.succeed(1, with: lateAnimation)
    try await waitUntil { await renders.completions.count == 3 }
    await drainResumedTasks()
    #expect(loader.presentation?.request == replacement)
    #expect(loader.presentation?.frame.image === replacementFull.image)
    #expect(await renders.starts.count == 3)
    #expect(await renders.cancelledCompletions == [1])
  }

  private func load(
    _ request: ViewerFrameRequest, into loader: ViewerFrameLoader,
    previews: ControlledViewerFrames, renders: ControlledViewerFrames,
    onReady: @escaping (ImageAsset) -> Void = { _ in }
  ) {
    loader.load(request,
      preview: { try await previews.run($0) },
      render: { try await renders.run($0, frameIndex: $1) },
      onReady: onReady)
  }

  private func request(_ number: Int) -> ViewerFrameRequest {
    ViewerFrameRequest(
      asset: ImageAsset(url: URL(fileURLWithPath: "/viewer-frame-tests/image-\(number).png"),
        byteCount: nil, modificationDate: nil),
      maxPixelSize: 1_024, adjustments: .identity, prefersHDR: false)
  }

  private func frame(
    width: Int, index: Int = 0, count: Int = 1, duration: TimeInterval? = nil
  ) throws -> RenderedFrame {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: width, height: 2,
      bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    return RenderedFrame(image: image, frameIndex: index, frameCount: count,
      duration: duration, sourcePixelSize: CGSize(width: width, height: 2))
  }

  private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
    // This is only a deadlock timeout; no elapsed duration is asserted by the tests.
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    throw ViewerFrameTestError.timeout
  }

  private func drainResumedTasks() async {
    // Give callers of explicitly completed decodes a chance to apply/reject them.
    // The decoded frame order itself is controlled by continuations, not timers.
    for _ in 0..<20 { await Task.yield() }
  }
}

private enum ViewerFrameTestError: LocalizedError {
  case decode
  case timeout

  var errorDescription: String? {
    switch self {
    case .decode: "The controlled image decoder failed."
    case .timeout: "A controlled frame operation did not finish."
    }
  }
}

/// Deliberately ignores cancellation until the test completes an operation, like
/// synchronous image decoding. This makes late-result rejection testable.
private actor ControlledViewerFrames {
  struct Start: Sendable {
    let request: ViewerFrameRequest
    let frameIndex: Int
  }

  private(set) var starts: [Start] = []
  private(set) var completions: [Int] = []
  private(set) var cancelledCompletions: [Int] = []
  private(set) var maximumRunning = 0
  private var running = 0
  private var continuations: [Int: CheckedContinuation<RenderedFrame, any Error>] = [:]

  func run(_ request: ViewerFrameRequest, frameIndex: Int = 0) async throws -> RenderedFrame {
    let id = starts.count
    starts.append(Start(request: request, frameIndex: frameIndex))
    running += 1
    maximumRunning = max(maximumRunning, running)
    defer {
      running -= 1
      completions.append(id)
      if Task.isCancelled { cancelledCompletions.append(id) }
    }
    return try await withCheckedThrowingContinuation { continuations[id] = $0 }
  }

  func succeed(_ id: Int, with frame: RenderedFrame) {
    guard let continuation = continuations.removeValue(forKey: id) else {
      Issue.record("No pending controlled decode \(id)")
      return
    }
    continuation.resume(returning: frame)
  }

  func fail(_ id: Int) {
    guard let continuation = continuations.removeValue(forKey: id) else {
      Issue.record("No pending controlled decode \(id)")
      return
    }
    continuation.resume(throwing: ViewerFrameTestError.decode)
  }
}
