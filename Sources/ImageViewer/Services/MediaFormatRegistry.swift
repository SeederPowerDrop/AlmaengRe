import Foundation

/// These extensions are candidates for macOS video playback, not a codec promise.
/// AVFoundation checks each file at playback or poster-generation time. Keeping
/// this separate leaves image associations and ZIP extraction image-only.
enum MediaFormatRegistry {
  static let videoExtensions: Set<String> = [
    "mp4", "m4v", "mov", "qt", "mpg", "mpeg", "m2v", "avi", "3gp", "3g2", "mts", "m2ts", "ts",
  ]

  static func isVideo(_ url: URL) -> Bool {
    !url.hasDirectoryPath && videoExtensions.contains(url.pathExtension.lowercased())
  }

  static func canAttemptToOpen(_ url: URL, includesVideos: Bool = false) -> Bool {
    if isVideo(url) { return includesVideos }
    return ImageFormatRegistry.canAttemptToDecode(url)
  }
}
