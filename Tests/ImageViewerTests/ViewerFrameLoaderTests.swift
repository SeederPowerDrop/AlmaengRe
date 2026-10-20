import CoreGraphics
import Foundation
import Testing

@testable import ImageViewer

@MainActor
@Suite("빠른 이미지 이동 중 표시 유지와 비동기 프레임 교체")
struct ViewerFrameLoaderTests {
  @Test("표시 타일 수에 따라 준비 시간을 바꾸되 미리보기와 최종 해상도·HDR 요청을 유지한다",
    arguments: [4, 5])
  func visibleCountControlsSchedulingWithoutReducingQuality(visibleCount: Int) async throws {
    let settling = ControlledViewerSettling()
    let loader = ViewerFrameLoader(waitForSettling: { await settling.wait($0) })
    defer {
      loader.stop()
      Task { await settling.releaseAll() }
    }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let policy = ViewerFrameLoadingPolicy.forVisibleItemCount(visibleCount)
    let requests = (1...2).map { number in
      ViewerFrameRequest(asset: request(number).asset, maxPixelSize: 2_048,
        adjustments: .identity, prefersHDR: true, loadingPolicy: policy)
    }
    for (index, value) in requests.enumerated() {
      load(value, into: loader, previews: previews, renders: renders)
      try await waitUntil { await settling.delays.count == index + 1 }
      try await waitUntil { await previews.starts.count == index + 1 }
      await previews.succeed(index, with: try frame(width: 8))
      try await waitUntil { loader.presentation?.request == value }
      #expect(await renders.starts.isEmpty)
    }
    let expectedDelay: Duration = visibleCount <= 4 ? .milliseconds(120) : .milliseconds(450)
    #expect(await settling.delays == [expectedDelay, expectedDelay])
    await settling.releaseAll()
    try await waitUntil { await renders.starts.count == 1 }
    #expect(await renders.starts.first?.request == requests[1])
    let detailed = try frame(width: 2_048)
    await renders.succeed(0, with: detailed)
    try await waitUntil { loader.presentation?.frame.image === detailed.image }
    #expect(loader.presentation?.frame.image.width == 2_048)
    #expect(loader.presentation?.request.prefersHDR == true)
  }

  @Test("큰 페이지의 애니메이션도 정밀 렌더 후 추가 대기 없이 다음 프레임을 계속 재생한다")
  func responsivePolicyKeepsAnimationRunning() async throws {
    let settling = ControlledViewerSettling()
    let loader = ViewerFrameLoader(waitForSettling: { await settling.wait($0) })
    defer {
      loader.stop()
      Task { await settling.releaseAll() }
    }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    var animated = request(1)
    animated.loadingPolicy = .forVisibleItemCount(10)
    load(animated, into: loader, previews: previews, renders: renders)
    try await waitUntil { await settling.delays.count == 1 }
    try await waitUntil { await previews.starts.count == 1 }
    await previews.succeed(0, with: try frame(width: 8))
    await settling.release(0)
    try await waitUntil { await renders.starts.count == 1 }
    let firstFrame = try frame(width: 1_024, index: 0, count: 3, duration: 0)
    await renders.succeed(0, with: firstFrame)
    try await waitUntil { await renders.starts.count == 2 }
    #expect(loader.presentation?.frame.image === firstFrame.image)
    #expect(await settling.delays == [.milliseconds(450)])
    #expect(await renders.starts.map(\.frameIndex) == [0, 1])
    loader.stop()
    await renders.succeed(1, with: try frame(width: 1_024, index: 1, count: 3, duration: 0))
    try await waitUntil { await renders.completions.count == 2 }
    #expect(loader.presentation == nil)
  }

