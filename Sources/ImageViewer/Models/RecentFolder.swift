import Foundation

/// A recently opened directory or original ZIP and the photos actually viewed in it.
/// Everything needed by the home screen is stored here, including bounded previews.
struct RecentFolder: Codable, Identifiable, Equatable, Sendable {
  let id: String
  let location: SessionLocation
  let lastOpened: Date
  let isArchive: Bool
  var photos: [RecentPhoto]

  var name: String { location.url.lastPathComponent.isEmpty ? "/" : location.url.lastPathComponent }

  init(location: SessionLocation, lastOpened: Date, isArchive: Bool, photos: [RecentPhoto] = []) {
    var location = location
    location.url = location.url.standardizedFileURL
    self.location = location
    id = location.url.absoluteString
    self.lastOpened = lastOpened
    self.isArchive = isArchive
    self.photos = photos
  }

  /// Legacy file bookmarks point to the photo, not its enclosing folder. Keep
  /// them on the photo and derive the folder without touching the filesystem.
  init(migrating photo: RecentPhoto) {
    var location = photo.location
    if photo.archiveEntryPath == nil {
      location.url = location.url.deletingLastPathComponent()
      location.bookmark = nil
    }
    self.init(location: location, lastOpened: photo.lastViewed,
      isArchive: photo.archiveEntryPath != nil, photos: [photo])
  }
}
