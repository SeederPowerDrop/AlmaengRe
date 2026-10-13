@preconcurrency import AVFoundation
import Darwin
import Foundation
import Testing

@testable import ImageViewer

/// Opt-in actual-media coverage. All inputs stay read-only; logs contain only
/// anonymous indices/counts and never paths, filenames, subtitle text or pixels.
@Suite("실제 강의 자막 자동 연결", .serialized)
@MainActor
struct RealSubtitleAutoloadTests {
  private enum Failure: Error {
    case directory, inventory, noMatchedPairs
    case state(String, Int)
  }

  private struct SourceStat: Equatable {
    let device: Int32, inode: UInt64, size: Int64
    let mtime: Int64, mtimeNanos: Int64, ctime: Int64, ctimeNanos: Int64
  }

  private struct Pair {
    let asset: ImageAsset
    let korean: URL
    let english: URL
  }

  @Test("모든 동명 한영 자막 자동 연결·캐시 재사용과 대표 2개 영상 준비 통합",
    .enabled(if: !(ProcessInfo.processInfo.environment["IMAGEVIEWER_VIDEO_DIRECTORY"] ?? "").isEmpty),
    .timeLimit(.minutes(5)))
  func allMatchedPairsAndRepresentativePlayers() async throws {
    let started = ContinuousClock.now
    let directory = try directoryURL()
    let before = try snapshot(directory)
    defer { verifyUnchanged(directory, before: before) }
    let opened: OpenedImageLibrary
    do { opened = try await ImageLibrary().open(urls: [directory], includesVideos: true) }
    catch { throw Failure.inventory }
    defer { withExtendedLifetime(opened.access) {} }
    let files = try regularFiles(directory)
    let videos = opened.assets.filter(\.isVideo)
    let pairs = videos.compactMap { asset -> Pair? in
      let stem = asset.url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
      let korean = files.first {
        $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() == stem + ".ko.srt"
      }
      let english = files.first {
        $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() == stem + ".en.srt"
      }
      guard let korean, let english else { return nil }
      return Pair(asset: asset, korean: korean, english: english)
    }
    guard !pairs.isEmpty else { throw Failure.noMatchedPairs }

    var totalCues = 0
    for (index, pair) in pairs.enumerated() {
      let reads = RealSubtitleReadCounts()
      let session = VideoStudySession(videoURL: pair.asset.url, preferredLanguage: "ko",
        discoverer: { try await reads.discover($0) },
        loader: { try await reads.load($0) })
      defer { session.cancelPendingWork() }
      session.prepareAutomaticSubtitles()
      // Simulate immediately opening settings while playback prepares subtitles.
      // Both consumers must use one discovery, without cancellation/restarts.
      await session.discoverSidecars()
      try await wait("model_autoload", index: index) { !session.isPreparingAutomaticSubtitles }
      let koreanFirst = sameFile(session.primary.sourceURL, pair.korean)
      let englishSecond = sameFile(session.secondary.sourceURL, pair.english)
      #expect(koreanFirst && englishSecond, "Korean app preference must put Korean first (paths suppressed)")
      totalCues += try verifySlots(session, pair: pair, index: index)

      let originalDocuments = [session.primary.document, session.secondary.document]
      let originalSuggestions = session.sidecarURLs
      let initialReads = await reads.counts()
      #expect(initialReads.discoveries == 1 && initialReads.loads == 2,
        "One folder scan and two subtitle reads must finish each matched pair")
      for _ in 0..<3 {
        await session.discoverSidecars()
        session.prepareAutomaticSubtitles()
      }
      let repeatedReads = await reads.counts()
      let documentsUnchanged = [session.primary.document, session.secondary.document] == originalDocuments
      let suggestionsUnchanged = session.sidecarURLs == originalSuggestions
      #expect(documentsUnchanged && suggestionsUnchanged,
        "Opening settings must preserve already loaded subtitles and suggestions (contents suppressed)")
      #expect(repeatedReads == initialReads, "Reopening settings must not scan or parse the same files again")

