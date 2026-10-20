import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import ImageViewer

@MainActor
@Suite("영상 포스터의 원본 버전·크기·표시 수명", .serialized)
struct VideoPosterLoaderTests {
  @Test("메타데이터는 디코딩 identity가 아니며 픽셀 요청은 기존 256~1024 범위에서 묶인다")
  func requestIdentityPreservesSourceAndSize() {
    let original = asset()
    var enriched = original
    enriched.location = ImageLocation(latitude: 37, longitude: 127)
    enriched.hasReadLocation = true
    enriched.photoMarkIdentity = "enriched"
    enriched.sortMetadata = LibrarySortMetadata(cameraMake: "Apple")
    let before = VideoTilePosterRequest(asset: original, maxPixelSize: 300)
    let after = VideoTilePosterRequest(asset: enriched, maxPixelSize: 380)
    #expect(original != enriched && before == after)
    #expect(Set([before, after]).count == 1)
    #expect(before.maxPixelSize == 384)
    #expect(VideoTilePosterRequest(asset: original, maxPixelSize: -1).maxPixelSize == 256)
    #expect(VideoTilePosterRequest(asset: original, maxPixelSize: 9_000).maxPixelSize == 1_024)
    #expect(before != VideoTilePosterRequest(asset: original, maxPixelSize: 512))
    #expect(before != VideoTilePosterRequest(asset: asset(bytes: 11), maxPixelSize: 300))
    #expect(before != VideoTilePosterRequest(asset: asset(modified: 101), maxPixelSize: 300))
  }

  @Test("진행 중·완료 후 메타데이터 갱신은 포스터를 지우거나 재요청하지 않고 최신 callback 정보를 쓴다")
  func metadataEnrichmentReusesPendingAndAcceptedBitmap() async throws {
    let loader = VideoPosterLoader()
    defer { loader.stop() }
    let previews = ControlledVideoPosters()
    let renders = ControlledVideoPosters()
    let original = asset()
    var enriched = original
    enriched.location = ImageLocation(latitude: 37, longitude: 127)
    let bitmap = try image(512)
    var oldReady: [ImageAsset] = []
    var newReady: [ImageAsset] = []
    var displayed: [ImageAsset?] = []
    load(original, pixels: 512, into: loader, previews: previews, renders: renders,
      ready: { oldReady.append($0) }, displayed: { displayed.append($0) })
    try await wait { await previews.starts.count == 1 }
    load(enriched, pixels: 512, into: loader, previews: previews, renders: renders,
      ready: { newReady.append($0) }, displayed: { displayed.append($0) })
    #expect(displayed.count == 1 && displayed[0] == nil)
    #expect(await previews.starts.count == 1)
    await previews.succeed(0, bitmap)
    try await wait { loader.presentation?.image === bitmap }
    #expect(loader.presentation?.request.asset == enriched)
    #expect(oldReady.isEmpty && newReady == [enriched])
    #expect(displayed.last! == enriched)

    var later = enriched
    later.sortMetadata = LibrarySortMetadata(cameraMake: "Apple", cameraModel: "iPhone")
    load(later, pixels: 512, into: loader, previews: previews, renders: renders,
      ready: { newReady.append($0) }, displayed: { displayed.append($0) })
    await drain()
    #expect(loader.presentation?.image === bitmap)
    #expect(loader.presentation?.request.asset == later)
    #expect(displayed.count == 3 && displayed.last! == later)
    #expect(newReady == [enriched], "Refreshing EXIF must not restart slideshow readiness")
    #expect(await previews.starts.count == 1)
    #expect(await renders.starts.isEmpty)
  }

  @Test("타일 확대는 기존 포스터를 유지하고 새 크기를 보완하며 축소는 같은 큰 비트맵을 쓴다")
  func enlargementKeepsBitmapUntilPreciseReplacement() async throws {
    let loader = VideoPosterLoader()
    defer { loader.stop() }
    let previews = ControlledVideoPosters()
    let renders = ControlledVideoPosters()
    let source = asset()
    let compact = try image(256), precise = try image(1_024)
    var ready = 0, cleared = 0
    func show(_ pixels: Int) {
      load(source, pixels: pixels, into: loader, previews: previews, renders: renders,
        ready: { _ in ready += 1 }, displayed: { if $0 == nil { cleared += 1 } })
    }
    show(256)
    try await wait { await previews.starts.count == 1 }
    await previews.succeed(0, compact)
    try await wait { loader.presentation?.image === compact }
    show(900)
    try await wait { await renders.starts.count == 1 }
    #expect(loader.presentation?.image === compact)
    #expect(await renders.starts[0].maxPixelSize == 1_024)
    #expect(await previews.starts.count == 1)
    await renders.succeed(0, precise)
    try await wait { loader.presentation?.image === precise }
    #expect(loader.presentation?.fulfilledPixelSize == 1_024)
    show(300)
    await drain()
    #expect(loader.presentation?.image === precise)
    #expect(await previews.starts.count == 1)
    #expect(await renders.starts.count == 1)
    #expect(ready == 1 && cleared == 1)
  }

