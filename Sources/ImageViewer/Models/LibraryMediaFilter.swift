import Foundation

enum LibraryMediaKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case all, images, videos, audio
  var id: Self { self }
  var title: String { MediaFormatsL10n.text("kind.\(rawValue)") }
}

enum LibraryMediaFilter {
  static func matches(_ asset: ImageAsset, query: LibraryQuery) -> Bool {
    if query.mediaKind == .images && asset.isPlaybackMedia { return false }
    if query.mediaKind == .videos && !asset.isVideo { return false }
    if query.mediaKind == .audio && !asset.isAudio { return false }
    // Image format families never include playback media in the legacy "other" bucket.
    if !query.formats.isEmpty && asset.isPlaybackMedia { return false }
    return query.fileExtensions.isEmpty
      || query.fileExtensions.contains { normalizedExtension($0) == asset.fileExtension }
  }

  static func normalizedExtension(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "*.%"))
  }
}

/// Normalize query-side extensions once. File metadata and codec support are
/// unchanged; this predicate owns no library index, image data or persistent cache.
struct PreparedLibraryMediaPredicate {
  private let kind: LibraryMediaKind
  private let excludesPlayback: Bool
  private let extensions: Set<String>

  init(query: LibraryQuery) {
    kind = query.mediaKind
    excludesPlayback = !query.formats.isEmpty
    extensions = Set(query.fileExtensions.map(LibraryMediaFilter.normalizedExtension))
  }

  var isActive: Bool { kind != .all || excludesPlayback || !extensions.isEmpty }

  func matches(_ asset: ImageAsset) -> Bool {
    switch kind {
    case .all: break
    case .images: if asset.isPlaybackMedia { return false }
    case .videos: if !asset.isVideo { return false }
    case .audio: if !asset.isAudio { return false }
    }
    // Image-only mode already performed this check above.
    if excludesPlayback && kind != .images && asset.isPlaybackMedia { return false }
    return extensions.isEmpty || extensions.contains(asset.fileExtension)
  }
}

enum MediaFormatsL10n {
  static func text(_ key: String) -> String {
    L10n.text(key, localeIdentifier: L10n.languageIdentifier, table: "MediaFormats")
  }
}
