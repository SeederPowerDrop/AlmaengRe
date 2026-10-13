import Foundation

/// A recent photo refers to its original file, or its logical member in a ZIP.
/// The optional JPEG is a bounded preview; full-size image pixels are never kept.
struct RecentPhoto: Codable, Identifiable, Equatable, Sendable {
  let id: String
  let location: SessionLocation
  let archiveEntryPath: String?
  let filename: String
  let lastViewed: Date
  let modificationDate: Date?
  let byteCount: Int64?
  var thumbnailData: Data?

  init(asset: ImageAsset, lastViewed: Date = Date(), thumbnailData: Data? = nil) {
    id = asset.sessionID
    location = SessionLocation(url: asset.archiveOrigin?.archiveURL ?? asset.url)
    archiveEntryPath = asset.archiveOrigin?.entryPath
    filename = asset.filename
    self.lastViewed = lastViewed
    modificationDate = asset.modificationDate
    byteCount = asset.byteCount
    self.thumbnailData = thumbnailData
  }

  /// Resolve on explicit opening. The caller keeps security-scoped access alive
  /// while the library is open, just as for any other SessionLocation.
  func resolvedSourceURL() throws -> URL { try location.resolve().standardizedFileURL }

  /// Bookmark resolution may find a moved file/archive. Use its resolved source
  /// to identify the selected photo in the newly opened collection.
  func sessionID(for sourceURL: URL) -> String {
    sourceURL.standardizedFileURL.absoluteString + (archiveEntryPath.map { "#" + $0 } ?? "")
  }

  func matches(_ asset: ImageAsset, sourceURL: URL) -> Bool {
    asset.sessionID == sessionID(for: sourceURL)
  }

  func hasSameVersion(as asset: ImageAsset) -> Bool {
    id == asset.sessionID && modificationDate == asset.modificationDate && byteCount == asset.byteCount
  }
}
