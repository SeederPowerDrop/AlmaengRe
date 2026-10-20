@preconcurrency import AVFoundation
import Combine
import CoreVideo
import Foundation
import Testing

@testable import ImageViewer

@Suite("영상 재생 위치와 탐색 수명", .serialized)
@MainActor
struct VideoPlaybackStateTests {
  @Test("영상 준비만으로 두 동명 자막을 켜고 전체 화면 전환은 끈 자막을 되살리지 않는다")
  func monitoringAutomaticallyConnectsSubtitles() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let english = fixture.video.deletingPathExtension().appendingPathExtension("en.srt")
    let korean = fixture.video.deletingPathExtension().appendingPathExtension("ko.srt")
    try Data("1\n00:00:00,000 --> 00:00:02,000\nAutomatic English\n".utf8).write(to: english)
    try Data("1\n00:00:00,000 --> 00:00:02,000\n자동 한국어\n".utf8).write(to: korean)

    let first = VideoPlaybackState()
    first.player.isMuted = true
    let monitor = Task { await first.monitor(fixture.asset) }
    defer { monitor.cancel(); first.stop() }
    // No settings view, manual discovery or slot.load() participates here.
    try await waitUntil {
      first.player.currentItem?.status == .readyToPlay
        && first.study?.primary.document != nil && first.study?.secondary.document != nil
        && first.study?.isPreparingAutomaticSubtitles == false
    }
    let session = try #require(first.study)
    #expect(first.player.rate == 0)
    #expect(session.primary.isEnabled && session.secondary.isEnabled)
    #expect(Set([session.primary.sourceURL, session.secondary.sourceURL].compactMap {
      $0?.standardizedFileURL.resolvingSymlinksInPath()
    }) == Set([english, korean].map { $0.standardizedFileURL.resolvingSymlinksInPath() }))
    #expect(Set([session.primary.text(at: 1), session.secondary.text(at: 1)].compactMap { $0 })
      == Set(["Automatic English", "자동 한국어"]))

    let documents = [session.primary.document, session.secondary.document]
    await session.discoverSidecars()
    #expect([session.primary.document, session.secondary.document] == documents)
    session.primary.isEnabled = false
    session.secondary.remove()

    let fullScreen = VideoPlaybackState()
    fullScreen.player.isMuted = true
    let fullScreenMonitor = Task { await fullScreen.monitor(fixture.asset) }
    defer { fullScreenMonitor.cancel(); fullScreen.stop() }
    try await waitUntil { fullScreen.player.currentItem?.status == .readyToPlay }
    #expect(fullScreen.study === session)
    await session.discoverSidecars()
    session.prepareAutomaticSubtitles()
    #expect(!session.isPreparingAutomaticSubtitles)
    #expect(!session.primary.isEnabled && session.primary.document == documents[0])
    #expect(!session.secondary.isEnabled && session.secondary.document == nil)
    #expect(session.secondary.sourceURL == nil)
    #expect(session.primary.text(at: 1) == nil && session.secondary.text(at: 1) == nil)
  }

  @Test("배속 변경은 멈춘 영상을 재생하지 않고 네이티브 재생·탐색 후에도 유지된다")
  func studyRateSurvivesNativePlayAndSeek() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let state = VideoPlaybackState()
    state.player.isMuted = true
    let monitor = Task { await state.monitor(fixture.asset) }
    defer { monitor.cancel(); state.stop() }
    try await waitUntil { state.player.currentItem?.status == .readyToPlay }
    let session = try #require(state.study)
    session.playbackRate = 0.5
    #expect(state.player.rate == 0)
    #expect(state.player.defaultRate == 0.5)
    // AVKit's native play button calls this method, not our SwiftUI command.
    state.player.play()
    try await waitUntil { state.player.currentTime().seconds > 0.05 }
    #expect(state.player.rate == 0.5)
    session.playbackRate = 1.5
    #expect(state.player.rate == 1.5)
    state.pause()
    session.playbackRate = 0.75
    #expect(state.player.rate == 0)
    state.play(from: 0.5)
    try await waitUntil { !state.isSeeking && state.player.rate != 0 }
    #expect(state.player.rate == 0.75)
    #expect(state.player.currentTime().seconds >= 0.499)
    #expect(state.player.currentItem?.audioTimePitchAlgorithm == .timeDomain)
    state.stop()
    session.playbackRate = 2
    #expect(state.player.currentItem == nil && state.player.rate == 0)
    #expect(state.study == nil)
  }

  @Test("전체 화면의 새 재생 상태는 같은 영상의 자막·배속 세션을 공유한다")
  func studySessionSharedWithFullScreenState() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let first = VideoPlaybackState()
    let second = VideoPlaybackState()
    let firstMonitor = Task { await first.monitor(fixture.asset) }
    defer { firstMonitor.cancel(); first.stop(); second.stop() }
    try await waitUntil { first.player.currentItem?.status == .readyToPlay }
    let session = try #require(first.study)
    session.playbackRate = 1.25
    session.primary.offsetSeconds = -0.8
    session.secondary.fontSize = 38
    let secondMonitor = Task { await second.monitor(fixture.asset) }
    defer { secondMonitor.cancel() }
    try await waitUntil { second.player.currentItem?.status == .readyToPlay }
    #expect(second.study === session)
    #expect(second.player.defaultRate == 1.25)
    #expect(second.study?.primary.offsetSeconds == -0.8)
    #expect(second.study?.secondary.fontSize == 38)
    first.stop()
    session.playbackRate = 1.5
    #expect(first.player.currentItem == nil)
    #expect(second.player.defaultRate == 1.5 && second.player.rate == 0)
  }

  @Test("멈춘 영상은 표시값을 반복 발행하지 않고 새 탐색만 화면을 갱신한다")
  func pausedMonitoringDoesNotInvalidateTheView() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let state = VideoPlaybackState()
    let monitor = Task { await state.monitor(fixture.asset) }
    defer { monitor.cancel(); state.stop() }
    try await waitUntil { state.canStepForward }

    var changes = 0
    let subscription = state.objectWillChange.sink { changes += 1 }
    defer { subscription.cancel() }
    // At least five monitor ticks pass. Previously each tick published four
    // unchanged properties, refreshing even a paused native player repeatedly.
    try await Task.sleep(for: .milliseconds(360))
    #expect(changes == 0)
    #expect(state.currentSeconds == 0 && !state.isPlaying)

    state.seek(0.75)
    try await waitUntil { !state.isSeeking }
    #expect(changes > 0)
    #expect(abs(state.currentSeconds - 0.75) < 0.000_01)
  }

  @Test("일시정지는 주기적 표시 갱신을 기다리지 않고 실제 재생 시각을 반영한다")
  func pauseCapturesActualPlayerTime() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let state = VideoPlaybackState()
    let monitor = Task { await state.monitor(fixture.asset) }
    defer { monitor.cancel(); state.stop() }
    try await waitUntil { state.player.currentItem?.status == .readyToPlay }

    state.togglePlayback()
    try await waitUntil { state.player.currentTime().seconds > 0.25 }
    state.pause()
    let paused = state.player.currentTime().seconds
    #expect(paused > 0.25)
    // Separate AVPlayer clock reads may settle a few microseconds apart. One
    // millisecond is well below a frame or the 60ms UI monitor interval.
    #expect(abs(state.currentSeconds - paused) < 0.001)
    #expect(!state.isPlaying && state.player.rate == 0)
  }

  @Test("완료되지 않은 탐색 중 프레임 이동을 막고 마지막 탐색 위치를 사용한다")
  func latestSeekWinsAndSteppingWaits() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let state = VideoPlaybackState()
    let monitor = Task { await state.monitor(fixture.asset) }
    defer { monitor.cancel(); state.stop() }
    try await waitUntil { state.canStepForward }

    // Do not yield between requests: their completion callbacks must wait for
    // this main-actor turn, so the first seek is definitely still pending.
    state.seek(0.5)
    #expect(state.isSeeking)
    #expect(!state.canStepForward && !state.canStepBackward)
    state.step(1)
    state.togglePlayback()
    #expect(state.player.rate == 0)
    state.seek(1.25)
    #expect(state.isSeeking)
    try await waitUntil { !state.isSeeking }
    #expect(abs(state.player.currentTime().seconds - 1.25) < 0.000_01)
    #expect(abs(state.currentSeconds - state.player.currentTime().seconds) < 0.000_001)
    #expect(state.canStepForward)
  }

  @Test("전체 화면에 넘긴 위치로 먼저 이동한 뒤 그 시점부터 재생한다")
  func fullScreenHandoffSeeksBeforePlaying() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let state = VideoPlaybackState()
    let monitor = Task { await state.monitor(fixture.asset) }
    defer { monitor.cancel(); state.stop() }
    try await waitUntil { state.canStepForward }

    state.play(from: 0.75)
    // Until the seek finishes, frame zero must not start playing or sounding.
    #expect(state.isSeeking && state.player.rate == 0)
    #expect(state.currentSeconds == 0.75)
    try await waitUntil { !state.isSeeking && state.player.rate != 0 }
    #expect(state.player.currentTime().seconds >= 0.75 - 0.001)
    try await waitUntil { state.player.currentTime().seconds > 0.85 }
    #expect(state.player.rate != 0)
  }

  @Test("전체 화면 시작 위치로 이동 중 일시정지하면 탐색 완료가 재생을 되살리지 않는다")
  func pauseDuringHandoffCancelsDeferredPlayback() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let state = VideoPlaybackState()
    let monitor = Task { await state.monitor(fixture.asset) }
    defer { monitor.cancel(); state.stop() }
    try await waitUntil { state.canStepForward }

    // Do not yield before pausing: the seek callback is still pending on the
    // main actor, matching dismissal while fullscreen is preparing its frame.
    state.play(from: 1.25)
    #expect(state.isSeeking)
    state.pause()
    try await waitUntil { !state.isSeeking }
    try await Task.sleep(for: .milliseconds(100))
    #expect(state.player.rate == 0 && !state.isPlaying)
    #expect(abs(state.player.currentTime().seconds - 1.25) < 0.000_01)
    #expect(abs(state.currentSeconds - 1.25) < 0.000_01)
  }

  @Test("중단한 파일의 탐색 완료가 정리된 상태나 새 플레이어 항목을 되살리지 않는다")
  func stoppingInvalidatesPendingSeek() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let state = VideoPlaybackState()
    let firstMonitor = Task { await state.monitor(fixture.asset) }
    defer { firstMonitor.cancel(); state.stop() }
    try await waitUntil { state.player.currentItem?.status == .readyToPlay }
    state.seek(1.5)
    #expect(state.isSeeking)
    state.stop()
    firstMonitor.cancel()
    await firstMonitor.value
    #expect(!state.isSeeking && state.currentSeconds == 0)
    #expect(state.document == nil && state.player.currentItem == nil)

    let secondMonitor = Task { await state.monitor(fixture.asset) }
    defer { secondMonitor.cancel(); state.stop() }
    try await waitUntil { state.player.currentItem?.status == .readyToPlay }
    state.seek(0.75)
    try await waitUntil { !state.isSeeking }
    #expect(abs(state.currentSeconds - 0.75) < 0.000_01)
    #expect(state.player.rate == 0)
  }

  @Test("재생 중 실패 알림은 준비된 항목도 종료하고 이유를 남기며 이전 항목의 오류는 무시한다")
  func midstreamFailureRemainsVisibleWithoutFailingTheNextItem() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let state = VideoPlaybackState()
    state.player.isMuted = true
    let firstMonitor = Task { await state.monitor(fixture.asset) }
    defer { firstMonitor.cancel(); state.stop() }
    try await waitUntil { state.player.currentItem?.status == .readyToPlay }
    let oldItem = try #require(state.player.currentItem)
    state.resume()
    try await waitUntil { state.player.currentTime().seconds > 0.05 }

    // This notification may be the only terminal signal from AVFoundation;
    // item.status need not change from readyToPlay. Use the real observer path.
    NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime,
      object: oldItem, userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: AVError(.decoderNotFound)])
    try await waitUntil { state.errorMessage != nil && state.player.currentItem == nil }
    await firstMonitor.value
    #expect(state.errorMessage == MediaLoadFailure.unsupported.message)
    #expect(state.document == nil && state.player.rate == 0 && !state.isPlaying)
    #expect(state.completedPlaybackCount == 0)

    let nextMonitor = Task { await state.monitor(fixture.asset) }
    defer { nextMonitor.cancel() }
    try await waitUntil { state.player.currentItem?.status == .readyToPlay }
    let nextItem = try #require(state.player.currentItem)
    #expect(nextItem !== oldItem && state.errorMessage == nil)
    NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime,
      object: oldItem, userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: AVError(.decodeFailed)])
    // Buffering and user-driven cancellation must not turn into a terminal
    // failure. The new item's real playback confirms all three were ignored.
    NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: nextItem)
    NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime,
      object: nextItem, userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: AVError(.operationCancelled)])
    state.resume()
    try await waitUntil { state.player.currentTime().seconds > 0.2 }
    #expect(state.errorMessage == nil && state.player.currentItem === nextItem)
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !predicate(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(predicate(), "AVPlayer did not reach the expected state before the deadline")
  }

  private struct Fixture: Sendable {
    let folder: URL
    let video: URL
    var asset: ImageAsset { ImageAsset(url: video, byteCount: nil, modificationDate: nil) }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    static func make() async throws -> Self {
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("video-playback-\(UUID())", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
      let fixture = Self(folder: folder, video: folder.appendingPathComponent("synthetic.mov"))
      do { try await fixture.writeMovie() }
      catch { fixture.remove(); throw error }
      return fixture
    }

    private func writeMovie() async throws {
      let writer = try AVAssetWriter(outputURL: video, fileType: .mov)
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 96, AVVideoHeightKey: 64,
        AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false],
      ])
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
          kCVPixelBufferWidthKey as String: 96, kCVPixelBufferHeightKey as String: 64,
        ])
      try #require(writer.canAdd(input))
      writer.add(input)
      try #require(writer.startWriting())
      writer.startSession(atSourceTime: .zero)
      do {
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 96, 64,
          kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixels))
        base.assumingMemoryBound(to: UInt32.self).initialize(repeating: 0xFF_40_80_C0,
          count: CVPixelBufferGetBytesPerRow(pixels) * 64 / 4)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let deadline = ContinuousClock.now + .seconds(10)
        for frame in 0..<24 {
          while !input.isReadyForMoreMediaData, writer.status == .writing, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
          }
          try #require(input.isReadyForMoreMediaData)
          try #require(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 24, timescale: 12))
        await writer.finishWriting()
        try #require(writer.status == .completed, "\(String(describing: writer.error))")
      } catch {
        writer.cancelWriting()
        throw error
      }
    }
  }
}