  @Test("네 장 이하로 바뀌면 화질 우선 대기로 전환하고 명시한 지연도 보존한다",
    arguments: [false, true])
  func responsiveToQualityChangeReschedulesRefinement(customDelay: Bool) async throws {
    let settling = ControlledViewerSettling()
    let loader = ViewerFrameLoader(settleDelay: customDelay ? .zero : nil,
      waitForSettling: { await settling.wait($0) })
    defer {
      loader.stop()
      Task { await settling.releaseAll() }
    }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    var many = request(1)
    many.loadingPolicy = .forVisibleItemCount(6)
    load(many, into: loader, previews: previews, renders: renders)
    try await waitUntil { await settling.delays.count == 1 }
    try await waitUntil { await previews.starts.count == 1 }
    let preview = try frame(width: 8)
    await previews.succeed(0, with: preview)
    try await waitUntil { loader.presentation?.frame.image === preview.image }
    var few = many
    // Use the actual three items remaining on a page, not its configured six slots.
    few.loadingPolicy = .forVisibleItemCount(3)
    load(few, into: loader, previews: previews, renders: renders)
    try await waitUntil { await settling.delays.count == 2 }
    #expect(await previews.starts.count == 1)
    let expected: [Duration] = customDelay ? [.zero, .zero]
      : [.milliseconds(450), .milliseconds(120)]
    #expect(await settling.delays == expected)
    await settling.releaseAll()
    try await waitUntil { await renders.starts.count == 1 }
    #expect(await renders.starts.first?.request == few)
    let detailed = try frame(width: 1_024)
    await renders.succeed(0, with: detailed)
    try await waitUntil { loader.presentation?.frame.image === detailed.image }
    #expect(loader.presentation?.request.loadingPolicy == .quality)
  }

  @Test("RAW 탐색은 미리보기를 즉시 표시하고 마지막 목적지만 입력 안정화 뒤 정밀 렌더한다")
  func rawNavigationSkipsAbandonedRefinement() async throws {
    let settling = ControlledViewerSettling()
    let loader = ViewerFrameLoader(waitForSettling: { await settling.wait($0) })
    defer {
      loader.stop()
      Task { await settling.releaseAll() }
    }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let requests = (1...3).map { number in
      let value = request(number)
      return ViewerFrameRequest(asset: value.asset.replacingURL(
        value.asset.url.deletingPathExtension().appendingPathExtension("DNG")),
        maxPixelSize: value.maxPixelSize, adjustments: value.adjustments,
        prefersHDR: value.prefersHDR)
    }
    let preview = try frame(width: 8)
    load(requests[0], into: loader, previews: previews, renders: renders)
    try await waitUntil { await settling.delays.count == 1 }
    try await waitUntil { await previews.starts.count == 1 }
    await previews.succeed(0, with: preview)
    await settling.release(0)
    try await waitUntil { await renders.starts.count == 1 }
    let firstDetail = try frame(width: 1_024)
    await renders.succeed(0, with: firstDetail)
    try await waitUntil { loader.presentation?.frame.image === firstDetail.image }

    for index in 1...2 {
      load(requests[index], into: loader, previews: previews, renders: renders)
      try await waitUntil { await settling.delays.count == index + 1 }
      try await waitUntil { await previews.starts.count == index + 1 }
      await previews.succeed(index, with: preview)
      try await waitUntil { loader.presentation?.request == requests[index] }
      #expect(await renders.starts.count == 1)
    }
    #expect(await settling.delays == [.milliseconds(120), .milliseconds(280), .milliseconds(280)])
    // Finish both waits after navigation; cancellation must prevent the middle
    // file's native RAW decoder from starting, even if its wait completed late.
    await settling.release(1)
    await settling.release(2)
    try await waitUntil { await renders.starts.count == 2 }
    #expect(await renders.starts.map(\.request) == [requests[0], requests[2]])
    let finalDetail = try frame(width: 1_024)
    await renders.succeed(1, with: finalDetail)
    try await waitUntil { loader.presentation?.frame.image === finalDetail.image }
    #expect(loader.presentation?.request == requests[2])
  }

