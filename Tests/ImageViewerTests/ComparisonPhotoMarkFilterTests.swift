import AppKit
import SQLite3
import Testing

@testable import ImageViewer

@Suite("비교 A·B의 독립 분류 조건")
@MainActor
struct ComparisonPhotoMarkFilterTests {
  @Test("각 칸의 OR·AND·미분류 조건은 공통 검색과 교집합이며 원본을 보존한다")
  func independentFiltersAndSharedQuery() async throws {
    let fixture = try Fixture()
    let marks = PhotoMarkStore(inMemory: true)
    let comparison = fixture.comparison(marks)
    defer { comparison.cancelLoads(); marks.flush(); fixture.remove() }
    let assets = try await fixture.assets()
    await marks.waitUntilReady()
    markFixture(assets, marks: marks)
    try await open(comparison, fixture: fixture)

    comparison.first.photoMarkFilter = PhotoMarkFilter(slots: [.one, .f])
    comparison.second.photoMarkFilter = PhotoMarkFilter(slots: [.one, .f], matchesAll: true)
    await ready(comparison)
    #expect(names(comparison.first) == ["a.png", "b.png", "c.png"])
    #expect(names(comparison.second) == ["c.png"])
    comparison.query = LibraryQuery(searchText: "b", sort: .nameDescending, formats: [.png])
    await ready(comparison)
    #expect(names(comparison.first) == ["b.png"])
    #expect(comparison.second.assets.isEmpty)
    comparison.query = LibraryQuery(sort: .nameDescending)
    comparison.second.photoMarkFilter = PhotoMarkFilter(unmarkedOnly: true)
    await ready(comparison)
    #expect(names(comparison.first) == ["c.png", "b.png", "a.png"])
    #expect(names(comparison.second) == ["d.png"])
    comparison.first.photoMarkFilter = PhotoMarkFilter()
    comparison.second.photoMarkFilter = PhotoMarkFilter()
    await ready(comparison)
    #expect(names(comparison.first) == ["d.png", "c.png", "b.png", "a.png"])
    #expect(comparison.first.assets == comparison.second.assets)
    #expect(comparison.first.sourceURLs == [fixture.photos])
    #expect(comparison.second.sourceURLs == [fixture.photos])
  }

  @Test("비교 양쪽의 포함·제외 조건을 독립적으로 검색과 결합한다")
  func independentExclusionsIntersectSharedQuery() async throws {
    let fixture = try Fixture()
    let marks = PhotoMarkStore(inMemory: true)
    let comparison = fixture.comparison(marks)
    defer { comparison.cancelLoads(); marks.flush(); fixture.remove() }
    let assets = try await fixture.assets()
    await marks.waitUntilReady()
    markFixture(assets, marks: marks)
    try await open(comparison, fixture: fixture)
    comparison.first.photoMarkFilter = PhotoMarkFilter(slots: [.one], excludedSlots: [.f])
    comparison.second.photoMarkFilter = PhotoMarkFilter(slots: [.f], excludedSlots: [.one])
    await ready(comparison)
    #expect(names(comparison.first) == ["a.png"])
    #expect(names(comparison.second) == ["b.png"])
    comparison.query.searchText = "b"
    await ready(comparison)
    #expect(comparison.first.assets.isEmpty)
    #expect(names(comparison.second) == ["b.png"])
    comparison.query.searchText = ""
    comparison.first.photoMarkFilter = PhotoMarkFilter(excludedSlots: [.f])
    await ready(comparison)
    #expect(names(comparison.first) == ["a.png", "d.png"])
    #expect(names(comparison.second) == ["b.png"])
  }

