import AppKit
@preconcurrency import AVFoundation
import AVKit
import CoreVideo
import Darwin
import Foundation
import SwiftUI
import Testing

@testable import ImageViewer

/// Opt-in native-view playback coverage for a read-only local corpus. Media is
/// never captured, exported, or logged. The offscreen window follows the existing
/// NativeVideoPlayerViewTests hosting pattern, and audio stays muted throughout.
@Suite("실제 영상의 네이티브 화면 재생", .serialized)
@MainActor
struct RealVideoNativeViewTests {
  private enum Failure: Error {
    case scan, noPlayableCandidate, deadline(String), playback(String), invalidFrame
  }

  private struct Candidate: Sendable {
    let url: URL
    let bytes: Int
  }

  private struct FrameSamples {
    var times = Set<Double>()
    var width = 0
    var height = 0

    mutating func pull(_ output: AVPlayerItemVideoOutput, time: CMTime) throws {
      guard time.isNumeric, output.hasNewPixelBuffer(forItemTime: time) else { return }
      var displayTime = CMTime.invalid
      guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayTime)
      else { return }
      let width = CVPixelBufferGetWidth(buffer)
      let height = CVPixelBufferGetHeight(buffer)
      guard width > 0, height > 0, displayTime.isNumeric else { throw Failure.invalidFrame }
      // Retain only anonymous times and dimensions, never a pixel buffer.
      times.insert(displayTime.seconds)
      self.width = width
      self.height = height
    }
  }

  @Test("가장 큰 재생 가능 영상의 화면 준비·실제 프레임·탐색·해제",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_VIDEO_DIRECTORY"] != nil),
    .timeLimit(.minutes(8)))
  func largestPlayableMovieInNativeView() async throws {
    let started = ProcessInfo.processInfo.systemUptime
    let path = try #require(ProcessInfo.processInfo.environment["IMAGEVIEWER_VIDEO_DIRECTORY"])
    let candidates = try candidates(in: URL(fileURLWithPath: path, isDirectory: true))
    var selected: Candidate?
    var selectedDocument: VideoDocument?
    var rejectedCount = 0
    for candidate in candidates {
      do {
        let document = try await Self.loadDocument(candidate.url)
        guard document.isPlayable else { rejectedCount += 1; continue }
        selected = candidate
        selectedDocument = document
        break
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Native errors may contain a private filename or URL.
        rejectedCount += 1
      }
    }
    guard let selected, let document = selectedDocument else { throw Failure.noPlayableCandidate }

    _ = NSApplication.shared
    let state = VideoPlaybackState()
    state.player.isMuted = true
    let host = NSHostingView(rootView: NativeVideoPlayerView(player: state.player))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 480, height: 270),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    let asset = ImageAsset(url: selected.url, byteCount: Int64(selected.bytes), modificationDate: nil)
    let monitor = Task { await state.monitor(asset) }
    defer {
      monitor.cancel()
      state.stop()
      window.orderOut(nil)
      window.contentView = nil
      window.close()
    }

    try await waitUntil("native-bridge", state: state) {
      host.layoutSubtreeIfNeeded()
      return playerViews(in: host).count == 1
        && state.player.currentItem?.status == .readyToPlay
    }
    let view = try #require(playerViews(in: host).first)
    #expect(view.player === state.player)
    #expect(view.bounds.width > 0 && view.bounds.height > 0)
    #expect(view.isInteractive && view.controlsStyle == .inline)
    #expect(view.videoGravity == .resizeAspect)
    #expect(!view.allowsVideoFrameAnalysis && !view.updatesNowPlayingInfoCenter)
    let item = try #require(state.player.currentItem)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
    output.suppressesPlayerRendering = false
    item.add(output)
    defer { item.remove(output) }
    try await waitUntil("native-first-frame", state: state) {
      host.layoutSubtreeIfNeeded()
      return view.isReadyForDisplay
    }
    let readySeconds = ProcessInfo.processInfo.systemUptime - started

    var played = FrameSamples()
    let playbackStarted = ProcessInfo.processInfo.systemUptime
    let startTime = state.player.currentTime().seconds
    let advance = min(1.0, document.durationSeconds * 0.5)
    state.togglePlayback()
    try await waitUntil("native-playback", state: state) {
      try played.pull(output, time: state.player.currentTime())
      return state.player.currentTime().seconds >= startTime + advance && played.times.count >= 2
    }
    let playbackSeconds = ProcessInfo.processInfo.systemUptime - playbackStarted
    state.pause()
    let pausedTime = state.player.currentTime().seconds
    try await Task.sleep(for: .milliseconds(200))
    #expect(abs(state.player.currentTime().seconds - pausedTime) < 0.002)
    #expect(abs(state.currentSeconds - pausedTime) < 0.002)
    #expect(state.player.rate == 0 && !state.isPlaying)

    let seekStarted = ProcessInfo.processInfo.systemUptime
    let target = document.durationSeconds * 0.5
    state.seek(target)
    try await waitUntil("native-seek", state: state) { !state.isSeeking }
    #expect(abs(state.player.currentTime().seconds - target) < 0.01)
    var sought = FrameSamples()
    try await waitUntil("native-seek-frame", state: state) {
      try sought.pull(output, time: state.player.currentTime())
      return view.isReadyForDisplay && !sought.times.isEmpty
    }
    let seekSeconds = ProcessInfo.processInfo.systemUptime - seekStarted

    state.togglePlayback()
    try await waitUntil("native-resume", state: state) { state.player.rate != 0 }
    NativeVideoPlayerView.dismantleNSView(view, coordinator: ())
    #expect(view.player == nil)
    #expect(state.player.rate == 0)
    monitor.cancel()
    await monitor.value
    state.stop()
    let released = state.player.currentItem == nil && state.document == nil
    #expect(released)
    #expect(!state.isSeeking && !state.isPlaying && state.currentSeconds == 0)

    Self.log([
      "phase": "native-view", "candidateCount": candidates.count,
      "rejectedBeforeSelection": rejectedCount, "selectedBytes": selected.bytes,
      "pixelWidth": document.pixelWidth, "pixelHeight": document.pixelHeight,
      "decodedWidth": played.width, "decodedHeight": played.height,
      "distinctPlaybackFrames": played.times.count, "seekFrames": sought.times.count,
      "readySeconds": readySeconds, "playbackWallSeconds": playbackSeconds,
      "playbackClockSeconds": pausedTime - startTime, "seekSeconds": seekSeconds,
      "seconds": ProcessInfo.processInfo.systemUptime - started,
      "muted": true, "readOnly": true, "screenCapture": false,
    ])
  }

  private func candidates(in directory: URL) throws -> [Candidate] {
    do {
      let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
      let urls = try FileManager.default.contentsOfDirectory(at: directory,
        includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
      return try urls.compactMap { url -> Candidate? in
        guard MediaFormatRegistry.isVideo(url) else { return nil }
        let values = try url.resourceValues(forKeys: keys)
        guard values.isRegularFile == true, values.isSymbolicLink != true,
          let bytes = values.fileSize, bytes > 0 else { return nil }
        return Candidate(url: url, bytes: bytes)
      }.sorted { $0.bytes > $1.bytes }
    } catch { throw Failure.scan }
  }

  private nonisolated static func loadDocument(_ url: URL) async throws -> VideoDocument {
    try await withThrowingTaskGroup(of: VideoDocument.self) { group in
      group.addTask { try await VideoDocument.load(url: url) }
      group.addTask {
        try await Task.sleep(for: .seconds(60))
        throw Failure.deadline("document")
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw Failure.noPlayableCandidate }
      return result
    }
  }

  private func waitUntil(_ phase: String, state: VideoPlaybackState,
    _ predicate: () throws -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(60)
    while true {
      try Task.checkCancellation()
      if state.errorMessage != nil || state.player.currentItem?.status == .failed {
        throw Failure.playback(phase)
      }
      if try predicate() { return }
      guard ContinuousClock.now < deadline else { throw Failure.deadline(phase) }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func playerViews(in view: NSView) -> [NativeVideoPlayerView.PlayerView] {
    if let player = view as? NativeVideoPlayerView.PlayerView { return [player] }
    return view.subviews.flatMap { playerViews(in: $0) }
  }

  private static func log(_ fields: [String: Any]) {
    var fields = fields
    var usage = rusage()
    if getrusage(RUSAGE_SELF, &usage) == 0 { fields["processPeakRSSBytes"] = usage.ru_maxrss }
    guard let encoded = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    else { return }
    var line = Data("VIDEO_NATIVE ".utf8)
    line.append(encoded)
    line.append(0x0a)
    FileHandle.standardOutput.write(line)
  }
}
