import AppKit
import Combine
import Testing

@testable import ImageViewer

@Suite("검색·즐겨찾기·이전 보기 복원")
@MainActor
struct LibrarySessionTests {
  @Test("검색과 다중 형식 필터는 원본 목록을 보존하고 모두 선택은 결과에만 적용한다")
  func filtersPreserveSourceCollection() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let folder = try album(fixture, name: "photos", files: ["cat2.png", "cat10.png", "cat3.jpg", "dog.png"])
    let store = makeStore()
    store.open(urls: [folder])
    try await wait { !store.isLoading }
    store.libraryQuery = LibraryQuery(searchText: "CAT", formats: [.png])
    try await wait { !store.isFiltering }
    #expect(store.allAssets.count == 4)
    #expect(store.assets.map(\.filename) == ["cat2.png", "cat10.png"])
    store.selectAllAssets()
    #expect(store.selectedAssets.count == 2)
    #expect(store.selectedURLs == Set(store.assets.map(\.url)))
    store.libraryQuery.formats.insert(.jpeg)
    try await wait { !store.isFiltering }
    #expect(store.assets.map(\.filename) == ["cat2.png", "cat3.jpg", "cat10.png"])
    store.libraryQuery.searchText = "nothing matches"
    try await wait { !store.isFiltering }
    #expect(store.assets.isEmpty && store.allAssets.count == 4 && store.selectedURLs.isEmpty)
    store.resetLibraryQuery()
    try await wait { !store.isFiltering }
    #expect(store.assets.count == 4 && store.selectedAssets.isEmpty)
  }

  @Test("빠른 검색 교체와 정렬은 최신 결과 및 현재 사진·확대 위치를 보존한다")
  func queryCancellationAndFocus() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let folder = try album(fixture, name: "photos", files: ["01.png", "02.png", "03.png"])
    let store = makeStore()
    store.open(urls: [folder])
    try await wait { !store.isLoading }
    store.select(index: 1)
    store.zoom = 3
    store.panOffset = CGSize(width: 25, height: -40)
    store.libraryQuery.searchText = "01"
    store.libraryQuery.searchText = "03"
    store.libraryQuery = LibraryQuery(sort: .nameDescending)
    try await wait { !store.isFiltering }
    #expect(store.assets.map(\.filename) == ["03.png", "02.png", "01.png"])
    #expect(store.currentAsset?.filename == "02.png")
    #expect(store.zoom == 3 && store.panOffset == CGSize(width: 25, height: -40))
    #expect(store.selectedAssets.map(\.filename) == ["02.png"])
  }

  @Test("마지막 보기는 명시적 복원에서만 폴더·선택·모드·검색·확대를 복원한다")
  func restoresSessionExplicitly() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let folder = try album(fixture, name: "photos", files: ["01.png", "02.png", "03.png"])
    let defaults = makeDefaults()
    let original = makeStore(defaults)
    original.open(urls: [folder])
    try await wait { !original.isLoading }
    original.select(index: 1)
    original.libraryQuery.sort = .nameDescending
    try await wait { !original.isFiltering }
    original.presentationMode = .overview
    original.zoom = 2.5
    original.panOffset = CGSize(width: 17, height: -8)
    original.baseScaleMode = .actualPixels
    original.saveSessionNow()
    let restored = makeStore(defaults)
    #expect(restored.assets.isEmpty)
    await restored.restoreLastSession()
    #expect(restored.allAssets.count == 3 && restored.assets.count == 3)
    #expect(restored.currentAsset?.filename == "02.png")
    #expect(restored.selectedAssets.map(\.filename) == ["02.png"])
    #expect(restored.presentationMode == .overview && restored.libraryQuery.sort == .nameDescending)
    #expect(restored.zoom == 2.5 && restored.panOffset == CGSize(width: 17, height: -8))
    #expect(restored.baseScaleMode == .actualPixels)
  }

  @Test("앱 재실행은 비교 모드·두 폴더·누락된 짝·활성 칸과 확대를 함께 복원한다")
  func restoresWholeComparisonSession() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let a = try album(fixture, name: "A", files: ["001.png", "003.png"])
    let b = try album(fixture, name: "B", files: ["001.jpg", "002.jpg", "003.jpg"])
    let defaults = makeDefaults()
    let original = makeStore(defaults)

    // Preserve the ordinary viewer too, so leaving a restored comparison returns to it.
    original.open(urls: [a])
    try await wait { !original.isLoading }
    original.select(index: 1)
    original.presentationMode = .overview
    original.toggleFolderComparison()
    original.folderComparison.activeSide = .first
    original.open(urls: [a])
    original.folderComparison.activeSide = .second
    original.open(urls: [b])
    try await wait {
      !original.folderComparison.first.isLoading && !original.folderComparison.second.isLoading
        && !original.folderComparison.isMatching && original.folderComparison.pairs.count == 3
    }
    original.perform(.nextPage)
    #expect(original.folderComparison.first.currentAsset == nil)
    #expect(original.folderComparison.second.currentAsset?.filename == "002.jpg")
    original.folderComparison.linksViewport = false
    original.setActualPixels()
    original.zoomIn()
    original.zoomIn()
    let savedZoom = original.folderComparison.second.zoom
    original.saveSessionNow()

    let restored = makeStore(defaults)
    #expect(restored.presentationMode == .viewer && restored.assets.isEmpty)
    #expect(restored.folderComparison.first.assets.isEmpty && restored.folderComparison.second.assets.isEmpty)
    await restored.restoreLastSession()
    #expect(restored.presentationMode == .folderComparison)
    #expect(restored.folderComparison.first.folderURL?.standardizedFileURL == a.standardizedFileURL)
    #expect(restored.folderComparison.second.folderURL?.standardizedFileURL == b.standardizedFileURL)
    #expect(restored.folderComparison.first.assets.count == 2 && restored.folderComparison.second.assets.count == 3)
    #expect(restored.folderComparison.first.currentAsset == nil)
    #expect(restored.folderComparison.first.showsMissingCounterpart)
    #expect(restored.folderComparison.second.currentAsset?.filename == "002.jpg")
    #expect(restored.folderComparison.matchIndex == 1 && restored.folderComparison.activeSide == .second)
    #expect(restored.folderComparison.second.zoom == savedZoom && savedZoom > 1)
    #expect(restored.folderComparison.second.scaleMode == .actualPixels)
    restored.toggleFolderComparison()
    #expect(restored.presentationMode == .overview && restored.currentAsset?.filename == "003.png")
  }

  @Test("일반 폴더가 사라져도 아직 유효한 A/B 비교는 이어서 복원한다")
  func restoresComparisonWhenOrdinaryFolderIsMissing() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let previous = try album(fixture, name: "previous", files: ["old.png"])
    let a = try album(fixture, name: "A", files: ["001.png", "003.png"])
    let b = try album(fixture, name: "B", files: ["001.jpg", "002.jpg", "003.jpg"])
    let defaults = makeDefaults()
    let original = makeStore(defaults)
    original.open(urls: [previous])
    try await wait { !original.isLoading }
    original.toggleFolderComparison()
    original.folderComparison.activeSide = .first
    original.open(urls: [a])
    original.folderComparison.activeSide = .second
    original.open(urls: [b])
    try await wait {
      !original.folderComparison.first.isLoading && !original.folderComparison.second.isLoading
        && !original.folderComparison.isMatching && original.folderComparison.pairs.count == 3
    }
    original.perform(.nextPage)
    original.saveSessionNow()
    try FileManager.default.removeItem(at: previous)

    let restored = makeStore(defaults)
    await restored.restoreLastSession()
    #expect(restored.assets.isEmpty && restored.currentFolderURL == nil)
    #expect(restored.presentationMode == .folderComparison)
    #expect(restored.folderComparison.first.assets.count == 2)
    #expect(restored.folderComparison.second.assets.count == 3)
    #expect(restored.folderComparison.first.showsMissingCounterpart)
    #expect(restored.folderComparison.second.currentAsset?.filename == "002.jpg")
    #expect(restored.folderComparison.matchIndex == 1)
  }

  @Test("이전 보기 복원 중 사용자가 바꾼 검색·정렬·형식은 저장된 설정보다 우선한다")
  func userQueryWinsWhileSessionRestoresComparison() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let a = try album(fixture, name: "A", files: ["001.png", "003.png", "003.jpg"])
    let b = try album(fixture, name: "B", files: ["001.jpg", "003.jpg"])
    let defaults = makeDefaults()
    let original = makeStore(defaults)
    original.open(urls: [a])
    try await wait { !original.isLoading }
    original.libraryQuery = LibraryQuery(searchText: "001", sort: .nameAscending)
    try await wait { !original.isFiltering }
    original.toggleFolderComparison()
    original.folderComparison.activeSide = .first
    original.open(urls: [a])
    original.folderComparison.activeSide = .second
    original.open(urls: [b])
    try await wait {
      !original.folderComparison.first.isLoading && !original.folderComparison.second.isLoading
        && !original.folderComparison.isMatching && !original.folderComparison.pairs.isEmpty
    }
    original.saveSessionNow()

    let restored = makeStore(defaults)
    let latestQuery = LibraryQuery(searchText: "003", sort: .nameDescending, formats: [.png])
    var changedDuringRestore = false
    // The comparison begins loading only after the ordinary collection is restored.
    // This produces a deterministic user edit inside the restore, without timing sleeps.
    let observation = restored.folderComparison.first.$isLoading.sink { loading in
      guard loading, !changedDuringRestore else { return }
      changedDuringRestore = true
      restored.libraryQuery = latestQuery
    }
    defer { observation.cancel() }
    await restored.restoreLastSession()
    try await wait { !restored.isFiltering }
    #expect(changedDuringRestore)
    #expect(restored.libraryQuery == latestQuery)
    #expect(restored.allAssets.count == 3)
    #expect(restored.assets.map(\.filename) == ["003.png"])
    #expect(restored.currentAsset?.filename == "003.png")
    #expect(restored.presentationMode == .folderComparison)
    #expect(restored.folderComparison.first.assets.count == 3 && restored.folderComparison.second.assets.count == 2)
  }

  @Test("사용자가 먼저 연 사진은 시작 복원이나 늦게 끝난 검색으로 교체하지 않는다")
  func explicitOpenWinsOverRestoreAndQuery() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let a = try album(fixture, name: "A", files: ["old.png"])
    let b = try album(fixture, name: "B", files: ["new.png"])
    let defaults = makeDefaults()
    let saved = makeStore(defaults)
    saved.open(urls: [a])
    try await wait { !saved.isLoading }
    saved.saveSessionNow()
    let current = makeStore(defaults)
    current.open(urls: [b])
    await current.restoreLastSession()
    try await wait { !current.isLoading }
    #expect(current.currentAsset?.filename == "new.png")
    current.libraryQuery.searchText = "old"
    current.resetLibraryQuery()
    current.open(urls: [b])
    try await wait { !current.isLoading && !current.isFiltering }
    #expect(current.currentAsset?.filename == "new.png" && current.allAssets.count == 1)
  }

  @Test("사라진 복원 폴더는 저장 상태를 덮어쓰지 않고 새 열기를 허용한다")
  func missingSessionFolderRemainsRecoverable() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let folder = try album(fixture, name: "photos", files: ["01.png"])
    let defaults = makeDefaults()
    let persistence = ViewerSessionPersistence(defaults: defaults)
    let missing = fixture.appendingPathComponent("missing", isDirectory: true)
    persistence.save(ViewerSession(sources: [SessionLocation(url: missing)]))
    let before = defaults.data(forKey: ViewerSessionPersistence.sessionKey)
    let store = makeStore(defaults)
    await store.restoreLastSession()
    #expect(store.assets.isEmpty && store.statusMessage != nil)
    #expect(defaults.data(forKey: ViewerSessionPersistence.sessionKey) == before)
    store.open(urls: [folder])
    try await wait { !store.isLoading }
    #expect(store.assets.count == 1)
  }

  @Test("즐겨찾기 고정은 중복 없이 저장되고 제거와 실패한 열기도 기존 사진을 보존한다")
  func favoritesPersistAndFailWithoutClearing() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let a = try album(fixture, name: "A", files: ["a.png"])
    let b = try album(fixture, name: "B", files: ["b.png"])
    let defaults = makeDefaults()
    let store = makeStore(defaults)
    store.toggleFavoriteFolder(a)
    store.toggleFavoriteFolder(b)
    #expect(store.favoriteFolders.count == 2)
    let restored = makeStore(defaults)
    #expect(restored.favoriteFolders.count == 2)
    restored.openFavoriteFolder(restored.favoriteFolders[0])
    try await wait { !restored.isLoading }
    #expect(restored.currentAsset?.filename == "a.png")
    try FileManager.default.removeItem(at: b)
    restored.openFavoriteFolder(restored.favoriteFolders[1])
    #expect(restored.currentAsset?.filename == "a.png" && restored.alert != nil)
    restored.removeFavoriteFolder(restored.favoriteFolders[1].id)
    #expect(restored.favoriteFolders.count == 1)
    #expect(makeStore(defaults).favoriteFolders.count == 1)
  }

  @Test("ZIP 복원은 추출 임시 경로 대신 논리 식별자를 사용하고 원본 편집을 막는다")
  func archiveSessionAndReadOnlyEditing() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let archive = fixture.appendingPathComponent("album.zip")
    try Data(base64Encoded: zipFixture)!.write(to: archive)
    let defaults = makeDefaults()
    let original = makeStore(defaults)
    original.open(urls: [archive])
    try await wait { !original.isLoading }
    #expect(original.assets.count == 2)
    original.select(index: 1)
    let oldURL = try #require(original.currentAsset?.url)
    let selectedID = original.currentAsset?.sessionID
    original.saveSessionNow()
    let snapshot = try #require(ViewerSessionPersistence(defaults: defaults).loadSession())
    #expect(snapshot.sources.count == 1)
    #expect(try snapshot.sources.first?.resolve().standardizedFileURL == archive.standardizedFileURL)
    let restored = makeStore(defaults)
    await restored.restoreLastSession()
    #expect(restored.statusMessage == nil)
    #expect(restored.currentAsset?.sessionID == selectedID)
    #expect(restored.currentAsset?.url != oldURL)
    #expect(restored.currentAsset?.isReadOnly == true)
    #expect(!restored.canEditCurrentEmbeddedMetadata)
    restored.presentBatchRename()
    #expect(restored.batchSheet == nil)
    let draft = ImageMetadataEditDraft(asset: restored.currentAsset, metadata: nil)
    await #expect(throws: LibraryAccessError.self) {
      try await restored.saveMetadataEdits(draft, replacing: draft)
    }
    var options = BatchRenameOptions()
    options.prefix = "renamed-"
    let plan = BatchRenamePlanner.plan(urls: restored.assets.map(\.url), options: options)
    await #expect(throws: LibraryAccessError.self) { try await restored.renameSelectedFiles(using: plan) }
    #expect(FileManager.default.fileExists(atPath: oldURL.path))
  }

  private func makeDefaults() -> UserDefaults { UserDefaults(suiteName: "LibrarySessionTests.\(UUID())")! }
  private func makeStore(_ defaults: UserDefaults? = nil) -> AppStore {
    AppStore(defaults: defaults ?? makeDefaults(), monitorsSystemResources: false)
  }
  private func makeFixture() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LibrarySessionTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
  private func album(_ root: URL, name: String, files: [String]) throws -> URL {
    let folder = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=")!
    for filename in files { try png.write(to: folder.appendingPathComponent(filename)) }
    return folder
  }
  private func wait(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(predicate())
  }
  private let zipFixture = "UEsDBBQAAAAAAF0CN12P/VI7RAAAAEQAAAAGAAAAMDEucG5niVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYIJQSwMEFAAAAAAAXQI3XY/9UjtEAAAARAAAAAYAAAAwMi5wbmeJUE5HDQoaCgAAAA1JSERSAAAAAQAAAAEIBAAAALUcDAIAAAALSURBVHjaY/z/HwADAwIA75ovWwAAAABJRU5ErkJgglBLAQIUAxQAAAAAAF0CN12P/VI7RAAAAEQAAAAGAAAAAAAAAAAAAACAAQAAAAAwMS5wbmdQSwECFAMUAAAAAABdAjddj/1SO0QAAABEAAAABgAAAAAAAAAAAAAAgAFoAAAAMDIucG5nUEsFBgAAAAACAAIAaAAAANAAAAAAAA=="
}
