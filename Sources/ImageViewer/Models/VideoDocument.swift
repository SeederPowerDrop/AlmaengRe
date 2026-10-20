@preconcurrency import AVFoundation
import Foundation

/// Metadata only. Nominal frame rate is a playback hint, not a frame index for
/// variable-frame-rate media. Use AVPlayerItem.step(byCount:) for frame stepping.
struct VideoDocument: Sendable, Equatable {
  let sourceURL: URL
  let durationSeconds: Double
  let pixelWidth: Int
  let pixelHeight: Int
  let nominalFrameRate: Double
  let isPlayable: Bool
  let isExportable: Bool
  let hasAudio: Bool
  let hasProtectedContent: Bool

  var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
  var fullRange: VideoTimeRange { VideoTimeRange(start: 0, end: durationSeconds) }

  static func load(url: URL, allowsAudioOnly: Bool = false) async throws -> Self {
    try Task.checkCancellation()
    guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
      throw VideoProcessingError.sourceUnavailable
    }
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let (playable, duration, exportable, protected) = try await asset.load(
      .isPlayable, .duration, .isExportable, .hasProtectedContent)
    try Task.checkCancellation()
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = videoTracks.first else {
      if allowsAudioOnly {
        if protected { throw VideoProcessingError.protectedContent }
        guard playable else { throw ImagePipelineError.unsupported(url) }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        try Task.checkCancellation()
        guard !audioTracks.isEmpty else { throw ImagePipelineError.unsupported(url) }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw ImagePipelineError.unsupported(url) }
        return Self(sourceURL: url, durationSeconds: seconds,
          pixelWidth: 0, pixelHeight: 0, nominalFrameRate: 0,
          isPlayable: playable, isExportable: exportable, hasAudio: true, hasProtectedContent: false)
      }
      throw missingVideoTrackFailure(isPlayable: playable, hasProtectedContent: protected, url: url)
    }
    let (naturalSize, transform, frameRate) = try await track.load(
      .naturalSize, .preferredTransform, .nominalFrameRate)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    try Task.checkCancellation()
    if allowsAudioOnly && audioTracks.isEmpty { throw ImagePipelineError.unsupported(url) }
    let seconds = CMTimeGetSeconds(duration)
    guard seconds.isFinite, seconds > 0 else { throw VideoProcessingError.invalidDuration }
    let displayed = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized.size
    guard displayed.width.isFinite, displayed.height.isFinite,
      displayed.width > 0, displayed.height > 0,
      displayed.width < Double(Int.max), displayed.height < Double(Int.max) else {
      throw VideoProcessingError.invalidDimensions
    }
    return Self(sourceURL: url, durationSeconds: seconds,
      pixelWidth: max(1, Int(displayed.width.rounded())),
      pixelHeight: max(1, Int(displayed.height.rounded())),
      nominalFrameRate: frameRate.isFinite && frameRate > 0 ? Double(frameRate) : 0,
      isPlayable: playable, isExportable: exportable,
      hasAudio: !audioTracks.isEmpty, hasProtectedContent: protected)
  }

  /// An empty track list is conclusive only when the container is readable.
  /// Unsupported containers can expose no tracks even though they hold video.
  static func missingVideoTrackFailure(isPlayable: Bool, hasProtectedContent: Bool, url: URL) -> any Error {
    if hasProtectedContent { return VideoProcessingError.protectedContent }
    if !isPlayable { return ImagePipelineError.unsupported(url) }
    return VideoProcessingError.noVideoTrack
  }
}

struct VideoTimeRange: Sendable, Equatable {
  var start: Double
  var end: Double
  var duration: Double { end - start }

  func validate(durationSeconds: Double) throws {
    guard start.isFinite, end.isFinite, durationSeconds.isFinite,
      durationSeconds > 0, start >= 0, end > start, end <= durationSeconds else {
      throw VideoProcessingError.invalidRange
    }
    let representedDuration = CMTimeGetSeconds(cmTimeRange.duration)
    guard representedDuration.isFinite, representedDuration > 0 else {
      throw VideoProcessingError.invalidRange
    }
  }

