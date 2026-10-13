import Foundation
import SQLite3
import Testing

@testable import ImageViewer

@Suite("분류 CSV의 현재 상태와 직전 두 상태 저장")
struct PhotoMarkClassificationHistoryTests {
  @Test("분류 네 번 변경 후 최신 세 상태와 날짜를 재시작 뒤에도 보존한다")
  func boundedHistorySurvivesRestart() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let persistence = try await fixture.open()
    let id = "file:///history/photo.jpg"
    for slot in [PhotoMarkSlot.one, .two, .three, .four] {
      try await set(persistence, [slot], id: id)
    }
    let row = try #require(try await persistence.classificationRecords().first)
    #expect(row.current.marks == [.four])
    #expect(row.previous.map(\.marks) == [[.three], [.two]])
    let dates = [row.current.changedAt] + row.previous.map(\.changedAt)
    #expect(dates.allSatisfy { $0 != nil })
    #expect(dates.compactMap { $0 } == dates.compactMap { $0 }.sorted(by: >))
    let reopened = try await fixture.open()
    #expect(try await reopened.classificationRecords() == [row])
    #expect(try fixture.historyRowCount() == 1)
  }

  @Test("v4 분류는 날짜 미기록 baseline으로 이관하고 현재·이전 이름을 보존한다")
  func olderDatabaseHasUnknownBaselineDate() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.execute("""
      CREATE TABLE mark_labels (slot TEXT PRIMARY KEY NOT NULL, label TEXT NOT NULL);
      CREATE TABLE asset_marks (asset_id TEXT PRIMARY KEY NOT NULL, marks INTEGER NOT NULL);
      INSERT INTO mark_labels VALUES ('one', '기존 이름');
      INSERT INTO asset_marks VALUES ('file:///history/photo.jpg', 1);
      PRAGMA user_version = 4;
      """)
    let persistence = try await fixture.open()
    let baseline = try #require(try await persistence.classificationRecords().first)
    #expect(baseline.current.changedAt == nil)
    #expect(baseline.current.labels[.one] == "기존 이름")
    #expect(baseline.previous.isEmpty)
    #expect(baseline.isUnavailable, "A legacy path without a verified reference is not confirmed accessible")
    try await set(persistence, [.one, .w], id: baseline.assetID)
    let updated = try #require(try await persistence.classificationRecords().first)
    #expect(updated.current.changedAt != nil)
    #expect(updated.previous == [baseline.current])
  }

  @Test("전체 해제 파일은 CSV 대상에서 빼되 재분류하면 해제 상태와 그 날짜를 보존한다")
  func clearingKeepsAnEmptyStateForLaterReclassification() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let persistence = try await fixture.open()
    let id = "file:///history/photo.jpg"
    try await set(persistence, [.q], id: id)
    let original = try #require(try await persistence.classificationRecords().first?.current)
    try await set(persistence, [], id: id)
    #expect(try await persistence.classificationRecords().isEmpty)
    #expect(try fixture.historyRowCount() == 1)
    try await set(persistence, [], id: id)
    try await set(persistence, [.w], id: id)
    let result = try #require(try await persistence.classificationRecords().first)
    #expect(result.previous.count == 2)
    #expect(result.previous[0].marks.isEmpty)
    #expect(result.previous[0].changedAt != nil)
    #expect(result.previous[1] == original)
  }

  @Test("동일 분류·이름 재저장과 색만 변경은 분류 이력이나 날짜를 바꾸지 않는다")
  func noOpAndColorChangesKeepHistory() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let persistence = try await fixture.open()
    let id = "file:///history/photo.jpg"
    try await set(persistence, [.one], id: id)
    let before = try await persistence.classificationRecords()
    try await set(persistence, [.one], id: id)
    try await complete { persistence.setLabels([:], completion: $0) }
    try await complete { persistence.setDefinitions(labels: [:], colors: [.one: .red], completion: $0) }
    #expect(try await persistence.classificationRecords() == before)
  }

  @Test("분류명 변경은 이전 기본명과 사용자 이름을 당시 의미대로 보존한다")
  func labelRenamesSnapshotOldMeanings() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let persistence = try await fixture.open()
    let id = "file:///history/one.jpg"
    let unaffectedID = "file:///history/two.jpg"
    try await set(persistence, [.one], id: id)
    try await set(persistence, [.two], id: unaffectedID)
    let initial = try await persistence.classificationRecords()
    let defaultState = try #require(initial.first { $0.assetID == id }?.current)
    let unaffected = try #require(initial.first { $0.assetID == unaffectedID })
    #expect(defaultState.labels[.one] == PhotoMarkSlot.one.defaultLabel)
    try await complete { persistence.setLabels([.one: "선별 완료"], completion: $0) }
    try await complete { persistence.setLabels([.one: "전달 완료"], completion: $0) }
    let rows = try await persistence.classificationRecords()
    let row = try #require(rows.first { $0.assetID == id })
    #expect(row.current.labels[.one] == "전달 완료")
    #expect(row.previous.map { $0.labels[.one] } == ["선별 완료", PhotoMarkSlot.one.defaultLabel])
    #expect(row.previous.last == defaultState)
    #expect(rows.first { $0.assetID == unaffectedID } == unaffected)
  }

  @Test("이름 교환·순환은 분류 변경으로 기록하지 않고 이력 전체를 이동한다")
  func remappingCyclesPreserveTheOriginalHistories() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let persistence = try await fixture.open()
    let a = "file:///history/a.jpg", b = "file:///history/b.jpg", c = "file:///history/c.jpg"
    try await set(persistence, [.one], id: a)
    try await set(persistence, [.q], id: a)
    try await set(persistence, [.two], id: b)
    try await set(persistence, [.three], id: c)
    let before = Dictionary(uniqueKeysWithValues: try await persistence.classificationRecords().map { ($0.assetID, $0) })
    try await complete { persistence.remapAssets([a: b, b: c, c: a], completion: $0) }
    let after = Dictionary(uniqueKeysWithValues: try await persistence.classificationRecords().map { ($0.assetID, $0) })
    for (source, destination) in [a: b, b: c, c: a] {
      #expect(after[destination]?.current == before[source]?.current)
      #expect(after[destination]?.previous == before[source]?.previous)
    }
  }

  @Test("명시적 이동은 원본 이력을 옮기고 복사본은 독립된 새 분류로 시작한다")
  func movesPreserveHistoryAndCopiesStartTheirOwnHistory() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let persistence = try await fixture.open()
    let source = try fixture.asset("source.jpg")
    let moved = try fixture.asset("moved.jpg")
    let copy = try fixture.asset("copy.jpg")
    try await set(persistence, [.one], id: source.photoMarkID, asset: source)
    try await set(persistence, [.q], id: source.photoMarkID, asset: source)
    let before = try #require(try await persistence.classificationRecords().first)
    let movedReference = try #require(PhotoMarkFileReference.capture(for: moved))
    try await complete {
      persistence.commitTransfer([.q], from: source.photoMarkID, to: moved.photoMarkID,
        reference: movedReference, moving: true, completion: $0)
    }
    let movedRow = try #require(try await persistence.classificationRecords().first)
    #expect(movedRow.assetID == moved.photoMarkID)
    #expect(movedRow.current == before.current && movedRow.previous == before.previous)
    #expect(movedRow.sourceURL == moved.url)

    let copyReference = try #require(PhotoMarkFileReference.capture(for: copy))
    try await complete {
      persistence.commitTransfer([.q], from: moved.photoMarkID, to: copy.photoMarkID,
        reference: copyReference, moving: false, completion: $0)
    }
    let rows = try await persistence.classificationRecords()
    let copied = try #require(rows.first { $0.assetID == copy.photoMarkID })
    #expect(copied.current.marks == [.q] && copied.current.changedAt != nil)
    #expect(copied.previous.isEmpty)
    #expect(rows.first { $0.assetID == moved.photoMarkID } == movedRow)
  }

  @Test("해제된 현재 상태의 이동은 날짜를 그대로 옮기고 빈 복사·미분류 이동은 이력을 만들지 않는다")
  func emptyCurrentHistoryMovesWithoutTrackingOrInventedDates() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let persistence = try await fixture.open()
    let source = try fixture.asset("source.jpg"), moved = try fixture.asset("moved.jpg")
    let reference = try #require(PhotoMarkFileReference.capture(for: moved))
    try await set(persistence, [.q], id: source.photoMarkID, asset: source)
    try await set(persistence, [], id: source.photoMarkID, asset: source)
    let history = try fixture.history(for: source.photoMarkID)
    try #require(history.count == 2 && history[0].marks.isEmpty)
    try await complete {
      persistence.commitTransfer([], from: source.photoMarkID, to: moved.photoMarkID,
        reference: reference, moving: false, completion: $0)
    }
    #expect(try fixture.history(for: moved.photoMarkID).isEmpty)
    try await complete {
      persistence.commitTransfer([], from: source.photoMarkID, to: source.photoMarkID,
        reference: reference, moving: true, completion: $0)
    }
    #expect(try fixture.history(for: source.photoMarkID) == history)
    try await complete {
      persistence.commitTransfer([], from: source.photoMarkID, to: moved.photoMarkID,
        reference: reference, moving: true, completion: $0)
    }
    #expect(try fixture.history(for: source.photoMarkID).isEmpty)
    #expect(try fixture.history(for: moved.photoMarkID) == history)
    // A source with no history must neither invent a state nor overwrite the
    // destination if the same completion is delivered a second time.
    try await complete {
      persistence.commitTransfer([], from: source.photoMarkID, to: moved.photoMarkID,
        reference: reference, moving: true, completion: $0)
    }
    #expect(try fixture.history(for: moved.photoMarkID) == history)
    let statistics = try persistence.storageStatistics()
    #expect(statistics.taggedFileCount == 0 && statistics.trackedFileCount == 0)
    #expect(statistics.cachedReferenceCount == 0)
    try await set(persistence, [.w], id: moved.photoMarkID, asset: moved)
    let row = try #require(try await persistence.classificationRecords().first)
    #expect(row.previous == history)
    #expect(try fixture.historyRowCount() == 1)
  }

  @Test("해제 이력을 이동하는 중 원본 삭제가 실패하면 목적지 기록도 원자적으로 되돌린다")
  func emptyHistoryTransferFailureRollsBackBothIdentities() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let persistence = try await fixture.open()
    let source = try fixture.asset("source.jpg"), moved = try fixture.asset("moved.jpg")
    try await set(persistence, [.q], id: source.photoMarkID, asset: source)
    try await set(persistence, [], id: source.photoMarkID, asset: source)
    let history = try fixture.history(for: source.photoMarkID)
    try fixture.execute("""
      CREATE TRIGGER reject_empty_history_move BEFORE DELETE ON classification_history
      WHEN OLD.asset_id = '\(source.photoMarkID.replacingOccurrences(of: "'", with: "''"))'
      BEGIN SELECT RAISE(FAIL, 'empty history move failed'); END;
      """)
    let reference = try #require(PhotoMarkFileReference.capture(for: moved))
    do {
      try await complete {
        persistence.commitTransfer([], from: source.photoMarkID, to: moved.photoMarkID,
          reference: reference, moving: true, completion: $0)
      }
      Issue.record("Failed empty-history transfer unexpectedly committed")
    } catch { #expect(error.localizedDescription.contains("empty history move failed")) }
    #expect(try fixture.history(for: source.photoMarkID) == history)
    #expect(try fixture.history(for: moved.photoMarkID).isEmpty)
    #expect(try fixture.historyRowCount() == 1)
  }

  @Test("오프라인 파일도 저장된 경로와 이력을 포함하고 읽기 API는 원본을 요구하지 않는다")
  func missingSourcesRemainInReport() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let persistence = try await fixture.open()
    let source = try fixture.asset("source.jpg")
    try await set(persistence, [.w], id: source.photoMarkID, asset: source)
    let before = try #require(try await persistence.classificationRecords().first)
    try FileManager.default.removeItem(at: source.url)
    // No source I/O is performed by classificationRecords itself.
    #expect(try await persistence.classificationRecords().first?.current == before.current)
    let reopened = try await fixture.open()
    let row = try #require(try await reopened.classificationRecords().first)
    #expect(row.isUnavailable && row.sourceURL == source.url)
    #expect(row.current == before.current && row.previous == before.previous)
  }

  @Test("폴더 재확인과 외부 이름 변경 추적은 분류 이력에 가짜 상태를 추가하지 않는다")
  func trackingAndExternalRenameDoNotAddClassificationEvents() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let persistence = try await fixture.open()
    let source = try fixture.asset("source.jpg")
    try await set(persistence, [.one], id: source.photoMarkID, asset: source)
    try await set(persistence, [.w], id: source.photoMarkID, asset: source)
    let before = try #require(try await persistence.classificationRecords().first)
    let destination = fixture.root.appendingPathComponent("renamed.jpg")
    try FileManager.default.moveItem(at: source.url, to: destination)
    let renamed = source.replacingURL(destination)
    _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Set<String>, Error>) in
      persistence.trackAssets([renamed]) { continuation.resume(with: $0.mapError { $0 as Error }) }
    }
    let reopened = try await fixture.open()
    let row = try #require(try await reopened.classificationRecords().first)
    #expect(row.current == before.current && row.previous == before.previous)
    #expect(row.sourceURL?.standardizedFileURL == destination.standardizedFileURL)
  }

  @Test("이력 저장 실패 시 현재 분류와 직전 상태들을 모두 되돌린다")
  func failedHistoryWriteRollsBackCurrentMarksAndHistory() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let persistence = try await fixture.open()
    let id = "file:///history/photo.jpg"
    try await set(persistence, [.one], id: id)
    let before = try await persistence.classificationRecords()
    try fixture.execute("""
      CREATE TRIGGER reject_history BEFORE INSERT ON classification_history
      BEGIN SELECT RAISE(FAIL, 'history write failed'); END;
      """)
    do {
      try await set(persistence, [.q], id: id)
      Issue.record("Failed history transaction unexpectedly committed")
    } catch { #expect(error.localizedDescription.contains("history write failed")) }
    do {
      _ = try await persistence.classificationRecords()
      Issue.record("A failed storage session must not report a successful export")
    } catch {}
    let reopened = try await fixture.open()
    #expect(try await reopened.classificationRecords() == before)
  }

  @Test("일괄 분류의 두 번째 이력 저장 실패는 첫 번째 파일 변경도 원자적으로 되돌린다")
  func batchFailureRollsBackEveryHistory() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let persistence = try await fixture.open()
    let a = try fixture.asset("a.jpg"), b = try fixture.asset("b.jpg")
    try await set(persistence, [.one], id: a.photoMarkID, asset: a)
    try await set(persistence, [.two], id: b.photoMarkID, asset: b)
    let before = try await persistence.classificationRecords()
    try fixture.execute("""
      CREATE TRIGGER reject_second_history BEFORE INSERT ON classification_history
      WHEN NEW.asset_id = '\(b.photoMarkID.replacingOccurrences(of: "'", with: "''"))'
      BEGIN SELECT RAISE(FAIL, 'second history failed'); END;
      """)
    do {
      try await complete {
        persistence.setMarks([PhotoMarkWrite(asset: a, marks: [.q]), PhotoMarkWrite(asset: b, marks: [.w])], completion: $0)
      }
      Issue.record("Failed batch unexpectedly committed")
    } catch { #expect(error.localizedDescription.contains("second history failed")) }
    let reopened = try await fixture.open()
    let after = try await reopened.classificationRecords()
    #expect(after.count == before.count)
    for (restored, original) in zip(after, before) {
      // Saved bookmarks may normalize /var to /private/var on restart. This
      // filesystem alias must not weaken the classification rollback assertions.
      #expect(restored.sourceURL?.resolvingSymlinksInPath().path
        == original.sourceURL?.resolvingSymlinksInPath().path)
      #expect(restored.assetID == original.assetID)
      #expect(restored.archiveEntryPath == original.archiveEntryPath)
      #expect(restored.isUnavailable == original.isUnavailable)
      #expect(restored.current == original.current)
      #expect(restored.previous == original.previous)
    }
  }

  @Test("옛 경로 이관은 기록된 날짜를 이동하고 합쳐진 baseline 날짜는 꾸미지 않는다")
  func legacyIdentityMergePreservesDatesWithoutInventingAnEdit() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let persistence = try await fixture.open()
    let source = "file:///history/source.jpg", destination = "document:v1:target"
    try await set(persistence, [.one], id: source)
    try await set(persistence, [.q], id: source)
    let before = try #require(try await persistence.classificationRecords().first)
    try await complete { persistence.migrateLegacyMarks([source: destination], completion: $0) }
    let migrated = try #require(try await persistence.classificationRecords().first)
    #expect(migrated.current == before.current && migrated.previous == before.previous)
    try await set(persistence, [.two], id: source)
    try await complete { persistence.migrateLegacyMarks([source: destination], completion: $0) }
    let merged = try #require(try await persistence.classificationRecords().first)
    #expect(merged.current.marks == [.q, .two])
    #expect(merged.current.changedAt == nil)
    #expect(merged.previous.count == 2)
    #expect(try fixture.historyRowCount() == 1)
  }

  @Test("동일 분류의 경로 이관은 최신 날짜와 직전 상태들을 보존하고 미기록 baseline으로 덮지 않는다")
  func equalMarkAliasesPreferTheNewestKnownHistory() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let source = "file:///history/newer.jpg", destination = "document:v1:target"
    let undated = "file:///history/undated.jpg"
    try fixture.execute("""
      CREATE TABLE mark_labels (slot TEXT PRIMARY KEY NOT NULL, label TEXT NOT NULL);
      CREATE TABLE asset_marks (asset_id TEXT PRIMARY KEY NOT NULL, marks INTEGER NOT NULL);
      INSERT INTO asset_marks VALUES ('\(destination)', 1), ('\(undated)', 1);
      PRAGMA user_version = 4;
      """)
    let persistence = try await fixture.open()
    // Give the canonical row a known older date; the path alias was edited later.
    try await set(persistence, [.q], id: destination)
    try await set(persistence, [.one], id: destination)
    try await set(persistence, [.two], id: source)
    try await set(persistence, [.three], id: source)
    try await set(persistence, [.one], id: source)
    let newest = try #require(try await persistence.classificationRecords().first { $0.assetID == source })
    try await complete { persistence.migrateLegacyMarks([source: destination], completion: $0) }
    let first = try #require(try await persistence.classificationRecords().first { $0.assetID == destination })
    #expect(first.current == newest.current && first.previous == newest.previous)
    try await complete { persistence.migrateLegacyMarks([undated: destination], completion: $0) }
    let second = try #require(try await persistence.classificationRecords().first)
    #expect(second.current == newest.current && second.previous == newest.previous)
  }

  private func set(_ persistence: PhotoMarkPersistence, _ marks: Set<PhotoMarkSlot>,
    id: String, asset: ImageAsset? = nil) async throws {
    try await complete { persistence.setMarks(marks, for: id, asset: asset, completion: $0) }
  }

  private func complete(_ operation: (@escaping @Sendable (Result<Void, PhotoMarkPersistenceError>) -> Void) -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      operation { continuation.resume(with: $0.mapError { $0 as Error }) }
    }
  }

  private struct Fixture {
    let root: URL
    var database: URL { root.appendingPathComponent("marks.sqlite") }

    init() throws {
      root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("PhotoMarkHistory-\(UUID())", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func open() async throws -> PhotoMarkPersistence {
      let persistence = PhotoMarkPersistence(databaseURL: database, inMemory: false)
      _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PhotoMarkSnapshot, Error>) in
        persistence.load { continuation.resume(with: $0.mapError { $0 as Error }) }
      }
      return persistence
    }

    func asset(_ name: String) throws -> ImageAsset {
      let url = root.appendingPathComponent(name)
      try Data("synthetic fixture, no personal photo".utf8).write(to: url)
      let identity = try #require(PhotoMarkFileIdentity.read(url))
      return ImageAsset(url: url, byteCount: nil, modificationDate: nil, photoMarkIdentity: identity.key)
    }

    func execute(_ sql: String) throws {
      try withDatabase { database in
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
          throw PhotoMarkPersistenceError(message: String(cString: sqlite3_errmsg(database)))
        }
      }
    }

    func historyRowCount() throws -> Int {
      try withDatabase { database in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM classification_history", -1, &statement, nil) == SQLITE_OK,
          let statement else { throw PhotoMarkPersistenceError(message: "Could not inspect history rows") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw PhotoMarkPersistenceError(message: "Could not count history rows") }
        return Int(sqlite3_column_int64(statement, 0))
      }
    }

    func history(for assetID: String) throws -> [PhotoMarkClassificationState] {
      try withDatabase { database in
        var statement: OpaquePointer?
        let sql = "SELECT history FROM classification_history WHERE asset_id = '\(assetID.replacingOccurrences(of: "'", with: "''"))'"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else { throw PhotoMarkPersistenceError(message: "Could not inspect history") }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return [] }
        guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
          throw PhotoMarkPersistenceError(message: "Could not read history")
        }
        return try JSONDecoder().decode([PhotoMarkClassificationState].self,
          from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
      }
    }

    func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
      var database: OpaquePointer?
      guard sqlite3_open(databaseURLPath, &database) == SQLITE_OK, let database else {
        throw PhotoMarkPersistenceError(message: "Could not open test database")
      }
      defer { sqlite3_close(database) }
      return try body(database)
    }

    private var databaseURLPath: String { database.path }
    func remove() { try? FileManager.default.removeItem(at: root) }
  }
}
