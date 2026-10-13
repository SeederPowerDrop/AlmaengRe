@preconcurrency import AVFoundation
import CoreVideo
import Darwin
import Foundation
import Testing

@testable import ImageViewer

/// Opt-in, read-only real-media coverage:
/// IMAGEVIEWER_VIDEO_DIRECTORY=/path/to/movies swift test --filter RealVideoPlaybackTests
/// IMAGEVIEWER_VIDEO_LIMIT is an optional positive candidate count for a smoke run.
/// No pixels, audio, filenames, paths, descriptive metadata or source writes leave
/// this test. Decoded-frame counts are samples, not a display frame-rate benchmark.
@Suite("실제 동영상 읽기 전용 재생 시험", .serialized)
@MainActor
struct RealVideoPlaybackTests {
  private enum Failure: Error {
    case missingDirectory, invalidLimit, inventory, scan, deadline(String), check(String)
  }

  private struct Inventory: Sendable {
    let candidateURLs: Set<URL>
    let videoCounts: [String: Int]
    let excludedCounts: [String: Int]
    let candidateBytes: Int64
  }

  private struct TrackSummary: Sendable {
    let videoCodecs: [String]
    let audioCodecs: [String]
    let videoTrackCount: Int
    let audioTrackCount: Int
  }

  private struct FrameSample {
    let count: Int
    let clockAdvance: Double
    let firstTimestamp: Double?
    let lastTimestamp: Double?
  }

  @Test("폴더 목록·실제 프레임·일시정지·탐색·프레임 이동·끝 재시작·취소 복구",
    .enabled(if: !(ProcessInfo.processInfo.environment["IMAGEVIEWER_VIDEO_DIRECTORY"] ?? "").isEmpty),
    .timeLimit(.minutes(6)))
  func readOnlyRealVideos() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["IMAGEVIEWER_VIDEO_DIRECTORY"], !path.isEmpty else {
      throw Failure.missingDirectory
    }
    let started = ProcessInfo.processInfo.systemUptime
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    let inventory = try Self.inventory(directory)
    let opened: OpenedImageLibrary
    do { opened = try await ImageLibrary().open(urls: [directory], includesVideos: true) }
    catch { throw Failure.scan }
    defer { withExtendedLifetime(opened.access) {} }
    let allCandidates = opened.assets.filter(\.isVideo)
    let matchesInventory = Set(allCandidates.map { $0.url.standardizedFileURL }) == inventory.candidateURLs
    #expect(matchesInventory, "Video library candidates must match the registered top-level inventory")
    let limit: Int
    if let value = environment["IMAGEVIEWER_VIDEO_LIMIT"] {
      guard let parsed = Int(value), parsed > 0 else { throw Failure.invalidLimit }
      limit = parsed
    } else { limit = allCandidates.count }
    let candidates = Array(allCandidates.prefix(limit))
    try #require(!candidates.isEmpty, "The fixture has no registered video candidates")
    Self.log("inventory", started: started, fields: [
      "videoExtensionCounts": inventory.videoCounts, "excludedExtensionCounts": inventory.excludedCounts,
      "candidateCount": allCandidates.count, "testedCandidateCount": candidates.count,
      "candidateBytes": inventory.candidateBytes, "limited": candidates.count < allCandidates.count,
      "indexBasis": "registered video library order, zero based", "readOnly": true, "muted": true,
    ])

    let state = VideoPlaybackState()
    state.player.isMuted = true
    var failures: [[String: String]] = []
    var playable: [(index: Int, asset: ImageAsset, document: VideoDocument)] = []
    var unsupportedCount = 0
    var decodedFrameCount = 0
    var posterCount = 0
    var completedPlaybackCount = 0
    var unsupportedRecoveryCount = 0
    var awaitingRecovery = false

