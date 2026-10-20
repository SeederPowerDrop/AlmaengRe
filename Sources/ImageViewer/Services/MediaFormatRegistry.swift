import Foundation

/// These extensions are candidates for macOS media playback, not a codec promise.
/// AVFoundation checks each file at playback or poster-generation time. Keeping
/// this separate leaves image associations and ZIP extraction image-only.
enum MediaFormatRegistry {
  static let videoExtensions: Set<String> = [
    "mp4", "m4v", "mov", "qt", "mpg", "mpeg", "m2v", "avi", "3gp", "3g2", "mts", "m2ts", "ts",
    // Keep known media containers visible for file management even when this
    // Mac cannot play their contents. Playback failures explain why on the tile.
    "mkv", "webm", "wmv", "flv", "ogv",
  ]

  static let audioExtensions: Set<String> = [
    "mp3", "m4a", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "amr",
    "ogg", "oga", "opus", "wma", "mka",
  ]

  static func isAudio(_ url: URL) -> Bool {
    !url.hasDirectoryPath && audioExtensions.contains(url.pathExtension.lowercased())
  }

  static func isPlaybackMedia(_ url: URL) -> Bool { isVideo(url) || isAudio(url) }

  static func isVideo(_ url: URL) -> Bool {
    !url.hasDirectoryPath && videoExtensions.contains(url.pathExtension.lowercased())
  }

  static func canAttemptToOpen(_ url: URL, includesVideos: Bool = false) -> Bool {
    // Preserve the persisted toggle/call-site name while applying it to both
    // video and audio. Native playback validates the actual tracks and codec.
    if isPlaybackMedia(url) { return includesVideos }
    return ImageFormatRegistry.canAttemptToDecode(url)
  }
}
