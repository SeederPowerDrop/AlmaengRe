import Foundation
import SQLite3
import Testing

@testable import ImageViewer

@Suite("사진 분류 색상 저장과 편집")
@MainActor
struct PhotoMarkColorTests {
  @Test("키별 기본 색상은 안정적으로 유지되고 모든 선택 색상이 왕복 저장된다")
  func paletteAndDefinitionsSurviveRelaunch() async throws {
    #expect(PhotoMarkSlot.allCases.map(\.defaultColor) == [
      .yellow, .green, .blue, .purple, .red, .teal, .orange, .pink, .indigo, .green, .blue, .gray,
    ])
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("marks.sqlite")
    let colors = Dictionary(uniqueKeysWithValues: zip(PhotoMarkSlot.allCases, PhotoMarkColor.allCases))
    let store = PhotoMarkStore(databaseURL: database)
    await store.waitUntilReady()
    #expect(store.color(for: .one) == .yellow)
    store.setDefinitions(labels: [.one: " 인화 후보 ", .f: ""], colors: colors)
    store.flush()
    #expect(store.isReady && store.errorMessage == nil)

    let reopened = PhotoMarkStore(databaseURL: database)
    await reopened.waitUntilReady()
    #expect(reopened.labels == [.one: "인화 후보", .f: ""])
    #expect(reopened.colors == colors)
    #expect(reopened.color(for: .f) == .gray)
  }

  @Test("기존 이름 변경 API는 사용자가 지정한 색상을 보존한다")
  func labelsOnlySavePreservesColors() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("marks.sqlite")
    let store = PhotoMarkStore(databaseURL: database)
    await store.waitUntilReady()
    store.setDefinitions(labels: [.one: "최상"], colors: [.one: .pink, .w: .orange])
    store.setLabels([.one: "전달 완료"])
    store.flush()

    let reopened = PhotoMarkStore(databaseURL: database)
    await reopened.waitUntilReady()
    #expect(reopened.labels == [.one: "전달 완료"])
    #expect(reopened.colors == [.one: .pink, .w: .orange])
  }

  @Test("옛 저장소의 분류와 이름을 보존하고 잘못된 색상은 기본값으로 읽는다")
  func legacyMigrationAndInvalidColorFallback() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("marks.sqlite")
    try execute(database, sql: """
      CREATE TABLE mark_labels (slot TEXT PRIMARY KEY NOT NULL, label TEXT NOT NULL);
      CREATE TABLE asset_marks (asset_id TEXT PRIMARY KEY NOT NULL, marks INTEGER NOT NULL);
      INSERT INTO mark_labels VALUES ('one', '보존할 이름');
      INSERT INTO asset_marks VALUES ('file:///photos/legacy.jpg', 33);
      PRAGMA user_version = 2;
      """)
    let store = PhotoMarkStore(databaseURL: database)
    await store.waitUntilReady()
    #expect(store.isReady)
    #expect(store.labels == [.one: "보존할 이름"])
    #expect(store.marksByAssetID == ["file:///photos/legacy.jpg": [.one, .w]])
    #expect(store.colors.isEmpty)
    #expect(store.color(for: .one) == .yellow)
    try execute(database, sql: """
      INSERT INTO mark_colors VALUES ('one', 'unknown'), ('w', 'pink'), ('future-slot', 'blue');
      """)

    let reopened = PhotoMarkStore(databaseURL: database)
    await reopened.waitUntilReady()
    #expect(reopened.isReady)
    #expect(reopened.colors == [.w: .pink])
    #expect(reopened.color(for: .one) == .yellow)
    #expect(reopened.color(for: .w) == .pink)
    #expect(reopened.labels == store.labels)
    #expect(reopened.marksByAssetID == store.marksByAssetID)
  }

  @Test("색상 쓰기가 실패하면 이름 변경도 함께 되돌린다")
  func failedDefinitionSaveRollsBackBothFields() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("marks.sqlite")
    let store = PhotoMarkStore(databaseURL: database)
    await store.waitUntilReady()
    store.setDefinitions(labels: [.one: "기존 이름"], colors: [.one: .green])
    store.flush()
    try execute(database, sql: """
      CREATE TRIGGER reject_colors BEFORE INSERT ON mark_colors
      BEGIN SELECT RAISE(FAIL, 'test color storage failure'); END;
      """)
    store.setDefinitions(labels: [.one: "저장 실패할 이름"], colors: [.one: .pink])
    store.flush()
    #expect(!store.isReady)
    #expect(store.errorMessage?.contains("test color storage failure") == true)

    let reopened = PhotoMarkStore(databaseURL: database)
    await reopened.waitUntilReady()
    #expect(reopened.labels == [.one: "기존 이름"])
    #expect(reopened.colors == [.one: .green])
  }

  @Test("서로 다른 편집창에서 같은 키의 이름과 색상을 변경해도 둘 다 보존한다")
  func nameAndColorEditorsMergeIndependently() {
    let labels: [PhotoMarkSlot: String] = [.one: "최상", .w: "업로드"]
    let colors: [PhotoMarkSlot: PhotoMarkColor] = [.one: .yellow, .w: .teal]
    var names = PhotoMarkLabelDraft(labels: labels, colors: colors)
    var palette = PhotoMarkLabelDraft(labels: labels, colors: colors)
    names.labels[.one] = "인화 후보"
    palette.colors[.one] = .purple
    #expect(names.hasChanges && palette.hasChanges)

    let savedLabels = names.applyingChanges(to: labels)
    let savedColors = names.applyingColorChanges(to: colors)
    #expect(palette.applyingChanges(to: savedLabels) == [.one: "인화 후보", .w: "업로드"])
    #expect(palette.applyingColorChanges(to: savedColors) == [.one: .purple, .w: .teal])
    palette.refresh(with: savedLabels, colors: savedColors)
    #expect(palette.labels[.one] == "인화 후보")
    #expect(palette.colors[.one] == .purple && palette.hasChanges)

    names.refresh(with: savedLabels, colors: palette.applyingColorChanges(to: savedColors))
    #expect(names.colors[.one] == .purple)
    #expect(!names.hasChanges)
  }

  @Test("기본색 복원과 오래된 이름 전용 새로고침도 색상 편집을 잃지 않는다")
  func colorResetAndLegacyRefreshKeepFieldEdits() {
    var draft = PhotoMarkLabelDraft(labels: [.one: "최상"], colors: [.one: .pink])
    draft.colors.removeValue(forKey: .one)
    draft.refresh(with: [.one: "전달 완료"])
    #expect(draft.colors.isEmpty && draft.hasChanges)
    #expect(draft.applyingColorChanges(to: [.one: .green, .w: .purple]) == [.w: .purple])
    draft = PhotoMarkLabelDraft(labels: draft.labels, colors: [.one: .green, .w: .purple])
    #expect(!draft.hasChanges)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoMarkColorTests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func execute(_ url: URL, sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else {
      throw PhotoMarkPersistenceError(message: "Unable to create color test database")
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw PhotoMarkPersistenceError(message: String(cString: sqlite3_errmsg(database)))
    }
  }
}