  @Test("작은 캐시 미리보기는 정밀 완료로 오인하지 않으며 작은 원본의 정밀 완료도 반복하지 않는다")
  func smallCachedPreviewRequiresExactRequestOnce() async throws {
    let loader = VideoPosterLoader()
    defer { loader.stop() }
    let previews = ControlledVideoPosters()
    let renders = ControlledVideoPosters()
    let source = asset()
    let cached = try image(128), native = try image(640)
    load(source, pixels: 1_024, into: loader, previews: previews, renders: renders)
    try await wait { await previews.starts.count == 1 }
    await previews.succeed(0, cached)
    try await wait { await renders.starts.count == 1 }
    #expect(loader.presentation?.image === cached)
    #expect(loader.presentation?.fulfilledPixelSize == 0)
    #expect(await renders.starts[0].maxPixelSize == 1_024)
    // The exact path can return the movie's native dimensions below the limit.
    await renders.succeed(0, native)
    try await wait { loader.presentation?.image === native }
    #expect(loader.presentation?.fulfilledPixelSize == 1_024)
    var enriched = source; enriched.hasReadLocation = true
    load(enriched, pixels: 896, into: loader, previews: previews, renders: renders)
    await drain()
    #expect(loader.presentation?.image === native)
    #expect(await previews.starts.count == 1)
    #expect(await renders.starts.count == 1)
  }

  @Test("크기나 수정일이 바뀐 같은 URL은 옛 비트맵을 버리고 늦은 결과를 거부한다", arguments: [false, true])
  func sourceReplacementRejectsLateResult(changeDate: Bool) async throws {
    let loader = VideoPosterLoader()
    defer { loader.stop() }
    let previews = ControlledVideoPosters(), renders = ControlledVideoPosters()
    let original = asset()
    let replacement = changeDate ? asset(modified: 101) : asset(bytes: 11)
    let old = try image(512), current = try image(512)
    var ready: [ImageAsset] = []
    load(original, pixels: 512, into: loader, previews: previews, renders: renders,
      ready: { ready.append($0) })
    try await wait { await previews.starts.count == 1 }
    load(replacement, pixels: 512, into: loader, previews: previews, renders: renders,
      ready: { ready.append($0) })
    try await wait { await previews.starts.count == 2 }
    #expect(loader.presentation == nil)
    await previews.succeed(1, current)
    try await wait { loader.presentation?.image === current }
    await previews.succeed(0, old)
    try await wait { await previews.completions.count == 2 }
    #expect(loader.presentation?.request.asset == replacement)
    #expect(loader.presentation?.image === current && ready == [replacement])
    #expect(await previews.cancelled == [0])
  }

  @Test("연속 확대에서 취소된 중간 크기 결과는 새 정밀 포스터를 덮지 않는다")
  func cancelledResizeCannotDowngradeLatestBitmap() async throws {
    let loader = VideoPosterLoader()
    defer { loader.stop() }
    let previews = ControlledVideoPosters(), renders = ControlledVideoPosters()
    let source = asset()
    let first = try image(256), middle = try image(512), latest = try image(1_024)
    load(source, pixels: 256, into: loader, previews: previews, renders: renders)
    try await wait { await previews.starts.count == 1 }
    await previews.succeed(0, first)
    try await wait { loader.presentation?.image === first }
    load(source, pixels: 512, into: loader, previews: previews, renders: renders)
    try await wait { await renders.starts.count == 1 }
    load(source, pixels: 1_024, into: loader, previews: previews, renders: renders)
    try await wait { await renders.starts.count == 2 }
    #expect(loader.presentation?.image === first)
    await renders.succeed(1, latest)
    try await wait { loader.presentation?.image === latest }
    await renders.succeed(0, middle)
    try await wait { await renders.completions.count == 2 }
    #expect(loader.presentation?.image === latest)
    #expect(loader.presentation?.fulfilledPixelSize == 1_024)
    #expect(await renders.cancelled == [0])
  }

