@preconcurrency import AVFoundation
import AVKit
import CoreVideo
import SwiftUI
import Testing

@testable import ImageViewer

/// Drives the real page-navigation and hosted tile lifetimes. App activation is
/// supplied explicitly because an offscreen SwiftPM host is not the foreground
/// app; player creation, media decoding, sound ownership, and teardown are real.
@Suite("실제 혼합 뷰어의 페이지 자동 재생", .serialized)
@MainActor
struct ViewerPageAutoplayIntegrationTests {
  @Test("몽땅보기 미리보기는 음성만 소리를 내고 하나만 재생하며 이탈·스크롤·필터·보기 변경 때 해제된다")
  func overviewPreviewHasOneOwnerAndSeparateSoundPolicy() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let defaults = try #require(UserDefaults(suiteName: fixture.suite))
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    store.open(urls: [fixture.folder])
    try await waitUntil("overview media library") { !store.isLoading && !store.isFiltering }
    let video = try #require(store.assets.first { $0.isVideo })
    let audio = try #require(store.assets.first { $0.isAudio })
    store.presentationMode = .overview
    store.mediaSoundSession.setEnabled(true)
    let preview = store.overviewMediaPreview
    defer { preview.stop() }
    preview.setEnabled(true)
    preview.hover(video, isInside: true)
    preview.hover(video, isInside: false)
    try await Task.sleep(for: .milliseconds(200))
    #expect(preview.playback == nil && preview.asset == nil)
    preview.hover(audio, isInside: true)
    // A click before the hover dwell has elapsed starts, rather than cancels.
    preview.toggle(audio)
    try await waitUntil("overview audible audio") {
      (preview.playback?.player.currentTime().seconds ?? 0) > 0.04
        && preview.playback?.player.isMuted == false
    }
    let oldAudio = try #require(preview.playback)
    #expect(store.mediaSoundSession.isEnabled)
    preview.hover(video, isInside: true)
    #expect(oldAudio.player.currentItem == nil && oldAudio.player.rate == 0 && oldAudio.player.isMuted)
    try await waitUntil("overview video always muted") {
      (preview.playback?.player.currentTime().seconds ?? 0) > 0.04
        && preview.playback?.player.isMuted == true
    }
    let oldVideo = try #require(preview.playback)
    preview.end(audio)
    #expect(preview.playback === oldVideo, "A late leave event must not cancel a newer preview")
    preview.setEnabled(false)
    #expect(oldVideo.player.currentItem == nil && oldVideo.player.rate == 0)
    preview.hover(audio, isInside: true)
    #expect(preview.playback == nil && preview.asset == nil)
    preview.setEnabled(true)
    preview.toggle(audio)
    try await waitUntil("overview audio after scroll") { preview.playback?.player.rate == 1 }
    preview.retain(in: [video])
    #expect(preview.asset == nil && preview.playback == nil)
    preview.toggle(video)
    try await waitUntil("overview before source replacement") { preview.playback?.player.rate == 1 }
    let replacement = ImageAsset(url: video.url, byteCount: (video.byteCount ?? 0) + 1,
      modificationDate: video.modificationDate)
    preview.retain(in: [replacement])
    #expect(preview.asset == nil && preview.playback == nil)
    preview.toggle(audio)
    try await waitUntil("overview before mode switch") { preview.playback?.player.rate == 1 }
    let finalAudio = try #require(preview.playback)
    store.presentationMode = .viewer
    #expect(preview.playback == nil && finalAudio.player.currentItem == nil && !preview.isEnabled)
    #expect(store.mediaSoundSession.isEnabled)
  }

  @Test("소리 유지는 사진·영상·음성을 반복 왕복하고 빠르게 여러 장을 넘겨도 해제되지 않는다")
  func sessionSoundSurvivesRepeatedMixedNavigation() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let defaults = try #require(UserDefaults(suiteName: fixture.suite))
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    store.open(urls: [fixture.folder])
    try await waitUntil("navigation library") { !store.isLoading && !store.isFiltering }
    let firstVideo = try #require(store.assets.firstIndex { $0.isVideo })
    store.select(index: firstVideo)
    _ = NSApplication.shared
    let host = NSHostingView(rootView: AnyView(ViewerCanvas(store: store,
      shortcuts: ShortcutStore(defaults: defaults))))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 960, height: 600),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { host.rootView = AnyView(Color.clear); window.orderOut(nil); window.contentView = nil; window.close() }
    try await waitUntil("navigation initial presentation") {
      host.layoutSubtreeIfNeeded()
      return store.viewerPresentedAssets.count == 1
    }
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    try await waitUntil("navigation first video") { nativePlayers(in: host).contains { $0.rate > 0 } }
    let id = try #require(store.currentAsset?.id)
    store.videoGridPlayback.cycleSound(id)
    try await waitUntil("navigation sound enabled") { nativePlayers(in: host).contains { !$0.isMuted } }
    store.videoGridPlayback.cycleSound(id)
    for round in 0..<3 {
      for direction in [1, -1] {
        for step in 0..<store.assets.count {
          store.navigatePage(direction)
          let asset = try #require(store.currentAsset)
          try await waitUntil("navigation poster \(asset.filename)") {
            host.layoutSubtreeIfNeeded()
            return store.viewerPresentedAssets.values.contains(AppStore.PresentedAssetVersion(asset))
          }
          // A photo-only page destroys the media tile. Its replacement needs
          // the same explicit activation as the initial offscreen test tile.
          NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
          try await waitUntil("navigation \(round)/\(direction)/\(step) \(asset.filename)") {
            host.layoutSubtreeIfNeeded()
            if !asset.isPlaybackMedia { return nativePlayers(in: host).isEmpty }
            return nativePlayers(in: host).contains {
              ($0.currentItem?.asset as? AVURLAsset)?.url == asset.url
                && $0.currentTime().seconds > 0.04 && $0.rate > 0
            }
          }
          #expect(store.mediaSoundSession.isEnabled)
          #expect(nativePlayers(in: host).allSatisfy { !$0.isMuted })
        }
      }
    }
    for _ in 0..<3 { store.navigatePage(1) }
    try await Task.sleep(for: .milliseconds(250))
    host.layoutSubtreeIfNeeded()
    #expect(store.mediaSoundSession.isEnabled)

    store.select(index: firstVideo)
    let current = try #require(store.currentAsset)
    try await waitUntil("handoff poster") {
      host.layoutSubtreeIfNeeded()
      return store.viewerPresentedAssets.values.contains(AppStore.PresentedAssetVersion(current))
    }
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    try await waitUntil("handoff original player") {
      nativePlayers(in: host).contains { $0.rate > 0 && !$0.isMuted }
    }
    // A handoff mutes the old native player automatically. That KVO event is
    // not a user's request to cancel sound for the rest of the app session.
    let transient = VideoTilePlaybackController()
    defer { transient.stop() }
    transient.update(asset: current, isMultiTile: true, isHovered: false,
      allowsPlayback: true, appIsActive: true,
      command: VideoTilePlaybackCommand(mode: .playing, isMuted: false, generation: UUID()))
    try await waitUntil("transient sound owner advances") {
      (transient.playback?.player.currentTime().seconds ?? 0) > 0.08
    }
    #expect(store.mediaSoundSession.isEnabled,
      "Programmatic sound handoff must not cancel the user's session choice")
    transient.stop()
    store.navigatePage(1)
    let nextAsset = try #require(store.currentAsset)
    try await waitUntil("next audio after handoff") {
      host.layoutSubtreeIfNeeded()
      return nativePlayers(in: host).contains {
        ($0.currentItem?.asset as? AVURLAsset)?.url == nextAsset.url
          && $0.rate > 0 && $0.currentTime().seconds > 0.04
      }
    }
    #expect(store.mediaSoundSession.isEnabled && nativePlayers(in: host).allSatisfy { !$0.isMuted })
  }

  @Test("전체 화면의 직접 음소거는 소리 유지를 해제하고 창 종료는 유지 선택을 보존한다")
  func fullScreenNativeMuteAndTeardownRespectSoundSession() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let defaults = try #require(UserDefaults(suiteName: fixture.suite))
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    let asset = ImageAsset(url: fixture.folder.appendingPathComponent("02.mov"),
      byteCount: 1_024, modificationDate: nil)
    store.mediaSoundSession.setEnabled(true)
    _ = NSApplication.shared
    let controller = VideoFullScreenController(asset: asset, seconds: 0,
      isMuted: false, store: store, onClose: {})
    let monitor = Task { await controller.playback.monitor(asset) }
    defer { monitor.cancel(); controller.requestClose() }
    try await waitUntil("full-screen native output observed") {
      controller.playback.document != nil && controller.playback.isSoundEnabled
    }
    controller.playback.player.isMuted = true
    try await waitUntil("full-screen native mute ends sound persistence") { !store.mediaSoundSession.isEnabled }
    store.mediaSoundSession.setEnabled(true)
    controller.requestClose()
    try await waitUntil("full-screen player released") { controller.playback.document == nil }
    try await Task.sleep(for: .milliseconds(40))
    #expect(store.mediaSoundSession.isEnabled)
  }

  @Test("자동 재생을 꺼도 몽땅보기에서 직접 연 음성은 뷰어 전환 뒤 무음으로 재생된다",
    arguments: [false, true])
  func explicitOverviewAudioSurvivesViewerAppearance(autoplay: Bool) async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let defaults = try #require(UserDefaults(suiteName: fixture.suite))
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    store.automaticallyPlaysSingleMedia = autoplay
    store.open(urls: [fixture.folder])
    try await waitUntil("explicit audio library") { !store.isLoading && !store.isFiltering }
    let audio = try #require(store.assets.first { $0.isAudio })
    store.presentationMode = .overview
    _ = NSApplication.shared
    let host = NSHostingView(rootView: AnyView(RootView(store: store,
      shortcuts: ShortcutStore(defaults: defaults))))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 960, height: 600),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer {
      host.rootView = AnyView(Color.clear)
      store.videoGridPlayback.reset()
      window.orderOut(nil); window.contentView = nil; window.close()
    }
    host.layoutSubtreeIfNeeded()
    store.openAudioForPlayback(audio)
    try await waitUntil("explicit audio viewer presentation") {
      host.layoutSubtreeIfNeeded()
      return store.tracksViewerPresentation && store.viewerPresentedAssets.count == 1
    }
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    try await waitUntil("explicit audio advances after viewer appearance") {
      host.layoutSubtreeIfNeeded()
      return nativePlayers(in: host).contains { $0.rate > 0 && $0.currentTime().seconds > 0.04 }
    }
    let player = try #require(nativePlayers(in: host).first)
    #expect(player.isMuted && store.videoGridPlayback.audioID == nil)
    #expect(store.videoGridPlayback.playingIDs == [audio.id])
    let item = try #require(player.currentItem)
    store.openAudioForPlayback(audio)
    host.layoutSubtreeIfNeeded()
    #expect(player.currentItem === item && player.rate > 0 && player.isMuted)
  }

  @Test("한 장 영상·음성의 무음 자동 재생과 Space·수동 모드·소리 선택이 실제 플레이어에 연결된다")
  func singleMediaAutoplayAndManualControlsReachNativePlayers() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let defaults = try #require(UserDefaults(suiteName: fixture.suite))
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    store.open(urls: [fixture.folder])
    try await waitUntil("single library") { !store.isLoading && !store.isFiltering }
    let videoMatch = store.assets.firstIndex { $0.isVideo }
    let audioMatch = store.assets.firstIndex { $0.isAudio }
    let videoIndex = try #require(videoMatch)
    let audioIndex = try #require(audioMatch)
    store.select(index: videoIndex)
    _ = NSApplication.shared
    let host = NSHostingView(rootView: AnyView(ViewerCanvas(store: store,
      shortcuts: ShortcutStore(defaults: defaults))))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 960, height: 600),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer {
      host.rootView = AnyView(Color.clear)
      store.videoGridPlayback.reset()
      window.orderOut(nil); window.contentView = nil; window.close()
    }
    try await waitUntil("single poster presented before activation") {
      host.layoutSubtreeIfNeeded()
      return store.viewerPresentedAssets.count == 1
    }
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    try await waitUntil("single video autoplays muted") {
      host.layoutSubtreeIfNeeded()
      return nativePlayers(in: host).contains { $0.rate > 0 && $0.currentTime().seconds > 0.04 && $0.isMuted }
    }
    let video = try #require(nativePlayers(in: host).first)
    store.handleViewerSpaceTap()
    try await waitUntil("space pauses current video") { video.rate == 0 }
    #expect(!store.isFocusMode)
    try await Task.sleep(for: .milliseconds(220))
    #expect(video.rate == 0)
    store.handleViewerSpaceTap()
    try await waitUntil("space resumes") { video.rate > 0 }
    store.automaticallyPlaysSingleMedia = false
    try await waitUntil("manual mode pauses existing video") { video.rate == 0 }
    store.select(index: audioIndex)
    try await Task.sleep(for: .milliseconds(250))
    host.layoutSubtreeIfNeeded()
    #expect(nativePlayers(in: host).allSatisfy { $0.rate == 0 })
    store.handleViewerSpaceTap()
    try await waitUntil("manual audio starts muted") {
      host.layoutSubtreeIfNeeded()
      return nativePlayers(in: host).contains { $0.rate > 0 && $0.isMuted }
    }
    let audio = try #require(nativePlayers(in: host).first)
    let audioID = try #require(store.currentAsset?.id)
    store.videoGridPlayback.toggleSound(audioID)
    try await waitUntil("sound button unmutes") { !audio.isMuted }
    audio.pause()
    try await waitUntil("native pause reaches main controls") { !store.videoGridPlayback.playingIDs.contains(audioID) }
    store.handleViewerSpaceTap()
    try await waitUntil("space preserves sound choice") { audio.rate > 0 && !audio.isMuted }
    store.automaticallyPlaysSingleMedia = true
    store.select(index: videoIndex)
    try await waitUntil("next file starts muted and releases old audio") {
      host.layoutSubtreeIfNeeded()
      return audio.currentItem == nil && nativePlayers(in: host).contains { $0 !== audio && $0.rate > 0 && $0.isMuted }
    }
    let nextVideo = try #require(nativePlayers(in: host).first)
    let nextVideoID = try #require(store.currentAsset?.id)
    let item = try #require(nextVideo.currentItem)
    store.videoGridPlayback.cycleSound(nextVideoID)
    try await waitUntil("first sound click unmutes this file") { !nextVideo.isMuted }
    store.videoGridPlayback.cycleSound(nextVideoID)
    try await waitUntil("second sound click arms session without reloading") {
      store.mediaSoundSession.isEnabled && !nextVideo.isMuted && nextVideo.currentItem === item
    }
    store.select(index: audioIndex)
    try await waitUntil("next audio inherits session sound and releases video") {
      host.layoutSubtreeIfNeeded()
      return nextVideo.currentItem == nil
        && nativePlayers(in: host).contains { $0.rate > 0 && !$0.isMuted }
    }
    let nextAudio = try #require(nativePlayers(in: host).first)
    store.handleViewerSpaceTap()
    try await waitUntil("session sound survives space pause") {
      nextAudio.rate == 0 && store.mediaSoundSession.isEnabled
    }
    store.handleViewerSpaceTap()
    try await waitUntil("session sound survives space resume") { nextAudio.rate > 0 && !nextAudio.isMuted }
    store.videoGridPlayback.cycleSound(audioID)
    try await waitUntil("third sound click mutes and disarms session") {
      nextAudio.isMuted && !store.mediaSoundSession.isEnabled
    }
    store.videoGridPlayback.cycleSound(audioID)
    try await waitUntil("sound re-enabled before native mute") { !nextAudio.isMuted }
    store.videoGridPlayback.cycleSound(audioID)
    // Complete real native pause/resume transitions before the next native
    // action, rather than outrunning the UI's deferred KVO delivery.
    store.handleViewerSpaceTap()
    try await waitUntil("rearmed sound pause reaches native player") { nextAudio.rate == 0 }
    store.handleViewerSpaceTap()
    try await waitUntil("rearmed sound resume reaches native player") { nextAudio.rate > 0 && !nextAudio.isMuted }
    nextAudio.isMuted = true
    try await waitUntil("native mute also disarms session sound") {
      !store.mediaSoundSession.isEnabled && store.videoGridPlayback.audioID == nil
    }
    store.select(index: videoIndex)
    try await waitUntil("next file stays muted after native mute") {
      host.layoutSubtreeIfNeeded()
      return nextAudio.currentItem == nil && nativePlayers(in: host).contains { $0.rate > 0 && $0.isMuted }
    }
  }

  @Test("사진 전용 페이지를 지나 영상·음성 자동 재생을 이어가고 이전 재생기는 해제한다")
  func hostedMixedPagesPreserveAutoplayUntilPaused() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let defaults = try #require(UserDefaults(suiteName: fixture.suite))
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    defer { store.videoGridPlayback.reset(); store.pauseSlideshow() }
    store.showsVideos = true
    store.open(urls: [fixture.folder])
    try await waitUntil("mixed library open") { !store.isLoading && !store.isFiltering }
    try #require(store.alert == nil && store.assets.count == 10)
    try #require(store.assets.map(\.filename) == Fixture.names)
    store.setImagesPerPage(3)
    store.wrapsNavigation = true

    _ = NSApplication.shared
    let host = NSHostingView(rootView: AnyView(ViewerCanvas(store: store,
      shortcuts: ShortcutStore(defaults: defaults))))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 960, height: 620),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "알맹Re · 합성 혼합 페이지 자동 재생 검사"
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer {
      store.videoGridPlayback.reset()
      host.rootView = AnyView(Color.clear)
      window.orderOut(nil)
      window.contentView = nil
      window.close()
    }

    func waitForView(_ phase: String, _ predicate: () -> Bool) async throws {
      do {
        try await waitUntil(phase) {
          host.layoutSubtreeIfNeeded()
          return predicate()
        }
      } catch {
        print("PAGE AUTOPLAY HOST FAILURE", phase, "index", store.currentIndex,
          "visible", store.visibleAssets.map(\.filename), "presented",
          store.viewerPresentedAssets.values.map { $0.id.lastPathComponent },
          "tracking", store.tracksViewerPresentation, "bounds", host.bounds,
          "players", nativePlayers(in: host).map { (mediaURL($0)?.lastPathComponent, $0.rate) })
        throw error
      }
    }
    func awaitPagePresentation() async throws {
      try await waitForView("visible page presented") {
        // Presentation records may retain now-absent slots on a partial final
        // page. Readiness concerns only the slots currently requested by it.
        store.tracksViewerPresentation
          && store.visibleAssets.enumerated().allSatisfy { slot, asset in
            store.viewerPresentedAssets[slot] == AppStore.PresentedAssetVersion(asset)
          }
      }
      NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    }
    func assertVisibleMediaPlaying() async throws -> [AVPlayer] {
      let expected = Set(store.visibleAssets.filter(\.isPlaybackMedia).map(\.url))
      try await waitForView("all visible media actually advance") {
        let players = nativePlayers(in: host)
        return Set(players.compactMap(mediaURL)) == expected && players.allSatisfy {
          $0.currentItem?.status == .readyToPlay && $0.rate > 0 && $0.currentTime().seconds > 0.05
        }
      }
      let players = nativePlayers(in: host)
      let audio = try #require(store.visibleAssets.first(where: { $0.isAudio }))
      #expect(store.videoGridPlayback.audioID == audio.id)
      #expect(players.filter { !$0.isMuted && $0.volume > 0 }.count == 1)
      #expect(players.first { mediaURL($0) == audio.url }?.isMuted == false)
      #expect(store.videoGridPlayback.playingIDs == expected,
        "Photos must remain still and never acquire a playback command")
      return players
    }

    try await awaitPagePresentation()
    try #require(store.allowsVideoPlayback)
    #expect(nativePlayers(in: host).isEmpty, "Idle mixed pages must not allocate playback items")

    // The same two actions as the current-page and next-pages play buttons.
    store.videoGridPlayback.playAll()
    #expect(!store.videoGridPlayback.followsPages)
    let firstPlayers = try await assertVisibleMediaPlaying()
    store.videoGridPlayback.playAll()
    try #require(store.videoGridPlayback.followsPages)
    #expect(store.currentIndex == 0 && !store.isSlideshowPlaying,
      "Page following must not start an album or advance pages on its own")

    store.navigatePage(1)
    try await awaitPagePresentation()
    try #require(store.currentIndex == 3 && store.visibleAssets.allSatisfy { !$0.isPlaybackMedia })
    try await waitForView("leaving the first page releases every media item") {
      firstPlayers.allSatisfy { $0.currentItem == nil && $0.rate == 0 }
        && nativePlayers(in: host).isEmpty
    }
    #expect(store.videoGridPlayback.followsPages)
    #expect(store.videoGridPlayback.playingIDs.isEmpty && store.videoGridPlayback.audioID == nil)

    store.navigatePage(1)
    try await awaitPagePresentation()
    try #require(store.currentIndex == 6)
    let lastPlayers = try await assertVisibleMediaPlaying()
    #expect(lastPlayers.allSatisfy { last in firstPlayers.allSatisfy { $0 !== last } })
    #expect(store.videoGridPlayback.followsPages && !store.isSlideshowPlaying)

    // A short final page still belongs to the three-frame viewer. Its one
    // remaining video must honor the same explicit command and mute policy.
    store.navigatePage(1)
    try await awaitPagePresentation()
    try #require(store.currentIndex == 9 && store.visibleAssets.count == 1)
    try await waitForView("single final video follows page playback") {
      let players = nativePlayers(in: host)
      return players.count == 1 && players[0].currentTime().seconds > 0.05
        && players[0].rate > 0
        && mediaURL(players[0])?.lastPathComponent == "10.mov"
    }
    let finalPlayer = try #require(nativePlayers(in: host).first)
    #expect(finalPlayer.isMuted && store.videoGridPlayback.audioID == nil)
    #expect(lastPlayers.allSatisfy { $0.currentItem == nil && $0.rate == 0 })

    store.videoGridPlayback.pauseAll()
    try await waitForView("pause stops the single final player") { finalPlayer.rate == 0 }
    #expect(!store.videoGridPlayback.followsPages)
    #expect(store.videoGridPlayback.playingIDs.isEmpty && store.videoGridPlayback.audioID == nil)

    store.navigatePage(-1)
    try await awaitPagePresentation()
    try await waitForView("paused last-page players are released") {
      finalPlayer.currentItem == nil && finalPlayer.rate == 0
    }
    store.navigatePage(-1)
    try await awaitPagePresentation()
    store.navigatePage(-1)
    try await awaitPagePresentation()
    #expect(store.currentIndex == 0 && store.visibleAssets.contains(where: \.isAudio))
    // Allow asynchronous appearance effects to settle so a deferred automatic
    // play request cannot accidentally pass the immediate empty-player check.
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    #expect(nativePlayers(in: host).isEmpty)
    #expect(store.videoGridPlayback.playingIDs.isEmpty && !store.videoGridPlayback.followsPages)
    #expect(store.alert == nil)
  }

  private func mediaURL(_ player: AVPlayer) -> URL? {
    (player.currentItem?.asset as? AVURLAsset)?.url
  }

  private func nativePlayers(in view: NSView) -> [AVPlayer] {
    if let native = view as? AVPlayerView { return native.player.map { [$0] } ?? [] }
    return view.subviews.flatMap { nativePlayers(in: $0) }
  }

  private func waitUntil(_ phase: String, seconds: Double = 10,
    _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while true {
      if predicate() { return }
      try #require(ContinuousClock.now < deadline,
        "Viewer page autoplay integration did not reach: \(phase)")
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private struct Fixture {
    static let names = ["01.png", "02.mov", "03.wav", "04.png", "05.png", "06.png",
      "07.png", "08.mov", "09.wav", "10.mov"]
    let folder: URL
    let suite = "ViewerPageAutoplayIntegrationTests.\(UUID())"

    static func make() async throws -> Self {
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("viewer-page-autoplay-\(UUID())", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let fixture = Self(folder: folder)
      do {
        for name in names where name.hasSuffix(".png") {
          try writeImage(to: folder.appendingPathComponent(name))
        }
        try await writeMovie(to: folder.appendingPathComponent("02.mov"), color: 0xFF_40_80_C0)
        try FileManager.default.copyItem(at: folder.appendingPathComponent("02.mov"),
          to: folder.appendingPathComponent("08.mov"))
        try FileManager.default.copyItem(at: folder.appendingPathComponent("02.mov"),
          to: folder.appendingPathComponent("10.mov"))
        try writeAudio(to: folder.appendingPathComponent("03.wav"))
        try FileManager.default.copyItem(at: folder.appendingPathComponent("03.wav"),
          to: folder.appendingPathComponent("09.wav"))
      } catch { fixture.remove(); throw error }
      return fixture
    }

    func remove() {
      UserDefaults.standard.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }

    private static func writeImage(to url: URL) throws {
      let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160,
        pixelsHigh: 96, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 640, bitsPerPixel: 32))
      let bytes = try #require(bitmap.bitmapData)
      bytes.initialize(repeating: 160, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      try data.write(to: url)
    }

    private static func writeAudio(to url: URL) throws {
      let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
      let count: AVAudioFrameCount = 48_000 * 30
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
      buffer.frameLength = count
      // Silent content keeps this real audio-owner regression quiet on the Mac.
      let channel = try #require(buffer.floatChannelData?[0])
      channel.initialize(repeating: 0, count: Int(count))
      let output = try AVAudioFile(forWriting: url, settings: format.settings)
      try output.write(from: buffer)
    }

    private static func writeMovie(to url: URL, color: UInt32) async throws {
      let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 96,
        AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false],
      ])
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
          kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96,
        ])
      try #require(writer.canAdd(input))
      writer.add(input)
      try #require(writer.startWriting())
      writer.startSession(atSourceTime: .zero)
      do {
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 160, 96,
          kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixels))
        base.assumingMemoryBound(to: UInt32.self).initialize(repeating: color,
          count: CVPixelBufferGetBytesPerRow(pixels) * 96 / 4)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let deadline = ContinuousClock.now + .seconds(10)
        // Thirty seconds prevents natural EOF from racing page-navigation checks.
        for frame in 0..<30 {
          while !input.isReadyForMoreMediaData, writer.status == .writing,
            ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
          }
          try #require(input.isReadyForMoreMediaData)
          try #require(adaptor.append(pixels,
            withPresentationTime: CMTime(value: Int64(frame), timescale: 1)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 30, timescale: 1))
        await writer.finishWriting()
        try #require(writer.status == .completed, "\(String(describing: writer.error))")
      } catch { writer.cancelWriting(); throw error }
    }
  }
}
