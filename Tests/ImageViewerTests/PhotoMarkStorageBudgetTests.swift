import Foundation
import SQLite3
import Testing

@testable import ImageViewer

@Suite("분류 저장소 용량과 복구", .serialized)
@MainActor
struct PhotoMarkStorageBudgetTests {
  @Test("1만 파일을 분류해도 북마크 캐시는 고정 크기이며 재시작 후 모든 분류가 남는다")
  func tenThousandRecordsHaveBoundedBookmarkCache() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var store: PhotoMarkStore? = try await fixture.store()
    let started = Date()
    var first: ImageAsset?
    var last: ImageAsset?
    for page in 0..<40 {
      var assets: [ImageAsset] = []
      for offset in 0..<250 {
        let asset = try fixture.asset(named: "synthetic-\(page * 250 + offset).jpg")
        assets.append(asset)
        if first == nil { first = asset }
        last = asset
      }
      store?.set(.one, enabled: true, for: assets)
      try #require(await store?.flushAsync() == true)
    }
    let written = try #require(try store?.storageStatistics())
    #expect(written.taggedFileCount == 10_000)
    #expect(written.trackedFileCount == 10_000)
    #expect(written.cachedReferenceCount <= PhotoMarkPersistence.referenceCacheLimit)
    #expect(written.cachedBookmarkBytes < 1_048_576)
    // Actual SQLite, WAL and SHM bytes, not a projected per-row estimate.
    #expect(written.databaseBytes < 64 * 1_048_576)
    store = nil
    let reopened = try await fixture.store()
    let loaded = try reopened.storageStatistics()
    #expect(reopened.marksByAssetID.count == 10_000)
    #expect(reopened.unavailableCount == 0)
    #expect(reopened.marks(for: try #require(first)) == [.one])
    #expect(reopened.marks(for: try #require(last)) == [.one])
    #expect(loaded.cachedReferenceCount <= PhotoMarkPersistence.referenceCacheLimit)
    #expect(loaded.cachedBookmarkBytes < 1_048_576)
    // Exercise a record evicted from the cache, both clearing and adding tags.
    reopened.set(.w, enabled: true, for: [try #require(first)])
    reopened.set(.one, enabled: false, for: [try #require(first)])
    try #require(await reopened.flushAsync())
    let verified = try await fixture.store()
    #expect(verified.marks(for: try #require(first)) == [.w])
    #expect(verified.marks(for: try #require(last)) == [.one])
    print("PHOTO_MARK_BUDGET records=10000 databaseBytes=\(loaded.databaseBytes) cachedReferences=\(loaded.cachedReferenceCount) cachedBookmarkBytes=\(loaded.cachedBookmarkBytes) elapsedSeconds=\(Date().timeIntervalSince(started))")
  }

  @Test("변경 관찰 기록만 제한하며 휴지통·누락 파일의 분류와 복구 참조는 삭제하지 않는다")
  func reportBudgetKeepsUnavailableClassifications() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var store: PhotoMarkStore? = try await fixture.store()
    let asset = try fixture.asset(named: "missing.jpg")
    store?.toggle(.f, for: asset)
    try #require(await store?.flushAsync() == true)
    store = nil
    try FileManager.default.removeItem(at: asset.url)
    try fixture.seedReports(count: PhotoMarkPersistence.trackingReportLimit + 125, assetID: asset.photoMarkID)
    let reopened = try await fixture.store()
    let stats = try reopened.storageStatistics()
    #expect(stats.reportCount == PhotoMarkPersistence.trackingReportLimit)
    #expect(reopened.trackingReports.count == PhotoMarkPersistence.trackingReportLimit)
    #expect(reopened.trackingReports.first?.event == .unavailable)
    #expect(stats.taggedFileCount == 1 && stats.trackedFileCount == 1)
    #expect(reopened.marksByAssetID[asset.photoMarkID] == [.f])
    #expect(reopened.unavailableCount == 1)
  }

  @Test("휴지통으로 보낸 파일을 재시작 후 되돌리면 원래 분류를 복원하고 동명 새 파일은 분류하지 않는다")
  func restoredIdentityKeepsMarksAfterRestart() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let original = try fixture.asset(named: "original.jpg")
    let bytes = try Data(contentsOf: original.url)
    var initial: PhotoMarkStore? = try await fixture.store()
    initial?.set(.q, enabled: true, for: [original])
    initial?.set(.w, enabled: true, for: [original])
    // This is the same barrier used before a real app trash/move operation.
    try #require(await initial?.flushAsync() == true)
    let trash = fixture.root.appendingPathComponent("SyntheticTrash", isDirectory: true)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
    let trashedURL = trash.appendingPathComponent("original.jpg")
    try FileManager.default.moveItem(at: original.url, to: trashedURL)
    initial = nil
    let inTrash = try await fixture.store()
    let trashed = try fixture.existingAsset(at: trashedURL)
    #expect(inTrash.marks(for: trashed) == [.q, .w])
    let replacement = try fixture.asset(named: "original.jpg")
    #expect(replacement.photoMarkID != original.photoMarkID)
    #expect(inTrash.marks(for: replacement).isEmpty)
    let restoredURL = fixture.root.appendingPathComponent("restored-original.jpg")
    try FileManager.default.moveItem(at: trashedURL, to: restoredURL)
    let restored = try fixture.existingAsset(at: restoredURL)
    let restarted = try await fixture.store()
    #expect(restarted.marks(for: restored) == [.q, .w])
    #expect(restarted.marks(for: replacement).isEmpty)
    #expect(restarted.unavailableCount == 0)
    #expect(try Data(contentsOf: restoredURL) == bytes)
  }

  private struct Fixture {
    let root: URL
    var database: URL { root.appendingPathComponent("marks.sqlite") }

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoMarkBudget-\(UUID())", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func asset(named name: String) throws -> ImageAsset {
      let url = root.appendingPathComponent(name)
      try Data("Synthetic file for tag-storage tests".utf8).write(to: url)
      return try existingAsset(at: url)
    }

    func existingAsset(at url: URL) throws -> ImageAsset {
      let identity = try #require(PhotoMarkFileIdentity.read(url))
      return ImageAsset(url: url, byteCount: nil, modificationDate: nil, photoMarkIdentity: identity.key)
    }

    @MainActor func store() async throws -> PhotoMarkStore {
      let store = PhotoMarkStore(databaseURL: database)
      await store.waitUntilReady()
      try #require(store.isReady && store.errorMessage == nil)
      return store
    }

    func seedReports(count: Int, assetID: String) throws {
      var database: OpaquePointer?
      try #require(sqlite3_open(self.database.path, &database) == SQLITE_OK)
      defer { sqlite3_close(database) }
      try #require(sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK)
      var statement: OpaquePointer?
      try #require(sqlite3_prepare_v2(database,
        "INSERT INTO tracking_reports (id, observed_at, report) VALUES (?, ?, ?)", -1, &statement, nil) == SQLITE_OK)
      defer { sqlite3_finalize(statement) }
      for index in 0..<count {
        let report = PhotoMarkTrackingReport(id: UUID(), observedAt: Date(timeIntervalSince1970: Double(index)),
          event: .relocated, assetID: assetID, previousURL: nil, currentURL: nil,
          archiveEntryPath: nil, slots: [.f], labels: [:])
        let data = try JSONEncoder().encode(report)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = report.id.uuidString.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        sqlite3_bind_double(statement, 2, Double(index))
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient) }
        try #require(sqlite3_step(statement) == SQLITE_DONE)
        sqlite3_reset(statement)
      }
      try #require(sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK)
    }
  }
}
