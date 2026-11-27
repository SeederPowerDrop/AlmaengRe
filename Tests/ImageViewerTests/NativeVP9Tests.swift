import AppKit
@preconcurrency import AVFoundation
import AVKit
import CoreVideo
import Foundation
import Testing

@testable import ImageViewer

/// The small test-only fixture is generated testsrc2 + sine, VP9/AAC in MP4.
/// No conversion tool, codec library or fixture is shipped in the application.
@Suite("시스템 VP9 디코더의 실제 읽기·재생", .serialized)
@MainActor
struct NativeVP9Tests {
  private func fixture() throws -> URL {
    try #require(Bundle.module.url(forResource: "test-pattern", withExtension: "mp4", subdirectory: "VP9"))
  }

  @Test("동시 정보·썸네일·필터 요청은 첫 VP9 파일부터 읽을 수 있다")
  func concurrentMetadataAndPosters() async throws {
    let url = try fixture()
    let before = try Data(contentsOf: url)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<12 {
        group.addTask {
          switch index % 3 {
          case 0:
            let document = try await VideoDocument.load(url: url)
            #expect(document.isPlayable && document.hasAudio)
            #expect(document.pixelSize == CGSize(width: 96, height: 64))
          case 1:
            let poster = try await VideoMediaReader.posterFrame(for: url, maxPixelSize: 48)
            #expect(poster.image.width == 48 && poster.image.height == 32)
          default:
            let metadata = try await LibrarySortMetadataReader.read(url, isVideo: true)
            #expect(metadata.pixelWidth == 96 && metadata.pixelHeight == 64)
          }
        }
      }
      try await group.waitForAll()
    }
    let asset = NativeVideoAsset.make(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let description = try #require(try await track.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_VP9)
    let pipeline = ImagePipeline(maxConcurrentDecodes: 1)
    let frame = try await pipeline.renderFrame(url: url, maxPixelSize: 48,
      adjustments: .identity, prefersHDR: false)
    // The full viewer buckets requests (unlike the direct poster API) and
    // never enlarges this 96x64 fixture to fill that bucket.
    #expect(frame.image.width == 96 && frame.image.height == 64)
    let thumbnails = ThumbnailPipeline()
    let thumbnail = try await thumbnails.thumbnail(for: ImageAsset(url: url,
      byteCount: nil, modificationDate: nil), maxPixelSize: 128)
    #expect(thumbnail.width == 96 && thumbnail.height == 64)
    #expect(try Data(contentsOf: url) == before)
    await pipeline.purgeCaches()
  }

  @Test("네이티브 플레이어가 VP9 프레임을 표시하고 탐색·일시정지·해제한다")
  func nativePlaybackAndSeek() async throws {
    _ = NSApplication.shared
    let url = try fixture()
    let original = try Data(contentsOf: url)
    let state = VideoPlaybackState()
    state.player.isMuted = true
    let view = NativeVideoPlayerView.PlayerView(frame: CGRect(x: 0, y: 0, width: 192, height: 128))
    view.player = state.player
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    window.orderBack(nil)
    let monitor = Task { await state.monitor(ImageAsset(url: url, byteCount: nil, modificationDate: nil)) }
    defer {
      monitor.cancel()
      state.stop()
      view.player = nil
      window.orderOut(nil)
    }
    try await wait { state.player.currentItem?.status == .readyToPlay || state.errorMessage != nil }
    #expect(state.errorMessage == nil)
    let item = try #require(state.player.currentItem)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    item.add(output)
    state.resume()
    var frameTimes = Set<Double>()
    try await wait {
      let time = state.player.currentTime()
      if output.hasNewPixelBuffer(forItemTime: time) {
        var actual = CMTime.invalid
        if let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &actual) {
          #expect(CVPixelBufferGetWidth(buffer) == 96 && CVPixelBufferGetHeight(buffer) == 64)
          if actual.isNumeric { frameTimes.insert(actual.seconds) }
        }
      }
      return frameTimes.count >= 3 && view.isReadyForDisplay
    }
    state.pause()
    #expect(state.player.rate == 0)
    state.seek(1.5)
    try await wait { !state.isSeeking && abs(state.player.currentTime().seconds - 1.5) < 0.1 }
    state.resume()
    try await wait { state.player.currentTime().seconds > 1.7 }
    monitor.cancel()
    await monitor.value
    #expect(state.player.currentItem == nil && state.player.rate == 0)
    #expect(try Data(contentsOf: url) == original)
  }

  @Test("VP9 프레임·선택 구간을 기존 저장 경로로 내보내며 원본을 보존한다")
  func nativeFrameAndRangeExport() async throws {
    let url = try fixture()
    let original = try Data(contentsOf: url)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vp9-export-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let exporter = VideoExporter()
    let frame = try await exporter.extractFrame(from: url, at: 1,
      to: directory.appendingPathComponent("frame.png"))
    #expect(frame.pixelWidth == 96 && frame.pixelHeight == 64)
    let movie = try await exporter.export(from: url, range: VideoTimeRange(start: 0.5, end: 1.5),
      to: directory.appendingPathComponent("clip.mp4"))
    #expect(movie.pixelWidth == 96 && movie.pixelHeight == 64)
    #expect(abs(movie.durationSeconds - 1) < 0.1)
    let document = try await VideoDocument.load(url: movie.destinationURL)
    #expect(document.isPlayable && document.hasAudio)
    #expect(try Data(contentsOf: url) == original)
  }

  private func wait(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(12)
    while !predicate(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(predicate(), "VP9 native operation did not reach its expected state")
  }
}