  var cmTimeRange: CMTimeRange {
    CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600_000),
      end: CMTime(seconds: end, preferredTimescale: 600_000))
  }
}

enum VideoContainer: String, Sendable, CaseIterable, Identifiable {
  case mp4, mov
  var id: Self { self }
  var fileExtension: String { rawValue }
  var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
}

/// AVFoundation's H.264/AAC presets do not upscale smaller sources. Presets
/// influence quality and dimensions; none guarantees a particular file size.
enum VideoExportPreset: String, Sendable, CaseIterable, Identifiable {
  case highestQuality, mediumQuality, lowQuality, hd1080, hd720, sd480
  var id: Self { self }

  var avPresetName: String {
    switch self {
    case .highestQuality: AVAssetExportPresetHighestQuality
    case .mediumQuality: AVAssetExportPresetMediumQuality
    case .lowQuality: AVAssetExportPresetLowQuality
    case .hd1080: AVAssetExportPreset1920x1080
    case .hd720: AVAssetExportPreset1280x720
    case .sd480: AVAssetExportPreset640x480
    }
  }
}

struct VideoExportOptions: Sendable, Equatable {
  var container: VideoContainer = .mp4
  var preset: VideoExportPreset = .highestQuality
}

struct VideoFrameResult: Sendable {
  let destinationURL: URL
  let requestedTimeSeconds: Double
  let actualTimeSeconds: Double
  let pixelWidth: Int
  let pixelHeight: Int
}

struct VideoExportResult: Sendable {
  let destinationURL: URL
  let durationSeconds: Double
  let pixelWidth: Int
  let pixelHeight: Int
  let byteCount: Int64
}

enum VideoProcessingError: LocalizedError, Sendable, Equatable {
  case sourceUnavailable, noVideoTrack, invalidDuration, invalidDimensions
  case invalidRange, invalidFrameTime, protectedContent, notExportable
  case sourceOverwrite, sourceChanged, invalidDestination, destinationExists
  case unsupportedPreset, unsupportedContainer, frameGenerationFailed
  case imageWriteFailed, exportFailed

  var errorDescription: String? {
    switch self {
    case .sourceUnavailable: MotionMediaL10n.text("video.error.sourceUnavailable")
    case .noVideoTrack: MotionMediaL10n.text("video.error.noVideoTrack")
    case .invalidDuration: MotionMediaL10n.text("video.error.invalidDuration")
    case .invalidDimensions: MotionMediaL10n.text("video.error.invalidDimensions")
    case .invalidRange: MotionMediaL10n.text("video.error.invalidRange")
    case .invalidFrameTime: MotionMediaL10n.text("video.error.invalidFrameTime")
    case .protectedContent: MotionMediaL10n.text("video.error.protectedContent")
    case .notExportable: MotionMediaL10n.text("video.error.notExportable")
    case .sourceOverwrite: MotionMediaL10n.text("video.error.sourceOverwrite")
    case .sourceChanged: MotionMediaL10n.text("video.error.sourceChanged")
    case .invalidDestination: MotionMediaL10n.text("video.error.invalidDestination")
    case .destinationExists: MotionMediaL10n.text("video.error.destinationExists")
    case .unsupportedPreset: MotionMediaL10n.text("video.error.unsupportedPreset")
    case .unsupportedContainer: MotionMediaL10n.text("video.error.unsupportedContainer")
    case .frameGenerationFailed: MotionMediaL10n.text("video.error.frameGenerationFailed")
    case .imageWriteFailed: MotionMediaL10n.text("video.error.imageWriteFailed")
    case .exportFailed: MotionMediaL10n.text("video.error.exportFailed")
    }
  }
}
