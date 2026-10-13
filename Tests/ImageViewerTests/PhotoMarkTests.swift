import Foundation
import SQLite3
import Testing

@testable import ImageViewer

@Suite("키보드 사진 분류 저장")
@MainActor
struct PhotoMarkTests {
  @Test("12개의 물리 키는 입력 언어와 관계없이 같은 분류에 대응한다")
  func physicalKeyPositions() {
    let codes: [UInt16] = [18, 19, 20, 21, 12, 13, 14, 15, 0, 1, 2, 3]
    #expect(codes.compactMap(PhotoMarkSlot.init(keyCode:)) == PhotoMarkSlot.allCases)
    #expect(PhotoMarkSlot.allCases.map(\.keyLabel) == ["1", "2", "3", "4", "Q", "W", "E", "R", "A", "S", "D", "F"])
    #expect(PhotoMarkSlot(keyCode: 123) == nil)
    #expect(PhotoMarkSlot(keyCode: 53) == nil)
    let all = Set(PhotoMarkSlot.allCases)
    #expect(PhotoMarkSlot.mask(for: all) == 4095)
    #expect(PhotoMarkSlot.slots(in: PhotoMarkSlot.mask(for: all)) == all)
  }

  @Test("복수 분류·해제·이름 변경이 재실행 이후에도 보존된다")
  func reopensMarksAndLabels() async throws {
    let fixture = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let database = fixture.appendingPathComponent("marks.sqlite")
    let photo = asset(fixture.appendingPathComponent("photo.jpg"))
    let store = PhotoMarkStore(databaseURL: database)
    await store.waitUntilReady()
    #expect(store.isReady)
    store.toggle(.one, for: photo)
    store.toggle(.w, for: photo)
    store.toggle(.q, for: photo)
    store.toggle(.q, for: photo)
    store.setLabels([.one: " 최종 선택 ", .w: "업로드", .f: ""])
    store.flush()
    #expect(store.errorMessage == nil)

    let reopened = PhotoMarkStore(databaseURL: database)
    await reopened.waitUntilReady()
    #expect(reopened.isReady)
    #expect(reopened.marks(for: photo) == [.one, .w])
    #expect(reopened.label(for: .one) == "최종 선택")
    #expect(reopened.label(for: .w) == "업로드")
    #expect(reopened.label(for: .f).isEmpty)
    #expect(reopened.label(for: .two) == PhotoMarkSlot.two.defaultLabel)
  }

  @Test("빠르게 반복한 표시와 해제는 입력 순서대로 저장된다")
  func rapidMutationsRemainOrdered() async throws {
    let fixture = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let database = fixture.appendingPathComponent("marks.sqlite")
    let photo = asset(fixture.appendingPathComponent("photo.jpg"))
    let store = PhotoMarkStore(databaseURL: database)
    await store.waitUntilReady()
    for _ in 0..<41 {
      store.toggle(.one, for: photo)
      store.toggle(.f, for: photo)
    }
    store.toggle(.f, for: photo)
    store.flush()
    let reopened = PhotoMarkStore(databaseURL: database)
    await reopened.waitUntilReady()
    #expect(reopened.marks(for: photo) == [.one])
    reopened.toggle(.one, for: photo)
    reopened.flush()
    let empty = PhotoMarkStore(databaseURL: database)
    await empty.waitUntilReady()
    #expect(empty.marksByAssetID.isEmpty)
  }

  @Test("순환 파일명 변경은 각 사진의 표시를 서로 덮어쓰지 않는다")
  func renameCyclesPreservePhotoIdentity() async throws {
    let fixture = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let database = fixture.appendingPathComponent("marks.sqlite")
    let a = asset(fixture.appendingPathComponent("a.jpg"))
    let b = asset(fixture.appendingPathComponent("b.jpg"))
    let c = asset(fixture.appendingPathComponent("c.jpg"))
    let store = PhotoMarkStore(databaseURL: database)
    await store.waitUntilReady()
    store.toggle(.one, for: a)
    store.toggle(.w, for: a)
    store.toggle(.two, for: b)
    // c intentionally has no marks: a cycle must also move that empty state.
    store.remapAssets([a.sessionID: b.sessionID, b.sessionID: c.sessionID, c.sessionID: a.sessionID])
    #expect(store.marks(for: a).isEmpty)
    #expect(store.marks(for: b) == [.one, .w])
    #expect(store.marks(for: c) == [.two])
    store.flush()
    let reopened = PhotoMarkStore(databaseURL: database)
    await reopened.waitUntilReady()
    #expect(reopened.marksByAssetID == store.marksByAssetID)
  }

  @Test("압축 파일 사진의 표시는 임시 추출 경로가 바뀌어도 유지된다")
  func archiveIdentitySurvivesExtraction() async {
    let archive = URL(fileURLWithPath: "/test/travel.zip")
    let first = ImageAsset(url: URL(fileURLWithPath: "/tmp/first/photo.jpg"), byteCount: nil,
      modificationDate: nil, archiveOrigin: ArchiveImageOrigin(archiveURL: archive, entryPath: "trip/photo.jpg"))
    let next = ImageAsset(url: URL(fileURLWithPath: "/tmp/next/photo.jpg"), byteCount: nil,
      modificationDate: nil, archiveOrigin: ArchiveImageOrigin(archiveURL: archive, entryPath: "trip/photo.jpg"))
    let store = PhotoMarkStore(inMemory: true)
    await store.waitUntilReady()
    store.toggle(.f, for: first)
    #expect(store.marks(for: next) == [.f])
    store.flush()
  }

