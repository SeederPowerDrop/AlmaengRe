import Foundation
import SQLite3
import Testing

@testable import ImageViewer

@Suite("사진 분류 문서 식별자 저장 전환")
struct PhotoMarkMigrationTests {
  @Test("기존 저장소의 분류와 이름을 보존하며 버전만 먼저 올린다", arguments: [0, 1, 2, 3, 4])
  func legacyDatabaseLoadsWithoutDroppingRows(version: Int) async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("marks.sqlite")
    try createDatabase(database, version: version, rows: "('file:///photos/original.jpg', 33)")

    let persistence = PhotoMarkPersistence(databaseURL: database, inMemory: false)
    let snapshot = try await load(persistence)
    #expect(snapshot.labels == [.one: "최상", .w: "업로드"])
    #expect(snapshot.marksByAssetID == ["file:///photos/original.jpg": [.one, .w]])
    #expect(persistence.flush() == nil)
    #expect(try databaseVersion(database) == 5)

    let reopened = try await load(PhotoMarkPersistence(databaseURL: database, inMemory: false))
    #expect(reopened.labels == snapshot.labels)
    #expect(reopened.marksByAssetID == snapshot.marksByAssetID)
  }

  @Test("여러 옛 경로의 분류를 문서의 기존 분류와 합치고 없는 원본은 무시한다")
  func migrationUnionsEverySourceAndPreservesUnrelatedMarks() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("marks.sqlite")
    let target = "document:v1:volume:42"
    let untouchedTarget = "document:v1:volume:99"
    try createDatabase(database, version: 1, rows: """
      ('file:///photos/old-a.jpg', 33),
      ('file:///photos/old-b.jpg', 2),
      ('file:///photos/untouched.jpg', 128),
      ('document:v1:volume:42', 8),
      ('document:v1:volume:99', 2048)
      """)
    let persistence = PhotoMarkPersistence(databaseURL: database, inMemory: false)
    _ = try await load(persistence)

    try await migrate(persistence, mapping: [
      "file:///photos/old-a.jpg": target,
      "file:///photos/old-b.jpg": target,
      "file:///photos/absent.jpg": untouchedTarget,
      untouchedTarget: untouchedTarget,
    ])
    #expect(persistence.flush() == nil)

    let reopened = try await load(PhotoMarkPersistence(databaseURL: database, inMemory: false))
    #expect(reopened.labels == [.one: "최상", .w: "업로드"])
    #expect(reopened.marksByAssetID == [
      target: [.one, .two, .four, .w],
      untouchedTarget: [.f],
      "file:///photos/untouched.jpg": [.r],
    ])
    #expect(try databaseVersion(database) == 5)
  }

  @Test("전환 중 오류가 생기면 대상 합치기와 원본 제거를 함께 되돌린다")
  func failedMigrationRollsBackEveryChange() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("marks.sqlite")
    try createDatabase(database, version: 1, rows: """
      ('file:///photos/original.jpg', 33),
      ('document:v1:volume:42', 2)
      """)
    let persistence = PhotoMarkPersistence(databaseURL: database, inMemory: false)
    let before = try await load(persistence)
    try execute(database, sql: """
      CREATE TRIGGER reject_legacy_removal BEFORE DELETE ON asset_marks
      WHEN OLD.asset_id = 'file:///photos/original.jpg'
      BEGIN SELECT RAISE(FAIL, 'migration removal failed'); END;
      """)

    do {
      try await migrate(persistence, mapping: ["file:///photos/original.jpg": "document:v1:volume:42"])
      Issue.record("The failing migration unexpectedly succeeded.")
    } catch {
      #expect(error.localizedDescription.contains("migration removal failed"))
    }
    #expect(persistence.flush()?.message.contains("migration removal failed") == true)

    let after = try await load(PhotoMarkPersistence(databaseURL: database, inMemory: false))
    #expect(after.labels == before.labels)
    #expect(after.marksByAssetID == before.marksByAssetID)
  }

  @Test("지원하지 않는 새 저장소는 오류를 알리고 변경하지 않는다")
  func newerDatabaseIsPreserved() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("marks.sqlite")
    try createDatabase(database, version: 6, rows: "('document:v1:volume:42', 33)")
    let original = try Data(contentsOf: database)
    let persistence = PhotoMarkPersistence(databaseURL: database, inMemory: false)
    do {
      _ = try await load(persistence)
      Issue.record("A newer database was unexpectedly accepted.")
    } catch {
      #expect(error.localizedDescription.contains("newer version"))
    }
    #expect(persistence.flush() != nil)
    #expect(try databaseVersion(database) == 6)
    #expect(try Data(contentsOf: database) == original)
  }

  @Test("추적 근거가 없는 파일 식별자는 보존하되 사용 가능한 분류로 취급하지 않는다")
  func identitiesWithoutReferencesAreUnavailable() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("marks.sqlite")
    let fileID = "file:v2:uuid=volume:42:100:123"
    let archiveID = "archive-file:v2:uuid=volume:43:100:123:entry:cGhvdG8uanBn"
    try createDatabase(database, version: 2, rows: """
      ('\(fileID)', 1), ('\(archiveID)', 2), ('file:///legacy/photo.jpg', 32)
      """)
    let snapshot = try await load(PhotoMarkPersistence(databaseURL: database, inMemory: false))
    #expect(snapshot.unavailableAssetIDs == [fileID, archiveID])
    #expect(snapshot.referenceIDs.isEmpty)
    #expect(snapshot.marksByAssetID == [fileID: [.one], archiveID: [.two], "file:///legacy/photo.jpg": [.w]])
  }

  @Test("추적 정보 저장 실패 시 새 분류도 함께 되돌린다")
  func trackingWriteFailureRollsBackMarks() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("marks.sqlite")
    let photo = try trackedAsset(in: directory)
    try createDatabase(database, version: 1, rows: "('file:///legacy/photo.jpg', 32)")
    let persistence = PhotoMarkPersistence(databaseURL: database, inMemory: false)
    let before = try await load(persistence)
    try execute(database, sql: """
      CREATE TRIGGER reject_tracking BEFORE INSERT ON asset_tracking
      BEGIN SELECT RAISE(FAIL, 'tracking write failed'); END;
      """)
    do {
      try await setMarks(persistence, [.one], for: photo)
      Issue.record("The failing tracking write unexpectedly succeeded.")
    } catch {
      #expect(error.localizedDescription.contains("tracking write failed"))
    }
    #expect(persistence.flush()?.message.contains("tracking write failed") == true)
    let after = try await load(PhotoMarkPersistence(databaseURL: database, inMemory: false))
    #expect(after.marksByAssetID == before.marksByAssetID)
    #expect(after.referenceIDs.isEmpty)
  }

  @Test("마지막 분류를 지우면 추적 정보도 지우고 다시 분류할 때 재생성한다")
  func removingMarksAlsoRemovesAndRecreatesTracking() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("marks.sqlite")
    let photo = try trackedAsset(in: directory)
    let persistence = PhotoMarkPersistence(databaseURL: database, inMemory: false)
    _ = try await load(persistence)
    try await setMarks(persistence, [.one, .w], for: photo)
    let saved = try await load(PhotoMarkPersistence(databaseURL: database, inMemory: false))
    #expect(saved.referenceIDs == [photo.photoMarkID])
    #expect(saved.unavailableAssetIDs.isEmpty)

    try await setMarks(persistence, [], for: photo)
    let cleared = try await load(PhotoMarkPersistence(databaseURL: database, inMemory: false))
    #expect(cleared.marksByAssetID.isEmpty && cleared.referenceIDs.isEmpty)

    try await setMarks(persistence, [.f], for: photo)
    let recreated = try await load(PhotoMarkPersistence(databaseURL: database, inMemory: false))
    #expect(recreated.marksByAssetID == [photo.photoMarkID: [.f]])
    #expect(recreated.referenceIDs == [photo.photoMarkID])
    #expect(recreated.unavailableAssetIDs.isEmpty)
  }

  private func load(_ persistence: PhotoMarkPersistence) async throws -> PhotoMarkSnapshot {
    try await withCheckedThrowingContinuation { continuation in
      persistence.load { continuation.resume(with: $0.mapError { $0 as Error }) }
    }
  }

  private func migrate(_ persistence: PhotoMarkPersistence, mapping: [String: String]) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      persistence.migrateLegacyMarks(mapping) { continuation.resume(with: $0.mapError { $0 as Error }) }
    }
  }

  private func setMarks(_ persistence: PhotoMarkPersistence, _ marks: Set<PhotoMarkSlot>,
    for asset: ImageAsset) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      persistence.setMarks(marks, for: asset.photoMarkID, asset: asset) {
        continuation.resume(with: $0.mapError { $0 as Error })
      }
    }
  }

  private func trackedAsset(in directory: URL) throws -> ImageAsset {
    let url = directory.appendingPathComponent("photo.jpg")
    try Data("photo bytes".utf8).write(to: url)
    let identity = try #require(PhotoMarkFileIdentity.read(url))
    return ImageAsset(url: url, byteCount: nil, modificationDate: nil, photoMarkIdentity: identity.key)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PhotoMarkMigrationTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func createDatabase(_ url: URL, version: Int, rows: String) throws {
    try execute(url, sql: """
      CREATE TABLE mark_labels (slot TEXT PRIMARY KEY NOT NULL, label TEXT NOT NULL);
      CREATE TABLE asset_marks (asset_id TEXT PRIMARY KEY NOT NULL,
        marks INTEGER NOT NULL CHECK (marks > 0 AND marks <= 4095));
      INSERT INTO mark_labels VALUES ('one', '최상'), ('w', '업로드');
      INSERT INTO asset_marks VALUES \(rows);
      PRAGMA user_version = \(version);
      """)
  }

  private func execute(_ url: URL, sql: String) throws {
    try withDatabase(url) { database in
      guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw PhotoMarkPersistenceError(message: String(cString: sqlite3_errmsg(database)))
      }
    }
  }

  private func databaseVersion(_ url: URL) throws -> Int {
    try withDatabase(url) { database in
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
        throw PhotoMarkPersistenceError(message: String(cString: sqlite3_errmsg(database)))
      }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PhotoMarkPersistenceError(message: String(cString: sqlite3_errmsg(database)))
      }
      return Int(sqlite3_column_int(statement, 0))
    }
  }

  private func withDatabase<T>(_ url: URL, body: (OpaquePointer) throws -> T) throws -> T {
    var database: OpaquePointer?
    let result = sqlite3_open(url.path, &database)
    defer { sqlite3_close(database) }
    guard result == SQLITE_OK, let database else {
      throw PhotoMarkPersistenceError(message: "Unable to open the test database.")
    }
    return try body(database)
  }
}