  @Test("일반 탐색은 기존 지연, RAW 탐색·편집·초기화는 긴 지연이며 명시한 지연도 따른다",
    arguments: [false, true])
  func navigationAndEditingUseTheirOwnQuietWindows(customDelay: Bool) async throws {
    let settling = ControlledViewerSettling()
    let loader = ViewerFrameLoader(settleDelay: customDelay ? .zero : nil,
      waitForSettling: { await settling.wait($0) })
    defer {
      loader.stop()
      Task { await settling.releaseAll() }
    }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    func rawRequest(_ number: Int) -> ViewerFrameRequest {
      let value = request(number)
      return ViewerFrameRequest(asset: value.asset.replacingURL(
        value.asset.url.deletingPathExtension().appendingPathExtension("dng")),
        maxPixelSize: value.maxPixelSize, adjustments: value.adjustments,
        prefersHDR: value.prefersHDR)
    }
    let raw = rawRequest(3)
    var adjusted = raw.adjustments
    adjusted.exposure = 1
    let edited = ViewerFrameRequest(asset: raw.asset, maxPixelSize: raw.maxPixelSize,
      adjustments: adjusted, prefersHDR: raw.prefersHDR)
    let requests = [rawRequest(1), request(2), raw, edited, raw]
    for (index, value) in requests.enumerated() {
      load(value, into: loader, previews: previews, renders: renders)
      try await waitUntil { await settling.delays.count == index + 1 }
      try await waitUntil { await previews.starts.count == index + 1 }
      await previews.succeed(index, with: try frame(width: 8))
      try await waitUntil { loader.presentation?.request == value }
    }
    let expected: [Duration] = customDelay ? Array(repeating: .zero, count: 5)
      : [.milliseconds(120), .milliseconds(120), .milliseconds(280), .milliseconds(280),
        .milliseconds(280)]
    #expect(await settling.delays == expected)
    await settling.releaseAll()
    try await waitUntil { await renders.starts.count == 1 }
    #expect(await renders.starts.first?.request == raw)
    let detailed = try frame(width: 1_024)
    await renders.succeed(0, with: detailed)
    try await waitUntil { loader.presentation?.frame.image === detailed.image }
  }

