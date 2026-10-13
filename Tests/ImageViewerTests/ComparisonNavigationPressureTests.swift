import CoreGraphics
import Foundation
import Testing

@testable import ImageViewer

@MainActor
@Suite("작업 여유가 없는 비교 화면의 연속 사진 이동")
struct ComparisonNavigationPressureTests {
  @Test("한 작업이 막혀 있어도 양쪽 입력을 합치고 마지막 사진까지 정밀 표시한다")
  func twoPanesConvergeAfterOccupiedWorkerFinishes() async throws {
    // Deterministic contention, not a timing benchmark or a real RAW workload.
    let governor = ImageResourceGovernor(mode: .comfortable,
      snapshot: ImageResourceSnapshot(physicalMemory: 16 * 1_024 * 1_024 * 1_024,
        activeProcessorCount: 8, appleSilicon: true),
      storageOverride: .internalSSD, maximumConcurrentLoadsOverride: 1)
    let namespace = UUID()
    let probe = ComparisonPressureProbe()
    let previewFrame = try frame(width: 4)
    let preciseFrame = try frame(width: 16)
    let loaders = [ViewerFrameLoader(settleDelay: .zero), ViewerFrameLoader(settleDelay: .zero)]
    defer { loaders.forEach { $0.stop() } }

    let preview: ViewerFrameLoader.Preview = { request in
      let key = ComparisonPressureWork(url: request.asset.url, stage: .preview)
      try Task.checkCancellation()
      await probe.submitted(key)
      return try await governor.value(for: ImageResourceWorkKey(namespace: namespace, key: key),
        url: key.url, priority: .interactivePreview) { _ in
          await probe.completed(key)
          return previewFrame
        }
    }
    let render: ViewerFrameLoader.Render = { request, _ in
      let key = ComparisonPressureWork(url: request.asset.url, stage: .refinement)
      try Task.checkCancellation()
      await probe.submitted(key)
      return try await governor.value(for: ImageResourceWorkKey(namespace: namespace, key: key),
        url: key.url) { _ in
          await probe.completed(key)
          return preciseFrame
        }
    }
    let original = (0..<2).map { request(pane: $0, revision: 0) }
    for pane in loaders.indices {
      loaders[pane].load(original[pane], preview: preview, render: render)
    }
    try await waitUntil {
      let state = await governor.stateSnapshot()
      return state.runningCount == 0 && state.queuedCount == 0 && state.waiterCount == 0
        && loaders.indices.allSatisfy {
          loaders[$0].presentation?.request == original[$0]
            && loaders[$0].presentation?.frame.image === preciseFrame.image
        }
    }
    await probe.reset()

    let occupied = ComparisonOccupiedWorker()
    let blockerURL = URL(fileURLWithPath: "/comparison-pressure/occupied.jpg")
    let blocker = Task {
      try await governor.value(for: ImageResourceWorkKey(namespace: UUID(), key: 0),
        url: blockerURL) { _ in
          await occupied.run()
          return 0
        }
    }
    defer {
      blocker.cancel()
      Task { await occupied.release() }
    }
    try await waitUntil { await occupied.started }

    // Both first previews enter the shared queue before the synchronous input burst.
    let pending = (0..<2).map { request(pane: $0, revision: 1) }
    for pane in loaders.indices {
      loaders[pane].load(pending[pane], preview: preview, render: render)
    }
    try await waitUntil {
      let state = await governor.stateSnapshot()
      return state.runningCount == 1 && state.queuedCount == 4 && state.waiterCount == 5
    }

    var submittedInputCount = 0
    for revision in 2...101 {
      for pane in loaders.indices {
        loaders[pane].load(request(pane: pane, revision: revision), preview: preview, render: render)
        submittedInputCount += 1
        // No await or timing assertion: all 200 input calls finish while work is blocked.
        #expect(loaders[pane].presentation?.request == original[pane])
        #expect(loaders[pane].presentation?.frame.image === preciseFrame.image)
        #expect(loaders[pane].errorMessage == nil)
      }
    }
    #expect(submittedInputCount == 200)

    let latest = (0..<2).map { request(pane: $0, revision: 101) }
    let finalRefinements = Set(latest.map {
      ComparisonPressureWork(url: $0.asset.url, stage: .refinement)
    })
    try await waitUntil {
      let submitted = await probe.submissions
      let state = await governor.stateSnapshot()
      return finalRefinements.isSubset(of: submitted)
        && state.runningCount == 1 && state.queuedCount == 4 && state.waiterCount == 5
    }
    #expect(await probe.completions.isEmpty)

    // A canceled native operation must retain its slot until it really returns.
    blocker.cancel()
    do {
      _ = try await blocker.value
      Issue.record("The canceled caller should stop waiting for the occupied worker")
    } catch is CancellationError {
    }
    try await waitUntil {
      let state = await governor.stateSnapshot()
      return state.runningCount == 1 && state.queuedCount <= 4 && state.waiterCount == 4
    }
    #expect(await probe.completions.isEmpty)
    #expect(await occupied.finished == false)

    await occupied.release()
    try await waitUntil {
      let completedRefinements = Set(await probe.completions.filter { $0.stage == .refinement })
      return completedRefinements == finalRefinements && loaders.indices.allSatisfy {
        loaders[$0].presentation?.request == latest[$0]
          && loaders[$0].presentation?.frame.image === preciseFrame.image
      }
    }
    try await waitUntil {
      let state = await governor.stateSnapshot()
      return state.runningCount == 0 && state.queuedCount == 0 && state.waiterCount == 0
    }

    let completed = await probe.completions
    let previews = completed.filter { $0.stage == .preview }
    let permittedPreviewURLs = Set((pending + latest).map(\.asset.url))
    #expect(Set(previews.map(\.url)).isSubset(of: permittedPreviewURLs))
    #expect(previews.count <= 4)
    #expect(completed.filter { $0.stage == .refinement }.count == 2)
    #expect(await occupied.finished)
    #expect(await occupied.wasCancelled)
    #expect(loaders.allSatisfy { $0.errorMessage == nil })
  }

