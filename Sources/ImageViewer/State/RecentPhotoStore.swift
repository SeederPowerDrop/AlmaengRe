import Combine
import Foundation
import ImageIO

/// Stores recently opened collections and up to five viewed photos in each.
/// Loading history never opens source files, resolves bookmarks or extracts ZIPs.
@MainActor
final class RecentPhotoStore: ObservableObject {
  nonisolated static let maximumFolderCount = 8
  nonisolated static let maximumPhotosPerFolder = 5
  nonisolated static let homeFolderLimit = 3
  nonisolated static let homePhotoLimit = 4
  nonisolated static let maximumCount = maximumFolderCount * maximumPhotosPerFolder
  nonisolated static let maximumThumbnailBytes = 128 * 1_024
  nonisolated static let maximumThumbnailPixelDimension = 384
  nonisolated static let defaultsKey = "ImageViewer.RecentFolders.v2"
  nonisolated static let legacyDefaultsKey = "ImageViewer.RecentPhotos.v1"

  @Published private(set) var folders: [RecentFolder]
  /// Limit the home presentation without deleting previously saved history.
  var homeFolders: [RecentFolder] {
    folders.prefix(Self.homeFolderLimit).map { folder in
      var displayed = folder
      displayed.photos = Array(folder.photos.prefix(Self.homePhotoLimit))
      return displayed
    }
  }
  /// Preserve the flat read API for thumbnail requests and explicit photo opening.
  var items: [RecentPhoto] { Self.sortedPhotos(folders.flatMap(\.photos)) }
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: Self.defaultsKey) {
      let saved = (try? JSONDecoder().decode([RecentFolder].self, from: data)) ?? []
      folders = Self.normalized(saved)
      if folders != saved { persist() }
      defaults.removeObject(forKey: Self.legacyDefaultsKey)
    } else if let data = defaults.data(forKey: Self.legacyDefaultsKey),
      let saved = try? JSONDecoder().decode([RecentPhoto].self, from: data) {
      folders = Self.normalized(saved.filter(Self.isValidPhoto).map { RecentFolder(migrating: $0) })
      persist()
      defaults.removeObject(forKey: Self.legacyDefaultsKey)
    } else {
      folders = []
    }
  }

  /// Record explicit folder/ZIP opening even if no photo has been displayed yet.
  func recordFolder(url: URL, isArchive: Bool = false, at date: Date = Date()) {
    guard url.isFileURL else { return }
    let location = SessionLocation(url: url.standardizedFileURL)
    let previous = folders.first { $0.id == location.url.absoluteString }
    let folder = RecentFolder(location: location, lastOpened: date, isArchive: isArchive,
      photos: previous?.isArchive == isArchive ? previous?.photos ?? [] : [])
    folders = [folder] + folders.filter { $0.id != folder.id }.prefix(Self.maximumFolderCount - 1)
    persist()
  }

  func record(_ asset: ImageAsset, at date: Date = Date()) {
    guard !asset.isPlaybackMedia, !MediaFormatRegistry.isPlaybackMedia(URL(fileURLWithPath: asset.filename)),
      (asset.archiveOrigin?.archiveURL ?? asset.url).isFileURL else { return }
    let previous = items.first { $0.id == asset.sessionID }
    let thumbnail = previous.flatMap { $0.hasSameVersion(as: asset) ? $0.thumbnailData : nil }
    let photo = RecentPhoto(asset: asset, lastViewed: date, thumbnailData: thumbnail)
    let collectionURL = (asset.archiveOrigin?.archiveURL ?? asset.url.deletingLastPathComponent())
      .standardizedFileURL
    let existingIndex = folders.firstIndex { $0.id == collectionURL.absoluteString }
    let existing = existingIndex.map { folders[$0] }
    let photos = Array(Self.sortedPhotos([photo] + (existing?.photos ?? []).filter { $0.id != photo.id })
      .prefix(Self.maximumPhotosPerFolder))
    let folder = RecentFolder(location: existing?.location ?? SessionLocation(url: collectionURL),
      lastOpened: existing?.lastOpened ?? date, isArchive: asset.archiveOrigin != nil, photos: photos)
    if let existingIndex {
      // A visible comparison pane or late display callback updates its photos,
      // but only an explicit collection open may change the home collection.
      var updated = folders
      updated[existingIndex] = folder
      folders = updated
    } else {
      folders = [folder] + folders.prefix(Self.maximumFolderCount - 1)
    }
    persist()
  }

  /// An asynchronous thumbnail cannot restore a removed photo/folder. A captured
  /// viewing date also excludes a newer visit or file version.
  func setThumbnail(_ data: Data, for id: String, matchingLastViewed date: Date? = nil) {
    guard let folderIndex = folders.firstIndex(where: { $0.photos.contains(where: { $0.id == id }) }),
      let photoIndex = folders[folderIndex].photos.firstIndex(where: { $0.id == id }),
      date == nil || folders[folderIndex].photos[photoIndex].lastViewed == date,
      Self.acceptsThumbnail(data), folders[folderIndex].photos[photoIndex].thumbnailData != data else { return }
    var updated = folders
    updated[folderIndex].photos[photoIndex].thumbnailData = data
    folders = updated
    persist()
  }

  func remove(id: String) {
    guard folders.contains(where: { $0.photos.contains(where: { $0.id == id }) }) else { return }
    var updated = folders
    for index in updated.indices { updated[index].photos.removeAll { $0.id == id } }
    folders = updated
    persist()
  }

  func removeFolder(id: String) {
    guard folders.contains(where: { $0.id == id }) else { return }
    folders.removeAll { $0.id == id }
    persist()
  }

  func clear() {
    folders = []
    defaults.removeObject(forKey: Self.defaultsKey)
    defaults.removeObject(forKey: Self.legacyDefaultsKey)
  }

  private func persist() {
    guard !folders.isEmpty else {
      defaults.removeObject(forKey: Self.defaultsKey)
      return
    }
    guard let data = try? JSONEncoder().encode(folders) else { return }
    defaults.set(data, forKey: Self.defaultsKey)
  }

  /// Sanitize and merge saved records using metadata only. Stable ties retain the
  /// existing order, including two folder opens recorded within the same instant.
  private static func normalized(_ saved: [RecentFolder]) -> [RecentFolder] {
    var result: [RecentFolder] = []
    let ordered = saved.enumerated().sorted {
      $0.element.lastOpened == $1.element.lastOpened ? $0.offset < $1.offset
        : $0.element.lastOpened > $1.element.lastOpened
    }.map(\.element)
    for candidate in ordered where candidate.location.url.isFileURL {
      let url = candidate.location.url.standardizedFileURL
      let id = url.absoluteString
      var seen: Set<String> = []
      let existingIndex = result.firstIndex { $0.id == id }
      let existing = existingIndex.map { result[$0] }
      guard existing == nil || existing?.isArchive == candidate.isArchive else { continue }
      let photos = sortedPhotos((existing?.photos ?? []) + candidate.photos).filter { photo in
        guard isValidPhoto(photo),
          (photo.archiveEntryPath != nil) == candidate.isArchive else { return false }
        let photoFolder = (candidate.isArchive ? photo.location.url
          : photo.location.url.deletingLastPathComponent()).standardizedFileURL
        return photoFolder == url && seen.insert(photo.id).inserted
      }.prefix(maximumPhotosPerFolder).map { photo in
        var photo = photo
        if let data = photo.thumbnailData, !acceptsThumbnail(data) { photo.thumbnailData = nil }
        return photo
      }
      if let existingIndex, let existing {
        result[existingIndex] = RecentFolder(location: existing.location,
          lastOpened: existing.lastOpened, isArchive: existing.isArchive, photos: photos)
      } else if result.count < maximumFolderCount {
        result.append(RecentFolder(location: candidate.location,
          lastOpened: candidate.lastOpened, isArchive: candidate.isArchive, photos: photos))
      }
    }
    return result
  }

  private static func sortedPhotos(_ photos: [RecentPhoto]) -> [RecentPhoto] {
    photos.enumerated().sorted {
      $0.element.lastViewed == $1.element.lastViewed ? $0.offset < $1.offset
        : $0.element.lastViewed > $1.element.lastViewed
    }.map(\.element)
  }

  private static func isValidPhoto(_ photo: RecentPhoto) -> Bool {
    photo.location.url.isFileURL && !photo.id.isEmpty && !photo.filename.isEmpty
      && !MediaFormatRegistry.isPlaybackMedia(URL(fileURLWithPath: photo.filename))
  }

  private static func acceptsThumbnail(_ data: Data) -> Bool {
    guard !data.isEmpty, data.count <= maximumThumbnailBytes,
      let source = CGImageSourceCreateWithData(data as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetType(source) as String? == "public.jpeg",
      CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return false }
    return (1...maximumThumbnailPixelDimension).contains(width)
      && (1...maximumThumbnailPixelDimension).contains(height)
  }
}
