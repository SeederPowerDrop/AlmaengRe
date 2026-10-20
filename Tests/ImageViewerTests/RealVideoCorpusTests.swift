@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import Testing

@testable import ImageViewer

/// Complements RealVideoPlaybackTests with actual audio decoding. This opt-in
/// test never plays sound, exports audio/pixels, or prints source paths/names.
/// IMAGEVIEWER_VIDEO_DIRECTORY=/path/to/movies swift test --filter RealVideoCorpusTests
@Suite("실제 영상 음성 디코딩 읽기 전용 검사", .serialized)
struct RealVideoCorpusTests {
  private enum Failure: Error {
    case directory, inventory, noCandidates, sourceChanged
    case deadline, audioReader, audioOutput, audioStart, noDecodedAudio
  }

  private struct SourceStamp: Equatable {
    let size: Int?
    let modified: Date?
  }

  private struct AudioSummary: Sendable {
    var trackCount = 0
    var buffers = 0
    var decodedSamples = 0
    var decodedBytes = 0
  }

  @Test("실제 재생 후보의 음성 트랙을 PCM으로 디코딩하고 원본 보존 확인",
    .enabled(if: !(ProcessInfo.processInfo.environment["IMAGEVIEWER_VIDEO_DIRECTORY"] ?? "").isEmpty),
    .timeLimit(.minutes(4)))
  func audioTracksDecodeWithoutSourceWrites() async throws {
    guard let path = ProcessInfo.processInfo.environment["IMAGEVIEWER_VIDEO_DIRECTORY"] else {
      throw Failure.directory
    }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    let urls: [URL]
    do {
      urls = try FileManager.default.contentsOfDirectory(at: directory,
        includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        .filter { url in
          MediaFormatRegistry.isVideo(url)
            && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    } catch { throw Failure.inventory }
    guard !urls.isEmpty else { throw Failure.noCandidates }
    let original = try stamps(urls)
    var playableCount = 0, unsupportedCount = 0, audioFileCount = 0, silentFileCount = 0
    var decodedSamples = 0, decodedBytes = 0
    var failures: [[String: String]] = []

    for (index, url) in urls.enumerated() {
      let document: VideoDocument
      do { document = try await VideoDocument.load(url: url) }
      catch {
        unsupportedCount += 1
        log(["phase": "metadata_rejected", "index": index,
          "extension": url.pathExtension.lowercased(), "nativeError": safeError(error)])
        continue
      }
      guard document.isPlayable else {
        unsupportedCount += 1
        continue
      }
      playableCount += 1
      guard document.hasAudio else { silentFileCount += 1; continue }
      do {
        let summary = try await Self.decodeAudio(url)
        guard summary.trackCount > 0, summary.decodedSamples > 0, summary.decodedBytes > 0 else {
          throw Failure.noDecodedAudio
        }
        audioFileCount += 1
        decodedSamples += summary.decodedSamples
        decodedBytes += summary.decodedBytes
        log(["phase": "audio", "index": index, "audioTrackCount": summary.trackCount,
          "decodedSamples": summary.decodedSamples, "decodedBytes": summary.decodedBytes,
          "buffers": summary.buffers])
      } catch {
        failures.append(["index": String(index), "error": safeError(error)])
      }
    }
    let unchanged = try stamps(urls) == original
    log(["phase": "summary", "candidateCount": urls.count, "playableCount": playableCount,
      "unsupportedCount": unsupportedCount, "audioFileCount": audioFileCount,
      "silentFileCount": silentFileCount, "decodedSamples": decodedSamples,
      "decodedBytes": decodedBytes, "failures": failures, "sourceUnchanged": unchanged,
      "speakerPlayback": false, "sourceWrites": 0])
    #expect(unchanged, "Audio validation must preserve source sizes and modification times")
    #expect(failures.isEmpty, "Actual audio decoding failures are recorded by anonymous index")
  }

  private static func decodeAudio(_ url: URL) async throws -> AudioSummary {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    var summary = AudioSummary(trackCount: tracks.count)
    for track in tracks {
      try Task.checkCancellation()
      let range = try await track.load(.timeRange)
      guard range.start.isNumeric, range.duration.isNumeric, range.duration.seconds > 0 else {
        throw Failure.noDecodedAudio
      }
      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ])
      output.alwaysCopiesSampleData = false
      guard reader.canAdd(output) else { throw Failure.audioOutput }
      reader.add(output)
      // Bound decode work even for multi-hour movies. Begin at the audio track's
      // real start, because a valid edit list can delay it beyond container zero.
      reader.timeRange = CMTimeRange(start: range.start,
        duration: CMTime(seconds: min(0.5, range.duration.seconds), preferredTimescale: 600_000))
      guard reader.startReading() else { throw reader.error ?? Failure.audioStart }
      defer { reader.cancelReading() }
      let deadline = ContinuousClock.now + .seconds(10)
      var trackSamples = 0
      while let sample = output.copyNextSampleBuffer() {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw Failure.deadline }
        let count = CMSampleBufferGetNumSamples(sample)
        let bytes = CMSampleBufferGetTotalSampleSize(sample)
        guard count > 0, bytes > 0 else { continue }
        trackSamples += count
        summary.decodedSamples += count
        summary.decodedBytes += bytes
        summary.buffers += 1
      }
      guard reader.status == .completed else { throw reader.error ?? Failure.audioReader }
      guard trackSamples > 0 else { throw Failure.noDecodedAudio }
    }
    return summary
  }

  private func stamps(_ urls: [URL]) throws -> [SourceStamp] {
    do {
      return try urls.map { url in
        let fresh = URL(fileURLWithPath: url.path)
        let values = try fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return SourceStamp(size: values.fileSize, modified: values.contentModificationDate)
      }
    } catch { throw Failure.inventory }
  }

  private func safeError(_ error: Error) -> String {
    if let local = error as? Failure { return String(describing: local) }
    let native = error as NSError
    return "\(native.domain):\(native.code)"
  }

  private func log(_ fields: [String: Any]) {
    guard let encoded = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
    var line = Data("VIDEO_CORPUS ".utf8)
    line.append(encoded)
    line.append(0x0a)
    FileHandle.standardOutput.write(line)
  }
}