  @Test("분류 중 목록과 선택을 고정하고 종료하면 최신 분류를 한 번에 반영한다")
  func markingFreezesMembershipAcrossQueriesAndThenRefreshes() async throws {
    let fixture = try Fixture()
    let marks = PhotoMarkStore(inMemory: true)
    let comparison = fixture.comparison(marks)
    defer { comparison.cancelLoads(); marks.flush(); fixture.remove() }
    let assets = try await fixture.assets()
    await marks.waitUntilReady()
    markFixture(assets, marks: marks)
    try await open(comparison, fixture: fixture)
    comparison.first.photoMarkFilter = PhotoMarkFilter(slots: [.one])
    comparison.second.photoMarkFilter = PhotoMarkFilter(unmarkedOnly: true)
    await ready(comparison)
    let selected = try #require(comparison.first.currentAsset)
    comparison.isPhotoMarking = true
    marks.toggle(.one, for: selected)
    marks.toggle(.one, for: assets[3])
    await Task.yield()
    comparison.query.sort = .nameDescending
    await ready(comparison)
    #expect(names(comparison.first) == ["c.png", "a.png"])
    #expect(comparison.first.currentAsset?.id == selected.id)
    #expect(names(comparison.second) == ["d.png"])
    comparison.isPhotoMarking = false
    await ready(comparison)
    #expect(names(comparison.first) == ["d.png", "c.png"])
    #expect(names(comparison.second) == ["a.png"])

    // Outside classification mode, an external mark update refreshes each pane.
    marks.toggle(.one, for: assets[1])
    await refreshAfterRevision(comparison)
    #expect(names(comparison.first) == ["d.png", "c.png", "b.png"])
    #expect(names(comparison.second) == ["a.png"])
  }

  @Test("잠긴 기준은 분류·공통 검색·새 분류 변경에도 유지하고 해제 시 최신 조건을 적용한다")
  func lockedPaneDefersLatestConditions() async throws {
    let fixture = try Fixture()
    let marks = PhotoMarkStore(inMemory: true)
    let comparison = fixture.comparison(marks)
    defer { comparison.cancelLoads(); marks.flush(); fixture.remove() }
    let assets = try await fixture.assets()
    await marks.waitUntilReady()
    markFixture(assets, marks: marks)
    try await open(comparison, fixture: fixture)
    comparison.linksViewport = false
    comparison.first.photoMarkFilter = PhotoMarkFilter(slots: [.one])
    await ready(comparison)
    comparison.updateZoom(2, on: .first)
    comparison.toggleLock(on: .first)
    let locked = comparison.first.currentAsset
    comparison.first.photoMarkFilter = PhotoMarkFilter(slots: [.f])
    comparison.query.searchText = "b"
    marks.toggle(.f, for: assets[2])
    await refreshAfterRevision(comparison)
    #expect(comparison.first.currentAsset == locked)
    #expect(names(comparison.first) == ["a.png", "c.png"])
    #expect(comparison.first.zoom == 2 && comparison.first.isLocked)
    #expect(names(comparison.second) == ["b.png"])
    comparison.toggleLock(on: .first)
    await ready(comparison)
    #expect(names(comparison.first) == ["b.png"])
    #expect(comparison.first.zoom == 1 && !comparison.first.isLocked)
  }

  @Test("필터로 다른 사진이 표시되면 확대·이동을 초기화하고 이전 사진의 크기 응답을 무시한다")
  func replacementSelectionResetsViewportAndRejectsStaleGeometry() async throws {
    let fixture = try Fixture()
    let marks = PhotoMarkStore(inMemory: true)
    let comparison = fixture.comparison(marks)
    defer { comparison.cancelLoads(); marks.flush(); fixture.remove() }
    let assets = try await fixture.assets()
    await marks.waitUntilReady()
    markFixture(assets, marks: marks)
    try await open(comparison, fixture: fixture)
    comparison.linksViewport = false
    let previous = try #require(comparison.first.currentAsset)
    let geometry = ImagePanGeometry(baseImageSize: CGSize(width: 400, height: 300),
      viewportSize: CGSize(width: 400, height: 300))
    comparison.updatePanGeometry(geometry, on: .first, assetID: previous.id)
    comparison.updateZoom(2, on: .first)
    comparison.pan(CGSize(width: 80, height: 40), on: .first)
    comparison.first.photoMarkFilter = PhotoMarkFilter(slots: [.f])
    await ready(comparison)
    #expect(comparison.first.currentAsset?.filename == "b.png")
    #expect(comparison.first.zoom == 1 && comparison.first.pan == .zero)
    #expect(comparison.first.viewport.snapshot.geometryAssetID == nil)
    comparison.updatePanGeometry(geometry, on: .first, assetID: previous.id)
    #expect(comparison.first.viewport.snapshot.viewportSize == nil)
  }