  @Test("이미 표시한 파일이 교체되면 이전 포스터를 새 파일의 표지로 남기지 않는다")
  func replacementClearsAlreadyAcceptedPoster() async throws {
    let loader = VideoPosterLoader()
    defer { loader.stop() }
    let previews = ControlledVideoPosters(), renders = ControlledVideoPosters()
    let original = asset(), replacement = asset(bytes: 11)
    let old = try image(512), current = try image(512)
    var displayed: [ImageAsset?] = []
    func show(_ source: ImageAsset) {
      load(source, pixels: 512, into: loader, previews: previews, renders: renders,
        displayed: { displayed.append($0) })
    }
    show(original)
    try await wait { await previews.starts.count == 1 }
    await previews.succeed(0, old)
    try await wait { loader.presentation?.image === old }
    show(replacement)
    #expect(loader.presentation == nil)
    #expect(displayed.count == 3 && displayed.last! == nil)
    try await wait { await previews.starts.count == 2 }
    await previews.succeed(1, current)
    try await wait { loader.presentation?.image === current }
    #expect(displayed.last! == replacement)
  }

  @Test("영상에서 오디오로 바뀌면 포스터 요청 없이 준비되고 옛 영상 결과가 덮지 않는다")
  func audioTransitionCancelsVideoAndCanReturnToVideo() async throws {
    let loader = VideoPosterLoader()
    defer { loader.stop() }
    let previews = ControlledVideoPosters(), renders = ControlledVideoPosters()
    let video = asset(), audio = asset(name: "audio.m4a")
    let bitmap = try image(512)
    var ready: [ImageAsset] = []
    func show(_ source: ImageAsset) {
      load(source, pixels: 512, into: loader, previews: previews, renders: renders,
        ready: { ready.append($0) })
    }
    show(video)
    try await wait { await previews.starts.count == 1 }
    show(audio)
    #expect(loader.presentation?.request.asset == audio && loader.presentation?.image == nil)
    #expect(ready == [audio])
    #expect(await previews.starts.count == 1)
    #expect(await renders.starts.isEmpty)
    await previews.succeed(0, bitmap)
    try await wait { await previews.completions.count == 1 }
    #expect(loader.presentation?.request.asset == audio)
    show(video)
    try await wait { await previews.starts.count == 2 }
    await previews.succeed(1, bitmap)
    try await wait { loader.presentation?.image === bitmap }
    #expect(ready == [audio, video])
  }

  @Test("사라진 타일의 늦은 포스터는 표시·callback을 되살리지 않고 같은 파일 재진입도 안전하다")
  func stopAndRestartRejectsPreviousLifetime() async throws {
    let loader = VideoPosterLoader()
    defer { loader.stop() }
    let previews = ControlledVideoPosters(), renders = ControlledVideoPosters()
    let source = asset(), bitmap = try image(512)
    var ready = 0
    func show() { load(source, pixels: 512, into: loader, previews: previews,
      renders: renders, ready: { _ in ready += 1 }) }
    show()
    try await wait { await previews.starts.count == 1 }
    loader.stop()
    show()
    try await wait { await previews.starts.count == 2 }
    await previews.succeed(0, bitmap)
    try await wait { await previews.completions.count == 1 }
    #expect(loader.presentation == nil && ready == 0)
    await previews.succeed(1, bitmap)
    try await wait { loader.presentation?.image === bitmap }
    #expect(ready == 1 && loader.errorMessage == nil)
    #expect(await previews.cancelled == [0])
  }

  @Test("미리보기와 정밀 보완의 실패는 사용 가능한 포스터를 지우지 않는다")
  func refinementFailureKeepsUsablePoster() async throws {
    let loader = VideoPosterLoader(failureReason: { _, _ in "controlled failure" })
    defer { loader.stop() }
    let previews = ControlledVideoPosters(), renders = ControlledVideoPosters()
    let source = asset(), bitmap = try image(256)
    load(source, pixels: 768, into: loader, previews: previews, renders: renders)
    try await wait { await previews.starts.count == 1 }
    await previews.succeed(0, bitmap)
    try await wait { await renders.starts.count == 1 }
    await renders.fail(0)
    try await wait { await renders.completions.count == 1 }
    await drain()
    #expect(loader.presentation?.image === bitmap && loader.errorMessage == nil)

    let replacement = asset(bytes: 11)
    load(replacement, pixels: 768, into: loader, previews: previews, renders: renders)
    try await wait { await previews.starts.count == 2 }
    await previews.fail(1)
    try await wait { await renders.starts.count == 2 }
    await renders.fail(1)
    try await wait { loader.errorMessage != nil }
    #expect(loader.presentation == nil && loader.errorMessage == "controlled failure")
  }

