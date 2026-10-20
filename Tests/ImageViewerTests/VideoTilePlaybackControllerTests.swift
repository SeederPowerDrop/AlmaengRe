@preconcurrency import AVFoundation
import AVKit
import CoreVideo
import Foundation
import SwiftUI
import Testing

@testable import ImageViewer

@Suite("여러 영상 타일의 미리보기 수명", .serialized)
@MainActor
struct VideoTilePlaybackControllerTests {
  @Test("대기 중인 여러 타일과 비활성 앱은 재생 항목이나 영상 문서를 만들지 않는다")
  func idleTilesNeverAllocatePlayers() async throws {
    let coordinator = VideoHoverPlaybackCoordinator()
    let controllers = (0..<10).map { _ in VideoTilePlaybackController(coordinator: coordinator) }
    let missing = ImageAsset(url: URL(fileURLWithPath: "/missing/idle.mov"),
      byteCount: nil, modificationDate: nil)
    for controller in controllers {
      controller.update(asset: missing, isMultiTile: true, isHovered: false,
        allowsPlayback: true, appIsActive: true)
      #expect(controller.playback == nil)
      controller.update(asset: missing, isMultiTile: true, isHovered: true,
        allowsPlayback: true, appIsActive: false)
      #expect(controller.playback == nil)
      controller.update(asset: missing, isMultiTile: true, isHovered: true,
        allowsPlayback: false, appIsActive: true)
      controller.toggleSound()
      #expect(controller.playback == nil && !controller.isSoundEnabled)
    }
    await Task.yield()
    #expect(controllers.allSatisfy { $0.playback == nil })
  }

  @Test("호버는 무음으로 시작하고 소리를 켜면 포인터가 떠나도 재생을 유지한다")
  func explicitSoundSurvivesHoverExit() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let controller = VideoTilePlaybackController(coordinator: VideoHoverPlaybackCoordinator())
    defer { controller.stop() }
    hover(controller, fixture.asset)
    let first = try #require(controller.playback)
    try await waitUntil { first.player.currentTime().seconds > 0.08 }
    #expect(first.document?.hasAudio == true)
    #expect(first.player.isMuted && !controller.isSoundEnabled)
    controller.toggleSound()
    #expect(!first.player.isMuted && controller.isSoundEnabled)
    controller.update(asset: fixture.asset, isMultiTile: true, isHovered: false,
      allowsPlayback: true, appIsActive: true)
    #expect(controller.playback === first && controller.isSoundEnabled)
    #expect(first.player.rate > 0 && !first.player.isMuted)
    controller.stop()
    #expect(controller.playback == nil && !controller.isSoundEnabled)
    #expect(first.player.currentItem == nil && first.document == nil)
    #expect(first.player.isMuted && first.player.rate == 0)

