@preconcurrency import AVFoundation
import AVKit
import CoreVideo
import SwiftUI
import Testing

@testable import ImageViewer

/// Exercises the real AppStore → ViewerCanvas → VideoViewerTile → AVPlayer →
/// EOF → AppStore route with real decoded frames and natural completion events.
/// The app-active lifecycle notification is supplied as a test input because a
/// SwiftPM test process cannot reliably become the foreground macOS application.
/// This test covers view wiring, not the operating system's activation policy.
@Suite("실제 뷰어의 영상 앨범 재생 연결", .serialized)
@MainActor
struct ViewerVideoAlbumIntegrationTests {
  @Test("영상 두 개의 다중 보기에서 시작한 앨범이 실제 EOF로 다음 영상을 재생하고 완료한다")
  func hostedViewerAdvancesAtRealVideoEOF() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let defaults = try #require(UserDefaults(suiteName: fixture.suite))
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    defer { store.pauseSlideshow() }
    store.showsVideos = true
    store.open(urls: [fixture.folder])
    try await waitUntil("library open") { !store.isLoading && !store.isFiltering }
    try #require(store.alert == nil && store.assets.count == 2)
    let containsOnlyVideos = store.assets.allSatisfy { $0.isVideo }
    try #require(containsOnlyVideos)
    store.setImagesPerPage(2)
    store.slideshowRepeats = false

    _ = NSApplication.shared
    let host = NSHostingView(rootView: AnyView(ViewerCanvas(store: store,
      shortcuts: ShortcutStore(defaults: defaults))))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 800, height: 560),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "알맹Re · 합성 영상 앨범 통합 검사"
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer {
      store.pauseSlideshow()
      host.rootView = AnyView(Color.clear)
      window.orderOut(nil)
      window.contentView = nil
      window.close()
    }
    try await waitUntil("both initial posters are presented") {
      host.layoutSubtreeIfNeeded()
      return store.tracksViewerPresentation && store.viewerPresentedAssets.count == 2
    }
    // Deliver only the app-lifecycle input. Readiness, playback and EOF remain
    // owned by the real hosted views and AVFoundation rather than test callbacks.
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    try #require(store.allowsVideoPlayback && store.canStartSlideshow)
    try #require(store.visibleAssets.count == 2)

    // This is the same action as the album button. Do not invoke a tile's
    // onReady/onEnded or AppStore.slideshowVideoFinished anywhere in this test.
    store.toggleSlideshow()
    try #require(store.isSlideshowPlaying && store.imagesPerPage == 1)
    let firstToken = try #require(store.slideshowVideoPlaybackID)
    try await waitUntil("first native player installed") {
      host.layoutSubtreeIfNeeded()
      return nativePlayers(in: host).contains { player in
        player.currentItem?.status == .readyToPlay
          && videoURL(player)?.lastPathComponent == "01.mov"
      }
    }
    let first = try #require(nativePlayers(in: host).first {
      videoURL($0)?.lastPathComponent == "01.mov"
    })
    let firstItem = try #require(first.currentItem)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
    firstItem.add(output)
    defer { firstItem.remove(output) }
    try await waitUntil("first decoded video frame") {
      host.layoutSubtreeIfNeeded()
      let time = first.currentTime()
      guard time.seconds > 0.03, first.rate > 0,
        output.hasNewPixelBuffer(forItemTime: time),
        let frame = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return false }
      return CVPixelBufferGetWidth(frame) == 160 && CVPixelBufferGetHeight(frame) == 96
    }
    #expect(!first.isMuted)
    #expect(store.currentIndex == 0)
    #expect(store.slideshowVideoPlaybackID == firstToken)

    try await waitUntil("actual EOF advances to second video") {
      host.layoutSubtreeIfNeeded()
      return store.currentIndex == 1 && nativePlayers(in: host).contains { player in
        videoURL(player)?.lastPathComponent == "02.mov"
          && player.currentTime().seconds > 0.03 && player.rate > 0
      }
    }
    let second = try #require(nativePlayers(in: host).first {
      videoURL($0)?.lastPathComponent == "02.mov"
    })
    #expect(second !== first)
    #expect(first.currentItem == nil && first.rate == 0)
    #expect(store.slideshowVideoPlaybackID != firstToken)
    #expect(!second.isMuted)
    try await waitUntil("second EOF completes nonrepeating album") {
      host.layoutSubtreeIfNeeded()
      return !store.isSlideshowPlaying
    }
    #expect(store.currentIndex == 1)
    #expect(store.slideshowVideoPlaybackID == nil)
    #expect(second.currentTime().seconds >= 0.7 && second.rate == 0)
    #expect(store.alert == nil)

    host.rootView = AnyView(Color.clear)
    try await waitUntil("viewer teardown releases second video") {
      host.layoutSubtreeIfNeeded()
      return second.currentItem == nil
    }
  }

  private func videoURL(_ player: AVPlayer) -> URL? {
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
        "Viewer album integration did not reach: \(phase)")
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private struct Fixture {
    let folder: URL
    let suite = "ViewerVideoAlbumIntegrationTests.\(UUID())"

    static func make() async throws -> Self {
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("viewer-video-album-\(UUID())", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let fixture = Self(folder: folder)
      do {
        try await writeMovie(to: folder.appendingPathComponent("01.mov"), color: 0xFF_40_80_C0)
        try await writeMovie(to: folder.appendingPathComponent("02.mov"), color: 0xFF_A0_50_40)
      } catch { fixture.remove(); throw error }
      return fixture
    }

    func remove() {
      UserDefaults.standard.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
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
        for frame in 0..<18 {
          while !input.isReadyForMoreMediaData, writer.status == .writing,
            ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
          }
          try #require(input.isReadyForMoreMediaData)
          try #require(adaptor.append(pixels,
            withPresentationTime: CMTime(value: Int64(frame), timescale: 24)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 18, timescale: 24))
        await writer.finishWriting()
        try #require(writer.status == .completed, "\(String(describing: writer.error))")
      } catch { writer.cancelWriting(); throw error }
    }
  }
}