    for (index, asset) in candidates.enumerated() {
      let itemStarted = ProcessInfo.processInfo.systemUptime
      var fields: [String: Any] = ["index": index, "extension": asset.fileExtension,
        "bytes": asset.byteCount ?? 0]
      var loadedDocument: VideoDocument?
      var metadataFailure: String?
      do {
        loadedDocument = try await Self.bounded("document", seconds: 10) {
          try await VideoDocument.load(url: asset.url)
        }
      } catch {
        metadataFailure = Self.safeError(error)
        if case Failure.deadline = error {
          failures.append(["index": String(index), "phase": "document", "error": Self.safeError(error)])
        }
      }
      if let document = loadedDocument {
        fields["durationSeconds"] = document.durationSeconds
        fields["width"] = document.pixelWidth
        fields["height"] = document.pixelHeight
        fields["nominalFrameRate"] = document.nominalFrameRate
        fields["metadataPlayable"] = document.isPlayable
        fields["hasAudio"] = document.hasAudio
        do {
          let tracks = try await Self.bounded("tracks", seconds: 10) {
            try await Self.trackSummary(asset.url)
          }
          fields["videoCodecs"] = tracks.videoCodecs
          fields["audioCodecs"] = tracks.audioCodecs
          fields["videoTrackCount"] = tracks.videoTrackCount
          fields["audioTrackCount"] = tracks.audioTrackCount
        } catch { fields["trackSummaryError"] = Self.safeError(error) }
      } else { fields["metadataError"] = metadataFailure ?? "unknown" }

      // Reuse the production state across every file, including rejected files.
      var monitorStarted = false
      let monitor = Task {
        monitorStarted = true
        await state.monitor(asset)
      }
      do {
        // stop() intentionally leaves the previous error visible until the next
        // monitor starts. Wait for this MainActor task to enter monitor and clear
        // that old state before interpreting ready/error for the new source.
        try await waitUntil("monitor_started", seconds: 2) { monitorStarted }
        try await waitUntil("ready_or_error", seconds: 10) {
          state.player.currentItem?.status == .readyToPlay
            || state.player.currentItem?.status == .failed || state.errorMessage != nil
        }
        if state.errorMessage != nil || state.player.currentItem?.status == .failed {
          let playerError = state.player.currentItem?.error.map(Self.safeError)
          try await waitUntil("unsupported_error_message", seconds: 2) { state.errorMessage != nil }
          unsupportedCount += 1
          awaitingRecovery = true
          fields["classification"] = "runtime_unsupported"
          fields["errorSurfaced"] = true
          fields["runtimeError"] = playerError ?? metadataFailure ?? "AVPlayer_rejected_after_metadata"
          // monitor's failure path must release decoder ownership as well as report.
          try await waitUntil("unsupported_cleanup", seconds: 2) {
            state.player.currentItem == nil && state.document == nil && state.player.rate == 0
          }
        } else {
          guard let document = state.document, let item = state.player.currentItem else {
            throw Failure.check("ready_without_document_or_item")
          }
          if let metadataFailure { failures.append(["index": String(index), "phase": "document", "error": metadataFailure]) }
          if awaitingRecovery {
            unsupportedRecoveryCount += 1
            awaitingRecovery = false
            fields["recoveredAfterUnsupported"] = true
          }
          fields["classification"] = "playable"
          playable.append((index, asset, document))
          // Default output keeps the source's native pixel format/HDR characteristics.
          // Pixels are decoded in memory and immediately discarded, never exported.
          let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
          item.add(output)
          do {
            let poster = try await Self.bounded("poster", seconds: 10) {
              try await VideoMediaReader.posterFrame(for: asset.url, maxPixelSize: 512)
            }
            guard poster.image.width > 0, poster.image.height > 0,
              max(poster.image.width, poster.image.height) <= 512 else {
              throw Failure.check("invalid_poster_dimensions")
            }
            fields["posterWidth"] = poster.image.width
            fields["posterHeight"] = poster.image.height
            posterCount += 1
          } catch { failures.append(["index": String(index), "phase": "poster", "error": Self.safeError(error)]) }

          let playback = try await samplePlayback(state, output: output, duration: 1,
            minimumFrames: document.durationSeconds * max(1, document.nominalFrameRate) < 2 ? 1 : 2,
            minimumAdvance: min(0.15, document.durationSeconds * 0.2))
          decodedFrameCount += playback.count
          fields["sampledDecodedFrames"] = playback.count
          fields["playbackClockAdvance"] = playback.clockAdvance
          fields["firstDecodedTimestamp"] = playback.firstTimestamp
          fields["lastDecodedTimestamp"] = playback.lastTimestamp

          state.pause()
          let paused = state.player.currentTime().seconds
          try await Task.sleep(for: .milliseconds(150))
          guard state.player.rate == 0, !state.isPlaying,
            abs(state.player.currentTime().seconds - paused) < 0.005,
            abs(state.currentSeconds - paused) < 0.005 else {
            throw Failure.check("pause_unstable")
          }

          let tolerance = max(0.005, 1 / max(1, document.nominalFrameRate))
          let lastSafeTime = max(0, document.durationSeconds - max(0.5, tolerance * 3))
          var seekFrames = 0
          var seekSamples: [[String: Any]] = []
          for fraction in [0.25, 0.5, 0.9] {
            let target = min(lastSafeTime, document.durationSeconds * fraction)
            try await seek(state, to: target, tolerance: tolerance)
            let sample = try await samplePlayback(state, output: output, duration: 0.3,
              minimumFrames: 1, minimumAdvance: min(0.06, document.durationSeconds * 0.1))
            guard let displayed = sample.lastTimestamp, displayed >= target - tolerance,
              displayed <= target + 1 + tolerance else { throw Failure.check("seek_decoded_timestamp") }
            seekSamples.append(["target": target, "lastDecodedTimestamp": displayed,
              "sampledDecodedFrames": sample.count])
            seekFrames += sample.count
            state.pause()
          }
          fields["seekDecodedFrames"] = seekFrames
          fields["seekSamples"] = seekSamples
          decodedFrameCount += seekFrames

          let finalTarget = min(lastSafeTime, document.durationSeconds * 0.5)
          state.seek(min(lastSafeTime, document.durationSeconds * 0.9))
          guard state.isSeeking else { throw Failure.check("seek_not_pending") }
          state.step(1)
          state.togglePlayback()
          guard state.player.rate == 0 else { throw Failure.check("play_during_seek") }
          state.seek(min(lastSafeTime, document.durationSeconds * 0.25))
          state.seek(finalTarget)
          try await waitUntil("latest_seek", seconds: 8) { !state.isSeeking }
          guard abs(state.currentSeconds - finalTarget) <= tolerance,
            abs(state.player.currentTime().seconds - finalTarget) <= tolerance else {
            throw Failure.check("latest_seek_position")
          }
          fields["latestSeekWins"] = true
          fields["canStepForward"] = state.canStepForward
          fields["canStepBackward"] = state.canStepBackward
          for direction in [1, -1] {
            let available = direction > 0 ? state.canStepForward : state.canStepBackward
            guard available else { continue }
            let before = state.player.currentTime().seconds
            // A codec may advertise stepping even when this very short source
            // has no adjacent frame in the requested direction.
            guard direction > 0 ? before + tolerance < document.durationSeconds : before > tolerance else { continue }
            state.step(direction)
            try await waitUntil("frame_step", seconds: 3) {
              let difference = state.player.currentTime().seconds - before
              return direction > 0 ? difference > 0.000_001 : difference < -0.000_001
            }
            guard state.player.rate == 0 else { throw Failure.check("step_resumed_playback") }
          }
          item.remove(output)
          completedPlaybackCount += 1
          fields["exerciseCompleted"] = true
        }
      } catch {
        fields["exerciseError"] = Self.safeError(error)
        failures.append(["index": String(index), "phase": "playback", "error": Self.safeError(error)])
      }
      await cleanup(state, monitor: monitor)
      let clean = state.player.currentItem == nil && state.document == nil && state.player.rate == 0 && !state.isSeeking
      if !clean { failures.append(["index": String(index), "phase": "cleanup", "error": "retained_player_state"]) }
      fields["cleanedUp"] = clean
      Self.log("file", started: itemStarted, fields: fields)
    }