  @Test("메타데이터·페이지 크기·사라짐이 겹친 연속 이동도 마지막 파일과 callback만 표시한다")
  func metadataResizeAndVisibilityChurnRejectsEveryOldCompletion() async throws {
    let loader = VideoPosterLoader()
    defer { loader.stop() }
    let previews = ControlledVideoPosters(), renders = ControlledVideoPosters()
    var source = asset()
    var ready: [ImageAsset] = []
    func show(_ pixels: Int) {
      load(source, pixels: pixels, into: loader, previews: previews, renders: renders,
        ready: { ready.append($0) })
    }
    show(1_024)
    try await wait { await previews.starts.count == 1 }
    source.location = ImageLocation(latitude: 37, longitude: 127)
    show(1_024) // Metadata while the first poster is pending: no new request.
    show(512)
    try await wait { await previews.starts.count == 2 }
    loader.stop()
    show(256)
    try await wait { await previews.starts.count == 3 }
    source.sortMetadata = LibrarySortMetadata(cameraMake: "Apple", cameraModel: "latest")
    show(256)
    show(768)
    try await wait { await previews.starts.count == 4 }
    let accepted = try image(768)
    await previews.succeed(3, accepted)
    try await wait { loader.presentation?.image === accepted }
    #expect(ready == [source])
    for index in [1, 0, 2] { await previews.succeed(index, try image(1_024)) }
    try await wait { await previews.completions.count == 4 }
    #expect(loader.presentation?.image === accepted)
    #expect(loader.presentation?.request.asset == source)
    #expect(await Set(previews.cancelled) == Set([0, 1, 2]))

    show(256) // A smaller page borrows the accepted 768px poster.
    show(1_024)
    try await wait { await renders.starts.count == 1 }
    source.photoMarkIdentity = "latest-callback-metadata"
    show(1_024)
    #expect(loader.presentation?.image === accepted)
    #expect(loader.presentation?.request.asset == source)
    loader.stop()
    show(384)
    try await wait { await previews.starts.count == 5 }
    let reentered = try image(384)
    await previews.succeed(4, reentered)
    try await wait { loader.presentation?.image === reentered }
    await renders.succeed(0, try image(1_024))
    try await wait { await renders.completions.count == 1 }
    #expect(loader.presentation?.image === reentered)
    #expect(loader.presentation?.request.asset == source)
    #expect(ready.last == source && ready.count == 2)
    #expect(await renders.cancelled == [0])
  }

