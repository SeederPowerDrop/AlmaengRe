@preconcurrency import AVFoundation
import AVKit
import AppKit
import CoreVideo
import Foundation
import SwiftUI
import Testing

@testable import ImageViewer

@Suite("영상 불러오기 실패 원인", .serialized)
@MainActor
struct VideoFailureReasonTests {
  @Test("빈 영상은 이전 파일 크기에 관계없이 실제 0바이트 원인을 표시한다")
  func emptyMovieReportsFreshSourceReason() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("empty.mov")
    try Data().write(to: url)
    let expected = await MediaLoadFailure.message(
      for: VideoProcessingError.noVideoTrack, url: url)
    let state = VideoPlaybackState()

    await state.monitor(ImageAsset(url: url, byteCount: 8_192, modificationDate: nil))

    #expect(expected != nil)
    #expect(state.errorMessage == expected)
    #expect(state.player.currentItem == nil && state.document == nil)
  }

  @Test("목록에서 사라진 영상은 일반 재생 오류 대신 파일 원인을 표시한다")
  func missingMovieReportsMissingSource() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("removed.mp4")
    let expected = await MediaLoadFailure.message(
      for: VideoProcessingError.sourceUnavailable, url: url)
    let state = VideoPlaybackState()

    await state.monitor(ImageAsset(url: url, byteCount: 8_192, modificationDate: nil))

    #expect(expected != nil)
    #expect(state.errorMessage == expected)
    #expect(state.player.currentItem == nil && state.document == nil)
    #expect(state.errorMessage?.contains(folder.path) == false)
  }

  @Test("재생 준비 취소는 파일 오류를 표시하지 않는다")
  func cancelledMonitorDoesNotReportFailure() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let state = VideoPlaybackState()
    let asset = ImageAsset(url: folder.appendingPathComponent("not-opened.mp4"),
      byteCount: nil, modificationDate: nil)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await state.monitor(asset)
    }

    await task.value

    #expect(state.errorMessage == nil)
    #expect(state.player.currentItem == nil && state.document == nil)
  }

  @Test("미리보기 성공 뒤 재생 실패 원인은 플레이어 해제 후에도 남고 복구되면 사라진다", arguments: [false, true])
  func hostedFailureSurvivesPlayerReleaseAndClearsAfterRecovery(isDark: Bool) async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("recoverable.mov")
    try await writeMovie(to: url)
    let savedMovie = try Data(contentsOf: url)
    let asset = ImageAsset(url: url, byteCount: Int64(savedMovie.count), modificationDate: nil)
    let grid = VideoGridPlaybackState()
    grid.updateVisibleAssets([asset])
    var readyCount = 0
    _ = NSApplication.shared
    let host = NSHostingView(rootView: AnyView(VideoViewerTile(asset: asset,
      itemCount: 2, thumbnailPipeline: ThumbnailPipeline(), allowsPlayback: true,
      onOpenTools: {}, onOpenFullScreen: { _, _ in }, onReady: { _ in readyCount += 1 },
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
    try await waitUntil("initial poster displayed") { host.layoutSubtreeIfNeeded(); return readyCount > 0 }
    let initialGlyphs = try await failureGlyphCount(in: host)
    #expect(initialGlyphs < 20, "The initial synthetic poster must contain no failure text")
    // The tile already has a good poster. Only the later playback attempt fails.
    try FileManager.default.removeItem(at: url)
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    grid.playAll()
    try await waitUntil("failed playback reported through tile callback") {
      host.layoutSubtreeIfNeeded()
      return grid.playingIDs.isEmpty
    }
    let currentGlyphs = try await failureGlyphCount(in: host)
    #expect(currentGlyphs > 100, "The failed player must visibly show its reason")
    // Return to hover waiting with the pointer outside this offscreen window.
    // This releases the failed player through the same stop() path as hover exit.
    grid.reset()
    grid.updateVisibleAssets([asset])
    let retainedGlyphs = try await failureGlyphCount(in: host)
    #expect(nativePlayer(in: host) == nil)
    #expect(retainedGlyphs > 100, "Releasing the failed player must leave its visible reason over the cached poster")

    try savedMovie.write(to: url)
    grid.playAll()
    try await waitUntil("restored video ready without failure notice") {
      host.layoutSubtreeIfNeeded()
      return nativePlayer(in: host)?.player?.currentItem?.status == .readyToPlay
    }
    // Drop the successful player again: stale failure must not return on its poster.
    grid.reset()
    grid.updateVisibleAssets([asset])
    try await waitUntil("restored player released") { host.layoutSubtreeIfNeeded(); return nativePlayer(in: host) == nil }
    let recoveredGlyphs = try await failureGlyphCount(in: host)
    #expect(recoveredGlyphs < 20, "Successful playback must clear the old reason before its player is released")
    print("VIDEO_FAILURE_GLYPHS dark=\(isDark) initial=\(initialGlyphs) current=\(currentGlyphs) retained=\(retainedGlyphs) recovered=\(recoveredGlyphs)")
  }

  private func failureGlyphCount(in host: NSView) async throws -> Int {
    // Offscreen SwiftUI hosts do not expose accessibility children on every OS.
    // Render the real text instead. The middle of the saturated blue fixture
    // has no neutral light pixels until a failure notice is drawn over it.
    // Exclude the header and bottom hover hint from this region.
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    var count = 0
    for y in (bitmap.pixelsHigh * 3 / 10)..<(bitmap.pixelsHigh * 8 / 10) {
      for x in (bitmap.pixelsWide / 10)..<(bitmap.pixelsWide * 9 / 10) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        let lightest = max(color.redComponent, color.greenComponent, color.blueComponent)
        let darkest = min(color.redComponent, color.greenComponent, color.blueComponent)
        if lightest - darkest < 0.08 && darkest > 0.5 { count += 1 }
      }
    }
    return count
  }

  private func nativePlayer(in view: NSView) -> AVPlayerView? {
    if let player = view as? AVPlayerView { return player }
    return view.subviews.lazy.compactMap { nativePlayer(in: $0) }.first
  }

  private func waitUntil(_ phase: String, _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !predicate(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(predicate(), "The hosted video did not reach: \(phase)")
  }

  private func writeMovie(to url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 96, AVVideoHeightKey: 64,
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
    for frame in 0..<12 {
      while !input.isReadyForMoreMediaData, writer.status == .writing, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      try #require(input.isReadyForMoreMediaData)
      try #require(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 6)))
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
    await writer.finishWriting()
    try #require(writer.status == .completed)
  }

  private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("video-failure-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
  }
}