    // Recheck the largest and longest playable sources at EOF; selected sources
    // are described only by the same anonymous library indices used above.
    let largest = playable.max { ($0.asset.byteCount ?? 0) < ($1.asset.byteCount ?? 0) }
    let longest = playable.max { $0.document.durationSeconds < $1.document.durationSeconds }
    var eofIndices: Set<Int> = []
    for candidate in [largest, longest].compactMap({ $0 }) where eofIndices.insert(candidate.index).inserted {
      let phaseStarted = ProcessInfo.processInfo.systemUptime
      let monitor = Task { await state.monitor(candidate.asset) }
      do {
        try await waitUntil("eof_ready", seconds: 10) { state.player.currentItem?.status == .readyToPlay }
        guard state.errorMessage == nil, let item = state.player.currentItem else { throw Failure.check("eof_open") }
        if awaitingRecovery { unsupportedRecoveryCount += 1; awaitingRecovery = false }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let eofTolerance = max(0.005, 1 / max(1, candidate.document.nominalFrameRate))
        try await seek(state, to: max(0, candidate.document.durationSeconds - 0.25),
          tolerance: eofTolerance)
        state.togglePlayback()
        try await waitUntil("natural_eof", seconds: 8) {
          !state.isSeeking && state.player.rate == 0
            && state.player.currentTime().seconds >= candidate.document.durationSeconds - eofTolerance
        }
        let sample = try await samplePlayback(state, output: output, duration: 0.6,
          minimumFrames: candidate.document.durationSeconds * max(1, candidate.document.nominalFrameRate) < 2 ? 1 : 2,
          minimumAdvance: 0, restartingFromEOF: true)
        guard let restartedFrame = sample.firstTimestamp,
          restartedFrame < min(2, candidate.document.durationSeconds * 0.75) else {
          throw Failure.check("eof_did_not_restart")
        }
        decodedFrameCount += sample.count
        item.remove(output)
        Self.log("eof_restart", started: phaseStarted, fields: ["index": candidate.index,
          "sampledDecodedFrames": sample.count, "endReachedNaturally": true, "passed": true])
      } catch { failures.append(["index": String(candidate.index), "phase": "eof_restart", "error": Self.safeError(error)]) }
      await cleanup(state, monitor: monitor)
    }

