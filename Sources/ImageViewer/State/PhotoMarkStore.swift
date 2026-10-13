import Combine
import Foundation

@MainActor
final class PhotoMarkStore: ObservableObject {
  @Published private(set) var isReady = false
  @Published var errorMessage: String?
  @Published private(set) var labels: [PhotoMarkSlot: String] = [:]
  @Published private(set) var colors: [PhotoMarkSlot: PhotoMarkColor] = [:]
  // Publish the revision instead of retaining a second dictionary in Combine.
  // Ordinary keypresses can then update one entry without copying every photo ID.
  private(set) var marksByAssetID: [String: Set<PhotoMarkSlot>] = [:]
  @Published private(set) var revision = 0
  @Published private(set) var trackingReports: [PhotoMarkTrackingReport] = []
  @Published private(set) var isRefreshingTracking = false

  var storageURL: URL { persistence.databaseURL }
  var unavailableCount: Int { unavailableAssetIDs.count }
  var classifiedFileCount: Int { marksByAssetID.count }

  private let persistence: PhotoMarkPersistence
  private var hasFinishedLoading = false
  private var readinessWaiters: [CheckedContinuation<Void, Never>] = []
  private var unavailableAssetIDs: Set<String> = []
  private var referenceIDs: Set<String> = []
  private var registeredLocations: [String: String] = [:]
  private var trackingGeneration = 0
  private var snapshotGeneration = 0

  init(databaseURL: URL? = nil, inMemory: Bool = false) {
    persistence = PhotoMarkPersistence(databaseURL: databaseURL, inMemory: inMemory)
    persistence.load { [weak self] result in
      Task { @MainActor [weak self] in
        guard let self else { return }
        switch result {
        case .success(let snapshot):
          apply(snapshot)
          isReady = true
        case .failure(let error):
          recordFailure(error)
        }
        hasFinishedLoading = true
        readinessWaiters.forEach { $0.resume() }
        readinessWaiters.removeAll()
      }
    }
  }

  func waitUntilReady() async {
    guard !hasFinishedLoading else { return }
    await withCheckedContinuation { readinessWaiters.append($0) }
  }

  /// Checks bookmarks without mounting disks or asking for access. Concurrent
  /// mark edits stay responsive; a superseded snapshot is read again before use.
  func refreshTracking() async {
    await waitUntilReady()
    guard !Task.isCancelled, isReady, !isRefreshingTracking else { return }
    isRefreshingTracking = true
    defer { isRefreshingTracking = false }
    while isReady, !Task.isCancelled {
      let startingRevision = revision
      let startingTrackingGeneration = trackingGeneration
      let result: Result<PhotoMarkSnapshot, PhotoMarkPersistenceError> = await withCheckedContinuation { continuation in
        persistence.load { continuation.resume(returning: $0) }
      }
      // An in-flight SQLite/bookmark pass finishes on its serial queue, but a
      // dismissed report must not apply it or repeat a superseded full scan.
      guard !Task.isCancelled else { return }
      switch result {
      case .success(let snapshot):
        guard revision == startingRevision, trackingGeneration == startingTrackingGeneration else { continue }
        apply(snapshot)
        return
      case .failure(let error):
        recordFailure(error)
        return
      }
    }
  }

  private func apply(_ snapshot: PhotoMarkSnapshot) {
    snapshotGeneration &+= 1
    labels = snapshot.labels
    colors = snapshot.colors
    marksByAssetID = snapshot.marksByAssetID
    unavailableAssetIDs = snapshot.unavailableAssetIDs
    referenceIDs = snapshot.referenceIDs
    trackingReports = snapshot.trackingReports
    registeredLocations.removeAll()
    revision &+= 1
  }

  func label(for slot: PhotoMarkSlot) -> String { labels[slot] ?? slot.defaultLabel }
  func color(for slot: PhotoMarkSlot) -> PhotoMarkColor { colors[slot] ?? slot.defaultColor }