  @Test("타일이 해제되면 느린 포스터 요청도 취소되고 loader를 붙잡지 않는다")
  func deinitCancelsWorkWithoutRetainingLoader() async throws {
    let previews = ControlledVideoPosters(), renders = ControlledVideoPosters()
    let bitmap = try image(512)
    var loader: VideoPosterLoader? = VideoPosterLoader()
    weak var reference = loader
    load(asset(), pixels: 512, into: try #require(loader), previews: previews, renders: renders)
    try await wait { await previews.starts.count == 1 }
    loader = nil
    #expect(reference == nil)
    await previews.succeed(0, bitmap)
    try await wait { await previews.completions.count == 1 }
    #expect(await previews.cancelled == [0])
  }

  @Test("확정적인 원본·코덱·트랙 실패는 같은 native 포스터를 두 번 시도하지 않고 재진입은 복구할 수 있다",
    arguments: TerminalVideoPosterFailure.allCases)
  func terminalPreviewDoesNotDuplicateNativeDecode(kind: TerminalVideoPosterFailure) async throws {
    let calls = VideoPosterAttemptCounts()
    let loader = VideoPosterLoader(failureReason: { _, _ in await calls.failureMessage() })
    defer { loader.stop() }
    let source = asset(), bitmap = try image(512)
    let request = VideoTilePosterRequest(asset: source, maxPixelSize: 512)
    let error = kind.error(url: source.url)
    loader.load(request, preview: { _ in
      await calls.notePreview(); throw error
    }, render: { _ in
      await calls.noteRender(); return bitmap
    })
    try await wait { loader.errorMessage == "controlled failure" }
    #expect(await calls.preview == 1)
    #expect(await calls.render == 0)
    #expect(await calls.reason == 1)
    #expect(loader.presentation == nil)
    // No unsupported-codec result is kept across a new visible lifetime.
    loader.stop()
    loader.load(request, preview: { _ in
      await calls.notePreview(); return bitmap
    }, render: { _ in
      await calls.noteRender(); return bitmap
    })
    try await wait { loader.presentation?.image === bitmap }
    #expect(loader.errorMessage == nil)
    #expect(await calls.preview == 2)
    #expect(await calls.render == 0)
  }

  @Test("캐시 미리보기 실패·알 수 없는 오류·일시적인 디코더 부족은 정밀 포스터로 이어 시도한다",
    arguments: RetryableVideoPosterFailure.allCases)
  func retryablePreviewStillReachesExactPoster(kind: RetryableVideoPosterFailure) async throws {
    let calls = VideoPosterAttemptCounts()
    let loader = VideoPosterLoader(failureReason: { _, _ in await calls.failureMessage() })
    defer { loader.stop() }
    let source = asset(), bitmap = try image(512)
    let error = kind.error(url: source.url)
    loader.load(VideoTilePosterRequest(asset: source, maxPixelSize: 512), preview: { _ in
      await calls.notePreview(); throw error
    }, render: { _ in
      await calls.noteRender(); return bitmap
    })
    try await wait { loader.presentation?.image === bitmap }
    #expect(loader.errorMessage == nil)
    #expect(await calls.preview == 1)
    #expect(await calls.render == 1)
    #expect(await calls.reason == 0)
    #expect(loader.presentation?.fulfilledPixelSize == 512)
  }

  @Test("Swift·native·underlying 취소는 정밀 재시도나 오류 표시를 시작하지 않는다",
    arguments: VideoPosterCancellation.allCases)
  func previewCancellationNeverStartsFallback(kind: VideoPosterCancellation) async throws {
    let calls = VideoPosterAttemptCounts()
    let loader = VideoPosterLoader(failureReason: { _, _ in await calls.failureMessage() })
    defer { loader.stop() }
    let error = kind.error
    let bitmap = try image(512)
    loader.load(VideoTilePosterRequest(asset: asset(), maxPixelSize: 512), preview: { _ in
      await calls.notePreview(); throw error
    }, render: { _ in
      await calls.noteRender(); return bitmap
    })
    try await wait { await calls.preview == 1 }
    await drain()
    #expect(await calls.render == 0)
    #expect(await calls.reason == 0)
    #expect(loader.presentation == nil && loader.errorMessage == nil)
  }

  @Test("정밀 보완의 native 취소는 표시 중인 포스터나 정상 오류 상태를 바꾸지 않는다")
  func nativeRefinementCancellationKeepsPreview() async throws {
    let calls = VideoPosterAttemptCounts()
    let loader = VideoPosterLoader(failureReason: { _, _ in await calls.failureMessage() })
    defer { loader.stop() }
    let bitmap = try image(256)
    let error = VideoPosterCancellation.native.error
    loader.load(VideoTilePosterRequest(asset: asset(), maxPixelSize: 768), preview: { _ in
      await calls.notePreview(); return bitmap
    }, render: { _ in
      await calls.noteRender(); throw error
    })
    try await wait { await calls.render == 1 }
    await drain()
    #expect(loader.presentation?.image === bitmap && loader.errorMessage == nil)
    #expect(await calls.reason == 0)
  }

  @Test("진단이 없는 일반 실행은 observer를 만들지 않고 기존 표시를 유지한다")
  func ordinaryLoadNeverInstallsDiagnosticObserver() async throws {
    let previous = VideoPosterLoader.diagnosticObserver
    VideoPosterLoader.diagnosticObserver = nil
    let loader = VideoPosterLoader()
    defer { loader.stop(); VideoPosterLoader.diagnosticObserver = previous }
    let bitmap = try image(512)
    loader.load(VideoTilePosterRequest(asset: asset(), maxPixelSize: 512),
      preview: { _ in bitmap }, render: { _ in bitmap })
    try await wait { loader.presentation?.image === bitmap }
    #expect(VideoPosterLoader.diagnosticObserver == nil)
  }

  @Test("진단은 실제 terminal enum만 기록하며 unreadableData를 unsupported로 바꾸지 않는다",
    arguments: TerminalVideoPosterFailure.allCases)
  func diagnosticTerminalFailureUsesTypedReason(kind: TerminalVideoPosterFailure) async throws {
    let source = asset(name: "diagnostic-terminal-\(UUID()).mp4")
    let previous = VideoPosterLoader.diagnosticObserver
    var events: [VideoPosterDiagnosticEvent] = []
    VideoPosterLoader.diagnosticObserver = {
      previous?($0)
      if $0.request.asset.url == source.url { events.append($0) }
    }
    let loader = VideoPosterLoader(failureReason: { _, _ in "localized notice must not enter diagnostics" })
    defer { loader.stop(); VideoPosterLoader.diagnosticObserver = previous }
    let error = kind.error(url: source.url)
    loader.load(VideoTilePosterRequest(asset: source, maxPixelSize: 512),
      preview: { _ in throw error }, render: { _ in throw error })
    try await wait { !events.isEmpty }
    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(event.request.hasSameSource(as: VideoTilePosterRequest(asset: source, maxPixelSize: 256)))
    guard case .terminalFailure(let failure) = event.outcome else {
      Issue.record("An unsuccessful poster cannot announce acceptance"); return
    }
    #expect(failure.kind == (MediaLoadFailure.reason(for: error) ?? .unknown))
    #expect(!failure.errorDomain.contains("localized") && !failure.errorDomain.contains(source.url.path))
    if case .unsupported = kind { #expect(failure.kind == .unreadableData) }
  }

  @Test("진단의 native·Swift 취소는 terminal 실패나 accepted를 남기지 않는다",
    arguments: VideoPosterCancellation.allCases)
  func diagnosticIgnoresCancellation(kind: VideoPosterCancellation) async throws {
    let source = asset(name: "diagnostic-cancel-\(UUID()).mp4")
    let previous = VideoPosterLoader.diagnosticObserver
    var events: [VideoPosterDiagnosticEvent] = []
    VideoPosterLoader.diagnosticObserver = {
      previous?($0)
      if $0.request.asset.url == source.url { events.append($0) }
    }
    let calls = VideoPosterAttemptCounts()
    let loader = VideoPosterLoader(failureReason: { _, _ in await calls.failureMessage() })
    defer { loader.stop(); VideoPosterLoader.diagnosticObserver = previous }
    let error = kind.error
    loader.load(VideoTilePosterRequest(asset: source, maxPixelSize: 512), preview: { _ in
      await calls.notePreview(); throw error
    }, render: { _ in throw error })
    try await wait { await calls.preview == 1 }
    await drain()
    #expect(events.isEmpty && loader.errorMessage == nil)
    #expect(await calls.reason == 0)
  }

  @Test("유지 중인 포스터·메타데이터 갱신은 실패로 집계하지 않는다")
  func diagnosticRetainedPosterIsNeverTerminalFailure() async throws {
    let source = asset(name: "diagnostic-retained-\(UUID()).mp4")
    let previous = VideoPosterLoader.diagnosticObserver
    var events: [VideoPosterDiagnosticEvent] = []
    VideoPosterLoader.diagnosticObserver = {
      previous?($0)
      if $0.request.asset.url == source.url { events.append($0) }
    }
    let loader = VideoPosterLoader(failureReason: { _, _ in "not displayed" })
    defer { loader.stop(); VideoPosterLoader.diagnosticObserver = previous }
    let bitmap = try image(256)
    let error = NSError(domain: AVFoundationErrorDomain, code: AVError.formatUnsupported.rawValue)
    loader.load(VideoTilePosterRequest(asset: source, maxPixelSize: 768),
      preview: { _ in bitmap }, render: { _ in throw error })
    try await wait { loader.presentation?.image === bitmap }
    await drain()
    #expect(events.count == 1 && events.first?.outcome == .accepted)
    var enriched = source; enriched.hasReadLocation = true
    loader.load(VideoTilePosterRequest(asset: enriched, maxPixelSize: 768),
      preview: { _ in bitmap }, render: { _ in throw error })
    await drain()
    #expect(events.count == 1 && loader.errorMessage == nil)
  }

  @Test("교체된 source의 늦은 native 완료는 진단에도 섞이지 않는다")
  func diagnosticRejectsLateSupersededWork() async throws {
    let name = "diagnostic-superseded-\(UUID()).mp4"
    let old = asset(name: name, bytes: 10), current = asset(name: name, bytes: 11)
    let previous = VideoPosterLoader.diagnosticObserver
    var events: [VideoPosterDiagnosticEvent] = []
    VideoPosterLoader.diagnosticObserver = {
      previous?($0)
      if $0.request.asset.url == current.url { events.append($0) }
    }
    let loader = VideoPosterLoader(failureReason: { _, _ in "controlled" })
    let previews = ControlledVideoPosters(), renders = ControlledVideoPosters()
    defer { loader.stop(); VideoPosterLoader.diagnosticObserver = previous }
    load(old, pixels: 512, into: loader, previews: previews, renders: renders)
    try await wait { await previews.starts.count == 1 }
    load(current, pixels: 512, into: loader, previews: previews, renders: renders)
    try await wait { await previews.starts.count == 2 }
    let bitmap = try image(512)
    await previews.succeed(1, bitmap)
    try await wait { events.count == 1 }
    await previews.fail(0)
    await drain()
    #expect(events.count == 1 && events.first?.outcome == .accepted)
    #expect(events.first?.request.asset.byteCount == 11)
  }

  @Test("오류 안내를 기다리던 source가 교체되면 늦은 terminal 진단도 폐기한다")
  func diagnosticRejectsReplacementDuringFailureClassification() async throws {
    let name = "diagnostic-reason-\(UUID()).mp4"
    let old = asset(name: name, bytes: 10), current = asset(name: name, bytes: 11)
    let previous = VideoPosterLoader.diagnosticObserver
    var events: [VideoPosterDiagnosticEvent] = []
    VideoPosterLoader.diagnosticObserver = {
      previous?($0)
      if $0.request.asset.url == current.url { events.append($0) }
    }
    let gate = PosterDiagnosticReasonGate()
    let loader = VideoPosterLoader(failureReason: { _, _ in await gate.wait() })
    defer { loader.stop(); VideoPosterLoader.diagnosticObserver = previous }
    let error = ImagePipelineError.unsupported(old.url)
    loader.load(VideoTilePosterRequest(asset: old, maxPixelSize: 512),
      preview: { _ in throw error }, render: { _ in throw error })
    try await wait { await gate.started }
    let bitmap = try image(512)
    loader.load(VideoTilePosterRequest(asset: current, maxPixelSize: 512),
      preview: { _ in bitmap }, render: { _ in bitmap })
    try await wait { events.count == 1 }
    await gate.complete()
    await drain()
    #expect(events.count == 1 && events.first?.outcome == .accepted)
    #expect(events.first?.request.asset.byteCount == 11 && loader.errorMessage == nil)
  }

  @Test("private 진단 종료는 이전 observer를 복원하고 두 번 종료해도 덮어쓰지 않는다")
  func sustainedObservationRestoresPreviousObserver() {
    let original = VideoPosterLoader.diagnosticObserver
    defer { VideoPosterLoader.diagnosticObserver = original }
    var previousCount = 0, currentCount = 0
    VideoPosterLoader.diagnosticObserver = { _ in previousCount += 1 }
    let observation = SustainedPosterDiagnosticObservation { _ in currentCount += 1 }
    let event = VideoPosterDiagnosticEvent(request: VideoTilePosterRequest(asset: asset(), maxPixelSize: 256), outcome: .accepted)
    VideoPosterLoader.diagnosticObserver?(event)
    #expect(previousCount == 1 && currentCount == 1)
    observation.stop()
    VideoPosterLoader.diagnosticObserver?(event)
    #expect(previousCount == 2 && currentCount == 1)
    VideoPosterLoader.diagnosticObserver = { _ in previousCount += 10 }
    observation.stop()
    VideoPosterLoader.diagnosticObserver?(event)
    #expect(previousCount == 12 && currentCount == 1)
  }

  @Test("개인 문자열이 섞인 사용자 error domain은 진단에서 내보내지 않는다")
  func diagnosticRedactsUnknownErrorDomains() {
    let failure = VideoPosterDiagnosticEvent.Failure(error:
      NSError(domain: "/private/personal-video.mp4", code: 7))
    #expect(failure.kind == .unknown && failure.errorDomain == "other" && failure.errorCode == 7)
  }

  private func load(_ asset: ImageAsset, pixels: Int, into loader: VideoPosterLoader,
    previews: ControlledVideoPosters, renders: ControlledVideoPosters,
    ready: @escaping (ImageAsset) -> Void = { _ in }, displayed: ((ImageAsset?) -> Void)? = nil) {
    loader.load(VideoTilePosterRequest(asset: asset, maxPixelSize: pixels),
      preview: { try await previews.run($0) }, render: { try await renders.run($0) },
      onReady: ready, onDisplayedAssetChange: displayed)
  }
  private func asset(name: String = "movie.mp4", bytes: Int64 = 10, modified: TimeInterval = 100) -> ImageAsset {
    ImageAsset(url: URL(fileURLWithPath: "/video-poster-tests/\(name)"), byteCount: bytes,
      modificationDate: Date(timeIntervalSince1970: modified))
  }
  private func image(_ width: Int) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: max(1, width / 2),
      bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return try #require(context.makeImage())
  }
  private func wait(_ ready: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if await ready() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    throw PosterTestFailure.timeout
  }
  private func drain() async { for _ in 0..<20 { await Task.yield() } }
}

private enum PosterTestFailure: Error { case decode, timeout }

private actor PosterDiagnosticReasonGate {
  private(set) var started = false
  private var continuation: CheckedContinuation<String?, Never>?
  func wait() async -> String? {
    started = true
    return await withCheckedContinuation { continuation = $0 }
  }
  func complete() {
    continuation?.resume(returning: "controlled localized notice")
    continuation = nil
  }
}

enum TerminalVideoPosterFailure: CaseIterable, Sendable {
  case empty, unsupported, noVideoTrack, nativeUnsupported, missingDecoder, invalidNativeData, protectedContent, wrappedUnsupported
  func error(url: URL) -> Error {
    switch self {
    case .empty: ImagePipelineError.emptyFile(url)
    case .unsupported: ImagePipelineError.unsupported(url)
    case .noVideoTrack: VideoProcessingError.noVideoTrack
    case .nativeUnsupported: NSError(domain: AVFoundationErrorDomain, code: AVError.formatUnsupported.rawValue)
    case .missingDecoder: NSError(domain: AVFoundationErrorDomain, code: AVError.decoderNotFound.rawValue)
    case .invalidNativeData: NSError(domain: AVFoundationErrorDomain, code: AVError.fileFormatNotRecognized.rawValue)
    case .protectedContent: VideoProcessingError.protectedContent
    case .wrappedUnsupported: NSError(domain: "PosterWrapper", code: 1,
      userInfo: [NSUnderlyingErrorKey: NSError(domain: AVFoundationErrorDomain, code: AVError.formatUnsupported.rawValue)])
    }
  }
}

enum RetryableVideoPosterFailure: CaseIterable, Sendable {
  case cacheMiss, unknown, temporarilyUnavailable, bitmapCreation
  func error(url: URL) -> Error {
    switch self {
    case .cacheMiss: ThumbnailPipelineError.generationFailed(url)
    case .unknown: PosterTestFailure.decode
    case .temporarilyUnavailable: NSError(domain: AVFoundationErrorDomain, code: AVError.decoderTemporarilyUnavailable.rawValue)
    case .bitmapCreation: ImagePipelineError.renderingFailed(url)
    }
  }
}

enum VideoPosterCancellation: CaseIterable, Sendable {
  case swift, native, wrapped
  var error: Error {
    switch self {
    case .swift: CancellationError()
    case .native: NSError(domain: AVFoundationErrorDomain, code: AVError.operationCancelled.rawValue)
    case .wrapped: NSError(domain: "PosterWrapper", code: 1,
      userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: URLError.cancelled.rawValue)])
    }
  }
}