  private func request(pane: Int, revision: Int) -> ViewerFrameRequest {
    ViewerFrameRequest(asset: ImageAsset(
      url: URL(fileURLWithPath: "/comparison-pressure/pane-\(pane)/photo-\(revision).jpg"),
      byteCount: nil, modificationDate: nil),
      maxPixelSize: 16, adjustments: .identity, prefersHDR: false)
  }

  private func frame(width: Int) throws -> RenderedFrame {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: width, height: 4,
      bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: 4))
    return RenderedFrame(image: try #require(context.makeImage()),
      frameIndex: 0, frameCount: 1, duration: nil)
  }

  private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await condition()) {
      guard ContinuousClock.now < deadline else { throw ComparisonPressureError.timeout }
      try await Task.sleep(for: .milliseconds(1))
    }
  }
}

private enum ComparisonPressureError: Error { case timeout }

private struct ComparisonPressureWork: Hashable, Sendable {
  enum Stage: Hashable, Sendable { case preview, refinement }
  let url: URL
  let stage: Stage
}

private actor ComparisonPressureProbe {
  private(set) var submissions: Set<ComparisonPressureWork> = []
  private(set) var completions: [ComparisonPressureWork] = []

  func submitted(_ key: ComparisonPressureWork) { submissions.insert(key) }
  func completed(_ key: ComparisonPressureWork) { completions.append(key) }
  func reset() {
    submissions.removeAll()
    completions.removeAll()
  }
}

private actor ComparisonOccupiedWorker {
  private(set) var started = false
  private(set) var finished = false
  private(set) var wasCancelled = false
  private var released = false
  private var continuation: CheckedContinuation<Void, Never>?

  func run() async {
    started = true
    if !released { await withCheckedContinuation { continuation = $0 } }
    wasCancelled = Task.isCancelled
    finished = true
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