  func marks(for asset: ImageAsset) -> Set<PhotoMarkSlot> {
    if !unavailableAssetIDs.contains(asset.photoMarkID), let marks = marksByAssetID[asset.photoMarkID] {
      return marks
    }
    // Version 1 stored paths only. A tracked but unavailable path must never be
    // reassigned to a replacement file merely because its name happens to match.
    if asset.photoMarkIdentity != nil, !referenceIDs.contains(asset.sessionID) {
      return marksByAssetID[asset.sessionID] ?? []
    }
    return []
  }

  /// Called after off-main directory scanning, never from a view's body. Existing
  /// path-only marks are adopted once; future opens use identity plus bookmarks.
  @discardableResult
  func reconcileAssets(_ assets: [ImageAsset], retryUnavailable: Bool = true) -> PhotoMarkReconciliation? {
    guard isReady else { return nil }
    var migration: [String: String] = [:]
    var tracked: [ImageAsset] = []
    var changed = false
    for asset in assets {
      let key = asset.photoMarkID
      if key != asset.sessionID, !referenceIDs.contains(asset.sessionID),
        let legacy = marksByAssetID.removeValue(forKey: asset.sessionID) {
        marksByAssetID[key, default: []].formUnion(legacy)
        migration[asset.sessionID] = key
        changed = true
      }
      guard marksByAssetID[key] != nil else { continue }
      // Search/sort/filter changes reuse an already scanned list. Missing files
      // cannot be validated from those values, so avoid a database read and
      // failed filesystem capture for every marked file on every keystroke.
      // A real rescan/open uses the default to rediscover returned identities.
      if !retryUnavailable, unavailableAssetIDs.contains(key) { continue }
      // Filtering can pass cached assets whose files no longer exist. Only the
      // background capture below can validate a returned disk or restored file.
      if registeredLocations[key] != asset.sessionID || unavailableAssetIDs.contains(key) {
        registeredLocations[key] = asset.sessionID
        tracked.append(asset)
        referenceIDs.insert(key)
      }
    }
    if !migration.isEmpty { persistence.migrateLegacyMarks(migration, completion: writeCompletion) }
    var reconciliation: PhotoMarkReconciliation?
    if !tracked.isEmpty {
      let pending = PhotoMarkReconciliation()
      reconciliation = pending
      trackingGeneration &+= 1
      let generation = snapshotGeneration
      persistence.trackAssets(tracked) { [weak self] result in
        Task { @MainActor [weak self] in
          defer { pending.finish() }
          guard let self else { return }
          switch result {
          case .success(let validatedIDs):
            // A more recent complete check takes precedence over this callback.
            guard snapshotGeneration == generation else { return }
            let recovered = unavailableAssetIDs.intersection(validatedIDs)
            if !recovered.isEmpty {
              unavailableAssetIDs.subtract(recovered)
              revision &+= 1
            }
          case .failure(let error): recordFailure(error)
          }
        }
      }
    }
    if changed { revision &+= 1 }
    return reconciliation
  }

  func toggle(_ slot: PhotoMarkSlot, for asset: ImageAsset) {
    guard isReady else { return }
    reconcileAssets([asset])
    // Never overwrite retained marks from a stale thumbnail while its file is
    // unavailable. A verified recovery will enable marking again.
    guard !unavailableAssetIDs.contains(asset.photoMarkID) else { return }
    var marks = self.marks(for: asset)
    if marks.contains(slot) { marks.remove(slot) } else { marks.insert(slot) }
    let key = asset.photoMarkID
    if marks.isEmpty {
      marksByAssetID.removeValue(forKey: key)
      referenceIDs.remove(key)
      registeredLocations.removeValue(forKey: key)
    } else {
      marksByAssetID[key] = marks
      referenceIDs.insert(key)
      registeredLocations[key] = asset.sessionID
    }
    unavailableAssetIDs.remove(key)
    revision &+= 1
    persistence.setMarks(marks, for: key, asset: asset, completion: writeCompletion)
  }

