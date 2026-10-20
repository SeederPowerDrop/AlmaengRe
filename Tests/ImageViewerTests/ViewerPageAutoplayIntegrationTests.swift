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