  @Test("지우기라는 분류도 사진 원본을 변경하거나 삭제하지 않는다")
  func labelsNeverChangeOriginalFiles() async throws {
    let fixture = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let photoURL = fixture.appendingPathComponent("original.jpg")
    let original = Data("original photo bytes".utf8)
    try original.write(to: photoURL)
    let store = PhotoMarkStore(inMemory: true)
    await store.waitUntilReady()
    store.setLabels([.q: "지우기"])
    store.toggle(.q, for: asset(photoURL))
    store.flush()
    #expect(try Data(contentsOf: photoURL) == original)
    #expect(store.marks(for: asset(photoURL)) == [.q])
  }

  @Test("선택 분류 중 하나·모두·미분류 조건을 구분한다")
  func filtersMatchIndependentMarks() {
    #expect(PhotoMarkFilter().matches([]))
    #expect(PhotoMarkFilter().matches([.one, .w]))
    #expect(!PhotoMarkFilter().isActive)
    let any = PhotoMarkFilter(slots: [.one, .w])
    #expect(any.isActive && any.matches([.w]) && any.matches([.one, .q]))
    #expect(!any.matches([]) && !any.matches([.q]))
    let all = PhotoMarkFilter(slots: [.one, .w], matchesAll: true)
    #expect(all.matches([.one, .w, .f]))
    #expect(!all.matches([.one]))
    let unmarked = PhotoMarkFilter(slots: [.one], unmarkedOnly: true)
    #expect(unmarked.matches([]) && !unmarked.matches([.one]))
  }

  @Test("손상된 저장소는 덮어쓰지 않고 분류 입력을 차단한다")
  func corruptDatabaseIsPreserved() async throws {
    let fixture = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let database = fixture.appendingPathComponent("marks.sqlite")
    let original = Data("not a SQLite database".utf8)
    try original.write(to: database)
    let store = PhotoMarkStore(databaseURL: database)
    // Loading is asynchronous; early input must not overwrite persisted state.
    store.toggle(.one, for: asset(fixture.appendingPathComponent("photo.jpg")))
    await store.waitUntilReady()
    #expect(!store.isReady && store.errorMessage != nil)
    store.setLabels([.one: "unsaved"])
    store.flush()
    #expect(store.labels.isEmpty && store.marksByAssetID.isEmpty)
    #expect(try Data(contentsOf: database) == original)
  }

  @Test("쓰기 실패는 표시되며 추가 입력과 저장 성공 상태를 차단한다")
  func writeFailureStopsFurtherMutations() async throws {
    let fixture = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let database = fixture.appendingPathComponent("marks.sqlite")
    let photo = asset(fixture.appendingPathComponent("photo.jpg"))
    let store = PhotoMarkStore(databaseURL: database)
    await store.waitUntilReady()
    var connection: OpaquePointer?
    #expect(sqlite3_open(database.path, &connection) == SQLITE_OK)
    defer { sqlite3_close(connection) }
    #expect(sqlite3_exec(connection,
      "CREATE TRIGGER reject_marks BEFORE INSERT ON asset_marks BEGIN SELECT RAISE(FAIL, 'test storage failure'); END;",
      nil, nil, nil) == SQLITE_OK)
    store.toggle(.one, for: photo)
    store.flush()
    #expect(!store.isReady)
    #expect(store.errorMessage?.contains("test storage failure") == true)
    #expect(store.marks(for: photo) == [.one])
    store.toggle(.two, for: photo)
    #expect(store.marks(for: photo) == [.one])
    let reopened = PhotoMarkStore(databaseURL: database)
    await reopened.waitUntilReady()
    #expect(reopened.marks(for: photo).isEmpty)
  }

  @Test("두 편집창이 서로 다른 키를 바꾸면 두 변경을 함께 보존한다")
  func independentLabelEditorsMergeOnlyChangedSlots() {
    let initial: [PhotoMarkSlot: String] = [.one: "최상", .w: "업로드", .q: "지우기"]
    var settings = PhotoMarkLabelDraft(labels: initial)
    var sheet = PhotoMarkLabelDraft(labels: initial)
    settings.labels[.one] = "보정할 사진"
    sheet.labels[.w] = "전달 완료"
    let savedBySheet = sheet.applyingChanges(to: initial)
    // Saving also merges safely if the shared-store change notification is pending.
    let expected: [PhotoMarkSlot: String] = [.one: "보정할 사진", .w: "전달 완료", .q: "지우기"]
    #expect(settings.applyingChanges(to: savedBySheet) == expected)
    settings.refresh(with: savedBySheet)
    #expect(settings.labels == expected && settings.hasChanges)
    #expect(settings.applyingChanges(to: savedBySheet) == expected)
  }

  @Test("직접 입력 중인 이름은 유지하고 취소는 최신 저장된 이름으로 돌아간다")
  func labelDraftPreservesTypedNameAndRevertsToLatest() {
    var draft = PhotoMarkLabelDraft(labels: [.one: "최상", .w: "업로드"])
    draft.labels[.one] = "인화 후보"
    let latest: [PhotoMarkSlot: String] = [.one: "보정 완료", .w: "전달 완료"]
    draft.refresh(with: latest)
    #expect(draft.labels == [.one: "인화 후보", .w: "전달 완료"])
    #expect(draft.hasChanges)
    draft = PhotoMarkLabelDraft(labels: latest)
    #expect(draft.labels == latest && !draft.hasChanges)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoMarkTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func asset(_ url: URL) -> ImageAsset {
    ImageAsset(url: url, byteCount: nil, modificationDate: nil)
  }
}