  /// Apply one classification to a selection without toggling mixed values apart.
  /// Only the app database changes; source files and their metadata stay intact.
  func set(_ slot: PhotoMarkSlot, enabled: Bool, for assets: [ImageAsset]) {
    guard isReady else { return }
    var seen: Set<String> = []
    var updates: [PhotoMarkWrite] = []
    var unavailable: [ImageAsset] = []
    var changed = false
    for asset in assets {
      let key = asset.photoMarkID
      guard seen.insert(key).inserted else { continue }
      // As with individual marking, a stale thumbnail cannot overwrite a saved
      // classification while the underlying file is unavailable.
      guard !unavailableAssetIDs.contains(key) else {
        unavailable.append(asset)
        continue
      }
      var marks = marksByAssetID[key] ?? []
      var legacyID: String?
      if key != asset.sessionID, !referenceIDs.contains(asset.sessionID),
        let legacy = marksByAssetID.removeValue(forKey: asset.sessionID) {
        marks.formUnion(legacy)
        legacyID = asset.sessionID
      }
      let previous = marks
      if enabled { marks.insert(slot) } else { marks.remove(slot) }
      let marksChanged = marks != previous || legacyID != nil
      // Even an unchanged selection may have moved since the last scan.
      let needsTracking = !marks.isEmpty && registeredLocations[key] != asset.sessionID
      guard marksChanged || needsTracking else { continue }
      if marks.isEmpty {
        marksByAssetID.removeValue(forKey: key)
        referenceIDs.remove(key)
        registeredLocations.removeValue(forKey: key)
      } else {
        marksByAssetID[key] = marks
        referenceIDs.insert(key)
        registeredLocations[key] = asset.sessionID
      }
      changed = changed || marksChanged
      updates.append(PhotoMarkWrite(asset: asset, marks: marks, legacyAssetID: legacyID))
    }
    if changed { revision &+= 1 }
    if !updates.isEmpty { persistence.setMarks(updates, completion: writeCompletion) }
    // Recovery is verified off-main and enables a later edit, never the edit
    // that was requested while the identity was still unavailable.
    if !unavailable.isEmpty { reconcileAssets(unavailable) }
  }

  func setLabels(_ labels: [PhotoMarkSlot: String]) {
    setDefinitions(labels: labels, colors: colors)
  }

  /// An explicit original-file copy inherits the source's app classifications.
  /// The destination has a newly verified identity; no image metadata is edited.
  func inheritMarks(_ marks: Set<PhotoMarkSlot>, for asset: ImageAsset) {
    guard isReady, !marks.isEmpty else { return }
    let key = asset.photoMarkID
    marksByAssetID[key, default: []].formUnion(marks)
    referenceIDs.insert(key)
    registeredLocations[key] = asset.sessionID
    unavailableAssetIDs.remove(key)
    revision &+= 1
    persistence.setMarks(marksByAssetID[key] ?? marks, for: key, asset: asset, completion: writeCompletion)
  }

  /// Preserve a committed transfer even if its destination is now unavailable.
  /// Await the database transaction before reporting that reconciliation ended.
  @discardableResult
  func commitTransferredMarks(_ marks: Set<PhotoMarkSlot>, from source: ImageAsset,
    to destination: ImageAsset, reference: PhotoMarkFileReference, moving: Bool) async -> Bool {
    guard isReady else { return false }
    guard !marks.isEmpty || moving else { return true }
    let sourceID = source.photoMarkID
    let destinationID = destination.photoMarkID
    let inherited = moving ? marks : (marksByAssetID[destinationID] ?? []).union(marks)
    let result: Result<Void, PhotoMarkPersistenceError> = await withCheckedContinuation { continuation in
      persistence.commitTransfer(inherited, from: sourceID, to: destinationID,
        reference: reference, moving: moving) { continuation.resume(returning: $0) }
    }
    switch result {
    case .success:
      // An unmarked move can transfer a previous classification history without
      // changing current marks or registering an unmarked file for tracking.
      guard !inherited.isEmpty else { return true }
      if moving, sourceID != destinationID {
        marksByAssetID.removeValue(forKey: sourceID)
        unavailableAssetIDs.remove(sourceID)
        referenceIDs.remove(sourceID)
        registeredLocations.removeValue(forKey: sourceID)
      }
      marksByAssetID[destinationID] = inherited
      unavailableAssetIDs.remove(destinationID)
      referenceIDs.insert(destinationID)
      registeredLocations[destinationID] = destination.sessionID
      revision &+= 1
      return true
    case .failure(let error):
      recordFailure(error)
      return false
    }
  }