  @Test("조건 선택 중 이동을 막고 다른 소스를 열어도 칸의 분류 조건은 유지한다")
  func filterEditingBlocksNavigationAndFiltersSurviveSourceChanges() async throws {
    let fixture = try Fixture()
    let marks = PhotoMarkStore(inMemory: true)
    let comparison = fixture.comparison(marks)
    defer { comparison.cancelLoads(); marks.flush(); fixture.remove() }
    await marks.waitUntilReady()
    try await open(comparison, fixture: fixture)
    comparison.editingPhotoMarkSide = .first
    #expect(!comparison.canNavigate(.first, direction: 1))
    #expect(!comparison.canNavigateBoth(1))
    comparison.jump(.first, number: 3)
    comparison.navigateSelection(1)
    #expect(comparison.first.index == 0 && comparison.second.index == 0)
    comparison.editingPhotoMarkSide = nil
    comparison.first.photoMarkFilter = PhotoMarkFilter(slots: [.f])
    let otherFolder = fixture.root.appendingPathComponent("Other")
    try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixture.photos.appendingPathComponent("d.png"),
      to: otherFolder.appendingPathComponent("d.png"))
    comparison.open(urls: [otherFolder], for: .first)
    await ready(comparison)
    #expect(comparison.first.photoMarkFilter == PhotoMarkFilter(slots: [.f]))
    #expect(comparison.first.assets.isEmpty)
    comparison.first.photoMarkFilter = PhotoMarkFilter()
    await ready(comparison)
    #expect(names(comparison.first) == ["d.png"])
    #expect(comparison.second.assets.count == 4)
  }

  @Test("12개 분류와 양쪽 선택·잠금을 저장 복원하고 구버전 세션도 읽는다")
  func filterSessionRoundTripAndLegacyCompatibility() async throws {
    let fixture = try Fixture()
    let marks = PhotoMarkStore(inMemory: true)
    let original = fixture.comparison(marks)
    let restored = fixture.comparison(marks)
    defer { original.cancelLoads(); restored.cancelLoads(); marks.flush(); fixture.remove() }
    let assets = try await fixture.assets()
    await marks.waitUntilReady()
    // Exercise all twelve persisted keys without making the expected locked
    // asset contradictory: C has all included keys; A carries the excluded E.
    let included = Set(PhotoMarkSlot.allCases).subtracting([.e])
    for slot in included { marks.toggle(slot, for: assets[2]) }
    marks.toggle(.one, for: assets[0])
    marks.toggle(.e, for: assets[0])
    try await open(original, fixture: fixture)
    original.first.photoMarkFilter = PhotoMarkFilter(slots: included,
      matchesAll: true, excludedSlots: [.e])
    original.second.photoMarkFilter = PhotoMarkFilter(unmarkedOnly: true)
    await ready(original)
    original.jump(.second, number: 2)
    original.toggleLock(on: .first)
    let session = try #require(original.captureSession())
    let encoded = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(ComparisonSession.self, from: encoded)
    #expect(decoded == session)
    await restored.restoreSession(decoded)
    #expect(restored.first.photoMarkFilter == original.first.photoMarkFilter)
    #expect(restored.second.photoMarkFilter == original.second.photoMarkFilter)
    #expect(names(restored.first) == ["c.png"] && names(restored.second) == ["b.png", "d.png"])
    #expect(restored.first.isLocked && restored.second.currentAsset?.filename == "d.png")
    #expect(restored.alert == nil)

    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    for key in ["first", "second"] {
      var pane = try #require(legacy[key] as? [String: Any])
      pane.removeValue(forKey: "photoMarkFilter")
      legacy[key] = pane
    }
    let oldSession = try JSONDecoder().decode(ComparisonSession.self,
      from: JSONSerialization.data(withJSONObject: legacy))
    #expect(oldSession.first.photoMarkFilter == nil && oldSession.second.photoMarkFilter == nil)
    await restored.restoreSession(oldSession)
    #expect(restored.first.photoMarkFilter == PhotoMarkFilter())
    #expect(restored.second.photoMarkFilter == PhotoMarkFilter())
    #expect(restored.first.assets.count == 4 && restored.second.assets.count == 4)
  }

  @Test("초기 저장소 준비를 기다리고 필터에 가려진 구버전 분류까지 원본 전체에서 이관한다")
  func reconcilesUnfilteredLegacyAssetsBeforeClassification() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let assets = try await fixture.assets()
    let database = fixture.root.appendingPathComponent("marks.sqlite")
    let firstPath = assets[0].sessionID.replacingOccurrences(of: "'", with: "''")
    let secondPath = assets[1].sessionID.replacingOccurrences(of: "'", with: "''")
    var connection: OpaquePointer?
    try #require(sqlite3_open(database.path, &connection) == SQLITE_OK)
    let handle = try #require(connection)
    let sql = """
      CREATE TABLE mark_labels (slot TEXT PRIMARY KEY NOT NULL, label TEXT NOT NULL);
      CREATE TABLE asset_marks (asset_id TEXT PRIMARY KEY NOT NULL, marks INTEGER NOT NULL);
      INSERT INTO asset_marks VALUES ('\(firstPath)', \(PhotoMarkSlot.one.bit));
      INSERT INTO asset_marks VALUES ('\(secondPath)', \(PhotoMarkSlot.f.bit));
      PRAGMA user_version = 1;
      """
    let success = sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    sqlite3_close(handle)
    try #require(success)
    let marks = PhotoMarkStore(databaseURL: database)
    let pane = FolderComparisonPane(photoMarks: marks)
    defer { pane.cancelLoad(); marks.flush() }
    pane.photoMarkFilter = PhotoMarkFilter(slots: [.one])
    pane.open(urls: [fixture.photos])
    await pane.waitUntilLoaded()
    #expect(marks.isReady && pane.errorMessage == nil)
    #expect(names(pane) == ["a.png"])
    #expect(marks.marksByAssetID[assets[0].photoMarkID] == [.one])
    #expect(marks.marksByAssetID[assets[1].photoMarkID] == [.f])
    #expect(marks.marksByAssetID[assets[0].sessionID] == nil)
    #expect(marks.marksByAssetID[assets[1].sessionID] == nil)
    pane.photoMarkFilter = PhotoMarkFilter(slots: [.f])
    await pane.waitUntilLoaded()
    #expect(names(pane) == ["b.png"])
  }

  @Test("원본 컬렉션의 접근 권한과 ZIP 수명을 유지하며 비디오는 비교에서 제외한다")
  func cachedCollectionRetainsSourceAccessAndArchiveLease() async throws {
    let fixture = try Fixture()
    let comparison = fixture.comparison(nil)
    defer { comparison.cancelLoads(); fixture.remove() }
    let extracted = fixture.root.appendingPathComponent("extracted")
    try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
    var lease: ArchiveImageLease? = ArchiveImageLease(directory: extracted)
    weak var retainedLease = lease
    var access: ImageLibraryAccess? = ImageLibraryAccess([fixture.photos])
    weak var retainedAccess = access
    let archive = fixture.root.appendingPathComponent("original.zip")
    var origin: ArchiveImageOrigin? = ArchiveImageOrigin(archiveURL: archive, entryPath: "a.png", lease: lease)
    var assets = [ImageAsset(url: extracted.appendingPathComponent("a.png"), byteCount: nil,
      modificationDate: nil, archiveOrigin: origin),
      ImageAsset(url: fixture.root.appendingPathComponent("video.mp4"), byteCount: nil, modificationDate: nil)]
    let sources = [SessionLocation(url: archive)]
    var grants = [try #require(access)]
    #expect(comparison.openCollectionForMarkComparison(assets: assets, folderURL: nil,
      sources: sources, access: grants, query: LibraryQuery(), initialFilter: PhotoMarkFilter()))
    assets.removeAll()
    grants.removeAll()
    origin = nil
    lease = nil
    access = nil
    await ready(comparison)
    #expect(retainedLease != nil && retainedAccess != nil)
    #expect(names(comparison.first) == ["a.png"] && names(comparison.second) == ["a.png"])
    let session = try #require(comparison.captureSession())
    #expect(session.first.sources == sources && session.second.sources == sources)
    #expect(session.first.selectedID == archive.standardizedFileURL.absoluteString + "#a.png")
  }

  private func names(_ pane: FolderComparisonPane) -> [String] { pane.assets.map(\.filename) }

  @Test("파일명 짝은 양쪽 분류 결과에서만 만들고 잠금 해제 뒤 최신 조건을 따른다")
  func filenameMatchingUsesFilteredMembership() async throws {
    let fixture = try Fixture()
    let marks = PhotoMarkStore(inMemory: true)
    let comparison = fixture.comparison(marks)
    defer { comparison.cancelLoads(); marks.flush(); fixture.remove() }
    let assets = try await fixture.assets()
    await marks.waitUntilReady()
    markFixture(assets, marks: marks)
    try await open(comparison, fixture: fixture)
    comparison.first.photoMarkFilter = PhotoMarkFilter(slots: [.one])
    comparison.second.photoMarkFilter = PhotoMarkFilter(slots: [.f])
    comparison.alignment = .filename
    await ready(comparison)
    try await matched(comparison)
    #expect(names(comparison.first) == ["a.png", "c.png"])
    #expect(names(comparison.second) == ["b.png", "c.png"])
    #expect(comparison.pairs.count == 3)
    comparison.jump(.first, number: 2)
    #expect(comparison.first.currentAsset?.filename == "c.png")
    #expect(comparison.second.currentAsset?.filename == "c.png")
    comparison.toggleLock(on: .first)
    marks.toggle(.one, for: assets[2])
    await refreshAfterRevision(comparison)
    try await matched(comparison)
    #expect(comparison.first.currentAsset?.filename == "c.png")
    comparison.toggleLock(on: .first)
    await ready(comparison)
    try await matched(comparison)
    #expect(names(comparison.first) == ["a.png"])
    #expect(comparison.first.currentAsset?.filename != "c.png")
    #expect(comparison.second.currentAsset?.filename == "c.png")
    #expect(comparison.first.showsMissingCounterpart)
  }

  private func matched(_ comparison: FolderComparisonStore) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while comparison.isMatching, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!comparison.isMatching)
  }

  private func markFixture(_ assets: [ImageAsset], marks: PhotoMarkStore) {
    marks.toggle(.one, for: assets[0])
    marks.toggle(.f, for: assets[1])
    marks.toggle(.one, for: assets[2])
    marks.toggle(.f, for: assets[2])
  }

  private func open(_ comparison: FolderComparisonStore, fixture: Fixture) async throws {
    comparison.open(urls: [fixture.photos], for: .first)
    comparison.open(urls: [fixture.photos], for: .second)
    await ready(comparison)
    try #require(comparison.first.assets.count == 4 && comparison.second.assets.count == 4)
  }

  private func ready(_ comparison: FolderComparisonStore) async {
    await comparison.first.waitUntilLoaded()
    await comparison.second.waitUntilLoaded()
  }

  private func refreshAfterRevision(_ comparison: FolderComparisonStore) async {
    // The revision observer deliberately hops out of @Published's willSet.
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(10))
    await ready(comparison)
  }

  private struct Fixture {
    let root: URL
    let photos: URL
    let suite = "ComparisonPhotoMarkFilterTests.\(UUID())"
    let defaults: UserDefaults

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("comparison-marks-\(UUID())")
      photos = root.appendingPathComponent("Photos")
      defaults = try #require(UserDefaults(suiteName: suite))
      try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
      let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32))
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      for name in ["a", "b", "c", "d"] { try png.write(to: photos.appendingPathComponent(name + ".png")) }
    }

    @MainActor func assets() async throws -> [ImageAsset] { try await ImageLibrary().scan(folder: photos) }

    @MainActor func comparison(_ marks: PhotoMarkStore?) -> FolderComparisonStore {
      FolderComparisonStore(defaults: defaults, alignment: .sequence, photoMarks: marks)
    }

    func remove() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
