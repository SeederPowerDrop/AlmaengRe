import Foundation

/// Names are captured with the classification; later label edits never rewrite
/// earlier meanings. Nil dates describe imported states whose date is unknown.
struct PhotoMarkClassificationState: Codable, Sendable, Equatable {
  let marks: Set<PhotoMarkSlot>
  let labels: [PhotoMarkSlot: String]
  let changedAt: Date?
}

/// One current classified file, including unavailable files. Reading this report
/// uses only saved SQLite metadata and never resolves or accesses source files.
struct PhotoMarkClassificationRecord: Sendable, Equatable {
  let assetID: String
  let sourceURL: URL?
  let archiveEntryPath: String?
  let isUnavailable: Bool
  let current: PhotoMarkClassificationState
  /// Most recent previous state first, at most two entries.
  let previous: [PhotoMarkClassificationState]
}