    hover(controller, fixture.asset)
    let second = try #require(controller.playback)
    #expect(second !== first && second.player.isMuted)
    try await waitUntil { second.document != nil }
    controller.update(asset: fixture.asset, isMultiTile: true, isHovered: true,
      allowsPlayback: true, appIsActive: false)
    #expect(controller.playback == nil && second.player.currentItem == nil)
    #expect(second.document == nil && second.player.isMuted)
  }

  @Test("새 호버 소유자는 이전 재생을 즉시 끝내고 늦은 로딩이 되살리지 않는다")
  func onlyOneHoverOwnerAndNoStaleLoading() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let coordinator = VideoHoverPlaybackCoordinator()
    let first = VideoTilePlaybackController(coordinator: coordinator)
    let second = VideoTilePlaybackController(coordinator: coordinator)
    defer { first.stop(); second.stop() }
    hover(first, fixture.asset)
    let discarded = try #require(first.playback)
    // Claim another tile before the first metadata load gets an actor turn.
    hover(second, fixture.asset)
    #expect(first.playback == nil && discarded.player.currentItem == nil)
    let active = try #require(second.playback)
    try await waitUntil { active.player.currentTime().seconds > 0.08 }
    #expect(first.playback == nil && discarded.document == nil)
    #expect(active.player.isMuted)
    second.toggleSound()
    first.toggleSound()
    #expect(second.isSoundEnabled && !first.isSoundEnabled)
    #expect(!active.player.isMuted && discarded.player.isMuted)

    let changed = ImageAsset(url: fixture.root.appendingPathComponent("missing.mov"),
      byteCount: nil, modificationDate: nil)
    second.update(asset: changed, isMultiTile: true, isHovered: false,
      allowsPlayback: true, appIsActive: true)
    #expect(second.playback == nil && active.player.currentItem == nil)
    #expect(active.document == nil && active.player.isMuted)
  }

  @Test("한 장 보기 영상은 정지 상태로 시작하고 비활성화 뒤 위치를 보존한다")
  func singlePlayerStartsPausedAndSuspendsWithoutLosingPosition() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let controller = VideoTilePlaybackController(coordinator: VideoHoverPlaybackCoordinator())
    defer { controller.stop() }
    controller.update(asset: fixture.asset, isMultiTile: false, isHovered: false,
      allowsPlayback: true, appIsActive: true)
    let state = try #require(controller.playback)
    try await waitUntil { state.canStepForward }
    #expect(state.player.rate == 0 && state.currentSeconds == 0)
    state.seek(0.5)
    try await waitUntil { !state.isSeeking }
    state.togglePlayback()
    try await waitUntil { state.player.currentTime().seconds > 0.6 }
    controller.update(asset: fixture.asset, isMultiTile: false, isHovered: false,
      allowsPlayback: false, appIsActive: true)
    #expect(controller.playback === state && state.player.rate == 0)
    let paused = state.currentSeconds
    #expect(paused > 0.6)
    controller.update(asset: fixture.asset, isMultiTile: false, isHovered: false,
      allowsPlayback: true, appIsActive: true)
    #expect(controller.playback === state && state.player.rate == 0)
    let fullScreen = controller.pauseForFullScreen()
    #expect(abs(fullScreen.seconds - paused) < 0.002)
    #expect(!fullScreen.isMuted)
    controller.stop()
    #expect(state.player.currentItem == nil && state.document == nil)
    #expect(!controller.pauseForFullScreen().isMuted)
  }

  @Test("다음 페이지에 영상 하나만 남아도 모두 재생과 일시정지가 실제 플레이어에 적용된다")
  func finalSingleVideoFollowsGridCommandsWithoutOverridingNativeControls() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let grid = VideoGridPlaybackState()
    let previous = ImageAsset(url: fixture.root.appendingPathComponent("previous.mp4"),
      byteCount: nil, modificationDate: nil)
    grid.updateVisibleAssets([previous])
    grid.playAll()
    grid.playAll()
    grid.updateVisibleAssets([fixture.asset])
    try #require(grid.followsPages && grid.playingIDs == [fixture.asset.id])
    let controller = VideoTilePlaybackController(coordinator: VideoHoverPlaybackCoordinator())
    defer { controller.stop() }
    func update(hovered: Bool = false) {
      controller.update(asset: fixture.asset, isMultiTile: false, isHovered: hovered,
        allowsPlayback: true, appIsActive: true, command: grid.command(for: fixture.asset.id))
    }
    update()
    let state = try #require(controller.playback)
    try await waitUntil(phase: "last-page single video autoplay") { state.currentSeconds > 0.08 }
    #expect(state.player.isMuted && state.player.rate > 0)

    // This one-tile layout exposes native controls. Hover/metadata refresh must
    // not undo an explicit native pause or sound choice on the same command.
    state.pause()
    state.player.isMuted = false
    let pausedPosition = state.currentSeconds
    update(hovered: true)
    #expect(state.player.rate == 0 && !state.player.isMuted)
    grid.pauseAll()
    update()
    #expect(state.player.rate == 0 && state.player.isMuted && !grid.followsPages)
    grid.playAll()
    update()
    try await waitUntil(phase: "single video resumes after grid play") {
      state.currentSeconds > pausedPosition + 0.04 && state.player.rate > 0
    }
    grid.pauseAll()
    update()
    #expect(state.player.rate == 0 && controller.playback === state)
  }

  @Test("실제 영상 타일을 화면에서 제거하면 재생 중인 플레이어 항목도 해제한다")
  func removingHostedTileReleasesItsPlayingItem() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    _ = NSApplication.shared
    var didShowPoster = false
    let host = NSHostingView(rootView: AnyView(VideoViewerTile(asset: fixture.asset,
      itemCount: 1, thumbnailPipeline: ThumbnailPipeline(), allowsPlayback: true,
      onOpenTools: {}, onOpenFullScreen: { _, _ in }, onReady: { _ in didShowPoster = true })))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 640, height: 420),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    try await waitUntil { host.layoutSubtreeIfNeeded(); return didShowPoster }
    // Deliver the real lifecycle input without stealing focus from another app.
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    try await waitUntil {
      host.layoutSubtreeIfNeeded()
      return nativePlayer(in: host)?.player?.currentItem?.status == .readyToPlay
    }
    let player = try #require(nativePlayer(in: host)?.player)
    defer { player.pause(); player.replaceCurrentItem(with: nil) }
    player.isMuted = true
    player.play()
    try await waitUntil { player.currentTime().seconds > 0.08 }

    // Replacing the actual SwiftUI subtree must run onDisappear; calling the
    // controller's stop() here would miss the view-lifecycle regression.
    host.rootView = AnyView(Color.clear)
    try await waitUntil { host.layoutSubtreeIfNeeded(); return player.currentItem == nil }
    #expect(player.rate == 0)
    #expect(nativePlayer(in: host) == nil)
  }

  @Test("전체 화면 창 종료는 재생 항목을 해제하고 닫힘 알림을 한 번만 보낸다")
  func closingFullScreenWindowReleasesPlaybackOnce() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    _ = NSApplication.shared
    var closeCount = 0
    let controller = VideoFullScreenController(asset: fixture.asset, seconds: 0.25,
      isMuted: true, onClose: { closeCount += 1 })
    let window = try #require(controller.window)
    window.setFrameOrigin(NSPoint(x: -2_000, y: -2_000))
    window.orderBack(nil)
    defer { window.orderOut(nil); window.close(); controller.playback.stop() }
    // macOS can refuse a Spaces transition. Exercise that supported playback
    // path, then use the real NSWindow close/delegate sequence for teardown.
    controller.windowDidFailToEnterFullScreen(window)
    try await waitUntil { controller.playback.player.currentItem?.status == .readyToPlay }
    // Even when backgrounding prevents autoplay, manual playback must retain
    // the mute choice handed over by the poster/preview.
    #expect(controller.playback.player.isMuted)
    controller.playback.togglePlayback()
    try await waitUntil { controller.playback.player.currentTime().seconds > 0.08 }
    controller.requestClose()
    try await waitUntil { closeCount == 1 }
    #expect(controller.playback.player.currentItem == nil)
    #expect(controller.playback.document == nil && controller.playback.player.rate == 0)
    #expect(window.contentView == nil)
    controller.requestClose()
    try await Task.sleep(for: .milliseconds(100))
    #expect(closeCount == 1 && controller.playback.player.currentItem == nil)
  }

  @Test("다중 보기의 실제 마우스 클릭이 영상 소리 버튼에 도달한다")
  func hostedCanvasPointerClickUnmutesVideo() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let otherVideo = fixture.root.appendingPathComponent("second.mov")
    try FileManager.default.copyItem(at: fixture.video, to: otherVideo)
    let suite = "VideoTilePointerTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: fixture.root.appendingPathComponent("marks.sqlite"))
    store.showsVideos = true
    store.open(urls: [fixture.video, otherVideo])
    try await waitUntil(phase: "pointer test library loaded") { !store.isLoading && !store.isFiltering }
    try #require(store.alert == nil && store.assets.count == 2)
    store.select(index: 0)
    store.setImagesPerPage(2)

    _ = NSApplication.shared
    let host = NSHostingView(rootView: AnyView(ViewerCanvas(store: store,
      shortcuts: ShortcutStore(defaults: defaults))))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 900, height: 560),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer {
      host.rootView = AnyView(Color.clear)
      window.orderOut(nil)
      window.contentView = nil
      window.close()
    }
    try await waitUntil(phase: "pointer test two posters presented") {
      host.layoutSubtreeIfNeeded()
      return store.viewerPresentedAssets.count == 2
    }
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    // Allocate the two muted previews, then exercise only pointer events for
    // the sound action. AXPress and calling toggleSound() directly would both
    // bypass the parent SwiftUI gesture mask that caused this regression.
    store.videoGridPlayback.playAll()
    try await waitUntil(phase: "pointer test two muted native players advancing") {
      host.layoutSubtreeIfNeeded()
      return nativePlayers(in: host).count == 2
        && nativePlayers(in: host).allSatisfy { ($0.player?.currentTime().seconds ?? 0) > 0.04 }
    }
    let native = try #require(nativePlayers(in: host).first)
    let player = try #require(native.player)
    let url = try #require((player.currentItem?.asset as? AVURLAsset)?.url)
    #expect(player.isMuted)
    for view in nativePlayers(in: host) { view.player?.pause() }
    let soundPoint = native.convert(NSPoint(x: native.bounds.maxX - 26,
      y: native.isFlipped ? native.bounds.maxY - 26 : native.bounds.minY + 26), to: nil)
    try sendPointerClick(to: window, at: soundPoint)
    try await waitUntil(phase: "pointer sound click reaches grid and unmutes advancing player") {
      host.layoutSubtreeIfNeeded()
      return store.videoGridPlayback.audioID == url && !player.isMuted && player.rate > 0
    }
    #expect(player.volume > 0)
    #expect(nativePlayers(in: host).filter { $0.player?.isMuted == false }.count == 1)

    try sendPointerClick(to: window, at: soundPoint)
    try await waitUntil(phase: "second pointer sound click mutes player") {
      store.videoGridPlayback.audioID == nil && player.isMuted
    }
  }


  @Test("혼합 페이지는 영상만 재생하고 선택·오디오·페이지 수명을 분리한다")
  func mixedGridCommandsAreBoundedToVisibleVideos() {
    let first = ImageAsset(url: URL(fileURLWithPath: "/test/one.mov"), byteCount: nil, modificationDate: nil)
    let second = ImageAsset(url: URL(fileURLWithPath: "/test/two.mp4"), byteCount: nil, modificationDate: nil)
    let image = ImageAsset(url: URL(fileURLWithPath: "/test/photo.png"), byteCount: nil, modificationDate: nil)
    let state = VideoGridPlaybackState()
    state.updateVisibleAssets([first, image, second])
    state.toggleSelection(first.id)
    state.toggleSelection(image.id)
    state.playSelected()
    #expect(state.playingIDs == [first.id])
    #expect(state.selectedIDs == [first.id])
    #expect(state.command(for: second.id).mode == .paused)
    state.playAll()
    #expect(state.playingIDs == [first.id, second.id])
    state.toggleSound(first.id)
    #expect(!state.command(for: first.id).isMuted && state.command(for: second.id).isMuted)
    state.toggleSound(second.id)
    #expect(state.command(for: first.id).isMuted && !state.command(for: second.id).isMuted)
    state.updateVisibleAssets([first, image])
    #expect(state.playingIDs == [first.id] && state.audioID == nil)
    state.pauseAll()
    #expect(state.playingIDs.isEmpty && state.command(for: first.id).mode == .paused)
    state.reset()
    #expect(state.selectedIDs.isEmpty && !state.usesExplicitPlayback)
  }

  @Test("합성 유음 영상 두 개를 동시에 디코딩하며 소리 소유권을 즉시 옮긴다")
  func explicitVideosDecodeTogetherWithOneAudioOwner() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    // Decode the movie's actual audio into PCM; a silent fixture could let an
    // apparently successful unmute regression test pass without usable audio.
    let source = AVURLAsset(url: fixture.video)
    let track = try #require(try await source.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: source)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    try #require(reader.startReading())
    var largestSample: Float = 0
    while let sample = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
      var data: UnsafeMutablePointer<Int8>?
      var length = 0
      guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
        totalLengthOut: &length, dataPointerOut: &data) == kCMBlockBufferNoErr, let data else { continue }
      data.withMemoryRebound(to: Float.self, capacity: length / 4) { samples in
        for index in 0..<(length / 4) { largestSample = max(largestSample, abs(samples[index])) }
      }
    }
    #expect(reader.status == .completed && largestSample > 0.005)

    let coordinator = VideoHoverPlaybackCoordinator()
    let first = VideoTilePlaybackController(coordinator: coordinator)
    let second = VideoTilePlaybackController(coordinator: coordinator)
    defer { first.stop(); second.stop() }
    var command = VideoTilePlaybackCommand(mode: .playing, isMuted: false, generation: UUID())
    first.update(asset: fixture.asset, isMultiTile: true, isHovered: false,
      allowsPlayback: true, appIsActive: true, command: command)
    command.isMuted = true
    second.update(asset: fixture.asset, isMultiTile: true, isHovered: false,
      allowsPlayback: true, appIsActive: true, command: command)
    let one = try #require(first.playback), two = try #require(second.playback)
    try await waitUntil { one.currentSeconds > 0.08 && two.currentSeconds > 0.08 }
    #expect(one.document?.hasAudio == true && two.document?.hasAudio == true)
    #expect(!one.player.isMuted && one.player.volume > 0 && two.player.isMuted)
    // Claiming the next audio owner must mute the previous one synchronously,
    // without relying on SwiftUI's ordering of independent tile updates.
    command.isMuted = false
    second.update(asset: fixture.asset, isMultiTile: true, isHovered: false,
      allowsPlayback: true, appIsActive: true, command: command)
    #expect(one.player.isMuted && !two.player.isMuted && two.player.volume > 0)
    #expect(one.player.rate > 0 && two.player.rate > 0)
    var enriched = fixture.asset
    enriched.hasReadLocation = true
    enriched.location = ImageLocation(latitude: 37.5, longitude: 127)
    let firstCommand = VideoTilePlaybackCommand(mode: .playing, isMuted: true, generation: UUID())
    first.update(asset: enriched, isMultiTile: true, isHovered: false,
      allowsPlayback: true, appIsActive: true, command: firstCommand)
    #expect(first.playback === one, "Metadata enrichment must not restart a decoded clip")
    first.update(asset: enriched, isMultiTile: true, isHovered: false,
      allowsPlayback: false, appIsActive: true, command: firstCommand)
    #expect(one.player.rate == 0 && first.playback === one)
    let pausedPosition = one.currentSeconds
    first.update(asset: enriched, isMultiTile: true, isHovered: false,
      allowsPlayback: true, appIsActive: true, command: firstCommand)
    try await waitUntil { one.currentSeconds > pausedPosition + 0.05 }
    #expect(first.playback === one && one.player.isMuted)
    command.mode = .paused
    second.update(asset: fixture.asset, isMultiTile: true, isHovered: true,
      allowsPlayback: true, appIsActive: true, command: command)
    #expect(two.player.rate == 0 && two.player.isMuted)
    #expect(second.playback === two && two.player.currentItem != nil)
  }

  @Test("영상 끝의 소리 버튼은 실제 재생을 다시 시작하고 전체 화면 기본 소리는 켜진다")
  func enablingAudioAfterEOFRestartsPlayback() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let controller = VideoTilePlaybackController(coordinator: VideoHoverPlaybackCoordinator())
    defer { controller.stop() }
    #expect(!controller.pauseForFullScreen().isMuted)
    hover(controller, fixture.asset)
    let state = try #require(controller.playback)
    try await waitUntil { state.player.currentItem?.status == .readyToPlay }
    #expect(!controller.pauseForFullScreen().isMuted)
    state.play(from: 1.8)
    try await waitUntil { state.completedPlaybackCount == 1 }
    #expect(state.player.rate == 0)
    controller.toggleSound()
    try await waitUntil { state.currentSeconds > 0.05 && state.currentSeconds < 1 && state.player.rate > 0 }
    #expect(!state.player.isMuted && controller.isSoundEnabled)
    controller.toggleSound()
    #expect(controller.pauseForFullScreen().isMuted)
  }

  @Test("앨범 재생 토큰은 실제 영상 종료를 감지하며 반복·일시 정지 탐색을 처리한다")
  func slideshowCommandsReachRealEOFAndCancelPendingSeek() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let controller = VideoTilePlaybackController(coordinator: VideoHoverPlaybackCoordinator())
    defer { controller.stop() }
    let token = UUID()
    controller.update(asset: fixture.asset, isMultiTile: false, isHovered: false,
      allowsPlayback: true, appIsActive: true, slideshowPlaybackID: token)
    let state = try #require(controller.playback)
    try await waitUntil { state.currentSeconds > 0.05 }
    #expect(!state.player.isMuted)
    state.play(from: 1.8)
    try await waitUntil { state.completedPlaybackCount == 1 }
    #expect(state.completedSlideshowID == token)
    controller.update(asset: fixture.asset, isMultiTile: false, isHovered: false,
      allowsPlayback: true, appIsActive: true, slideshowPlaybackID: UUID())
    try await waitUntil { state.currentSeconds > 0.05 && state.currentSeconds < 1 && state.player.rate > 0 }
    state.play(from: 0.5)
    controller.update(asset: fixture.asset, isMultiTile: false, isHovered: false,
      allowsPlayback: true, appIsActive: true, slideshowPlaybackID: nil)
    try await waitUntil { !state.isSeeking }
    #expect(state.player.rate == 0)
    #expect(state.completedPlaybackCount == 1)
  }

  private func nativePlayer(in view: NSView) -> AVPlayerView? {
    if let player = view as? AVPlayerView { return player }
    return view.subviews.lazy.compactMap { nativePlayer(in: $0) }.first
  }

  private func nativePlayers(in view: NSView) -> [AVPlayerView] {
    if let player = view as? AVPlayerView { return [player] }
    return view.subviews.flatMap { nativePlayers(in: $0) }
  }

  private func sendPointerClick(to window: NSWindow, at point: NSPoint) throws {
    for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
      let event = try #require(NSEvent.mouseEvent(with: type, location: point,
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.01,
        windowNumber: window.windowNumber, context: nil, eventNumber: index + 1,
        clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
      window.sendEvent(event)
    }
  }

  private func hover(_ controller: VideoTilePlaybackController, _ asset: ImageAsset) {
    controller.update(asset: asset, isMultiTile: true, isHovered: true,
      allowsPlayback: true, appIsActive: true)
  }

  private func waitUntil(phase: String = "playback", _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !predicate(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(predicate(), "Video tile did not reach: \(phase)")
  }

  private struct Fixture: Sendable {
    let root: URL
    var video: URL { root.appendingPathComponent("with-audio.mov") }
    var asset: ImageAsset { ImageAsset(url: video, byteCount: nil, modificationDate: nil) }
    func remove() { try? FileManager.default.removeItem(at: root) }

    static func make() async throws -> Self {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("video-tile-\(UUID())", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      let fixture = Self(root: root)
      do { try await fixture.writeMovie() }
      catch { fixture.remove(); throw error }
      return fixture
    }

    private func writeMovie() async throws {
      let silentVideo = root.appendingPathComponent("silent.mov")
      let writer = try AVAssetWriter(outputURL: silentVideo, fileType: .mov)
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 96, AVVideoHeightKey: 64,
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
            try await Task.sleep(for: .milliseconds(5))
          }
          try #require(input.isReadyForMoreMediaData)
          try #require(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 24, timescale: 12))
        await writer.finishWriting()
        try #require(writer.status == .completed)
      } catch { writer.cancelWriting(); throw error }

      let audioURL = root.appendingPathComponent("tone-audio.caf")
      try writeAudio(to: audioURL)
      let videoSource = AVURLAsset(url: silentVideo), audioSource = AVURLAsset(url: audioURL)
      let videoTrack = try #require(try await videoSource.loadTracks(withMediaType: .video).first)
      let audioTrack = try #require(try await audioSource.loadTracks(withMediaType: .audio).first)
      let composition = AVMutableComposition()
      let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
      let composedVideo = try #require(composition.addMutableTrack(withMediaType: .video,
        preferredTrackID: kCMPersistentTrackID_Invalid))
      let composedAudio = try #require(composition.addMutableTrack(withMediaType: .audio,
        preferredTrackID: kCMPersistentTrackID_Invalid))
      try composedVideo.insertTimeRange(range, of: videoTrack, at: .zero)
      try composedAudio.insertTimeRange(range, of: audioTrack, at: .zero)
      let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
      export.outputURL = video
      export.outputFileType = .mov
      await export.export()
      try #require(export.status == .completed, "\(String(describing: export.error))")
    }

    private func writeAudio(to url: URL) throws {
      let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
      buffer.frameLength = 96_000
      let samples = try #require(buffer.floatChannelData?[0])
      for sample in 0..<96_000 {
        samples[sample] = Float(sin(Double(sample) * 2 * .pi * 440 / 48_000)) * 0.025
      }
      let output = try AVAudioFile(forWriting: url, settings: format.settings)
      try output.write(from: buffer)
    }
  }
}
