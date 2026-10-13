@preconcurrency import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Display-only video metadata and a bounded first-frame poster. Actual video
/// playback and video export have separate paths; a poster is never an image
/// conversion of the original movie.
enum VideoMediaReader {
  static func metadata(for url: URL) async throws -> ImageMetadata {
    try Task.checkCancellation()
    guard MediaFormatRegistry.isVideo(url) else { throw ImagePipelineError.unsupported(url) }
    let asset = AVURLAsset(url: url)
    let size = try await videoSize(of: asset, url: url)
    try Task.checkCancellation()
    return ImageMetadata(
      pixelWidth: Int(size.width.rounded()), pixelHeight: Int(size.height.rounded()),
      frameCount: 1,
      typeIdentifier: UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.movie.identifier
    )
  }

  static func posterFrame(for url: URL, maxPixelSize: Int) async throws -> RenderedFrame {
    try Task.checkCancellation()
    guard MediaFormatRegistry.isVideo(url) else { throw ImagePipelineError.unsupported(url) }
    let asset = AVURLAsset(url: url)
    let sourceSize = try await videoSize(of: asset, url: url)
    try Task.checkCancellation()
    let limit = min(4096, max(1, maxPixelSize))
    let request = VideoPosterRequest(asset: asset, maxPixelSize: limit)
    let poster = try await request.value()
    try Task.checkCancellation()
    guard let bounded = ThumbnailBitmapDecoder.rasterized(poster.image, maxPixelSize: limit) else {
      throw ImagePipelineError.decodingFailed(url)
    }
    return RenderedFrame(image: bounded.image, frameIndex: 0, frameCount: 1,
      duration: nil, sourcePixelSize: sourceSize)
  }

  private static func videoSize(of asset: AVURLAsset, url: URL) async throws -> CGSize {
    guard try await asset.load(.isPlayable) else {
      throw ImagePipelineError.unsupported(url)
    }
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw VideoProcessingError.noVideoTrack
    }
    try Task.checkCancellation()
    let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
    let size = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized.size
    guard size.width.isFinite, size.height.isFinite,
      size.width >= 1, size.height >= 1,
      size.width < CGFloat(Int.max), size.height < CGFloat(Int.max) else {
      throw ImagePipelineError.decodingFailed(url)
    }
    return size
  }
}

/// Configuration is complete before the one asynchronous generation starts.
/// The cancellation handler only calls AVFoundation's cancellation API.
private final class VideoPosterRequest: @unchecked Sendable {
  private let generator: AVAssetImageGenerator

  init(asset: AVAsset, maxPixelSize: Int) {
    generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
    generator.requestedTimeToleranceBefore = .zero
    // Some valid movie tracks start a few milliseconds after container time
    // zero (for example after an MP4 edit-list offset). A thumbnail may use
    // the first nearby frame; demanding an exact frame at zero rejects those
    // playable files with AVError.noImageAtTime. Keep the search forward-only
    // and bounded; precise user-requested frame capture uses its own generator.
    generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
  }

  func value() async throws -> RenderedFrame {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let result = try await generator.image(at: .zero)
      try Task.checkCancellation()
      return RenderedFrame(image: result.image, frameIndex: 0, frameCount: 1, duration: nil)
    } onCancel: {
      self.generator.cancelAllCGImageGeneration()
    }
  }
}
