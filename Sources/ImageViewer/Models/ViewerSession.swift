import Foundation

/// A bookmark keeps the user's original grant and survives a moved folder when macOS can resolve it.
struct SessionLocation: Codable, Equatable, Sendable {
  var url: URL
  var bookmark: Data?

  init(url: URL) {
    self.url = url
    bookmark = (try? url.bookmarkData(options: [.withSecurityScope],
      includingResourceValuesForKeys: nil, relativeTo: nil))
      ?? (try? url.bookmarkData(options: [.minimalBookmark],
        includingResourceValuesForKeys: nil, relativeTo: nil))
  }

  func resolve() throws -> URL {
    guard let bookmark else { return url }
    var stale = false
    return try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
      relativeTo: nil, bookmarkDataIsStale: &stale)
  }
}

struct ComparisonPaneSession: Codable, Equatable, Sendable {
  var sources: [SessionLocation]
  var selectedID: String?
  var index: Int = 0
  var zoom: Double = 1
  var panX: Double = 0
  var panY: Double = 0
  var actualPixels: Bool = false
  var isLocked: Bool = false
}

struct ComparisonSession: Codable, Equatable, Sendable {
  var first: ComparisonPaneSession
  var second: ComparisonPaneSession
  var activeSide: String = "first"
  var alignment: String = "filename"
  var matchIndex: Int = 0
  var query = LibraryQuery()
}

struct ViewerSession: Codable, Equatable, Sendable {
  var version = 1
  var sources: [SessionLocation]
  var selectedID: String?
  var selectedIDs: Set<String> = []
  var presentationMode: String = "viewer"
  var returnMode: String = "viewer"
  var zoom: Double = 1
  var panX: Double = 0
  var panY: Double = 0
  var actualPixels: Bool = false
  var imagesPerPage: Int = 1
  var query = LibraryQuery()
  var comparison: ComparisonSession?
}

struct FavoriteFolder: Codable, Equatable, Identifiable, Sendable {
  var id: UUID = UUID()
  var location: SessionLocation
  var name: String { location.url.lastPathComponent.isEmpty ? "/" : location.url.lastPathComponent }
}

enum LibraryAccessError: LocalizedError {
  case readOnlyArchive

  var errorDescription: String? {
    L10n.text("ZIP 안의 이미지는 읽기 전용입니다. 새 파일로 내보낸 뒤 수정하세요.")
  }
}