      session.primary.isEnabled = false
      session.secondary.remove()
      session.prepareAutomaticSubtitles()
      await session.discoverSidecars()
      let respectsChoice = !session.isPreparingAutomaticSubtitles && !session.primary.isEnabled
        && !session.secondary.isEnabled && session.secondary.document == nil && session.secondary.sourceURL == nil
      #expect(respectsChoice, "Automatic preparation and settings must preserve disable/remove choices")
      Self.log(["phase": "pair", "index": index, "matchedSources": koreanFirst && englishSecond,
        "cachedDiscoveryCount": repeatedReads.discoveries, "cachedReadCount": repeatedReads.loads,
        "userChoicePreserved": respectsChoice])
    }

    // Native setup is deliberately limited to two representatives. All matched
    // files above exercise the production discovery/parser/selection path.
    let representativeIndices = pairs.count == 1 ? [0] : [0, pairs.count - 1]
    for index in representativeIndices {
      let pair = pairs[index]
      let state = VideoPlaybackState()
      state.player.isMuted = true
      let monitor = Task { await state.monitor(pair.asset) }
      do {
        try await wait("native_autoload", index: index, state: state) {
          state.player.currentItem?.status == .readyToPlay && state.document != nil
            && state.study?.isPreparingAutomaticSubtitles == false
            && state.study?.primary.document != nil && state.study?.secondary.document != nil
        }
        guard let session = state.study else { throw Failure.state("missing_session", index) }
        _ = try verifySlots(session, pair: pair, index: index)
        #expect(state.player.rate == 0 && state.player.isMuted,
          "Connecting subtitles must not start playback or sound")
        if L10n.languageIdentifier == "ko" {
          let koreanFirst = sameFile(session.primary.sourceURL, pair.korean)
          #expect(koreanFirst, "The Korean app's native monitor must connect Korean first (paths suppressed)")
        }
        Self.log(["phase": "native_monitor", "index": index,
          "bothSubtitlesConnectedWithoutSettings": true, "startedPaused": state.player.rate == 0,
          "muted": state.player.isMuted])
      } catch {
        monitor.cancel(); state.stop(); await monitor.value
        if let safe = error as? Failure { throw safe }
        throw Failure.state("native_operation", index)
      }
      monitor.cancel(); state.stop(); await monitor.value
      let cleanedUp = state.player.currentItem == nil && state.study == nil && state.document == nil
      #expect(cleanedUp, "The native monitor must release its item and document (paths suppressed)")
    }
    let elapsed = started.duration(to: .now).components
    Self.log(["phase": "summary", "videoCount": videos.count, "matchedPairCount": pairs.count,
      "automaticallyConnectedSubtitleCount": pairs.count * 2, "loadedCueCount": totalCues,
      "nativeMonitorCount": representativeIndices.count,
      "elapsedSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
      "sourceWrites": 0, "subtitleTextExported": false, "pixelsExported": false])
  }

  private func verifySlots(_ session: VideoStudySession, pair: Pair, index: Int) throws -> Int {
    let actualSources = Set([session.primary.sourceURL, session.secondary.sourceURL].compactMap {
      $0?.standardizedFileURL.resolvingSymlinksInPath()
    })
    let expectedSources = Set([pair.korean, pair.english].map { $0.standardizedFileURL.resolvingSymlinksInPath() })
    let sourcesMatch = actualSources == expectedSources
    #expect(sourcesMatch, "Automatic selection must use both exact matching sidecars (paths suppressed)")
    var cues = 0
    for slot in [session.primary, session.secondary] {
      guard let document = slot.document, let track = slot.selectedTrack,
        let cue = track.cues.first else { throw Failure.state("empty_subtitle", index) }
      let sourceMatches = sameFile(slot.sourceURL, document.sourceURL)
      let midpoint = (cue.start + cue.end) / 2
      let displaysCue = slot.isEnabled && slot.text(at: midpoint)?.contains(cue.text) == true
      let selectedTrackMatches = document.tracks.contains { $0.id == track.id }
      #expect(sourceMatches && selectedTrackMatches && displaysCue,
        "The enabled source track must display its cue at the midpoint (contents suppressed)")
      cues += track.cues.count
    }
    return cues
  }

  private func sameFile(_ lhs: URL?, _ rhs: URL) -> Bool {
    lhs?.standardizedFileURL.resolvingSymlinksInPath() == rhs.standardizedFileURL.resolvingSymlinksInPath()
  }

  private func wait(_ phase: String, index: Int, state: VideoPlaybackState? = nil,
    _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while !condition() {
      if state?.errorMessage != nil || state?.player.currentItem?.status == .failed {
        throw Failure.state(phase + "_playback", index)
      }
      guard ContinuousClock.now < deadline else { throw Failure.state(phase + "_deadline", index) }
      try Task.checkCancellation()
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func directoryURL() throws -> URL {
    guard let path = ProcessInfo.processInfo.environment["IMAGEVIEWER_VIDEO_DIRECTORY"], !path.isEmpty else {
      throw Failure.directory
    }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  private func regularFiles(_ directory: URL) throws -> [URL] {
    do {
      return try FileManager.default.contentsOfDirectory(at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        .filter {
          let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
          return values.isRegularFile == true && values.isSymbolicLink != true
        }
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

  private static func log(_ fields: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
    var line = Data("SUBTITLE_AUTOLOAD_REAL ".utf8)
    line.append(data); line.append(0x0a)
    FileHandle.standardOutput.write(line)
  }
}

private actor RealSubtitleReadCounts {
  struct Counts: Equatable, Sendable { let discoveries: Int, loads: Int }
  private var discoveries = 0
  private var loads = 0

  func discover(_ url: URL) async throws -> [URL] {
    discoveries += 1
    return try await VideoStudySession.findSidecars(url)
  }

  func load(_ url: URL) async throws -> SubtitleDocument {
    loads += 1
    return try await VideoStudySession.readSubtitle(url)
  }

  func counts() -> Counts { Counts(discoveries: discoveries, loads: loads) }
}