    // Cancel while a precise seek callback is pending, then open another source
    // immediately. Await the canceled owner after the replacement owner starts.
    var cancellationCount = 0
    if !playable.isEmpty {
      for round in 0..<3 {
        let first = playable[round % playable.count]
        let next = playable[(round + 1) % playable.count]
        let phaseStarted = ProcessInfo.processInfo.systemUptime
        let firstMonitor = Task { await state.monitor(first.asset) }
        var nextMonitor: Task<Void, Never>?
        do {
          try await waitUntil("cancel_ready", seconds: 10) { state.player.currentItem?.status == .readyToPlay }
          state.seek(first.document.durationSeconds * 0.8)
          guard state.isSeeking else { throw Failure.check("cancel_seek_not_pending") }
          firstMonitor.cancel()
          state.stop()
          guard state.player.currentItem == nil, state.document == nil, state.player.rate == 0,
            !state.isSeeking else { throw Failure.check("cancel_not_clean") }
          nextMonitor = Task { await state.monitor(next.asset) }
          await firstMonitor.value
          try await waitUntil("replacement_ready", seconds: 10) { state.player.currentItem?.status == .readyToPlay }
          let replacedCorrectly = state.document?.sourceURL.standardizedFileURL == next.asset.url.standardizedFileURL
          guard replacedCorrectly, state.errorMessage == nil, let item = state.player.currentItem else {
            throw Failure.check("replacement_document")
          }
          let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
          item.add(output)
          let sample = try await samplePlayback(state, output: output, duration: 0.4,
            minimumFrames: next.document.durationSeconds * max(1, next.document.nominalFrameRate) < 2 ? 1 : 2,
            minimumAdvance: min(0.06, next.document.durationSeconds * 0.1))
          decodedFrameCount += sample.count
          item.remove(output)
          cancellationCount += 1
          Self.log("cancel_and_switch", started: phaseStarted, fields: ["index": first.index,
            "replacementIndex": next.index, "sampledDecodedFrames": sample.count, "passed": true])
        } catch { failures.append(["index": String(first.index), "phase": "cancel_and_switch", "error": Self.safeError(error)]) }
        firstMonitor.cancel()
        await firstMonitor.value
        if let nextMonitor { await cleanup(state, monitor: nextMonitor) }
        else { state.stop() }
      }
    }
    Self.log("summary", started: started, fields: [
      "candidateCount": candidates.count, "playableCount": playable.count,
      "runtimeUnsupportedCount": unsupportedCount, "completedPlaybackCount": completedPlaybackCount,
      "posterCount": posterCount, "sampledDecodedFrames": decodedFrameCount,
      "eofRestartCandidateCount": eofIndices.count, "cancelAndSwitchCount": cancellationCount,
      "unsupportedRecoveryCount": unsupportedRecoveryCount, "failures": failures,
      "audioMutedThroughout": state.player.isMuted, "sourceFilesWritten": 0,
    ])
    let allClean = state.player.currentItem == nil && state.document == nil && state.player.rate == 0 && !state.isSeeking
    #expect(allClean, "The final player must release the movie and all pending seeks")
    #expect(failures.isEmpty, "Anonymous per-file failures are recorded in VIDEO_REAL diagnostics")
  }

  private func cleanup(_ state: VideoPlaybackState, monitor: Task<Void, Never>) async {
    monitor.cancel()
    state.stop()
    await monitor.value
  }

  private func seek(_ state: VideoPlaybackState, to seconds: Double, tolerance: Double) async throws {
    state.seek(seconds)
    try await waitUntil("seek", seconds: 8) { !state.isSeeking }
    guard abs(state.currentSeconds - seconds) <= tolerance,
      abs(state.player.currentTime().seconds - seconds) <= tolerance,
      state.player.rate == 0 else { throw Failure.check("seek_position_or_pause") }
  }

  private func samplePlayback(_ state: VideoPlaybackState, output: AVPlayerItemVideoOutput,
    duration: Double, minimumFrames: Int, minimumAdvance: Double, restartingFromEOF: Bool = false
  ) async throws -> FrameSample {
    let before = state.player.currentTime().seconds
    var timestamps: Set<Int64> = []
    state.togglePlayback()
    // EOF toggle performs an asynchronous seek before resuming the player.
    try await waitUntil("play_started", seconds: 5) { state.player.rate > 0 || state.errorMessage != nil }
    let startupDeadline = ProcessInfo.processInfo.systemUptime + 8
    let totalDeadline = startupDeadline + duration
    var observationStarted: TimeInterval?
    while true {
      let now = ProcessInfo.processInfo.systemUptime
      if let observationStarted, now - observationStarted >= duration { break }
      guard now < totalDeadline else { throw Failure.deadline("decoded_frame_observation") }
      if observationStarted == nil, now >= startupDeadline { throw Failure.deadline("first_decoded_frame") }
      guard state.errorMessage == nil, state.player.currentItem?.status != .failed else {
        throw Failure.check("decoder_failed")
      }
      let time = state.player.currentTime()
      if output.hasNewPixelBuffer(forItemTime: time) {
        var displayed = CMTime.invalid
        if let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayed),
          CVPixelBufferGetWidth(buffer) > 0, CVPixelBufferGetHeight(buffer) > 0,
          displayed.seconds.isFinite {
          timestamps.insert(Int64((displayed.seconds * 1_000_000).rounded()))
          // AVPlayer.rate can become nonzero while local decoding is still
          // warming up. Start the observation window only after a real frame.
          if observationStarted == nil { observationStarted = ProcessInfo.processInfo.systemUptime }
        }
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    let after = state.player.currentTime().seconds
    let advance = restartingFromEOF ? after : after - before
    guard timestamps.count >= minimumFrames else { throw Failure.check("insufficient_decoded_frames_\(timestamps.count)") }
    guard advance >= minimumAdvance else { throw Failure.check("clock_did_not_advance") }
    return FrameSample(count: timestamps.count, clockAdvance: advance,
      firstTimestamp: timestamps.min().map { Double($0) / 1_000_000 },
      lastTimestamp: timestamps.max().map { Double($0) / 1_000_000 })
  }

  private func waitUntil(_ phase: String, seconds: Double, _ predicate: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !predicate() {
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.deadline(phase) }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  nonisolated private static func bounded<T: Sendable>(_ phase: String, seconds: Double,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(for: .seconds(seconds))
        throw Failure.deadline(phase)
      }
      defer { group.cancelAll() }
      guard let value = try await group.next() else { throw Failure.check("empty_operation") }
      return value
    }
  }

  nonisolated private static func inventory(_ directory: URL) throws -> Inventory {
    do {
      let urls = try FileManager.default.contentsOfDirectory(at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])
      var candidates: Set<URL> = []
      var counts: [String: Int] = [:], excluded: [String: Int] = [:]
      var bytes: Int64 = 0
      let knownVideoExtensions = MediaFormatRegistry.videoExtensions.union(["mkv", "webm", "flv", "wmv", "ogv"])
      for url in urls {
        let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { continue }
        let suffix = url.pathExtension.lowercased()
        if knownVideoExtensions.contains(suffix) { counts[suffix, default: 0] += 1 }
        if MediaFormatRegistry.isVideo(url) {
          candidates.insert(url.standardizedFileURL)
          bytes += Int64(values.fileSize ?? 0)
        } else if knownVideoExtensions.contains(suffix) { excluded[suffix, default: 0] += 1 }
      }
      return Inventory(candidateURLs: candidates, videoCounts: counts, excludedCounts: excluded,
        candidateBytes: bytes)
    } catch { throw Failure.inventory }
  }

  nonisolated private static func trackSummary(_ url: URL) async throws -> TrackSummary {
    let asset = AVURLAsset(url: url)
    let video = try await asset.loadTracks(withMediaType: .video)
    let audio = try await asset.loadTracks(withMediaType: .audio)
    var videoCodecs: [String] = [], audioCodecs: [String] = []
    for track in video {
      for format in try await track.load(.formatDescriptions) { videoCodecs.append(fourCC(CMFormatDescriptionGetMediaSubType(format))) }
    }
    for track in audio {
      for format in try await track.load(.formatDescriptions) { audioCodecs.append(fourCC(CMFormatDescriptionGetMediaSubType(format))) }
    }
    return TrackSummary(videoCodecs: videoCodecs, audioCodecs: audioCodecs,
      videoTrackCount: video.count, audioTrackCount: audio.count)
  }

  nonisolated private static func fourCC(_ value: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 255) }
    return bytes.allSatisfy { $0 >= 32 && $0 <= 126 }
      ? String(decoding: bytes, as: UTF8.self) : String(format: "0x%08x", value)
  }

  nonisolated private static func safeError(_ error: Error) -> String {
    if let failure = error as? Failure {
      switch failure {
      case .deadline(let phase): return "deadline:\(phase)"
      case .check(let check): return "check:\(check)"
      case .missingDirectory: return "missing_directory"
      case .invalidLimit: return "invalid_limit"
      case .inventory: return "inventory"
      case .scan: return "scan"
      }
    }
    let nsError = error as NSError
    // Never use localizedDescription or userInfo: both can reveal source paths.
    return "\(nsError.domain):\(nsError.code)"
  }

  nonisolated private static func log(_ phase: String, started: TimeInterval, fields: [String: Any]) {
    var values = fields
    values["phase"] = phase
    values["seconds"] = ProcessInfo.processInfo.systemUptime - started
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    if status == KERN_SUCCESS { values["rssBytes"] = UInt64(info.resident_size) }
    var usage = rusage()
    if getrusage(RUSAGE_SELF, &usage) == 0 { values["processPeakRSSBytes"] = usage.ru_maxrss }
    guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
    var line = Data("VIDEO_REAL ".utf8)
    line.append(data)
    line.append(0x0a)
    FileHandle.standardOutput.write(line)
  }
}
