import Foundation
import SQLite3

struct PhotoMarkSnapshot: Sendable {
  var labels: [PhotoMarkSlot: String] = [:]
  var colors: [PhotoMarkSlot: PhotoMarkColor] = [:]
  var marksByAssetID: [String: Set<PhotoMarkSlot>] = [:]
  var unavailableAssetIDs: Set<String> = []
  var referenceIDs: Set<String> = []
  var trackingReports: [PhotoMarkTrackingReport] = []
}

struct PhotoMarkPersistenceError: Error, LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

struct PhotoMarkStorageStatistics: Sendable {
  let taggedFileCount: Int
  let trackedFileCount: Int
  let reportCount: Int
  let cachedReferenceCount: Int
  let cachedBookmarkBytes: Int
  let databaseBytes: Int
}

struct PhotoMarkWrite: Sendable {
  let asset: ImageAsset
  let marks: Set<PhotoMarkSlot>
  var legacyAssetID: String? = nil
}

/// SQLite and its connection belong exclusively to this serial queue. A keypress
/// updates one small row, without decoding photos or rewriting the whole library.
final class PhotoMarkPersistence: @unchecked Sendable {
  private let queue = DispatchQueue(label: "org.almaengre.photo-marks", qos: .utility)
  let databaseURL: URL
  private let inMemory: Bool
  private var database: OpaquePointer?
  private var terminalError: PhotoMarkPersistenceError?
  // Bookmarks are relatively large. Keep only a small working set in memory;
  // the complete, durable history stays in SQLite even for unavailable disks.
  static let referenceCacheLimit = 256
  static let trackingReportLimit = 1_000
  private var referencesByAssetID: [String: PhotoMarkFileReference] = [:]
  private var referenceAccessOrder: [String: UInt64] = [:]
  private var referenceAccessClock: UInt64 = 0
  private var referencesNeedingRefresh: Set<String> = []
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init(databaseURL: URL?, inMemory: Bool) {
    self.databaseURL = databaseURL ?? FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    )[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "AlmaengRe", isDirectory: true)
      .appendingPathComponent("PhotoMarks.sqlite")
    self.inMemory = inMemory
  }

  deinit {
    // Queued operations retain self, so none can still use the connection here.
    if let database { sqlite3_close(database) }
  }

  func load(completion: @escaping @Sendable (Result<PhotoMarkSnapshot, PhotoMarkPersistenceError>) -> Void) {
    queue.async { [self] in
      if let terminalError { completion(.failure(terminalError)); return }
      do {
        try open()
        var snapshot = PhotoMarkSnapshot()
        try rows("SELECT slot, label FROM mark_labels") { statement in
          guard let slot = PhotoMarkSlot(rawValue: string(statement, column: 0)) else { return }
          snapshot.labels[slot] = string(statement, column: 1)
        }
        snapshot.unavailableAssetIDs = try reconcileTrackedAssets(labels: snapshot.labels)
        try rows("SELECT asset_id FROM asset_tracking") { snapshot.referenceIDs.insert(string($0, column: 0)) }
        try rows("SELECT slot, color FROM mark_colors") { statement in
          guard let slot = PhotoMarkSlot(rawValue: string(statement, column: 0)),
            let color = PhotoMarkColor(rawValue: string(statement, column: 1)) else { return }
          snapshot.colors[slot] = color
        }
        try rows("SELECT asset_id, marks FROM asset_marks") { statement in
          let marks = PhotoMarkSlot.slots(in: Int(sqlite3_column_int(statement, 1)))
          let assetID = string(statement, column: 0)
          if !marks.isEmpty {
            snapshot.marksByAssetID[assetID] = marks
            if Self.requiresReference(assetID), !snapshot.referenceIDs.contains(assetID) {
              snapshot.unavailableAssetIDs.insert(assetID)
            }
          }
        }
        snapshot.trackingReports = try trackingReports()
        completion(.success(snapshot))
      } catch {
        let failure = failure(error)
        terminalError = failure
        completion(.failure(failure))
      }
    }
  }

  func setMarks(_ marks: Set<PhotoMarkSlot>, for assetID: String, asset: ImageAsset? = nil,
    completion: @escaping @Sendable (Result<Void, PhotoMarkPersistenceError>) -> Void) {
    write(completion: completion) { [self] in
      let reference = try marks.isEmpty ? nil : asset.flatMap { try updatedReference(for: $0, assetID: assetID) }
      try transaction {
        try changeClassification(marks, for: assetID, labels: storedLabels(), at: Date())
        if marks.isEmpty {
          try removeReference(for: assetID)
          try setUnavailable(false, for: assetID)
        }
        else if let reference { try replaceReference(reference, for: assetID) }
      }
      if marks.isEmpty { discardCachedReference(for: assetID) }
      else if let reference { cacheReference(reference, for: assetID) }
      if marks.isEmpty || reference != nil { referencesNeedingRefresh.remove(assetID) }
    }
  }

  /// One selection is one durable change, including any path-only records being
  /// adopted. A failed mark or bookmark write rolls the entire selection back.
  func setMarks(_ updates: [PhotoMarkWrite],
    completion: @escaping @Sendable (Result<Void, PhotoMarkPersistenceError>) -> Void) {
    write(completion: completion) { [self] in
      guard !updates.isEmpty else { return }
      var references: [String: PhotoMarkFileReference] = [:]
      for update in updates where !update.marks.isEmpty {
        let key = update.asset.photoMarkID
        if let reference = try updatedReference(for: update.asset, assetID: key) {
          references[key] = reference
        }
      }
      try transaction {
        let labels = try storedLabels()
        let date = Date()
        for update in updates {
          let key = update.asset.photoMarkID
          if let legacyID = update.legacyAssetID, legacyID != key {
            let oldMarks = try marks(for: legacyID)
            if !oldMarks.isEmpty {
              try mergeClassificationHistory(from: legacyID, to: key, labels: labels)
              try unionMarks(oldMarks, for: key)
            }
            try replaceMarks([], for: legacyID)
            try replaceClassificationHistory([], for: legacyID)
            try removeReference(for: legacyID)
            try setUnavailable(false, for: legacyID)
          }
          try changeClassification(update.marks, for: key, labels: labels, at: date)
          if update.marks.isEmpty {
            try removeReference(for: key)
            try setUnavailable(false, for: key)
          } else if let reference = references[key] {
            try replaceReference(reference, for: key)
          }
        }
      }
      for update in updates {
        let key = update.asset.photoMarkID
        if let legacyID = update.legacyAssetID {
          discardCachedReference(for: legacyID)
          referencesNeedingRefresh.remove(legacyID)
        }
        if update.marks.isEmpty { discardCachedReference(for: key) }
        else if let reference = references[key] { cacheReference(reference, for: key) }
        if update.marks.isEmpty || references[key] != nil { referencesNeedingRefresh.remove(key) }
      }
    }
  }

  /// Called after discovering legacy marks or after an app-controlled file change.
  /// Only marked files need bookmarks; unmarked libraries require no tracking I/O.
  func trackAssets(_ assets: [ImageAsset],
    completion: @escaping @Sendable (Result<Set<String>, PhotoMarkPersistenceError>) -> Void) {
    write(completion: completion) { [self] in
      var updates: [String: PhotoMarkFileReference] = [:]
      for asset in assets {
        let assetID = asset.photoMarkID
        guard try !marks(for: assetID).isEmpty,
          let reference = try updatedReference(for: asset, assetID: assetID) else { continue }
        updates[assetID] = reference
      }
      guard !updates.isEmpty else { return [] }
      try transaction {
        let labels = try storedLabels()
        let unavailable = try storedUnavailableIDs()
        for (assetID, reference) in updates {
          let previous = try storedReference(for: assetID)
          if unavailable.contains(assetID) {
            try recordReport(.recovered, assetID: assetID, previous: previous, current: reference,
              marks: try marks(for: assetID), labels: labels)
          } else if let previous, previous.sourceURL.standardizedFileURL != reference.sourceURL.standardizedFileURL {
            try recordReport(.relocated, assetID: assetID, previous: previous, current: reference,
              marks: try marks(for: assetID), labels: labels)
          }
          try setUnavailable(false, for: assetID)
          try replaceReference(reference, for: assetID)
        }
        try trimTrackingReports()
      }
      for (assetID, reference) in updates { cacheReference(reference, for: assetID) }
      referencesNeedingRefresh.subtract(updates.keys)
      return Set(updates.keys)
    }
  }

  func setLabels(_ labels: [PhotoMarkSlot: String],
    completion: @escaping @Sendable (Result<Void, PhotoMarkPersistenceError>) -> Void) {
    write(completion: completion) { [self] in
      try transaction { try changeLabels(labels) }
    }
  }

  func setDefinitions(labels: [PhotoMarkSlot: String], colors: [PhotoMarkSlot: PhotoMarkColor],
    completion: @escaping @Sendable (Result<Void, PhotoMarkPersistenceError>) -> Void) {
    write(completion: completion) { [self] in
      try transaction {
        try changeLabels(labels)
        try execute("DELETE FROM mark_colors")
        for (slot, color) in colors {
          try statement("INSERT INTO mark_colors (slot, color) VALUES (?, ?)") { statement in
            try bind(slot.rawValue, to: statement, at: 1)
            try bind(color.rawValue, to: statement, at: 2)
            try finish(statement)
          }
        }
      }
    }
  }

  func remapAssets(_ mapping: [String: String],
    completion: @escaping @Sendable (Result<Void, PhotoMarkPersistenceError>) -> Void) {
    write(completion: completion) { [self] in
      var sourceReferences: [String: PhotoMarkFileReference] = [:]
      var updatedReferences: [String: PhotoMarkFileReference] = [:]
      try transaction {
        // Read every source before deleting anything, including swap/cycle renames.
        let previousUnavailable = try storedUnavailableIDs()
        let labels = try storedLabels()
        var marksBySource: [String: Set<PhotoMarkSlot>] = [:]
        var historiesBySource: [String: [PhotoMarkClassificationState]] = [:]
        for source in mapping.keys {
          sourceReferences[source] = try storedReference(for: source)
          try statement("SELECT marks FROM asset_marks WHERE asset_id = ?") { statement in
            try bind(source, to: statement, at: 1)
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
              marksBySource[source] = PhotoMarkSlot.slots(in: Int(sqlite3_column_int(statement, 0)))
            } else if result != SQLITE_DONE { throw sqliteError() }
          }
          historiesBySource[source] = try classificationHistory(for: source,
            fallbackMarks: marksBySource[source] ?? [], labels: labels)
        }
        for assetID in Set(mapping.keys).union(mapping.values) {
          try replaceMarks([], for: assetID)
          try replaceClassificationHistory([], for: assetID)
          try removeReference(for: assetID)
          try setUnavailable(false, for: assetID)
          discardCachedReference(for: assetID)
        }
        for (source, destination) in mapping {
          try replaceMarks(marksBySource[source] ?? [], for: destination)
          try replaceClassificationHistory(historiesBySource[source] ?? [], for: destination)
          if previousUnavailable.contains(source), marksBySource[source]?.isEmpty == false {
            try setUnavailable(true, for: destination)
          }
          if marksBySource[source]?.isEmpty == false, let reference = sourceReferences[source] {
            try replaceReference(reference, for: destination)
            updatedReferences[destination] = reference
          }
        }
      }
      for (assetID, reference) in updatedReferences { cacheReference(reference, for: assetID) }
      referencesNeedingRefresh.subtract(mapping.keys)
      referencesNeedingRefresh.formUnion(mapping.values.filter { updatedReferences[$0] != nil })
    }
  }

  /// Commit the identity and bookmark captured by the file operation itself.
  /// No destination I/O is required here: its disk may have gone offline while
  /// the rest of the batch was finishing. Marks and tracking change together.
  func commitTransfer(_ marks: Set<PhotoMarkSlot>, from sourceID: String,
    to destinationID: String, reference: PhotoMarkFileReference, moving: Bool,
    completion: @escaping @Sendable (Result<Void, PhotoMarkPersistenceError>) -> Void) {
    write(completion: completion) { [self] in
      if marks.isEmpty {
        guard moving, sourceID != destinationID else { return }
        let history = try classificationHistory(for: sourceID, fallbackMarks: [], labels: [:])
        guard history.first?.marks.isEmpty == true else { return }
        // Clearing all marks removes tracking, but retains a dated empty state.
        // Moving that file transfers only its history; it must not create a
        // bookmark or a fresh classification date for an unmarked document.
        try transaction {
          try replaceClassificationHistory(history, for: destinationID)
          try replaceClassificationHistory([], for: sourceID)
        }
        return
      }
      try transaction {
        let labels = try storedLabels()
        if moving {
          let sourceMarks = try self.marks(for: sourceID)
          let history = try classificationHistory(for: sourceID, fallbackMarks: sourceMarks, labels: labels)
          let transferred = history.first?.marks == marks ? history
            : [classificationState(marks, labels: labels, at: Date())] + history.prefix(2)
          try replaceMarks(marks, for: destinationID)
          try replaceClassificationHistory(transferred, for: destinationID)
        } else {
          try changeClassification(marks, for: destinationID, labels: labels, at: Date())
        }
        try replaceReference(reference, for: destinationID)
        try setUnavailable(false, for: destinationID)
        if moving, sourceID != destinationID {
          try replaceMarks([], for: sourceID)
          try replaceClassificationHistory([], for: sourceID)
          try removeReference(for: sourceID)
          try setUnavailable(false, for: sourceID)
        }
      }
      if moving, sourceID != destinationID {
        discardCachedReference(for: sourceID)
        referencesNeedingRefresh.remove(sourceID)
      }
      cacheReference(reference, for: destinationID)
      referencesNeedingRefresh.remove(destinationID)
    }
  }

  /// Upgrade a discovered path-based identity without losing marks already saved
  /// for the document. Missing legacy rows must leave the destination untouched.
  func migrateLegacyMarks(_ mapping: [String: String],
    completion: @escaping @Sendable (Result<Void, PhotoMarkPersistenceError>) -> Void) {
    write(completion: completion) { [self] in
      var updatedReferences: [String: PhotoMarkFileReference] = [:]
      try transaction {
        let previousUnavailable = try storedUnavailableIDs()
        let labels = try storedLabels()
        for (source, destination) in mapping where source != destination {
          let legacyMarks = try marks(for: source)
          guard !legacyMarks.isEmpty else { continue }
          try mergeClassificationHistory(from: source, to: destination, labels: labels)
          try unionMarks(legacyMarks, for: destination)
          if try storedReference(for: destination) == nil, let reference = try storedReference(for: source) {
            try replaceReference(reference, for: destination)
            updatedReferences[destination] = reference
          }
          try replaceMarks([], for: source)
          try replaceClassificationHistory([], for: source)
          try removeReference(for: source)
          try setUnavailable(false, for: source)
          if previousUnavailable.contains(source) { try setUnavailable(true, for: destination) }
          discardCachedReference(for: source)
        }
      }
      for (assetID, reference) in updatedReferences { cacheReference(reference, for: assetID) }
      referencesNeedingRefresh.subtract(mapping.keys)
      referencesNeedingRefresh.formUnion(mapping.values.filter { updatedReferences[$0] != nil })
    }
  }

  /// Used at termination after all UI mutations have been enqueued. SQLite commits
  /// are durable when the queue drains; no main-thread callback must run to finish.
  func flush() -> PhotoMarkPersistenceError? { queue.sync { terminalError } }

  /// Drain capture and database writes before an app-controlled rename, move or
  /// trash operation can invalidate a freshly marked source path.
  func flushAsync() async -> PhotoMarkPersistenceError? {
    await withCheckedContinuation { continuation in
      queue.async { [self] in continuation.resume(returning: terminalError) }
    }
  }

  func classificationRecords() async throws -> [PhotoMarkClassificationRecord] {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        do {
          if let terminalError { throw terminalError }
          guard database != nil else { throw PhotoMarkPersistenceError(message: "Photo mark storage is not ready.") }
          let labels = try storedLabels()
          let unavailable = try storedUnavailableIDs()
          var result: [PhotoMarkClassificationRecord] = []
          try rows("SELECT asset_id, marks FROM asset_marks ORDER BY asset_id") { statement in
            let assetID = string(statement, column: 0)
            let marks = PhotoMarkSlot.slots(in: Int(sqlite3_column_int(statement, 1)))
            guard !marks.isEmpty else { return }
            let history = try classificationHistory(for: assetID, fallbackMarks: marks, labels: labels)
            guard let current = history.first, current.marks == marks else {
              throw PhotoMarkPersistenceError(message: "Saved classification history does not match the current marks.")
            }
            let reference = try storedReference(for: assetID)
            let legacyURL = URL(string: assetID).flatMap { $0.isFileURL ? $0 : nil }
            result.append(PhotoMarkClassificationRecord(assetID: assetID,
              sourceURL: reference?.sourceURL ?? legacyURL, archiveEntryPath: reference?.entryPath,
              isUnavailable: unavailable.contains(assetID) || reference == nil, current: current,
              previous: Array(history.dropFirst().prefix(2))))
          }
          continuation.resume(returning: result)
        } catch { continuation.resume(throwing: failure(error)) }
      }
    }
  }

  func storageStatistics() throws -> PhotoMarkStorageStatistics {
    try queue.sync {
      if let terminalError { throw terminalError }
      func count(_ table: String) throws -> Int {
        try statement("SELECT COUNT(*) FROM \(table)") { statement in
          guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError() }
          return Int(sqlite3_column_int64(statement, 0))
        }
      }
      let diskBytes = inMemory ? 0 : [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
        .reduce(0) { total, path in
          total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0)
        }
      return try PhotoMarkStorageStatistics(taggedFileCount: count("asset_marks"),
        trackedFileCount: count("asset_tracking"), reportCount: count("tracking_reports"),
        cachedReferenceCount: referencesByAssetID.count,
        cachedBookmarkBytes: referencesByAssetID.values.reduce(0) { $0 + ($1.bookmark?.count ?? 0) },
        databaseBytes: diskBytes)
    }
  }

  private func write<Value: Sendable>(completion: @escaping @Sendable (Result<Value, PhotoMarkPersistenceError>) -> Void,
    operation: @escaping @Sendable () throws -> Value) {
    queue.async { [self] in
      if let terminalError { completion(.failure(terminalError)); return }
      do {
        guard database != nil else { throw PhotoMarkPersistenceError(message: "Photo mark storage is not ready.") }
        let value = try operation()
        completion(.success(value))
      } catch {
        let failure = failure(error)
        terminalError = failure
        completion(.failure(failure))
      }
    }
  }

  private func open() throws {
    guard database == nil else { return }
    if !inMemory {
      try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    }
    let result = sqlite3_open_v2(inMemory ? ":memory:" : databaseURL.path, &database,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    guard result == SQLITE_OK else { throw sqliteError() }
    sqlite3_busy_timeout(database, 5_000)
    var version = 0
    try rows("PRAGMA user_version") { version = Int(sqlite3_column_int($0, 0)) }
    guard version <= 5 else {
      throw PhotoMarkPersistenceError(message: "These photo marks were saved by a newer version of AlmaengRe.")
    }
    try execute("PRAGMA journal_mode = WAL")
    try execute("PRAGMA synchronous = FULL")
    // Bound SQLite's page cache and its reusable journal independently of the
    // number of tagged photos. Freed report pages are reused by later changes.
    try execute("PRAGMA cache_size = -2048")
    try execute("PRAGMA wal_autocheckpoint = 256")
    try execute("PRAGMA journal_size_limit = 1048576")
    try execute("PRAGMA temp_store = FILE")
    try transaction {
      try execute("CREATE TABLE IF NOT EXISTS mark_labels (slot TEXT PRIMARY KEY NOT NULL, label TEXT NOT NULL)")
      try execute("CREATE TABLE IF NOT EXISTS mark_colors (slot TEXT PRIMARY KEY NOT NULL, color TEXT NOT NULL)")
      try execute("CREATE TABLE IF NOT EXISTS asset_marks (asset_id TEXT PRIMARY KEY NOT NULL, marks INTEGER NOT NULL CHECK (marks > 0 AND marks <= 4095))")
      try execute("CREATE TABLE IF NOT EXISTS asset_tracking (asset_id TEXT PRIMARY KEY NOT NULL, reference BLOB NOT NULL)")
      // Version 2 accepts both legacy paths and document identities. Individual
      // rows are upgraded only after the corresponding file has been identified.
      // Version 3 adds independent palette choices; missing rows use slot defaults.
      try execute("CREATE TABLE IF NOT EXISTS tracking_unavailable (asset_id TEXT PRIMARY KEY NOT NULL)")
      try execute("CREATE TABLE IF NOT EXISTS tracking_reports (id TEXT PRIMARY KEY NOT NULL, observed_at REAL NOT NULL, report BLOB NOT NULL)")
      try execute("CREATE INDEX IF NOT EXISTS tracking_reports_time ON tracking_reports (observed_at DESC)")
      try execute("CREATE TABLE IF NOT EXISTS classification_history (asset_id TEXT PRIMARY KEY NOT NULL, history BLOB NOT NULL)")
      if version < 5 {
        // Existing classification dates were never saved. Import a baseline with
        // an explicitly unknown date, not the upgrade time or a tracking date.
        let labels = try storedLabels()
        try rows("SELECT asset_id, marks FROM asset_marks") { statement in
          let assetID = string(statement, column: 0)
          let marks = PhotoMarkSlot.slots(in: Int(sqlite3_column_int(statement, 1)))
          try replaceClassificationHistory([classificationState(marks, labels: labels, at: nil)], for: assetID)
        }
      }
      try execute("PRAGMA user_version = 5")
    }
  }

  private static func requiresReference(_ assetID: String) -> Bool {
    assetID.hasPrefix("file:v2:") || assetID.hasPrefix("archive-file:v2:")
  }

  /// File identifiers are only trusted after validating the saved bookmark and
  /// creation identity. An offline volume keeps its rows for a later restart.
  private func reconcileTrackedAssets(labels: [PhotoMarkSlot: String]) throws -> Set<String> {
    referencesByAssetID.removeAll(keepingCapacity: true)
    referenceAccessOrder.removeAll(keepingCapacity: true)
    let previousUnavailable = try storedUnavailableIDs()
    var unavailable: Set<String> = []
    // A disk-backed staging table makes identity swaps safe without keeping
    // every bookmark (or every changed bookmark) alive during a large refresh.
    try execute("CREATE TEMP TABLE IF NOT EXISTS resolved_tracking (source TEXT PRIMARY KEY, destination TEXT NOT NULL, reference BLOB NOT NULL, marks INTEGER NOT NULL, history BLOB NOT NULL)")
    try execute("DELETE FROM resolved_tracking")
    defer { try? execute("DELETE FROM resolved_tracking") }
    try transaction {
      try rows("SELECT asset_tracking.asset_id, reference, COALESCE(marks, 0) FROM asset_tracking LEFT JOIN asset_marks ON asset_marks.asset_id = asset_tracking.asset_id") { statement in
        try autoreleasepool {
          let assetID = string(statement, column: 0)
          let reference = try decodeReference(statement, column: 1)
          let marks = PhotoMarkSlot.slots(in: Int(sqlite3_column_int(statement, 2)))
          guard let result = reference.resolve() else {
            unavailable.insert(assetID)
            if !previousUnavailable.contains(assetID) {
              try recordReport(.unavailable, assetID: assetID, previous: reference, current: nil,
                marks: marks, labels: labels)
            }
            return
          }
          if previousUnavailable.contains(assetID) {
            try recordReport(.recovered, assetID: result.id, previous: reference,
              current: result.reference, marks: marks, labels: labels)
          } else if reference.sourceURL.standardizedFileURL != result.reference.sourceURL.standardizedFileURL {
            try recordReport(.relocated, assetID: result.id, previous: reference,
              current: result.reference, marks: marks, labels: labels)
          }
          if assetID != result.id || !sameReference(reference, result.reference) {
            let data = try JSONEncoder().encode(result.reference)
            let history = try classificationHistory(for: assetID, fallbackMarks: marks, labels: labels)
            let historyData = try JSONEncoder().encode(history)
            try self.statement("INSERT INTO resolved_tracking (source, destination, reference, marks, history) VALUES (?, ?, ?, ?, ?)") { update in
              try bind(assetID, to: update, at: 1)
              try bind(result.id, to: update, at: 2)
              try bind(data, to: update, at: 3)
              guard sqlite3_bind_int(update, 4, Int32(PhotoMarkSlot.mask(for: marks))) == SQLITE_OK else { throw sqliteError() }
              try bind(historyData, to: update, at: 5)
              try finish(update)
            }
          }
          cacheReference(result.reference, for: result.id)
        }
      }
      // Identity-only records remain recoverable when a future folder scan
      // finds that exact physical file; a reused path is never sufficient.
      try rows("SELECT asset_marks.asset_id FROM asset_marks LEFT JOIN asset_tracking ON asset_marks.asset_id = asset_tracking.asset_id WHERE asset_tracking.asset_id IS NULL") { statement in
        let assetID = string(statement, column: 0)
        guard Self.requiresReference(assetID) else { return }
        unavailable.insert(assetID)
        if !previousUnavailable.contains(assetID) {
          try recordReport(.unavailable, assetID: assetID, previous: nil, current: nil,
            marks: try marks(for: assetID), labels: labels)
        }
      }
      try execute("DELETE FROM tracking_unavailable")
      for assetID in unavailable { try setUnavailable(true, for: assetID) }
      // Remove old identities before merging any destination, including cycles.
      try rows("SELECT source FROM resolved_tracking WHERE source != destination") { statement in
        let assetID = string(statement, column: 0)
        try replaceMarks([], for: assetID)
        try replaceClassificationHistory([], for: assetID)
        try removeReference(for: assetID)
        discardCachedReference(for: assetID)
      }
      try rows("SELECT source, destination, reference, marks, history FROM resolved_tracking") { statement in
        try autoreleasepool {
          let source = string(statement, column: 0)
          let destination = string(statement, column: 1)
          let marks = PhotoMarkSlot.slots(in: Int(sqlite3_column_int(statement, 3)))
          guard !marks.isEmpty else { return }
          if source != destination {
            let history = try decodeClassificationHistory(statement, column: 4)
            try mergeClassificationHistory(from: source, to: destination, labels: labels,
              sourceHistory: history, sourceMarks: marks)
            try unionMarks(marks, for: destination)
          }
          let reference = try decodeReference(statement, column: 2)
          try replaceReference(reference, for: destination)
          cacheReference(reference, for: destination)
        }
      }
      try trimTrackingReports()
    }
    referencesNeedingRefresh = unavailable
    return unavailable
  }

  private func decodeReference(_ statement: OpaquePointer, column: Int32) throws -> PhotoMarkFileReference {
    let count = Int(sqlite3_column_bytes(statement, column))
    guard let bytes = sqlite3_column_blob(statement, column), count > 0 else {
      throw PhotoMarkPersistenceError(message: "A saved photo tracking reference is invalid.")
    }
    return try JSONDecoder().decode(PhotoMarkFileReference.self, from: Data(bytes: bytes, count: count))
  }

  private func storedReference(for assetID: String) throws -> PhotoMarkFileReference? {
    if let reference = referencesByAssetID[assetID] {
      cacheReference(reference, for: assetID)
      return reference
    }
    return try statement("SELECT reference FROM asset_tracking WHERE asset_id = ?") { statement in
      try bind(assetID, to: statement, at: 1)
      let result = sqlite3_step(statement)
      guard result == SQLITE_ROW else {
        guard result == SQLITE_DONE else { throw sqliteError() }
        return nil
      }
      let reference = try decodeReference(statement, column: 0)
      cacheReference(reference, for: assetID)
      return reference
    }
  }

  private func cacheReference(_ reference: PhotoMarkFileReference, for assetID: String) {
    if referencesByAssetID[assetID] == nil, referencesByAssetID.count >= Self.referenceCacheLimit,
      let oldest = referenceAccessOrder.min(by: { $0.value < $1.value })?.key {
      discardCachedReference(for: oldest)
    }
    referenceAccessClock &+= 1
    referencesByAssetID[assetID] = reference
    referenceAccessOrder[assetID] = referenceAccessClock
  }

  private func discardCachedReference(for assetID: String) {
    referencesByAssetID.removeValue(forKey: assetID)
    referenceAccessOrder.removeValue(forKey: assetID)
  }

  /// Event history is informational. Classification and recovery references are
  /// never expired; only older observations beyond this fixed budget are pruned.
  private func trimTrackingReports() throws {
    try execute("DELETE FROM tracking_reports WHERE rowid NOT IN (SELECT rowid FROM tracking_reports ORDER BY observed_at DESC, rowid DESC LIMIT \(Self.trackingReportLimit))")
  }

  private func storedLabels() throws -> [PhotoMarkSlot: String] {
    var labels: [PhotoMarkSlot: String] = [:]
    try rows("SELECT slot, label FROM mark_labels") { statement in
      guard let slot = PhotoMarkSlot(rawValue: string(statement, column: 0)) else { return }
      labels[slot] = string(statement, column: 1)
    }
    return labels
  }

  private func storedUnavailableIDs() throws -> Set<String> {
    var ids: Set<String> = []
    try rows("SELECT asset_id FROM tracking_unavailable") { ids.insert(string($0, column: 0)) }
    return ids
  }

  private func setUnavailable(_ unavailable: Bool, for assetID: String) throws {
    let sql = unavailable
      ? "INSERT OR IGNORE INTO tracking_unavailable (asset_id) VALUES (?)"
      : "DELETE FROM tracking_unavailable WHERE asset_id = ?"
    try statement(sql) { statement in
      try bind(assetID, to: statement, at: 1)
      try finish(statement)
    }
  }

  private func recordReport(_ event: PhotoMarkTrackingReport.Event, assetID: String,
    previous: PhotoMarkFileReference?, current: PhotoMarkFileReference?,
    marks: Set<PhotoMarkSlot>, labels: [PhotoMarkSlot: String]) throws {
    guard !marks.isEmpty else { return }
    let report = PhotoMarkTrackingReport(id: UUID(), observedAt: Date(), event: event,
      assetID: assetID, previousURL: previous?.sourceURL, currentURL: current?.sourceURL,
      archiveEntryPath: current?.entryPath ?? previous?.entryPath,
      slots: PhotoMarkSlot.allCases.filter { marks.contains($0) },
      labels: labels.filter { marks.contains($0.key) })
    let data = try JSONEncoder().encode(report)
    try statement("INSERT INTO tracking_reports (id, observed_at, report) VALUES (?, ?, ?)") { statement in
      try bind(report.id.uuidString, to: statement, at: 1)
      guard sqlite3_bind_double(statement, 2, report.observedAt.timeIntervalSince1970) == SQLITE_OK else { throw sqliteError() }
      let result = data.withUnsafeBytes {
        sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient)
      }
      guard result == SQLITE_OK else { throw sqliteError() }
      try finish(statement)
    }
  }

  private func trackingReports() throws -> [PhotoMarkTrackingReport] {
    var reports: [PhotoMarkTrackingReport] = []
    try rows("SELECT report FROM tracking_reports ORDER BY observed_at DESC, rowid DESC LIMIT \(Self.trackingReportLimit)") { statement in
      let count = Int(sqlite3_column_bytes(statement, 0))
      guard let bytes = sqlite3_column_blob(statement, 0), count > 0 else {
        throw PhotoMarkPersistenceError(message: "A saved classification report is invalid.")
      }
      reports.append(try JSONDecoder().decode(PhotoMarkTrackingReport.self,
        from: Data(bytes: bytes, count: count)))
    }
    return reports
  }

  private func updatedReference(for asset: ImageAsset, assetID: String) throws -> PhotoMarkFileReference? {
    let sourceURL = asset.archiveOrigin?.archiveURL ?? asset.url
    let entryPath = asset.archiveOrigin?.entryPath
    if !referencesNeedingRefresh.contains(assetID), let existing = try storedReference(for: assetID),
      existing.sourceURL.standardizedFileURL == sourceURL.standardizedFileURL,
      existing.entryPath == entryPath { return nil }
    return PhotoMarkFileReference.capture(for: asset)
  }

  private func sameReference(_ lhs: PhotoMarkFileReference, _ rhs: PhotoMarkFileReference) -> Bool {
    lhs.sourceURL == rhs.sourceURL && lhs.entryPath == rhs.entryPath && lhs.bookmark == rhs.bookmark
      && lhs.birthSeconds == rhs.birthSeconds && lhs.birthNanoseconds == rhs.birthNanoseconds
      && lhs.volumeUUID == rhs.volumeUUID && lhs.fileNumber == rhs.fileNumber
  }

  private func replaceReference(_ reference: PhotoMarkFileReference, for assetID: String) throws {
    let data = try JSONEncoder().encode(reference)
    try statement("INSERT INTO asset_tracking (asset_id, reference) VALUES (?, ?) ON CONFLICT(asset_id) DO UPDATE SET reference = excluded.reference") { statement in
      try bind(assetID, to: statement, at: 1)
      let result = data.withUnsafeBytes {
        sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient)
      }
      guard result == SQLITE_OK else { throw sqliteError() }
      try finish(statement)
    }
  }

  private func removeReference(for assetID: String) throws {
    try statement("DELETE FROM asset_tracking WHERE asset_id = ?") { statement in
      try bind(assetID, to: statement, at: 1)
      try finish(statement)
    }
  }

  private func marks(for assetID: String) throws -> Set<PhotoMarkSlot> {
    try statement("SELECT marks FROM asset_marks WHERE asset_id = ?") { statement in
      try bind(assetID, to: statement, at: 1)
      let result = sqlite3_step(statement)
      if result == SQLITE_ROW {
        return PhotoMarkSlot.slots(in: Int(sqlite3_column_int(statement, 0)))
      }
      guard result == SQLITE_DONE else { throw sqliteError() }
      return []
    }
  }

  private func unionMarks(_ marks: Set<PhotoMarkSlot>, for assetID: String) throws {
    guard !marks.isEmpty else { return }
    try replaceMarks(try self.marks(for: assetID).union(marks), for: assetID)
  }

  private func classificationState(_ marks: Set<PhotoMarkSlot>,
    labels: [PhotoMarkSlot: String], at date: Date?) -> PhotoMarkClassificationState {
    PhotoMarkClassificationState(marks: marks,
      labels: Dictionary(uniqueKeysWithValues: marks.map { ($0, labels[$0] ?? $0.defaultLabel) }),
      changedAt: date)
  }

  private func classificationHistory(for assetID: String, fallbackMarks: Set<PhotoMarkSlot>,
    labels: [PhotoMarkSlot: String]) throws -> [PhotoMarkClassificationState] {
    try statement("SELECT history FROM classification_history WHERE asset_id = ?") { statement in
      try bind(assetID, to: statement, at: 1)
      let result = sqlite3_step(statement)
      if result == SQLITE_ROW { return try decodeClassificationHistory(statement, column: 0) }
      guard result == SQLITE_DONE else { throw sqliteError() }
      return fallbackMarks.isEmpty ? [] : [classificationState(fallbackMarks, labels: labels, at: nil)]
    }
  }

  private func decodeClassificationHistory(_ statement: OpaquePointer, column: Int32) throws
    -> [PhotoMarkClassificationState] {
    let count = Int(sqlite3_column_bytes(statement, column))
    guard let bytes = sqlite3_column_blob(statement, column), count > 0 else {
      throw PhotoMarkPersistenceError(message: "Saved classification history is invalid.")
    }
    let history = try JSONDecoder().decode([PhotoMarkClassificationState].self,
      from: Data(bytes: bytes, count: count))
    guard history.count <= 3 else {
      throw PhotoMarkPersistenceError(message: "Saved classification history exceeds its state limit.")
    }
    return history
  }

  private func replaceClassificationHistory(_ history: [PhotoMarkClassificationState], for assetID: String) throws {
    guard !history.isEmpty else {
      try statement("DELETE FROM classification_history WHERE asset_id = ?") { statement in
        try bind(assetID, to: statement, at: 1)
        try finish(statement)
      }
      return
    }
    let data = try JSONEncoder().encode(Array(history.prefix(3)))
    try statement("INSERT INTO classification_history (asset_id, history) VALUES (?, ?) ON CONFLICT(asset_id) DO UPDATE SET history = excluded.history") { statement in
      try bind(assetID, to: statement, at: 1)
      try bind(data, to: statement, at: 2)
      try finish(statement)
    }
  }

  /// Only deliberate changes call this method; identity moves use raw mark and
  /// history transfers so moving a file never fabricates a classification date.
  private func changeClassification(_ marks: Set<PhotoMarkSlot>, for assetID: String,
    labels: [PhotoMarkSlot: String], at date: Date) throws {
    let previous = try self.marks(for: assetID)
    guard previous != marks else { return }
    let history = try classificationHistory(for: assetID, fallbackMarks: previous, labels: labels)
    try replaceMarks(marks, for: assetID)
    try replaceClassificationHistory([classificationState(marks, labels: labels, at: date)]
      + history.prefix(2), for: assetID)
  }

  private func changeLabels(_ labels: [PhotoMarkSlot: String]) throws {
    let previousLabels = try storedLabels()
    let changedSlots = Set(PhotoMarkSlot.allCases.filter {
      (previousLabels[$0] ?? $0.defaultLabel) != (labels[$0] ?? $0.defaultLabel)
    })
    if !changedSlots.isEmpty {
      let date = Date()
      try rows("SELECT asset_id, marks FROM asset_marks") { statement in
        let marks = PhotoMarkSlot.slots(in: Int(sqlite3_column_int(statement, 1)))
        guard !marks.isDisjoint(with: changedSlots) else { return }
        let assetID = string(statement, column: 0)
        let history = try classificationHistory(for: assetID, fallbackMarks: marks, labels: previousLabels)
        try replaceClassificationHistory([classificationState(marks, labels: labels, at: date)]
          + history.prefix(2), for: assetID)
      }
    }
    try replaceLabels(labels)
  }

  /// Consolidating older identities is not a user edit. An aggregate that never
  /// had a recorded date remains undated; existing snapshots keep their names.
  private func mergeClassificationHistory(from source: String, to destination: String,
    labels: [PhotoMarkSlot: String], sourceHistory: [PhotoMarkClassificationState]? = nil,
    sourceMarks: Set<PhotoMarkSlot>? = nil) throws {
    let incomingMarks = try sourceMarks ?? marks(for: source)
    let destinationMarks = try marks(for: destination)
    let incoming = try sourceHistory ?? classificationHistory(for: source, fallbackMarks: incomingMarks, labels: labels)
    let existing = try classificationHistory(for: destination, fallbackMarks: destinationMarks, labels: labels)
    guard !incoming.isEmpty else { return }
    if existing.isEmpty {
      try replaceClassificationHistory(incoming, for: destination)
    } else if incomingMarks == destinationMarks {
      // Two aliases can both contain dated changes. Keep the latest known
      // classification and its own preceding states, never an older/undated
      // canonical row merely because it already owns the destination identity.
      if let incomingDate = incoming.first?.changedAt,
        (existing.first?.changedAt).map({ incomingDate > $0 }) ?? true {
        try replaceClassificationHistory(incoming, for: destination)
      }
    } else if incomingMarks.isSubset(of: destinationMarks) {
      // Re-identifying an alias must not use up one of the two previous states.
      return
    } else if destinationMarks.isSubset(of: incomingMarks) {
      try replaceClassificationHistory(incoming, for: destination)
    } else {
      var previous: [PhotoMarkClassificationState] = []
      for state in (existing + incoming).sorted(by: {
        ($0.changedAt ?? .distantPast) > ($1.changedAt ?? .distantPast)
      }) where !previous.contains(state) { previous.append(state) }
      let merged = classificationState(incomingMarks.union(destinationMarks), labels: labels, at: nil)
      try replaceClassificationHistory([merged] + previous.prefix(2), for: destination)
    }
  }

  private func replaceMarks(_ marks: Set<PhotoMarkSlot>, for assetID: String) throws {
    if marks.isEmpty {
      try statement("DELETE FROM asset_marks WHERE asset_id = ?") { statement in
        try bind(assetID, to: statement, at: 1)
        try finish(statement)
      }
    } else {
      try statement("INSERT INTO asset_marks (asset_id, marks) VALUES (?, ?) ON CONFLICT(asset_id) DO UPDATE SET marks = excluded.marks") { statement in
        try bind(assetID, to: statement, at: 1)
        guard sqlite3_bind_int(statement, 2, Int32(PhotoMarkSlot.mask(for: marks))) == SQLITE_OK else { throw sqliteError() }
        try finish(statement)
      }
    }
  }

  private func replaceLabels(_ labels: [PhotoMarkSlot: String]) throws {
    try execute("DELETE FROM mark_labels")
    for (slot, label) in labels {
      try statement("INSERT INTO mark_labels (slot, label) VALUES (?, ?)") { statement in
        try bind(slot.rawValue, to: statement, at: 1)
        try bind(label, to: statement, at: 2)
        try finish(statement)
      }
    }
  }

  private func transaction(_ operation: () throws -> Void) throws {
    try execute("BEGIN IMMEDIATE TRANSACTION")
    do { try operation(); try execute("COMMIT") }
    catch { try? execute("ROLLBACK"); throw error }
  }

  private func execute(_ sql: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw sqliteError() }
  }

  private func statement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
    var prepared: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw sqliteError() }
    defer { sqlite3_finalize(prepared) }
    return try body(prepared)
  }

  private func rows(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
    try statement(sql) { statement in
      while true {
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return }
        guard result == SQLITE_ROW else { throw sqliteError() }
        try body(statement)
      }
    }
  }

  private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
    let result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    guard result == SQLITE_OK else { throw sqliteError() }
  }

  private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
    let result = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
    guard result == SQLITE_OK else { throw sqliteError() }
  }

  private func finish(_ statement: OpaquePointer) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
  }

  private func string(_ statement: OpaquePointer, column: Int32) -> String {
    guard let value = sqlite3_column_text(statement, column) else { return "" }
    return String(cString: value)
  }

  private func sqliteError() -> PhotoMarkPersistenceError {
    PhotoMarkPersistenceError(message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open photo mark storage.")
  }

  private func failure(_ error: Error) -> PhotoMarkPersistenceError {
    (error as? PhotoMarkPersistenceError) ?? PhotoMarkPersistenceError(message: error.localizedDescription)
  }
}
