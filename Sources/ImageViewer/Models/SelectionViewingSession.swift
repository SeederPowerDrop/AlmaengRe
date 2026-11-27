import Foundation

/// Logical IDs survive ZIP extraction paths and contain no image data.
struct SelectionViewingSession: Codable, Equatable, Sendable {
  var memberIDs: Set<String>
  var overviewFocusID: String?
  var overviewImagesPerPage: Int
  var scrollX: Double?
  var scrollY: Double?
  var overviewAnchorID: String? = nil
  var overviewViewportWidth: Double? = nil
  var overviewThumbnailSize: Double? = nil
}

struct SelectionViewingContext {
  var saved: SelectionViewingSession
  // Copy-on-write metadata shares the existing collection, never its bitmaps.
  var overviewAssets: [ImageAsset]
  var query: LibraryQuery
  var markFilter: PhotoMarkFilter
  var memberURLs: Set<URL>
  var overviewFocusURL: URL?
  var overviewAnchorURL: URL?

  init(saved: SelectionViewingSession, overviewAssets: [ImageAsset], query: LibraryQuery,
    markFilter: PhotoMarkFilter, sourceAssets: [ImageAsset]? = nil, memberURLs: Set<URL>? = nil,
    overviewFocusURL: URL? = nil, overviewAnchorURL: URL? = nil) {
    self.saved = saved; self.overviewAssets = overviewAssets
    self.query = query; self.markFilter = markFilter
    if let memberURLs {
      self.memberURLs = memberURLs
      self.overviewFocusURL = overviewFocusURL
      self.overviewAnchorURL = overviewAnchorURL
    } else {
      // Canonical logical IDs are needed once on session restore. Live queries
      // and overview return use the URLs already owned by the open collection.
      var members: Set<URL> = []
      for asset in sourceAssets ?? overviewAssets {
        let id = asset.sessionID
        if saved.memberIDs.contains(id) { members.insert(asset.url) }
        if id == saved.overviewFocusID { self.overviewFocusURL = asset.url }
        if id == saved.overviewAnchorID { self.overviewAnchorURL = asset.url }
      }
      self.memberURLs = members
    }
  }
}

struct SelectionOverviewScrollRestore {
  var origin: CGPoint
  var viewportWidth: Double?
  var thumbnailSize: Double?
}
