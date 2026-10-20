@preconcurrency import AVFoundation
import AVKit
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ImageViewer

@Suite("음성 파일의 네이티브 재생과 페이지 수명", .serialized)
@MainActor
struct AudioPlaybackTests {
  @Test("WAV·CAF·AIFF·M4A를 원본 그대로 재생하고 영상 전용 읽기는 그대로 거부한다", arguments: ["wav", "caf", "aiff", "m4a"])
  func nativeAudioFormats(suffix: String) async throws {
    let fixture = try Fixture.make(suffix: suffix, duration: 0.4)
    defer { fixture.remove() }
    let document = try await VideoDocument.load(url: fixture.url, allowsAudioOnly: true)
    #expect(document.isPlayable && document.hasAudio && !document.hasProtectedContent)
    #expect(document.pixelWidth == 0 && document.pixelHeight == 0 && document.nominalFrameRate == 0)
    #expect(abs(document.durationSeconds - 0.4) < (suffix == "m4a" ? 0.06 : 0.01))
    await #expect(throws: VideoProcessingError.noVideoTrack) {
      try await VideoDocument.load(url: fixture.url)
    }

    let state = VideoPlaybackState()
    state.player.isMuted = true
    let monitor = Task { await state.monitor(fixture.asset) }
    defer { monitor.cancel(); state.stop() }
    try await waitUntil("\(suffix): native item ready") { state.player.currentItem?.status == .readyToPlay }
    #expect(state.study == nil && !state.canStepForward && !state.canStepBackward)
    state.resume()
    try await waitUntil("\(suffix): native playback advances") { state.player.currentTime().seconds > 0.05 }
    #expect(state.errorMessage == nil)
    #expect((state.player.currentItem?.asset as? AVURLAsset)?.url == fixture.url)
    state.seek(0.2)
    try await waitUntil("\(suffix): native seek completes") { !state.isSeeking }
    #expect(abs(state.currentSeconds - 0.2) < 0.01)
    state.resume()
    try await waitUntil("\(suffix): native EOF") { state.completedPlaybackCount == 1 }
    #expect(state.errorMessage == nil)
  }

  @Test("오디오는 호버로 준비하지 않고 명시적 재생·음량·일시정지·정리를 유지한다")
  func explicitAudioControllerLifecycle() async throws {
    let fixture = try Fixture.make(duration: 2)
    defer { fixture.remove() }
    let coordinator = VideoHoverPlaybackCoordinator()
    let controller = VideoTilePlaybackController(coordinator: coordinator)
    defer { controller.stop() }
    controller.update(asset: fixture.asset, isMultiTile: true, isHovered: true,
      allowsPlayback: true, appIsActive: true)
    #expect(controller.playback == nil)
    let command = VideoTilePlaybackCommand(mode: .playing, isMuted: false, generation: UUID())
    controller.update(asset: fixture.asset, isMultiTile: false, isHovered: false,
      allowsPlayback: true, appIsActive: true, command: command)
    let playback = try #require(controller.playback)
    try await waitUntil { playback.currentSeconds > 0.05 }
    #expect(!playback.player.isMuted && controller.isSoundEnabled)
    #expect(playback.study == nil)
    playback.player.volume = 0.2
    controller.update(asset: fixture.asset, isMultiTile: false, isHovered: false,
      allowsPlayback: true, appIsActive: true, command: command)
    #expect(playback.player.volume == 0.2, "Updating a tile must retain the native audio volume")
    controller.update(asset: fixture.asset, isMultiTile: false, isHovered: false,
      allowsPlayback: true, appIsActive: false, command: command)
    #expect(playback.player.rate == 0 && controller.playback === playback)
    let paused = playback.currentSeconds
    controller.update(asset: fixture.asset, isMultiTile: false, isHovered: false,
      allowsPlayback: true, appIsActive: true, command: command)
    try await waitUntil { playback.currentSeconds > paused + 0.05 }
    // A zero-volume slider keeps its owner until another media item takes it.
    // Raising that old slider afterward must not unmute both media items.
    playback.player.volume = 0
    let next = VideoTilePlaybackController(coordinator: coordinator)
    defer { next.stop() }
    next.update(asset: fixture.asset, isMultiTile: true, isHovered: false,
      allowsPlayback: true, appIsActive: true, command: command)
    try await waitUntil { next.playback?.document != nil }
    #expect(playback.player.isMuted && next.isSoundEnabled)
    playback.player.volume = 0.2
    #expect(playback.player.isMuted && next.playback?.player.isMuted == false)
    controller.stop()
    #expect(controller.playback == nil && playback.player.currentItem == nil && playback.player.rate == 0)
  }

  @Test("혼합 페이지의 영상·음성만 재생하고 오디오 소유자는 하나만 정한다")
  func mixedGridAudioSelection() {
    let first = ImageAsset(url: URL(fileURLWithPath: "/test/one.wav"), byteCount: nil, modificationDate: nil)
    let second = ImageAsset(url: URL(fileURLWithPath: "/test/two.m4a"), byteCount: nil, modificationDate: nil)
    let video = ImageAsset(url: URL(fileURLWithPath: "/test/movie.mp4"), byteCount: nil, modificationDate: nil)
    let image = ImageAsset(url: URL(fileURLWithPath: "/test/photo.png"), byteCount: nil, modificationDate: nil)
    let grid = VideoGridPlaybackState()
    grid.updateVisibleAssets([image, first, video, second])
    grid.playAll()
    #expect(grid.playingIDs == [first.id, video.id, second.id])
    #expect(grid.audioID == first.id)
    #expect(!grid.command(for: first.id).isMuted && grid.command(for: second.id).isMuted)
    grid.pauseAll()
    grid.toggleSelection(second.id)
    grid.playSelected()
    #expect(grid.playingIDs == [second.id] && grid.audioID == second.id)
    grid.nativeAudioPlaybackChanged(second.id, isPlaying: false, isSoundEnabled: false)
    #expect(grid.playingIDs.isEmpty && grid.audioID == nil)
    grid.nativeAudioPlaybackChanged(first.id, isPlaying: true, isSoundEnabled: true)
    #expect(grid.playingIDs == [first.id] && grid.audioID == first.id)
    grid.updateVisibleAssets([second, image])
    #expect(grid.playingIDs.isEmpty && grid.audioID == nil)
    grid.togglePlayback(second.id)
    #expect(grid.audioID == second.id && !grid.command(for: second.id).isMuted)
    grid.nativeAudioSoundChanged(second.id, isEnabled: false)
    #expect(grid.audioID == nil && grid.command(for: second.id).isMuted)
    grid.nativeAudioSoundChanged(first.id, isEnabled: false)
    #expect(grid.audioID == nil)
  }

  @Test("오디오 앨범은 이전 일시정지보다 우선 시작하고 토큰 해제 시 바로 멈춘다")
  func audioAlbumOverridesOldPauseAndStopsWithItsToken() async throws {
    let fixture = try Fixture.make(duration: 2)
    defer { fixture.remove() }
    let controller = VideoTilePlaybackController(coordinator: VideoHoverPlaybackCoordinator())
    defer { controller.stop() }
    let paused = VideoTilePlaybackCommand(mode: .paused, isMuted: true, generation: UUID())
    let token = UUID()
    controller.update(asset: fixture.asset, isMultiTile: false, isHovered: false,
      allowsPlayback: true, appIsActive: true, command: paused, slideshowPlaybackID: token)
    let playback = try #require(controller.playback)
    try await waitUntil { playback.currentSeconds > 0.05 }
    #expect(!playback.player.isMuted)
    playback.play(from: 1.8)
    try await waitUntil { playback.completedPlaybackCount == 1 }
    #expect(playback.completedSlideshowID == token)
    controller.update(asset: fixture.asset, isMultiTile: false, isHovered: false,
      allowsPlayback: true, appIsActive: true, command: paused, slideshowPlaybackID: UUID())
    try await waitUntil { playback.currentSeconds > 0.05 && playback.currentSeconds < 1 }
    // Even a stale manual-play command must not defeat album stop, including
    // while a position handoff has a pending play-after-seek completion.
    playback.play(from: 0.5)
    let stalePlaying = VideoTilePlaybackCommand(mode: .playing, isMuted: false, generation: UUID())
    controller.update(asset: fixture.asset, isMultiTile: false, isHovered: false,
      allowsPlayback: true, appIsActive: true, command: stalePlaying, slideshowPlaybackID: nil)
    try await waitUntil { !playback.isSeeking }
    #expect(playback.player.rate == 0)
    controller.update(asset: fixture.asset, isMultiTile: false, isHovered: true,
      allowsPlayback: true, appIsActive: true, command: stalePlaying, slideshowPlaybackID: nil)
    #expect(playback.player.rate == 0)
    controller.update(asset: fixture.asset, isMultiTile: false, isHovered: false,
      allowsPlayback: true, appIsActive: false, command: stalePlaying)
    controller.update(asset: fixture.asset, isMultiTile: false, isHovered: false,
      allowsPlayback: true, appIsActive: true, command: stalePlaying)
    #expect(playback.player.rate == 0, "Activation must not revive the pre-stop play command")
    var newPlay = stalePlaying
    newPlay.generation = UUID()
    controller.update(asset: fixture.asset, isMultiTile: false, isHovered: false,
      allowsPlayback: true, appIsActive: true, command: newPlay)
    try await waitUntil { playback.player.rate > 0 }
  }

  @Test("좁은 오디오 타일의 네이티브 제어가 보이고 일시정지·재생·소리 소유권을 동기화한다", arguments: [false, true])
  func hostedAudioControls(isDark: Bool) async throws {
    let fixture = try Fixture.make(duration: 12)
    defer { fixture.remove() }
    _ = NSApplication.shared
    let grid = VideoGridPlaybackState()
    grid.updateVisibleAssets([fixture.asset])
    var ready = false
    var forbiddenVideoAction = false
    let language = L10n.languageIdentifier
    let host = NSHostingView(rootView: AnyView(VideoViewerTile(asset: fixture.asset,
      itemCount: 2, thumbnailPipeline: ThumbnailPipeline(), allowsPlayback: true,
      onOpenTools: { forbiddenVideoAction = true }, onOpenFullScreen: { _, _ in forbiddenVideoAction = true },
      onReady: { _ in ready = true }, gridPlayback: grid)
      .environment(\.locale, Locale(identifier: language))
      .environment(\.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight)
      .environment(\.colorScheme, isDark ? .dark : .light)))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 260, height: 240),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    host.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    window.appearance = host.appearance
    window.contentView = host
    window.orderBack(nil)
    defer {
      host.rootView = AnyView(Color.clear)
      window.orderOut(nil)
      window.contentView = nil
      window.close()
    }
    func waitForView(_ phase: String = "expected playback state", _ predicate: () -> Bool) async throws {
      do {
        try await waitUntil(phase) {
          // Unlike a visible application window, this offscreen fixture has no
          // regular layout/display pass after SwiftUI state changes.
          host.layoutSubtreeIfNeeded()
          return predicate()
        }
      } catch {
        let diagnostic = nativePlayers(in: host).first
        print("AUDIO HOST FAILURE", phase, "playing", grid.playingIDs.count,
          "owner", grid.audioID != nil, "rate", diagnostic?.player?.rate as Any,
          "time", diagnostic?.player?.currentTime().seconds as Any,
          "status", diagnostic?.player?.timeControlStatus.rawValue as Any,
          "waiting", diagnostic?.player?.reasonForWaitingToPlay as Any,
          "interactive", (diagnostic as? NativeVideoPlayerView.PlayerView)?.isInteractive as Any)
        throw error
      }
    }
    try await waitForView { ready }
    #expect(nativePlayers(in: host).isEmpty, "Idle audio must not allocate a native media player")
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    grid.togglePlayback(fixture.asset.id)
    try await waitForView {
      host.layoutSubtreeIfNeeded()
      return (nativePlayers(in: host).first?.player?.currentTime().seconds ?? 0) > 0.1
    }
    let native = try #require(nativePlayers(in: host).first)
    let player = try #require(native.player)
    #expect(!player.isMuted && player.volume > 0)
    #expect(native.controlsStyle == .inline && !native.showsFullScreenToggleButton)
    let frame = native.convert(native.bounds, to: host)
    #expect(frame.minX >= -0.5 && frame.maxX <= host.bounds.maxX + 0.5)
    #expect(frame.minY >= -0.5 && frame.maxY <= host.bounds.maxY + 0.5)
    #expect(frame.height >= 60 && frame.width >= 180)
    #expect(!forbiddenVideoAction)
    if let output = ProcessInfo.processInfo.environment["IMAGEVIEWER_LOCALIZED_CONTROLS_OUTPUT"] {
      // Match other offscreen render tests: allow the final SwiftUI header
      // variant and native layers to commit before taking the bitmap only.
      try await Task.sleep(for: .milliseconds(200))
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      let directory = URL(fileURLWithPath: output, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: directory.appendingPathComponent("audio-\(language)-260-\(isDark ? "dark" : "light").png"))
    }
    // Lifecycle pauses are not a user's pause command. Preserve the grid's
    // desired playback and sound owner until the application becomes active.
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    try await waitForView("background audio pauses") { player.rate == 0 }
    #expect(native.controlsStyle == .inline, "Keep the native audio timeline stable while interaction is suspended")
    #expect(grid.playingIDs.contains(fixture.asset.id) && grid.audioID == fixture.asset.id)
    let backgroundPosition = player.currentTime().seconds
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    try await waitForView("foreground audio resumes") { player.currentTime().seconds > backgroundPosition + 0.05 }

    // A native mute is remembered through the same lifecycle/request updates.
    player.isMuted = true
    try await waitForView("native mute relinquishes sound") { grid.audioID == nil }
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    try await waitForView { player.rate == 0 }
    let mutedPosition = player.currentTime().seconds
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    try await waitForView { player.currentTime().seconds > mutedPosition + 0.05 }
    #expect(player.isMuted && grid.audioID == nil)
    player.pause()
    try await waitForView("native muted pause recorded") { grid.playingIDs.isEmpty }
    player.play()
    try await waitForView("native muted resume recorded") { grid.playingIDs.contains(fixture.asset.id) }
    #expect(player.isMuted && grid.audioID == nil)

    player.isMuted = false
    try await waitForView("native unmute restores sound owner") { grid.audioID == fixture.asset.id }
    player.volume = 0
    // Zero volume does not add a second, invisible mute flag. The owner is
    // retained so the native slider alone can make this item audible again.
    await Task.yield()
    #expect(grid.audioID == fixture.asset.id && !player.isMuted)
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    try await waitForView("zero-volume background pauses") { player.rate == 0 }
    let silentPosition = player.currentTime().seconds
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    try await waitForView("zero-volume foreground resumes silently") { player.currentTime().seconds > silentPosition + 0.05 }
    #expect(player.volume == 0 && !player.isMuted && grid.audioID == fixture.asset.id)

    player.volume = 0.2
    try await waitForView("native slider restores audible volume") { grid.audioID == fixture.asset.id }
    player.pause()
    try await waitForView("native audible pause recorded") { grid.playingIDs.isEmpty }
    player.play()
    try await waitForView("native audible resume recorded") { grid.playingIDs.contains(fixture.asset.id) && !player.isMuted }
    #expect(player.volume == 0.2)

    // The real SwiftUI surface must not feed album playback back into the
    // manual grid command; otherwise stopping the album leaves audio playing.
    grid.pauseAll()
    try await waitForView { player.rate == 0 }
    let albumPosition = player.currentTime().seconds
    host.rootView = AnyView(VideoViewerTile(asset: fixture.asset,
      itemCount: 2, thumbnailPipeline: ThumbnailPipeline(), allowsPlayback: true,
      onOpenTools: {}, onOpenFullScreen: { _, _ in }, gridPlayback: grid,
      slideshowPlaybackID: UUID())
      .environment(\.locale, Locale(identifier: language))
      .environment(\.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight)
      .environment(\.colorScheme, isDark ? .dark : .light))
    try await waitForView("hosted album starts after manual pause") {
      host.layoutSubtreeIfNeeded()
      return player.currentTime().seconds > albumPosition + 0.05
    }
    #expect(grid.playingIDs.isEmpty && !player.isMuted)
    host.rootView = AnyView(VideoViewerTile(asset: fixture.asset,
      itemCount: 2, thumbnailPipeline: ThumbnailPipeline(), allowsPlayback: true,
      onOpenTools: {}, onOpenFullScreen: { _, _ in }, gridPlayback: grid)
      .environment(\.locale, Locale(identifier: language))
      .environment(\.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight)
      .environment(\.colorScheme, isDark ? .dark : .light))
    try await waitForView("hosted album token removal pauses") {
      // An offscreen hosting window has no regular display pass. Apply the
      // replaced root tree before evaluating its album-lifetime side effect.
      host.layoutSubtreeIfNeeded()
      return player.rate == 0
    }
    #expect(grid.playingIDs.isEmpty)
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    await Task.yield()
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    try await Task.sleep(for: .milliseconds(150))
    #expect(player.rate == 0 && grid.playingIDs.isEmpty)
    host.rootView = AnyView(Color.clear)
    try await waitForView {
      host.layoutSubtreeIfNeeded()
      return player.currentItem == nil && player.rate == 0
    }
  }

  @Test("음성 재생 실패도 빈 파일 원인을 남긴다")
  func emptyAudioReportsSourceFailure() async throws {
    let fixture = try Fixture.make()
    defer { fixture.remove() }
    try Data().write(to: fixture.url)
    let state = VideoPlaybackState()
    await state.monitor(fixture.asset)
    #expect(state.errorMessage == MediaLoadFailure.empty.message)
    #expect(state.player.currentItem == nil && state.study == nil)
  }

  @Test("실제 음성 타일의 손상 WAV 재생 실패를 표시하고 재생 상태를 해제한다",
    arguments: [1, 2], [false, true])
  func hostedCorruptAudioReportsFailure(itemCount: Int, isDark: Bool) async throws {
    let fixture = try Fixture.make(duration: 2)
    defer { fixture.remove() }
    try Data("deliberately invalid test-only media\n".utf8).write(to: fixture.url)
    _ = NSApplication.shared
    let grid = VideoGridPlaybackState()
    grid.updateVisibleAssets([fixture.asset])
    var ready = false
    let host = NSHostingView(rootView: AnyView(VideoViewerTile(asset: fixture.asset,
      itemCount: itemCount, thumbnailPipeline: ThumbnailPipeline(), allowsPlayback: true,
      onOpenTools: {}, onOpenFullScreen: { _, _ in }, onReady: { _ in ready = true },
      gridPlayback: grid).environment(\.colorScheme, isDark ? .dark : .light)))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 640, height: 420),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer {
      host.rootView = AnyView(Color.clear)
      window.orderOut(nil)
      window.contentView = nil
      window.close()
    }
    try await waitUntil("corrupt audio placeholder ready") { host.layoutSubtreeIfNeeded(); return ready }
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    grid.togglePlayback(fixture.asset.id)
    try #require(grid.playingIDs == [fixture.asset.id])
    try await waitUntil("corrupt audio failure reaches tile and stops grid intent") {
      host.layoutSubtreeIfNeeded()
      return grid.playingIDs.isEmpty
    }
    #expect(grid.audioID == nil && nativePlayers(in: host).isEmpty)
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    if let output = ProcessInfo.processInfo.environment["IMAGEVIEWER_AUDIO_FAILURE_OUTPUT"] {
      let directory = URL(fileURLWithPath: output, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try #require(bitmap.representation(using: .png, properties: [:])).write(to:
        directory.appendingPathComponent("corrupt-audio-\(itemCount)-\(isDark ? "dark" : "light").png"))
    }
    // Repeated explicit play must report failure again, not remain stuck in a
    // paused command or reset itself to the unvalidated ready placeholder.
    grid.togglePlayback(fixture.asset.id)
    try #require(grid.playingIDs == [fixture.asset.id])
    try await waitUntil("corrupt audio retry reports failure") {
      host.layoutSubtreeIfNeeded()
      return grid.playingIDs.isEmpty
    }
  }

  private func nativePlayers(in view: NSView) -> [AVPlayerView] {
    if let player = view as? AVPlayerView { return [player] }
    return view.subviews.flatMap { nativePlayers(in: $0) }
  }

  private func waitUntil(_ phase: String = "expected playback state", _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !predicate(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(predicate(), "Audio playback did not reach: \(phase)")
  }

  private struct Fixture {
    let folder: URL
    let url: URL
    var asset: ImageAsset { ImageAsset(url: url, byteCount: nil, modificationDate: nil) }
    func remove() { try? FileManager.default.removeItem(at: folder) }

    static func make(suffix: String = "wav", duration: Double = 0.4) throws -> Self {
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("audio-playback-\(UUID())", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
      let fixture = Self(folder: folder, url: folder.appendingPathComponent("synthetic.\(suffix)"))
      do {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let count = AVAudioFrameCount(48_000 * duration)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        let channel = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(count) {
          channel[index] = Float(sin(Double(index) * 2 * .pi * 440 / 48_000)) * 0.01
        }
        var settings = format.settings
        if suffix == "aiff" { settings[AVLinearPCMIsBigEndianKey] = true }
        if suffix == "m4a" {
          settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]
        }
        let output = try AVAudioFile(forWriting: fixture.url, settings: settings)
        try output.write(from: buffer)
        return fixture
      } catch {
        fixture.remove()
        throw error
      }
    }
  }
}