private actor VideoPosterAttemptCounts {
  private(set) var preview = 0
  private(set) var render = 0
  private(set) var reason = 0
  func notePreview() { preview += 1 }
  func noteRender() { render += 1 }
  func failureMessage() -> String { reason += 1; return "controlled failure" }
}

/// Like AVFoundation, an old native completion may arrive after cancellation.
private actor ControlledVideoPosters {
  private(set) var starts: [VideoTilePosterRequest] = []
  private(set) var completions: [Int] = []
  private(set) var cancelled: [Int] = []
  private var pending: [Int: CheckedContinuation<CGImage, any Error>] = [:]
  func run(_ request: VideoTilePosterRequest) async throws -> CGImage {
    let index = starts.count
    starts.append(request)
    defer { completions.append(index); if Task.isCancelled { cancelled.append(index) } }
    return try await withCheckedThrowingContinuation { pending[index] = $0 }
  }
  func succeed(_ index: Int, _ image: CGImage) {
    guard let continuation = pending.removeValue(forKey: index) else { Issue.record("Missing poster request"); return }
    continuation.resume(returning: image)
  }
  func fail(_ index: Int) {
    guard let continuation = pending.removeValue(forKey: index) else { Issue.record("Missing poster request"); return }
    continuation.resume(throwing: PosterTestFailure.decode)
  }
}