  func setDefinitions(labels: [PhotoMarkSlot: String], colors: [PhotoMarkSlot: PhotoMarkColor]) {
    guard isReady else { return }
    // An explicitly empty name is kept: a slot can be named after photos are marked.
    let normalized = labels.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard self.labels != normalized || self.colors != colors else { return }
    self.labels = normalized
    self.colors = colors
    revision &+= 1
    persistence.setDefinitions(labels: normalized, colors: colors, completion: writeCompletion)
  }

  func remapAssets(_ mapping: [String: String]) {
    guard isReady else { return }
    let changed = mapping.filter { $0.key != $0.value }
    guard !changed.isEmpty else { return }
    let previous = marksByAssetID
    let previousUnavailable = unavailableAssetIDs
    let previousReferences = referenceIDs
    for assetID in Set(changed.keys).union(changed.values) { marksByAssetID.removeValue(forKey: assetID) }
    for assetID in Set(changed.keys).union(changed.values) {
      unavailableAssetIDs.remove(assetID)
      referenceIDs.remove(assetID)
      registeredLocations.removeValue(forKey: assetID)
    }
    for (source, destination) in changed {
      if let marks = previous[source] { marksByAssetID[destination] = marks }
      if previousUnavailable.contains(source) { unavailableAssetIDs.insert(destination) }
      if previousReferences.contains(source) { referenceIDs.insert(destination) }
    }
    revision &+= 1
    persistence.remapAssets(changed, completion: writeCompletion)
  }

  func flush() {
    if let error = persistence.flush() { recordFailure(error) }
  }

  @discardableResult
  func flushAsync() async -> Bool {
    if let error = await persistence.flushAsync() {
      recordFailure(error)
      return false
    }
    return isReady
  }

  func storageStatistics() throws -> PhotoMarkStorageStatistics {
    try persistence.storageStatistics()
  }

  /// The serial database read follows all queued classification writes, keeping
  /// exported marks and their history in one durable snapshot.
  func classificationRecords() async throws -> [PhotoMarkClassificationRecord] {
    await waitUntilReady()
    guard isReady else {
      throw PhotoMarkPersistenceError(message: errorMessage ?? PhotoMarkReportL10n.text("export.notReady"))
    }
    return try await persistence.classificationRecords()
  }

  func exportClassifications(to destination: URL) async throws -> Int {
    let records = try await classificationRecords()
    let columns = PhotoMarkCSVExporter.Strings()
    let timeZone = TimeZone.current
    return try await Task.detached(priority: .userInitiated) {
      let access = destination.startAccessingSecurityScopedResource()
      defer { if access { destination.stopAccessingSecurityScopedResource() } }
      let data = PhotoMarkCSVExporter.data(for: records, strings: columns, timeZone: timeZone)
      try data.write(to: destination, options: .atomic)
      return records.count
    }.value
  }

  private var writeCompletion: @Sendable (Result<Void, PhotoMarkPersistenceError>) -> Void {
    { [weak self] result in
      guard case .failure(let error) = result else { return }
      Task { @MainActor [weak self] in self?.recordFailure(error) }
    }
  }

  private func recordFailure(_ error: PhotoMarkPersistenceError) {
    // Keep the visible, unsaved marks and stop accepting more input. Never replace
    // a damaged database with an empty one or suggest that a failed write saved.
    isReady = false
    errorMessage = PhotoMarkL10n.text("storage.error") + "\n" + error.localizedDescription
  }
}

/// Lets library queries wait for off-main identity checks before filtering, while
/// ordinary keypresses can continue to enqueue their writes synchronously.
@MainActor
final class PhotoMarkReconciliation {
  private var isFinished = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isFinished else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  fileprivate func finish() {
    isFinished = true
    waiters.forEach { $0.resume() }
    waiters.removeAll()
  }
}