  @Test("연속 편집의 미리보기는 합쳐서 즉시 이어 읽고 취소된 정밀 렌더는 시작하지 않는다")
  func editingKeepsImmediatePreviewAndCancelsAbandonedRefinement() async throws {
    let settling = ControlledViewerSettling()
    let loader = ViewerFrameLoader(waitForSettling: { await settling.wait($0) })
    defer {
      loader.stop()
      Task { await settling.releaseAll() }
    }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let original = request(1)
    func edited(_ exposure: Double) -> ViewerFrameRequest {
      var adjustments = original.adjustments
      adjustments.exposure = exposure
      return ViewerFrameRequest(asset: original.asset, maxPixelSize: original.maxPixelSize,
        adjustments: adjustments, prefersHDR: original.prefersHDR)
    }
    load(original, into: loader, previews: previews, renders: renders)
    try await waitUntil { await previews.starts.count == 1 }
    try await waitUntil { await settling.delays.count == 1 }
    await previews.succeed(0, with: try frame(width: 8))
    try await waitUntil { loader.presentation?.request == original }

    let firstEdit = edited(1)
    load(firstEdit, into: loader, previews: previews, renders: renders)
    try await waitUntil { await previews.starts.count == 2 }
    try await waitUntil { await settling.delays.count == 2 }
    load(edited(2), into: loader, previews: previews, renders: renders)
    try await waitUntil { await settling.delays.count == 3 }
    load(edited(3), into: loader, previews: previews, renders: renders)
    try await waitUntil { await settling.delays.count == 4 }
    #expect(await previews.starts.count == 2)
    #expect(await renders.starts.isEmpty)

    // The one running preview completes, then only the latest edit is sampled.
    await previews.succeed(1, with: try frame(width: 10))
    try await waitUntil { await previews.starts.count == 3 }
    #expect(await previews.starts.map(\.request) == [original, firstEdit, edited(3)])
    await previews.succeed(2, with: try frame(width: 12))
    try await waitUntil { loader.presentation?.request == edited(3) }
    #expect(await renders.starts.isEmpty)
    #expect(await settling.delays == [.milliseconds(120), .milliseconds(280),
      .milliseconds(280), .milliseconds(280)])

    // A cancelled quiet window can return late without starting native decoding.
    await settling.release(0)
    await settling.release(1)
    await settling.release(2)
    await drainResumedTasks()
    #expect(await renders.starts.isEmpty)
    await settling.release(3)
    try await waitUntil { await renders.starts.count == 1 }
    #expect(await renders.starts.first?.request == edited(3))
    let detail = try frame(width: original.maxPixelSize)
    await renders.succeed(0, with: detail)
    try await waitUntil { loader.presentation?.frame.image === detail.image }
    #expect(loader.presentation?.request == edited(3))
  }

  @Test("편집 전용 대기는 일반 탐색·HDR 변경·창 크기 변경 대기에 영향을 주지 않는다")
  func editingDelayOverrideIsIndependent() async throws {
    let settling = ControlledViewerSettling()
    let loader = ViewerFrameLoader(settleDelay: .milliseconds(11),
      editingSettleDelay: .milliseconds(33), waitForSettling: { await settling.wait($0) })
    defer {
      loader.stop()
      Task { await settling.releaseAll() }
    }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let original = request(1)
    var adjusted = original.adjustments
    adjusted.brightness = 0.2
    let edited = ViewerFrameRequest(asset: original.asset, maxPixelSize: original.maxPixelSize,
      adjustments: adjusted, prefersHDR: original.prefersHDR)
    let hdr = ViewerFrameRequest(asset: original.asset, maxPixelSize: original.maxPixelSize,
      adjustments: adjusted, prefersHDR: true)
    let resized = ViewerFrameRequest(asset: original.asset, maxPixelSize: 2_048,
      adjustments: adjusted, prefersHDR: true)
    let requests = [original, edited, hdr, resized, request(2)]
    for (index, value) in requests.enumerated() {
      load(value, into: loader, previews: previews, renders: renders)
      try await waitUntil { await settling.delays.count == index + 1 }
      if index == 0 { try await waitUntil { await previews.starts.count == 1 } }
    }
    #expect(await settling.delays == [.milliseconds(11), .milliseconds(33),
      .milliseconds(11), .milliseconds(11), .milliseconds(11)])
    await previews.succeed(0, with: try frame(width: 8))
    try await waitUntil { await previews.starts.count == 2 }
    await previews.succeed(1, with: try frame(width: 8))
    try await waitUntil { loader.presentation?.request == requests.last }
  }

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

  @Test("이전 원본 미리보기가 멈춰 있어도 최신 목적지의 RAM 비트맵을 즉시 재사용한다")
  func warmDestinationOvertakesBlockedSourcePreview() async throws {
    let loader = ViewerFrameLoader(settleDelay: .seconds(3_600))
    defer { loader.stop() }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let first = request(1)
    let latest = request(2)
    let oldFrame = try frame(width: 8)
    let warmFrame = try frame(width: 512)
    var ready: [ImageAsset] = []

    load(first, into: loader, previews: previews, renders: renders)
    try await waitUntil { await previews.starts.count == 1 }
    loader.load(latest, cachedPreview: { _ in warmFrame },
      preview: { try await previews.run($0) },
      render: { try await renders.run($0, frameIndex: $1) },
      onReady: { ready.append($0) })
    // The source operation is deliberately unresolved, so this proves cache
    // publication can bypass it without relying on a timing threshold.
    try await waitUntil { loader.presentation?.request == latest }
    #expect(loader.presentation?.frame.image === warmFrame.image)
    #expect(await previews.starts.map(\.request) == [first])
    #expect(await renders.starts.isEmpty)
    #expect(ready == [latest.asset])

    await previews.succeed(0, with: oldFrame)
    try await waitUntil { await previews.completions.count == 1 }
    await drainResumedTasks()
    #expect(loader.presentation?.frame.image === warmFrame.image)
    #expect(await previews.starts.map(\.request) == [first],
      "A destination already shown from RAM must not request another source preview")
    #expect(await previews.maximumRunning == 1)
    #expect(await previews.cancelledCompletions.isEmpty)
  }

  @Test("취소를 늦게 관찰한 이전 RAM 조회가 최신 목적지의 비트맵을 덮지 않는다")
  func rejectsLateCacheReplyAfterNavigation() async throws {
    let loader = ViewerFrameLoader(settleDelay: .seconds(3_600))
    defer { loader.stop() }
    let cached = ControlledViewerFrames()
    let first = request(1)
    let latest = request(2)
    let oldFrame = try frame(width: 8)
    let warmFrame = try frame(width: 512)
    func loadCached(_ value: ViewerFrameRequest) {
      loader.load(value, cachedPreview: { try? await cached.run($0) },
        preview: { _ in throw ViewerFrameTestError.decode },
        render: { _, _ in throw ViewerFrameTestError.decode })
    }
    loadCached(first)
    try await waitUntil { await cached.starts.count == 1 }
    loadCached(latest)
    try await waitUntil { await cached.starts.count == 2 }
    await cached.succeed(1, with: warmFrame)
    try await waitUntil { loader.presentation?.request == latest }
    await cached.succeed(0, with: oldFrame)
    try await waitUntil { await cached.completions.count == 2 }
    await drainResumedTasks()
    #expect(loader.presentation?.request == latest)
    #expect(loader.presentation?.frame.image === warmFrame.image)
    #expect(await cached.cancelledCompletions == [0])
  }

  @Test("정밀 프레임이 먼저 끝나면 늦은 RAM 미리보기로 화질이 떨어지지 않는다")
  func lateCacheReplyDoesNotDowngradeRefinedFrame() async throws {
    let loader = ViewerFrameLoader(settleDelay: .zero)
    defer { loader.stop() }
    let cached = ControlledViewerFrames()
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let destination = request(1)
    let small = try frame(width: 8)
    let detailed = try frame(width: destination.maxPixelSize)
    loader.load(destination, cachedPreview: { try? await cached.run($0) },
      preview: { try await previews.run($0) },
      render: { try await renders.run($0, frameIndex: $1) })
    try await waitUntil { await cached.starts.count == 1 }
    try await waitUntil { await previews.starts.count == 1 }
    try await waitUntil { await renders.starts.count == 1 }
    await renders.succeed(0, with: detailed)
    try await waitUntil { loader.presentation?.frame.image === detailed.image }
    await cached.succeed(0, with: small)
    await previews.succeed(0, with: small)
    try await waitUntil { await cached.completions.count == 1 }
    try await waitUntil { await previews.completions.count == 1 }
    await drainResumedTasks()
    #expect(loader.presentation?.request == destination)
    #expect(loader.presentation?.frame.image === detailed.image)
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

  @Test("작은 축소·재확대는 같은 정밀 픽셀을 즉시 재사용하고 누적 축소는 메모리를 줄인다")
  func reusesRefinedPixelsWithinBoundedResizeRange() async throws {
    let loader = ViewerFrameLoader(settleDelay: .zero)
    defer { loader.stop() }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let original = request(1)
    func resized(_ pixels: Int) -> ViewerFrameRequest {
      ViewerFrameRequest(asset: original.asset, maxPixelSize: pixels,
        adjustments: original.adjustments, prefersHDR: original.prefersHDR)
    }
    let detailed = try frame(width: 1_024)
    var ready: [ImageAsset] = []
    load(original, into: loader, previews: previews, renders: renders) { ready.append($0) }
    try await waitUntil { await previews.starts.count == 1 }
    try await waitUntil { await renders.starts.count == 1 }
    await renders.succeed(0, with: detailed)
    try await waitUntil { loader.presentation?.frame.image === detailed.image }

    for pixels in [1_000, 900, 850, 1_024] {
      let destination = resized(pixels)
      load(destination, into: loader, previews: previews, renders: renders) { ready.append($0) }
      #expect(loader.presentation?.request == destination)
      #expect(loader.presentation?.frame.image === detailed.image)
    }
    // The initial preview is deliberately late and must not replace reused detail.
    await previews.succeed(0, with: try frame(width: 8))
    try await waitUntil { await previews.completions.count == 1 }
    await drainResumedTasks()
    #expect(loader.presentation?.frame.image === detailed.image)
    #expect(await renders.starts.count == 1)
    #expect(await previews.starts.count == 1)
    #expect(ready.count == 5)

    // Repeated steps cannot hide the original bitmap size from the memory bound.
    load(resized(850), into: loader, previews: previews, renders: renders)
    load(resized(800), into: loader, previews: previews, renders: renders)
    try await waitUntil { await renders.starts.count == 2 }
    let smaller = try frame(width: 800)
    await renders.succeed(1, with: smaller)
    try await waitUntil { loader.presentation?.frame.image === smaller.image }
    #expect(loader.presentation?.request.maxPixelSize == 800)
  }

  @Test("큰 미리보기만 있는 축소 요청도 정밀 렌더를 생략하지 않는다")
  func previewCannotSubstituteForRefinementAfterResize() async throws {
    let loader = ViewerFrameLoader(settleDelay: .zero)
    defer { loader.stop() }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let original = request(1)
    let smaller = ViewerFrameRequest(asset: original.asset, maxPixelSize: 900,
      adjustments: original.adjustments, prefersHDR: original.prefersHDR)
    load(original, into: loader, previews: previews, renders: renders)
    try await waitUntil { await previews.starts.count == 1 }
    try await waitUntil { await renders.starts.count == 1 }
    let preview = try frame(width: 1_024)
    await previews.succeed(0, with: preview)
    try await waitUntil { loader.presentation?.frame.image === preview.image }
    load(smaller, into: loader, previews: previews, renders: renders)
    try await waitUntil { await renders.starts.count == 2 }
    let detailed = try frame(width: 900)
    await renders.succeed(1, with: detailed)
    await renders.succeed(0, with: try frame(width: 1_024))
    try await waitUntil { loader.presentation?.frame.image === detailed.image }
    #expect(loader.presentation?.request == smaller)
  }

  @Test("색 조정이나 HDR 변경은 크기가 작아도 이전 정밀 픽셀을 재사용하지 않는다",
    arguments: [false, true])
  func contentChangesInvalidateResizeReuse(changeHDR: Bool) async throws {
    let loader = ViewerFrameLoader(settleDelay: .zero)
    defer { loader.stop() }
    let previews = ControlledViewerFrames()
    let renders = ControlledViewerFrames()
    let original = request(1)
    var adjustments = original.adjustments
    if !changeHDR { adjustments.exposure = 1 }
    let changed = ViewerFrameRequest(asset: original.asset, maxPixelSize: 900,
      adjustments: adjustments, prefersHDR: changeHDR)
    load(original, into: loader, previews: previews, renders: renders)
    try await waitUntil { await previews.starts.count == 1 }
    try await waitUntil { await renders.starts.count == 1 }
    await previews.succeed(0, with: try frame(width: 8))
    let detailed = try frame(width: 1_024)
    await renders.succeed(0, with: detailed)
    try await waitUntil { loader.presentation?.frame.image === detailed.image }
    load(changed, into: loader, previews: previews, renders: renders)
    try await waitUntil { await previews.starts.count == 2 }
    try await waitUntil { await renders.starts.count == 2 }
    let changedFrame = try frame(width: 900)
    await previews.succeed(1, with: try frame(width: 8))
    await renders.succeed(1, with: changedFrame)
    try await waitUntil { loader.presentation?.frame.image === changedFrame.image }
    #expect(loader.presentation?.request == changed)
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

/// A controllable quiet window avoids elapsed-time assertions. Cancellation is
/// intentionally checked by the loader after the suspended wait returns.
private actor ControlledViewerSettling {
  private(set) var delays: [Duration] = []
  private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

  func wait(_ delay: Duration) async {
    let id = delays.count
    delays.append(delay)
    await withCheckedContinuation { continuations[id] = $0 }
  }

  func release(_ id: Int) {
    continuations.removeValue(forKey: id)?.resume()
  }

  func releaseAll() {
    let pending = continuations.values
    continuations.removeAll()
    for continuation in pending { continuation.resume() }
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
