import Foundation

enum LibraryMediaKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case all, images, videos
  var id: Self { self }
  var title: String { MediaFormatsL10n.text("kind.\(rawValue)") }
}

enum LibraryMediaFilter {
  static func matches(_ asset: ImageAsset, query: LibraryQuery) -> Bool {
    if query.mediaKind == .images && asset.isVideo { return false }
    if query.mediaKind == .videos && !asset.isVideo { return false }
    // Image format families never include movies in the legacy "other" bucket.
    if !query.formats.isEmpty && asset.isVideo { return false }
    return query.fileExtensions.isEmpty
      || query.fileExtensions.contains { normalizedExtension($0) == asset.fileExtension }
  }

  static func normalizedExtension(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "*.%"))
  }
}

enum MediaFormatsL10n {
  static func text(_ key: String) -> String {
    L10n.text(key, localeIdentifier: L10n.languageIdentifier, table: "MediaFormats")
  }
}
