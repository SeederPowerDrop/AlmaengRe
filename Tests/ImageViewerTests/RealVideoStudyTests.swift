@preconcurrency import AVFoundation
import CoreVideo
import Darwin
import Foundation
import Testing

@testable import ImageViewer

/// Opt-in, read-only actual-media coverage. Set IMAGEVIEWER_VIDEO_DIRECTORY and
/// filter RealVideoStudyTests. Logs contain anonymous indices/counts only. Text,
/// frames, audio, filenames, and source paths are never logged or exported.
@Suite("실제 영상 속도·이중 자막 읽기 전용 검증", .serialized)
@MainActor
struct RealVideoStudyTests {
  private enum Failure: Error { case directory, inventory, noPlayableVideo, deadline(String), playback(String), subtitle(String) }
  private struct SourceStat: Equatable {
    let device: Int32, inode: UInt64, size: Int64
    let mtime: Int64, mtimeNanos: Int64, ctime: Int64, ctimeNanos: Int64
  }
  private struct KnownCue { let start: Double, end: Double, text: String }

  @Test("실제 대표 영상 2개의 0.25·0.5·1.5·2·4배속·탐색·재개와 한영 자막",
    .enabled(if: !(ProcessInfo.processInfo.environment["IMAGEVIEWER_VIDEO_DIRECTORY"] ?? "").isEmpty),
    .timeLimit(.minutes(5)))
  func realRatesAndDualSubtitles() async throws {
    let directory = try directoryURL()
    let before = try snapshot(directory)
    defer { verifyUnchanged(directory, before: before) }
    let opened: OpenedImageLibrary
    do { opened = try await ImageLibrary().open(urls: [directory], includesVideos: true) }
    catch { throw Failure.inventory }
    defer { withExtendedLifetime(opened.access) {} }
    let candidates = opened.assets.filter(\.isVideo)
    // Scan the two ends of production library order; do not assume every MP4
    // codec is playable or duplicate the same source in a one-video folder.
    var selected: [(Int, ImageAsset)] = []
    for indices in [Array(candidates.indices), Array(candidates.indices.reversed())] {
      for index in indices where !selected.contains(where: { $0.0 == index }) {
        do {
          let document = try await VideoDocument.load(url: candidates[index].url)
          if document.isPlayable {
            selected.append((index, candidates[index])); break
          }
        } catch { continue }
      }
    }
    guard !selected.isEmpty else { throw Failure.noPlayableVideo }
    let state = VideoPlaybackState()
    state.player.isMuted = true
    var rateChecks = 0, dualChecks = 0, decodedFrames = 0
    for (index, asset) in selected {
      let monitor = Task { await state.monitor(asset) }
      do {
        try await wait("ready", state: state) { state.player.currentItem?.status == .readyToPlay && state.document != nil && state.study != nil }
        guard let item = state.player.currentItem, let document = state.document, let session = state.study else { throw Failure.playback("missing_ready_state") }
        defer {
          session.playbackRate = 1
          session.primary.remove(); session.secondary.remove(); session.cancelPendingWork()
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        defer { item.remove(output) }
        for rate in [0.25, 0.5, 1.5, 2.0, 4.0] {
          state.pause()
          session.playbackRate = rate
          try await wait("default_rate", state: state) { abs(Double(state.player.defaultRate) - rate) < 0.001 }
          let target = min(document.durationSeconds * 0.25, max(1, document.durationSeconds - 2))
          state.seek(target)
          try await wait("seek", state: state) { !state.isSeeking }
          let seekMatches = abs(state.player.currentTime().seconds - target) < max(0.02, 1 / max(1, document.nominalFrameRate))
          #expect(seekMatches, "Precise seek must remain correct after choosing a playback rate")
          state.togglePlayback()
          try await wait("rate_applied", state: state) { abs(Double(state.player.rate) - rate) < 0.001 }
          var times = Set<Int64>()
          try await wait("first_decoded_frame", state: state) { pull(output, time: state.player.currentTime(), into: &times); return !times.isEmpty }
          let started = ProcessInfo.processInfo.systemUptime
          let clockBefore = state.player.currentTime().seconds
          while ProcessInfo.processInfo.systemUptime - started < 0.65 {
            pull(output, time: state.player.currentTime(), into: &times)
            try await Task.sleep(for: .milliseconds(10))
          }
          let advance = state.player.currentTime().seconds - clockBefore
          let hasFramesAndAdvance = times.count >= 2 && advance > 0.1
          #expect(hasFramesAndAdvance, "Chosen rate must decode multiple frames and advance the playback clock")
          decodedFrames += times.count
          state.pause()
          let paused = state.player.currentTime().seconds
          try await Task.sleep(for: .milliseconds(120))
          let pausedStable = state.player.rate == 0 && !state.isPlaying && abs(state.player.currentTime().seconds - paused) < 0.005
          #expect(pausedStable, "Pause must remain stable at every selected speed")
          state.seek(min(document.durationSeconds * 0.5, max(1, document.durationSeconds - 2)))
          try await wait("resume_seek", state: state) { !state.isSeeking }
          state.togglePlayback()
          try await wait("resume_selected_rate", state: state) { abs(Double(state.player.rate) - rate) < 0.001 }
          state.pause()
          rateChecks += 1
          Self.log(["phase": "rate", "index": index, "rate": rate, "sampledFrames": times.count,
            "clockAdvanceSeconds": advance, "observationSeconds": ProcessInfo.processInfo.systemUptime - started,
            "pausedStable": pausedStable, "seekMatches": seekMatches])
        }
        // The actual lecture files each have UTF-8 .en.srt and .ko.srt. Other
        // folders may lack this pair; all supported sidecars get a separate test.
        await session.discoverSidecars()
        let english = session.sidecarURLs.first { $0.lastPathComponent.lowercased().hasSuffix(".en.srt") }
        let korean = session.sidecarURLs.first { $0.lastPathComponent.lowercased().hasSuffix(".ko.srt") }
        if let english, let korean {
          let en = try knownCue(english), ko = try knownCue(korean)
          session.primary.load(url: english)
          session.secondary.load(url: korean)
          try await wait("dual_subtitles", state: state) {
            !session.primary.isLoading && !session.secondary.isLoading
              && session.primary.document != nil && session.secondary.document != nil
          }
          let enTime = (en.start + en.end) / 2, koTime = (ko.start + ko.end) / 2
          session.primary.offsetSeconds = 0
          session.secondary.offsetSeconds = 0
          let primaryMatches = session.primary.text(at: enTime) == en.text
          let secondaryMatches = session.secondary.text(at: koTime) == ko.text
          #expect(primaryMatches, "English cue must match independently read source text (text suppressed)")
          #expect(secondaryMatches, "Korean cue must match independently read source text (text suppressed)")
          session.primary.offsetSeconds = 2
          session.secondary.offsetSeconds = -1
          let delayedPrimaryMatches = session.primary.text(at: enTime + 2) == en.text
          let advancedSecondaryMatches = session.secondary.text(at: koTime - 1) == ko.text
          #expect(delayedPrimaryMatches && advancedSecondaryMatches, "Both subtitle offsets must act independently (text suppressed)")
          session.primary.isEnabled = false
          let independentSecondary = session.primary.text(at: enTime + 2) == nil && session.secondary.text(at: koTime - 1) == ko.text
          #expect(independentSecondary, "Disabling the primary slot must preserve the secondary slot")
          session.primary.isEnabled = true
          dualChecks += 1
          Self.log(["phase": "dual_subtitles", "index": index, "matchedSidecars": session.sidecarURLs.count,
            "primaryCueCount": session.primary.selectedTrack?.cues.count ?? 0,
            "secondaryCueCount": session.secondary.selectedTrack?.cues.count ?? 0,
            "primaryTextMatched": primaryMatches, "secondaryTextMatched": secondaryMatches,
            "independentOffsetsMatched": delayedPrimaryMatches && advancedSecondaryMatches,
            "subtitleTextExported": false])
        }
      } catch {
        monitor.cancel(); state.stop(); await monitor.value
        // Native errors can contain a source URL. Never let one reach test output.
        if let safe = error as? Failure { throw safe }
        throw Failure.playback("native_operation_failed")
      }
      monitor.cancel(); state.stop(); await monitor.value
      let clean = state.player.currentItem == nil && state.document == nil && state.study == nil && state.player.rate == 0
      #expect(clean, "Leaving a real video must release player state")
    }
    Self.log(["phase": "summary", "candidateCount": candidates.count, "selectedCount": selected.count,
      "rateChecks": rateChecks, "dualSubtitleChecks": dualChecks, "sampledDecodedFrames": decodedFrames,
      "muted": state.player.isMuted, "sourceWrites": 0, "pixelsExported": false])
  }

  @Test("실제 폴더의 모든 지원 자막 읽기와 활성 구간 조회",
    .enabled(if: !(ProcessInfo.processInfo.environment["IMAGEVIEWER_VIDEO_DIRECTORY"] ?? "").isEmpty),
    .timeLimit(.minutes(2)))
  func allActualSubtitleFiles() throws {
    let directory = try directoryURL()
    let before = try snapshot(directory)
    defer { verifyUnchanged(directory, before: before) }
    let files = try regularFiles(directory).filter { ["srt", "vtt", "smi", "sami"].contains($0.pathExtension.lowercased()) }
    var cueCount = 0, trackCount = 0, formats: [String: Int] = [:]
    for (index, url) in files.enumerated() {
      let document: SubtitleDocument
      do { document = try SubtitleReader.read(url) }
      catch { throw Failure.subtitle("read_failed_at_anonymous_index_\(index)") }
      let hasTracks = !document.tracks.isEmpty
      #expect(hasTracks, "A real supported subtitle must contain at least one track")
      for track in document.tracks {
        guard let cue = track.cues.first else { throw Failure.subtitle("empty_track") }
        let displaysKnownCue = track.text(at: (cue.start + cue.end) / 2)?.contains(cue.text) == true
        #expect(displaysKnownCue, "A real cue must be active inside its own interval (text suppressed)")
        cueCount += track.cues.count; trackCount += 1
      }
      formats[url.pathExtension.lowercased(), default: 0] += 1
    }
    Self.log(["phase": "all_subtitles", "fileCount": files.count, "trackCount": trackCount,
      "cueCount": cueCount, "formats": formats, "sourceWrites": 0, "subtitleTextExported": false])
  }

  private func wait(_ phase: String, state: VideoPlaybackState, _ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 12
    while !condition() {
      if state.errorMessage != nil || state.player.currentItem?.status == .failed { throw Failure.playback(phase) }
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.deadline(phase) }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
  private func pull(_ output: AVPlayerItemVideoOutput, time: CMTime, into times: inout Set<Int64>) {
    guard output.hasNewPixelBuffer(forItemTime: time) else { return }
    var displayed = CMTime.invalid
    guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayed),
      CVPixelBufferGetWidth(buffer) > 0, CVPixelBufferGetHeight(buffer) > 0, displayed.seconds.isFinite else { return }
    times.insert(Int64((displayed.seconds * 1_000_000).rounded()))
  }
  private func directoryURL() throws -> URL {
    guard let path = ProcessInfo.processInfo.environment["IMAGEVIEWER_VIDEO_DIRECTORY"], !path.isEmpty else { throw Failure.directory }
    return URL(fileURLWithPath: path, isDirectory: true)
  }
  private func regularFiles(_ directory: URL) throws -> [URL] {
    do {
      return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        .filter { let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]); return values.isRegularFile == true && values.isSymbolicLink != true }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    } catch { throw Failure.inventory }
  }
  private func snapshot(_ directory: URL) throws -> [URL: SourceStat] {
    var result: [URL: SourceStat] = [:]
    for url in try regularFiles(directory) {
      var value = stat()
      guard url.path.withCString({ lstat($0, &value) }) == 0 else { throw Failure.inventory }
      result[url] = SourceStat(device: value.st_dev, inode: value.st_ino, size: value.st_size,
        mtime: Int64(value.st_mtimespec.tv_sec), mtimeNanos: Int64(value.st_mtimespec.tv_nsec),
        ctime: Int64(value.st_ctimespec.tv_sec), ctimeNanos: Int64(value.st_ctimespec.tv_nsec))
    }
    return result
  }
  private func verifyUnchanged(_ directory: URL, before: [URL: SourceStat]) {
    let after = try? snapshot(directory)
    let unchanged = after == before
    #expect(unchanged, "Original size/device/inode/mtime/ctime must remain unchanged (paths suppressed)")
    Self.log(["phase": "source_metadata", "sourceFileCount": before.count, "unchanged": unchanged])
  }
  private func knownCue(_ url: URL) throws -> KnownCue {
    // Independent, deliberately small SRT reference reader for plain UTF-8
    // lecture cues; no source strings are attached to expectations or logs.
    guard let data = try? Data(contentsOf: url), let source = String(data: data, encoding: .utf8) else { throw Failure.subtitle("reference_utf8") }
    let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    for block in normalized.components(separatedBy: "\n\n") {
      let lines = block.components(separatedBy: "\n")
      guard let timing = lines.firstIndex(where: { $0.contains(" --> ") }), timing + 1 < lines.count else { continue }
      let ends = lines[timing].components(separatedBy: " --> ")
      guard ends.count == 2, let start = seconds(ends[0]), let end = seconds(ends[1]), start >= 2, end > start else { continue }
      let text = lines.dropFirst(timing + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, !text.contains("<"), !text.contains("&") else { continue }
      return KnownCue(start: start, end: end, text: text)
    }
    throw Failure.subtitle("no_plain_reference_cue")
  }
  private func seconds(_ value: String) -> Double? {
    let parts = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
    guard parts.count == 3, let hour = Double(parts[0]), let minute = Double(parts[1]), let second = Double(parts[2]) else { return nil }
    return hour * 3600 + minute * 60 + second
  }
  private static func log(_ fields: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
    var line = Data("VIDEO_STUDY_REAL ".utf8); line.append(data); line.append(0x0a)
    FileHandle.standardOutput.write(line)
  }
}
