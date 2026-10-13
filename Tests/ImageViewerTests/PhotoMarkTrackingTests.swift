import AppKit
import SQLite3
import Testing

@testable import ImageViewer

@Suite("사진 분류 외부 이동 추적")
@MainActor
struct PhotoMarkTrackingTests {
  @Test("앱 종료 뒤 파일명과 폴더를 바꿔도 복수 분류와 공통 이름을 복원한다")
  func externalRenameAndMoveSurviveRelaunch() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let original = try await fixture.asset(fixture.photo)
    var store: PhotoMarkStore? = try await fixture.store()
    store?.setLabels([.one: "최상", .w: "업로드 후보"])
    store?.toggle(.one, for: original)
    store?.toggle(.w, for: original)
    store?.flush()
    store = nil

    let destination = fixture.destination.appendingPathComponent("renamed.png")
    try FileManager.default.moveItem(at: fixture.photo, to: destination)
    let moved = try await fixture.asset(destination)
    #expect(original.sessionID != moved.sessionID)
    let reopened = try await fixture.store()
    #expect(reopened.marks(for: moved) == [.one, .w])
    #expect(reopened.label(for: .w) == "업로드 후보")
    reopened.reconcileAssets([moved])
    reopened.flush()
    #expect(reopened.errorMessage == nil)
    #expect(try Data(contentsOf: destination) == fixture.png)
  }

  @Test("사진이 든 상위 폴더의 이름 변경도 북마크로 복원한다")
  func enclosingFolderRenameSurvivesRelaunch() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try await fixture.store()
    store.toggle(.f, for: try await fixture.asset(fixture.photo))
    store.flush()
    let renamedFolder = fixture.root.appendingPathComponent("Renamed album")
    try FileManager.default.moveItem(at: fixture.photos, to: renamedFolder)
    let moved = try await fixture.asset(renamedFolder.appendingPathComponent("photo.png"))
    let reopened = try await fixture.store()
    #expect(reopened.marks(for: moved) == [.f])
  }

  @Test("실행 중 이동한 파일은 새 폴더를 열면 분류가 연결되고 다음 실행에도 남는다")
  func reopeningDestinationRefreshesTracking() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try await fixture.store()
    store.toggle(.one, for: try await fixture.asset(fixture.photo))
    store.flush()
    let movedURL = fixture.destination.appendingPathComponent("moved.png")
    try FileManager.default.moveItem(at: fixture.photo, to: movedURL)
    let moved = try await fixture.asset(movedURL)
    store.reconcileAssets([moved])
    #expect(store.marks(for: moved) == [.one])
    store.toggle(.w, for: moved)
    store.flush()
    let reopened = try await fixture.store()
    #expect(reopened.marks(for: moved) == [.one, .w])
  }

  @Test("원본과 바이트가 같은 복사본에는 원본의 분류를 자동 상속하지 않는다")
  func copiedFileHasIndependentMarks() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let original = try await fixture.asset(fixture.photo)
    let store = try await fixture.store()
    store.toggle(.one, for: original)
    store.flush()
    let copyURL = fixture.destination.appendingPathComponent("photo.png")
    try FileManager.default.copyItem(at: fixture.photo, to: copyURL)
    let copy = try await fixture.asset(copyURL)
    #expect(copy.photoMarkID != original.photoMarkID)
    let reopened = try await fixture.store()
    reopened.reconcileAssets([original, copy])
    #expect(reopened.marks(for: original) == [.one])
    #expect(reopened.marks(for: copy).isEmpty)
  }

  @Test("삭제 후 같은 이름으로 생긴 파일에 기존 분류를 붙이지 않고 옛 기록은 보존한다")
  func replacementAtDeletedPathIsNotTheOriginal() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let original = try await fixture.asset(fixture.photo)
    let store = try await fixture.store()
    store.toggle(.q, for: original)
    store.flush()
    try FileManager.default.removeItem(at: fixture.photo)
    let missing = try await fixture.store()
    #expect(missing.marksByAssetID[original.photoMarkID] == [.q])
    #expect(missing.marks(for: original).isEmpty)

    try fixture.png.write(to: fixture.photo)
    let replacement = try await fixture.asset(fixture.photo)
    #expect(replacement.photoMarkID != original.photoMarkID)
    let reopened = try await fixture.store()
    reopened.reconcileAssets([replacement])
    #expect(reopened.marks(for: replacement).isEmpty)
    #expect(reopened.marksByAssetID[original.photoMarkID] == [.q])
  }

  @Test("이동한 원본의 옛 경로를 다른 파일이 차지해도 원본만 분류된다")
  func reusedOldPathDoesNotStealMarks() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try await fixture.store()
    store.toggle(.w, for: try await fixture.asset(fixture.photo))
    store.flush()
    let movedURL = fixture.destination.appendingPathComponent("original.png")
    try FileManager.default.moveItem(at: fixture.photo, to: movedURL)
    try fixture.png.write(to: fixture.photo)
    let replacement = try await fixture.asset(fixture.photo)
    let moved = try await fixture.asset(movedURL)
    let reopened = try await fixture.store()
    await reopened.reconcileAssets([replacement, moved])?.wait()
    #expect(reopened.marks(for: replacement).isEmpty)
    #expect(reopened.marks(for: moved) == [.w])
  }

  @Test("기존 경로 저장소는 사진을 다시 연 뒤 이동 추적으로 전환된다")
  func legacyPathMarksUpgradeOnOpen() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let original = try await fixture.asset(fixture.photo)
    let escapedPath = original.sessionID.replacingOccurrences(of: "'", with: "''")
    try fixture.execute("""
      CREATE TABLE mark_labels (slot TEXT PRIMARY KEY NOT NULL, label TEXT NOT NULL);
      CREATE TABLE asset_marks (asset_id TEXT PRIMARY KEY NOT NULL, marks INTEGER NOT NULL);
      INSERT INTO mark_labels VALUES ('w', '업로드 후보');
      INSERT INTO asset_marks VALUES ('\(escapedPath)', 33);
      PRAGMA user_version = 1;
      """)
    let store = try await fixture.store()
    store.reconcileAssets([original])
    #expect(store.marks(for: original) == [.one, .w])
    #expect(store.marksByAssetID[original.sessionID] == nil)
    store.flush()
    let movedURL = fixture.destination.appendingPathComponent("upgraded.png")
    try FileManager.default.moveItem(at: fixture.photo, to: movedURL)
    let moved = try await fixture.asset(movedURL)
    let reopened = try await fixture.store()
    #expect(reopened.marks(for: moved) == [.one, .w])
    #expect(reopened.label(for: .w) == "업로드 후보")
  }

  @Test("저장된 조회 키가 달라져도 북마크를 검증한 현재 키로 다시 연결한다")
  func bookmarkRebuildsLookupIdentity() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let original = try await fixture.asset(fixture.photo)
    let store = try await fixture.store()
    store.toggle(.three, for: original)
    store.flush()
    try fixture.execute("""
      UPDATE asset_marks SET asset_id = 'file:v2:old-launch-identity';
      UPDATE asset_tracking SET asset_id = 'file:v2:old-launch-identity';
      """)
    let reopened = try await fixture.store()
    #expect(reopened.marks(for: original) == [.three])
    #expect(reopened.marksByAssetID["file:v2:old-launch-identity"] == nil)
  }

  @Test("ZIP 이름 변경 뒤에도 내부 경로마다 서로 다른 분류를 복원한다")
  func archiveContainerAndMemberIdentities() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let archive = fixture.root.appendingPathComponent("album.zip")
    // Tracking operates on the container, independently of decoding/extraction.
    try Data("archive container fixture".utf8).write(to: archive)
    let first = try fixture.archiveMember(archive, entry: "first/photo.png")
    let second = try fixture.archiveMember(archive, entry: "second/photo.png")
    let store = try await fixture.store()
    store.toggle(.one, for: first)
    store.toggle(.w, for: second)
    store.flush()
    let movedArchive = fixture.destination.appendingPathComponent("renamed.zip")
    try FileManager.default.moveItem(at: archive, to: movedArchive)
    let reopened = try await fixture.store()
    #expect(reopened.marks(for: try fixture.archiveMember(movedArchive, entry: "first/photo.png")) == [.one])
    #expect(reopened.marks(for: try fixture.archiveMember(movedArchive, entry: "second/photo.png")) == [.w])
    #expect(reopened.marks(for: try fixture.archiveMember(movedArchive, entry: "third/photo.png")).isEmpty)
  }

  @Test("앱의 마지막 보기 복원 후 저장된 분류를 필터에 바로 적용한다")
  func restoredAppSessionCanFilterPersistedMarks() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let suite = "PhotoMarkTracking.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try fixture.png.write(to: fixture.photos.appendingPathComponent("other.png"))
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: fixture.database)
    store.open(urls: [fixture.photos])
    try await ready(store)
    let original = try #require(store.assets.first { $0.filename == "photo.png" })
    store.photoMarks.toggle(.one, for: original)
    store.photoMarks.toggle(.w, for: original)
    store.saveSessionNow()
    let restored = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: fixture.database)
    defer { store.folderComparison.cancelLoads(); restored.folderComparison.cancelLoads() }
    await restored.restoreLastSession()
    try #require(restored.assets.count == 2)
    let restoredPhoto = try #require(restored.assets.first { $0.filename == "photo.png" })
    #expect(restored.photoMarks.marks(for: restoredPhoto) == [.one, .w])
    restored.photoMarkFilter = PhotoMarkFilter(slots: [.one, .w], matchesAll: true)
    try await ready(restored)
    #expect(restored.assets.map(\.filename) == ["photo.png"])
    #expect(restored.photoMarks.errorMessage == nil)
    restored.saveSessionNow()
  }

  @Test("앱에서 같은 경로의 메타데이터를 저장해 파일이 교체되어도 분류를 유지한다")
  func metadataReplacementRefreshesPersistentReference() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let suite = "PhotoMarkMetadataTracking.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: fixture.database)
    defer { store.folderComparison.cancelLoads() }
    store.open(urls: [fixture.photos])
    try await ready(store)
    let original = try #require(store.currentAsset)
    store.photoMarks.toggle(.one, for: original)
    store.photoMarks.flush()
    let metadata = try await ImagePipeline().metadata(for: original.url)
    let before = ImageMetadataEditDraft(asset: original, metadata: metadata)
    var after = before
    after.imageDescription = "Marked photo metadata edit"
    try await store.saveMetadataEdits(after, replacing: before)
    let edited = try #require(store.currentAsset)
    #expect(edited.url.standardizedFileURL == original.url.standardizedFileURL)
    #expect(store.photoMarks.marks(for: edited) == [.one])
    store.saveSessionNow()
    let movedURL = fixture.destination.appendingPathComponent("edited.png")
    try FileManager.default.moveItem(at: edited.url, to: movedURL)
    let reopened = try await fixture.store()
    #expect(reopened.marks(for: try await fixture.asset(movedURL)) == [.one])
  }

  @Test("하드 링크의 한쪽 이름을 바꾸면 같은 실제 파일의 분류는 양쪽에서 유지된다")
  func hardLinksSharePhysicalFileMarksAfterRename() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try FileManager.default.linkItem(at: fixture.photo,
      to: fixture.photos.appendingPathComponent("linked.png"))
    let suite = "PhotoMarkHardLinkTracking.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: fixture.database)
    defer { store.folderComparison.cancelLoads() }
    store.open(urls: [fixture.photos])
    try await ready(store)
    try #require(store.assets.count == 2)
    #expect(store.assets[0].photoMarkID == store.assets[1].photoMarkID)
    store.photoMarks.toggle(.w, for: store.assets[0])
    var options = BatchRenameOptions()
    options.prefix = "renamed_"
    let plan = BatchRenamePlanner.plan(urls: [store.assets[0].url], options: options)
    try #require(plan.canApply)
    try await store.renameSelectedFiles(using: plan)
    #expect(store.assets.count == 2)
    #expect(store.assets.filter { $0.filename.hasPrefix("renamed_") }.count == 1)
    #expect(store.assets.allSatisfy { store.photoMarks.marks(for: $0) == [.w] })
    store.saveSessionNow()
    let reopened = try await fixture.store()
    #expect(store.assets.allSatisfy { reopened.marks(for: $0) == [.w] })
  }

  private func ready(_ store: AppStore) async throws {
    for _ in 0..<500 {
      if !store.isLoading && !store.isFiltering { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.timedOut
  }

  private enum FixtureError: Error { case timedOut, sqlite(String) }

  private struct Fixture {
    let root: URL
    let photos: URL
    let destination: URL
    let photo: URL
    let database: URL
    let png: Data

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoTracking-\(UUID())")
      photos = root.appendingPathComponent("Photos")
      destination = root.appendingPathComponent("Destination")
      photo = photos.appendingPathComponent("photo.png")
      database = root.appendingPathComponent("marks.sqlite")
      let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
      png = try #require(bitmap.representation(using: .png, properties: [:]))
      for folder in [photos, destination] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      }
      try png.write(to: photo)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func asset(_ url: URL) async throws -> ImageAsset {
      let assets = try await ImageLibrary().assets(from: [url])
      let asset = try #require(assets.first)
      try #require(asset.photoMarkIdentity != nil)
      return asset
    }

    @MainActor func store() async throws -> PhotoMarkStore {
      let store = PhotoMarkStore(databaseURL: database)
      await store.waitUntilReady()
      try #require(store.isReady && store.errorMessage == nil)
      return store
    }

    func archiveMember(_ archive: URL, entry: String) throws -> ImageAsset {
      let identity = try #require(PhotoMarkFileIdentity.read(archive, entryPath: entry))
      return ImageAsset(url: root.appendingPathComponent("extracted-\(UUID()).png"),
        byteCount: nil, modificationDate: nil,
        archiveOrigin: ArchiveImageOrigin(archiveURL: archive, entryPath: entry),
        photoMarkIdentity: identity.key)
    }

    func execute(_ sql: String) throws {
      var connection: OpaquePointer?
      guard sqlite3_open(database.path, &connection) == SQLITE_OK, let connection else {
        throw FixtureError.sqlite("open failed")
      }
      defer { sqlite3_close(connection) }
      guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
        throw FixtureError.sqlite(String(cString: sqlite3_errmsg(connection)))
      }
    }
  }
}
