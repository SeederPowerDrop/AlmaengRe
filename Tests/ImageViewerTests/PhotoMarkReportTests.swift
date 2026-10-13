import Darwin
import Foundation
import SQLite3
import Testing

@testable import ImageViewer

@Suite("분류 파일 변경 리포트")
@MainActor
struct PhotoMarkReportTests {
  @Test("같은 목록의 반복 필터는 누락 파일을 재검사하지 않고 실제 다시 열기에서 복구한다")
  func cachedQueriesSkipUnavailableTrackingUntilRediscovery() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let initial = try await fixture.store()
    let original = try fixture.asset(fixture.photo)
    initial.toggle(.f, for: original)
    initial.flush()
    try fixture.invalidateBookmark()
    let store = try await fixture.store()
    #expect(store.unavailableCount == 1)
    let revision = store.revision
    for _ in 0..<20 {
      #expect(store.reconcileAssets([original], retryUnavailable: false) == nil)
    }
    #expect(store.revision == revision)
    #expect(store.marksByAssetID[original.photoMarkID] == [.f])
    #expect(store.marks(for: original).isEmpty)

    let reconciliation = try #require(store.reconcileAssets([original]))
    await reconciliation.wait()
    #expect(store.unavailableCount == 0)
    #expect(store.marks(for: original) == [.f])
    #expect(store.reconcileAssets([original], retryUnavailable: false) == nil)
    await store.refreshTracking()
    #expect(store.trackingReports.map(\.event) == [.recovered, .unavailable])
  }

  @Test("이미 취소된 리포트 확인은 전체 추적을 다시 읽거나 화면 리비전을 발행하지 않는다")
  func cancelledRefreshDoesNotReloadTracking() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try await fixture.store()
    let revision = store.revision
    let refresh = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await store.refreshTracking()
    }
    await refresh.value
    #expect(store.revision == revision)
    #expect(!store.isRefreshingTracking && store.errorMessage == nil)
  }

  @Test("외부 이름 변경은 즉시 확인할 수 있고 당시 분류와 함께 재실행 후에도 보관된다")
  func relocationReportPersistsAndDoesNotRepeat() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try await fixture.store()
    let original = try fixture.asset(fixture.photo)
    store.setLabels([.w: "업로드"])
    store.toggle(.w, for: original)
    store.flush()
    let movedURL = fixture.root.appendingPathComponent("renamed.jpg")
    try FileManager.default.moveItem(at: fixture.photo, to: movedURL)
    await store.refreshTracking()
    #expect(store.marks(for: try fixture.asset(movedURL)) == [.w])
    let report = try #require(store.trackingReports.first)
    #expect(report.event == .relocated)
    #expect(report.previousURL?.standardizedFileURL == fixture.photo.standardizedFileURL)
    #expect(report.currentURL?.standardizedFileURL == movedURL.standardizedFileURL)
    #expect(report.labels == [.w: "업로드"])
    #expect(report.slots == [.w])
    #expect(store.unavailableCount == 0)
    store.setLabels([.w: "전달 완료"])
    store.flush()
    await store.refreshTracking()
    #expect(store.trackingReports == [report])
    let reopened = try await fixture.store()
    #expect(reopened.trackingReports == [report])
    #expect(reopened.label(for: .w) == "전달 완료")
  }

  @Test("사라진 파일의 분류를 보관하고 반복 확인과 동명 새 파일로 리포트를 중복하거나 잘못 연결하지 않는다")
  func unavailableReportSurvivesReplacementAndRelaunch() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try await fixture.store()
    let original = try fixture.asset(fixture.photo)
    store.toggle(.one, for: original)
    store.flush()
    try FileManager.default.removeItem(at: fixture.photo)
    await store.refreshTracking()
    #expect(store.unavailableCount == 1)
    #expect(store.marksByAssetID[original.photoMarkID] == [.one])
    #expect(store.marks(for: original).isEmpty)
    let report = try #require(store.trackingReports.first)
    #expect(report.event == .unavailable)
    #expect(report.currentURL == nil)
    try Data("replacement".utf8).write(to: fixture.photo)
    let replacement = try fixture.asset(fixture.photo)
    #expect(replacement.photoMarkID != original.photoMarkID)
    store.reconcileAssets([replacement])
    await store.refreshTracking()
    #expect(store.marks(for: replacement).isEmpty)
    #expect(store.trackingReports == [report])
    let reopened = try await fixture.store()
    #expect(reopened.trackingReports == [report])
    #expect(reopened.unavailableCount == 1)
  }

  @Test("북마크가 일시적으로 접근 불가능해도 정확한 파일을 다시 열면 복구 이력을 보관한다")
  func rediscoveredIdentityRecoversWithoutDuplicateHistory() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let initial = try await fixture.store()
    let original = try fixture.asset(fixture.photo)
    initial.toggle(.f, for: original)
    initial.flush()
    // Model an inaccessible bookmark while leaving the file identity intact.
    // A directory scan can later rediscover that exact identity safely.
    try fixture.invalidateBookmark()
    let store = try await fixture.store()
    #expect(store.unavailableCount == 1)
    #expect(store.trackingReports.map(\.event) == [.unavailable])
    store.reconcileAssets([original])
    store.flush()
    await store.refreshTracking()
    #expect(store.marks(for: original) == [.f])
    #expect(store.unavailableCount == 0)
    #expect(store.trackingReports.map(\.event) == [.recovered, .unavailable])
    let reopened = try await fixture.store()
    #expect(reopened.trackingReports == store.trackingReports)
    #expect(reopened.unavailableCount == 0)
  }

  @Test("실행 중 새 폴더를 열어 갱신한 위치도 리포트에 남는다")
  func discoveredRelocationIsRecorded() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try await fixture.store()
    store.toggle(.two, for: try fixture.asset(fixture.photo))
    store.flush()
    let movedURL = fixture.root.appendingPathComponent("moved.jpg")
    try FileManager.default.moveItem(at: fixture.photo, to: movedURL)
    store.reconcileAssets([try fixture.asset(movedURL)])
    store.flush()
    await store.refreshTracking()
    #expect(store.trackingReports.map(\.event) == [.relocated])
  }

  @Test("필터의 캐시된 사진 목록이 누락 상태를 취소하거나 보관한 분류를 덮어쓰지 않는다")
  func staleAssetsCannotRecoverMissingFiles() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try await fixture.store()
    let original = try fixture.asset(fixture.photo)
    store.toggle(.one, for: original)
    store.flush()
    try FileManager.default.removeItem(at: fixture.photo)
    await store.refreshTracking()
    let revision = store.revision
    // The app reapplies active filters using its cached ImageAsset values when
    // a tracking refresh publishes a revision. Those values are not a new scan.
    store.reconcileAssets([original])
    store.toggle(.w, for: original)
    store.flush()
    await Task.yield()
    #expect(store.unavailableCount == 1)
    #expect(store.marks(for: original).isEmpty)
    #expect(store.marksByAssetID[original.photoMarkID] == [.one])
    #expect(store.revision == revision)
    await store.refreshTracking()
    #expect(store.trackingReports.map(\.event) == [.unavailable])
  }

  @Test("생성 시각까지 같은 동명 대체 파일도 파일 번호가 다르면 분류를 넘기지 않는다")
  func preservedBirthTimeDoesNotTransferIdentity() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.setBirthTime(fixture.photo)
    let original = try fixture.asset(fixture.photo)
    let captured = try #require(PhotoMarkFileReference.capture(for: original))
    // A path fallback still needs to reject replacements when bookmark creation
    // was unavailable. Some backup tools preserve the exact original birth time.
    let reference = PhotoMarkFileReference(sourceURL: captured.sourceURL,
      entryPath: nil, bookmark: nil, fileNumber: captured.fileNumber,
      birthSeconds: captured.birthSeconds, birthNanoseconds: captured.birthNanoseconds,
      volumeUUID: captured.volumeUUID)
    let movedURL = fixture.root.appendingPathComponent("original-moved.jpg")
    try FileManager.default.moveItem(at: fixture.photo, to: movedURL)
    try Data("replacement".utf8).write(to: fixture.photo)
    try fixture.setBirthTime(fixture.photo)
    let replacement = try #require(PhotoMarkFileIdentity.read(fixture.photo))
    #expect(replacement.birthSeconds == reference.birthSeconds)
    #expect(replacement.birthNanoseconds == reference.birthNanoseconds)
    #expect(replacement.fileNumber != reference.fileNumber)
    #expect(reference.resolve() == nil)
    // Old JSON without fileNumber remains readable and is upgraded on resolution.
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(captured)) as? [String: Any])
    json.removeValue(forKey: "fileNumber")
    let legacy = try JSONDecoder().decode(PhotoMarkFileReference.self,
      from: JSONSerialization.data(withJSONObject: json))
    #expect(legacy.fileNumber == nil)
  }

  @Test("리포트 문구와 형식 인수는 지원 언어 모두에 존재한다")
  func reportLocalizationCoverage() {
    let keys = PhotoMarkReportL10n.keys(localeIdentifier: "ko")
    #expect(keys.contains("event.unavailable"))
    for locale in L10n.supportedLocalizations {
      #expect(PhotoMarkReportL10n.keys(localeIdentifier: locale) == keys)
      for key in keys {
        let value = PhotoMarkReportL10n.text(key, localeIdentifier: locale)
        #expect(!value.isEmpty && value != key)
      }
      for key in ["unavailableFormat", "historyFormat"] {
        #expect(PhotoMarkReportL10n.text(key, localeIdentifier: locale).components(separatedBy: "%d").count == 2)
      }
      for key in ["previousFormat", "currentFormat", "archiveEntryFormat"] {
        #expect(PhotoMarkReportL10n.text(key, localeIdentifier: locale).components(separatedBy: "%@").count == 2)
      }
    }
  }

  private struct Fixture {
    let root: URL
    let photo: URL
    let database: URL

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoMarkReports-\(UUID())")
      photo = root.appendingPathComponent("photo.jpg")
      database = root.appendingPathComponent("marks.sqlite")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try Data("original".utf8).write(to: photo)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func asset(_ url: URL) throws -> ImageAsset {
      let identity = try #require(PhotoMarkFileIdentity.read(url))
      return ImageAsset(url: url, byteCount: nil, modificationDate: nil, photoMarkIdentity: identity.key)
    }

    @MainActor func store() async throws -> PhotoMarkStore {
      let store = PhotoMarkStore(databaseURL: database)
      await store.waitUntilReady()
      try #require(store.isReady && store.errorMessage == nil)
      return store
    }

    func setBirthTime(_ url: URL) throws {
      var attributes = attrlist()
      attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
      attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
      var value = timespec(tv_sec: 1_700_000_000, tv_nsec: 0)
      let result = url.withUnsafeFileSystemRepresentation { path in
        setattrlist(path, &attributes, &value, MemoryLayout<timespec>.size, 0)
      }
      try #require(result == 0)
    }

    func invalidateBookmark() throws {
      var connection: OpaquePointer?
      try #require(sqlite3_open(database.path, &connection) == SQLITE_OK)
      defer { sqlite3_close(connection) }
      var statement: OpaquePointer?
      try #require(sqlite3_prepare_v2(connection, "SELECT reference FROM asset_tracking", -1, &statement, nil) == SQLITE_OK)
      defer { sqlite3_finalize(statement) }
      try #require(sqlite3_step(statement) == SQLITE_ROW)
      let bytes = try #require(sqlite3_column_blob(statement, 0))
      let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
      var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      json["bookmark"] = Data("unavailable bookmark".utf8).base64EncodedString()
      let replacement = try JSONSerialization.data(withJSONObject: json)
      var update: OpaquePointer?
      try #require(sqlite3_prepare_v2(connection, "UPDATE asset_tracking SET reference = ?", -1, &update, nil) == SQLITE_OK)
      defer { sqlite3_finalize(update) }
      let result = replacement.withUnsafeBytes {
        sqlite3_bind_blob(update, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      }
      try #require(result == SQLITE_OK)
      try #require(sqlite3_step(update) == SQLITE_DONE)
    }
  }
}
