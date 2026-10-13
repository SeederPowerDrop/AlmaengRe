import Foundation
import SQLite3
import Testing

@testable import ImageViewer

@Suite("선택한 사진·영상의 일괄 분류 저장")
@MainActor
struct PhotoMarkBatchPersistenceTests {
  @Test("혼합 선택에 한 분류를 적용·해제하며 다른 분류와 원본을 보존한다")
  func batchPreservesOtherMarksAndOriginals() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let photo = try fixture.asset("photo.jpg")
    let video = try fixture.asset("video.mp4")
    let untouched = try fixture.asset("untouched.png")
    let photoBytes = try Data(contentsOf: photo.url)
    let videoBytes = try Data(contentsOf: video.url)
    let photoDate = try photo.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    let videoDate = try video.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    let store = await fixture.store()
    store.toggle(.one, for: photo)
    store.toggle(.q, for: photo)
    store.toggle(.w, for: video)
    store.toggle(.f, for: untouched)
    let initialRevision = store.revision

    // Repeated identities in a selection are applied once, never toggled twice.
    store.set(.one, enabled: true, for: [photo, video, photo, video])
    #expect(store.revision == initialRevision + 1)
    #expect(store.marks(for: photo) == [.one, .q])
    #expect(store.marks(for: video) == [.one, .w])
    #expect(store.marks(for: untouched) == [.f])
    store.set(.one, enabled: true, for: [photo, video])
    #expect(store.revision == initialRevision + 1)
    store.flush()
    let saved = await fixture.store()
    #expect(saved.marks(for: photo) == [.one, .q])
    #expect(saved.marks(for: video) == [.one, .w])

    store.set(.one, enabled: false, for: [photo, video])
    #expect(store.revision == initialRevision + 2)
    store.flush()
    let cleared = await fixture.store()
    #expect(cleared.marks(for: photo) == [.q])
    #expect(cleared.marks(for: video) == [.w])
    #expect(cleared.marks(for: untouched) == [.f])
    #expect(try Data(contentsOf: photo.url) == photoBytes)
    #expect(try Data(contentsOf: video.url) == videoBytes)
    #expect(try photo.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == photoDate)
    #expect(try video.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == videoDate)
    #expect(store.errorMessage == nil)
  }

  @Test("일괄 분류가 옛 경로 기록을 한 번에 이전하고 이동 추적을 등록한다")
  func batchAdoptsLegacyMarksAndTracksRenames() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let photo = try fixture.asset("photo.jpg")
    let video = try fixture.asset("video.mp4")
    try fixture.execute("""
      CREATE TABLE mark_labels (slot TEXT PRIMARY KEY NOT NULL, label TEXT NOT NULL);
      CREATE TABLE asset_marks (asset_id TEXT PRIMARY KEY NOT NULL, marks INTEGER NOT NULL);
      INSERT INTO asset_marks VALUES ('\(fixture.quoted(photo.sessionID))', 16),
        ('\(fixture.quoted(video.sessionID))', 32);
      PRAGMA user_version = 1;
      """)
    let store = await fixture.store()
    let initialRevision = store.revision
    store.set(.one, enabled: true, for: [photo, video])
    #expect(store.revision == initialRevision + 1)
    #expect(store.marksByAssetID[photo.sessionID] == nil)
    #expect(store.marksByAssetID[video.sessionID] == nil)
    #expect(store.marks(for: photo) == [.one, .q])
    #expect(store.marks(for: video) == [.one, .w])
    store.flush()
    #expect(store.errorMessage == nil)

    let renamedURL = fixture.root.appendingPathComponent("renamed.mp4")
    try FileManager.default.moveItem(at: video.url, to: renamedURL)
    let renamed = video.replacingURL(renamedURL)
    let reopened = await fixture.store()
    #expect(reopened.unavailableCount == 0)
    #expect(reopened.marks(for: photo) == [.one, .q])
    #expect(reopened.marks(for: renamed) == [.one, .w])
    reopened.set(.one, enabled: false, for: [photo, renamed])
    reopened.set(.q, enabled: false, for: [photo])
    reopened.set(.w, enabled: false, for: [renamed])
    reopened.flush()
    let empty = await fixture.store()
    #expect(empty.marksByAssetID.isEmpty)
    #expect(empty.unavailableCount == 0)
  }

  @Test("선택 중 한 파일 저장이 실패하면 모든 분류 변경을 되돌린다")
  func failedBatchRollsBackEveryRow() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let photo = try fixture.asset("photo.jpg")
    let video = try fixture.asset("video.mp4")
    let store = await fixture.store()
    store.toggle(.q, for: photo)
    store.flush()
    try fixture.execute("""
      CREATE TRIGGER reject_second_file BEFORE INSERT ON asset_tracking
      WHEN NEW.asset_id = '\(fixture.quoted(video.photoMarkID))'
      BEGIN SELECT RAISE(FAIL, 'batch tracking write failed'); END;
      """)
    store.set(.one, enabled: true, for: [photo, video])
    store.flush()
    #expect(!store.isReady)
    #expect(store.errorMessage?.contains("batch tracking write failed") == true)
    // Unsaved visible values remain for the failure message, as with one-photo edits.
    #expect(store.marks(for: photo) == [.one, .q])
    #expect(store.marks(for: video) == [.one])
    let reopened = await fixture.store()
    #expect(reopened.marks(for: photo) == [.q])
    #expect(reopened.marks(for: video).isEmpty)
    #expect(reopened.unavailableCount == 0)
  }

  @Test("사용할 수 없는 파일의 기록은 유지하며 사용 가능한 선택만 분류한다")
  func unavailableSelectedIdentityIsNotOverwritten() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let missing = try fixture.asset("missing.jpg")
    let available = try fixture.asset("available.mp4")
    let store = await fixture.store()
    store.toggle(.w, for: missing)
    store.flush()
    try FileManager.default.removeItem(at: missing.url)
    let reopened = await fixture.store()
    #expect(reopened.unavailableCount == 1)
    reopened.set(.one, enabled: true, for: [missing, available])
    #expect(reopened.marksByAssetID[missing.photoMarkID] == [.w])
    #expect(reopened.marks(for: missing).isEmpty)
    #expect(reopened.marks(for: available) == [.one])
    reopened.flush()
    let saved = await fixture.store()
    #expect(saved.marksByAssetID[missing.photoMarkID] == [.w])
    #expect(saved.marks(for: available) == [.one])
    #expect(saved.unavailableCount == 1)
  }

  private struct Fixture {
    let root: URL
    var database: URL { root.appendingPathComponent("marks.sqlite") }

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PhotoMarkBatchTests-\(UUID())", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func asset(_ name: String) throws -> ImageAsset {
      let url = root.appendingPathComponent(name)
      try Data("Synthetic classification fixture: \(name)".utf8).write(to: url)
      let identity = try #require(PhotoMarkFileIdentity.read(url))
      return ImageAsset(url: url, byteCount: nil, modificationDate: nil, photoMarkIdentity: identity.key)
    }

    @MainActor
    func store() async -> PhotoMarkStore {
      let store = PhotoMarkStore(databaseURL: database)
      await store.waitUntilReady()
      #expect(store.isReady)
      return store
    }

    func quoted(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "''") }

    func execute(_ sql: String) throws {
      var connection: OpaquePointer?
      #expect(sqlite3_open(database.path, &connection) == SQLITE_OK)
      defer { sqlite3_close(connection) }
      guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
        throw PhotoMarkPersistenceError(message: String(cString: sqlite3_errmsg(connection)))
      }
    }
  }
}
