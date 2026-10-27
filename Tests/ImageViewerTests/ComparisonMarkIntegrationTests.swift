import AppKit
import Testing

@testable import ImageViewer

@Suite("현재 컬렉션의 A·B 분류 비교 연결")
@MainActor
struct ComparisonMarkIntegrationTests {
  @Test("현재 분류 결과 대신 원본 캐시를 공유하고 공통 조건과 A 분류만 계승한다")
  func opensCachedSourceWithIndependentClassification() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    let first = try #require(store.allAssets.first { $0.filename == "keep-1.png" })
    let second = try #require(store.allAssets.first { $0.filename == "keep-2.png" })
    store.photoMarks.toggle(.one, for: first)
    store.photoMarks.toggle(.w, for: second)
    store.libraryQuery = LibraryQuery(searchText: "keep", sort: .nameDescending, formats: [.png])
    store.photoMarkFilter = PhotoMarkFilter(slots: [.one])
    try await ready(store)
    try #require(store.assets.map(\.filename) == ["keep-1.png"])
    let originalQuery = store.libraryQuery
    let originalFilter = store.photoMarkFilter
    let originalAssets = store.assets
    store.presentationMode = .overview

    // A fresh directory scan would see this file. The quick action must reuse
    // the already opened collection, including assets hidden by the A filter.
    try fixture.png.write(to: fixture.photos.appendingPathComponent("keep-late.png"))
    #expect(store.canCompareCurrentCollectionByMarks)
    store.compareCurrentCollectionByMarks()
    try await ready(store)
    let comparison = store.folderComparison
    #expect(store.presentationMode == .folderComparison)
    #expect(comparison.alignment == .sequence)
    #expect(comparison.query == originalQuery)
    #expect(comparison.first.query == originalQuery && comparison.second.query == originalQuery)
    #expect(comparison.first.photoMarkFilter == originalFilter)
    #expect(comparison.second.photoMarkFilter == PhotoMarkFilter())
    #expect(comparison.first.assets.map(\.filename) == ["keep-1.png"])
    #expect(comparison.second.assets.map(\.filename) == ["keep-3.png", "keep-2.png", "keep-1.png"])
    #expect(comparison.first.sourceURLs == [fixture.photos])
    #expect(comparison.second.sourceURLs == [fixture.photos])
    #expect(comparison.first.folderURL?.standardizedFileURL.path == fixture.photos.standardizedFileURL.path)
    #expect(comparison.second.folderURL?.standardizedFileURL.path == fixture.photos.standardizedFileURL.path)

    comparison.first.photoMarkFilter = PhotoMarkFilter(slots: [.w])
    try await ready(store)
    #expect(comparison.first.assets.map(\.filename) == ["keep-2.png"])
    #expect(comparison.second.assets.count == 3)
    #expect(store.assets == originalAssets && store.photoMarkFilter == originalFilter)
    #expect(store.libraryQuery == originalQuery)
    #expect(store.handleEscapeKey())
    #expect(store.presentationMode == .overview && store.assets == originalAssets)
  }

  @Test("지도 범위로 결과가 비어 있어도 현재 컬렉션을 열고 양쪽에 범위를 유지한다")
  func inheritsGeographicScopeFromEmptyViewerResult() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    store.libraryQuery.geographicSelection = .radius(
      center: GeoCoordinate(latitude: 48.8584, longitude: 2.2945), meters: 1_000)
    try await ready(store)
    try #require(store.assets.isEmpty && !store.allAssets.isEmpty)
    let query = store.libraryQuery

    #expect(store.canCompareCurrentCollectionByMarks)
    store.compareCurrentCollectionByMarks()
    try await ready(store)

    #expect(store.presentationMode == .folderComparison)
    #expect(store.folderComparison.query == query)
    #expect(store.folderComparison.first.query == query && store.folderComparison.second.query == query)
    #expect(store.folderComparison.first.assets.isEmpty && store.folderComparison.second.assets.isEmpty)
    store.folderComparison.query.geographicSelection = nil
    try await ready(store)
    #expect(store.folderComparison.first.assets.count == 5)
    #expect(store.folderComparison.second.assets.count == 5)
    #expect(store.libraryQuery == query && store.assets.isEmpty)
  }

  @Test("잠긴 기준 칸이 있으면 빠른 열기가 기존 비교를 교체하지 않는다",
    arguments: FolderComparisonSide.allCases)
  func quickOpenPreservesLockedComparison(side: FolderComparisonSide) async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    store.compareCurrentCollectionByMarks()
    try await ready(store)
    let comparison = store.folderComparison
    comparison.jump(side, number: 2)
    comparison.updateZoom(2, on: side)
    comparison.toggleLock(on: side)
    try #require(comparison.pane(side).isLocked)
    let snapshot = try #require(comparison.captureSession())

    #expect(!store.canCompareCurrentCollectionByMarks)
    store.compareCurrentCollectionByMarks()

    #expect(comparison.captureSession() == snapshot)
    #expect(store.presentationMode == .folderComparison)
    #expect(!comparison.first.isLoading && !comparison.second.isLoading)
  }

  @Test("분류 조건 팝업을 조작하는 키와 분류 버튼은 뒤의 사진을 바꾸지 않는다",
    arguments: [false, true])
  func classificationPopupProtectsSelectionAndMarks(marking: Bool) async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    store.compareCurrentCollectionByMarks()
    try await ready(store)
    let comparison = store.folderComparison
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    let first = try #require(comparison.first.currentAsset)
    let second = try #require(comparison.second.currentAsset)
    store.isPhotoMarking = marking
    comparison.editingPhotoMarkSide = .first

    #expect(!store.canMarkPhoto && !store.canCompareCurrentCollectionByMarks)
    #expect(!store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    #expect(!store.handleViewerKeyDown(try key(18, characters: "1"), shortcuts: shortcuts))
    store.perform(.nextPage)
    store.perform(.nextSecondFolder)
    store.togglePhotoMark(.one)
    comparison.navigateSelection(1)
    #expect(comparison.first.currentAsset == first && comparison.second.currentAsset == second)
    #expect(store.photoMarks.marks(for: first).isEmpty)
    #expect(store.photoMarks.marks(for: second).isEmpty)

    comparison.editingPhotoMarkSide = nil
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    #expect(comparison.first.currentAsset?.id != first.id)
    #expect(comparison.second.currentAsset?.id != second.id)
  }

  @Test("분류 상태를 비교에 동기화해 작업 중 목록을 고정하고 종료 후 양쪽을 갱신한다",
    arguments: [false, true])
  func markingFreezesBothListsUntilItEnds(startBeforeOpening: Bool) async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    store.photoMarkFilter = PhotoMarkFilter(unmarkedOnly: true)
    try await ready(store)
    let returnMode: PresentationMode = startBeforeOpening ? .overview : .viewer
    store.presentationMode = returnMode
    let libraryAssets = store.assets
    let libraryCurrentAsset = store.currentAsset
    let librarySelection = store.selectedURLs
    let libraryFilter = store.photoMarkFilter
    if startBeforeOpening { store.togglePhotoMarking() }
    store.compareCurrentCollectionByMarks()
    try await ready(store)
    let comparison = store.folderComparison
    comparison.second.photoMarkFilter = PhotoMarkFilter(slots: [.one])
    try await ready(store)
    try #require(comparison.first.assets.count == 5 && comparison.second.assets.isEmpty)
    if !startBeforeOpening { store.togglePhotoMarking() }
    try #require(store.isPhotoMarking && comparison.isPhotoMarking)
    comparison.activeSide = .first
    let selected = try #require(comparison.first.currentAsset)
    let firstList = comparison.first.assets
    let shortcuts = ShortcutStore(defaults: fixture.defaults)

    #expect(store.handleViewerKeyDown(try key(18, characters: "1"), shortcuts: shortcuts))
    for _ in 0..<3 { await Task.yield() }
    await comparison.first.waitUntilLoaded()
    await comparison.second.waitUntilLoaded()
    #expect(store.photoMarks.marks(for: selected) == [.one])
    #expect(comparison.first.currentAsset == selected && comparison.first.assets == firstList)
    #expect(comparison.second.assets.isEmpty)
    #expect(!comparison.first.isFiltering && !comparison.second.isFiltering)

    store.togglePhotoMarking()
    #expect(!store.isPhotoMarking && !comparison.isPhotoMarking)
    try await ready(store)
    #expect(comparison.first.assets.count == 4)
    #expect(!comparison.first.assets.contains { $0.id == selected.id })
    #expect(comparison.second.assets.map(\.id) == [selected.id])
    // A/B is visible, so its lists update immediately while the ordinary
    // library keeps its collection and selection until the user returns.
    #expect(store.assets == libraryAssets && store.currentAsset == libraryCurrentAsset)
    #expect(store.selectedURLs == librarySelection && store.photoMarkFilter == libraryFilter)
    #expect(!store.isFiltering)
    store.toggleFolderComparison()
    #expect(store.presentationMode == returnMode)
    try await ready(store)
    #expect(store.assets.count == 4 && store.photoMarkFilter == libraryFilter)
    #expect(!store.assets.contains { $0.id == selected.id })
  }

  @Test("양쪽 분류 결과가 모두 비어도 저장된 비교 화면과 각 필터를 복원한다")
  func restoresComparisonModeWithTwoEmptyClassificationResults() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    store.presentationMode = .overview
    store.compareCurrentCollectionByMarks()
    try await ready(store)
    store.folderComparison.first.photoMarkFilter = PhotoMarkFilter(slots: [.one])
    store.folderComparison.second.photoMarkFilter = PhotoMarkFilter(slots: [.w], matchesAll: true)
    try await ready(store)
    try #require(store.folderComparison.first.assets.isEmpty && store.folderComparison.second.assets.isEmpty)
    store.saveSessionNow()

    let persistence = ViewerSessionPersistence(defaults: fixture.defaults)
    var session = try #require(persistence.loadSession())
    // Exercise saved comparison/filter state independently of security-scoped
    // bookmark resolution, which has its own permission and migration tests.
    func withoutBookmarks(_ sources: [SessionLocation]) -> [SessionLocation] {
      sources.map { var source = $0; source.bookmark = nil; return source }
    }
    session.sources = withoutBookmarks(session.sources)
    var comparisonSession = try #require(session.comparison)
    comparisonSession.first.sources = withoutBookmarks(comparisonSession.first.sources)
    comparisonSession.second.sources = withoutBookmarks(comparisonSession.second.sources)
    session.comparison = comparisonSession
    persistence.save(session)
    let restored = fixture.makeStore()
    defer { restored.folderComparison.cancelLoads(); restored.saveSessionNow() }

    await restored.restoreLastSession()
    try await ready(restored)

    #expect(restored.alert == nil && restored.folderComparison.alert == nil)
    #expect(restored.presentationMode == .folderComparison)
    #expect(restored.folderComparison.first.assets.isEmpty && restored.folderComparison.second.assets.isEmpty)
    #expect(restored.folderComparison.first.sourceURLs == [fixture.photos])
    #expect(restored.folderComparison.second.sourceURLs == [fixture.photos])
    #expect(restored.folderComparison.first.photoMarkFilter == PhotoMarkFilter(slots: [.one]))
    #expect(restored.folderComparison.second.photoMarkFilter == PhotoMarkFilter(slots: [.w], matchesAll: true))
    restored.folderComparison.second.photoMarkFilter = PhotoMarkFilter()
    try await ready(restored)
    #expect(restored.folderComparison.first.assets.isEmpty)
    #expect(restored.folderComparison.second.assets.count == 5)
    #expect(restored.handleEscapeKey())
    #expect(restored.presentationMode == .overview)
  }

  private func openPhotos(_ store: AppStore, fixture: Fixture) async throws {
    await store.photoMarks.waitUntilReady()
    try #require(store.photoMarks.isReady)
    store.open(urls: [fixture.photos])
    try await ready(store)
    try #require(store.assets.count == 5 && store.alert == nil)
  }

  private func ready(_ store: AppStore) async throws {
    for _ in 0..<500 {
      let comparison = store.folderComparison
      if !store.isLoading && !store.isFiltering && !store.isIndexingLocations
        && !comparison.first.isLoading && !comparison.second.isLoading
        && !comparison.first.isFiltering && !comparison.second.isFiltering && !comparison.isMatching {
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.loadingTimedOut
  }

  private func key(_ code: UInt16, characters: String = "") throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, characters: characters,
      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
  }

  private func cleanup(_ store: AppStore, fixture: Fixture) {
    store.folderComparison.cancelLoads()
    store.saveSessionNow()
    fixture.defaults.removePersistentDomain(forName: fixture.suite)
    try? FileManager.default.removeItem(at: fixture.root)
  }

  private enum FixtureError: Error { case loadingTimedOut }

  private struct Fixture {
    let root: URL
    let photos: URL
    let database: URL
    let suite: String
    let defaults: UserDefaults
    let png: Data

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("ComparisonMarks-\(UUID())")
      photos = root.appendingPathComponent("Photos")
      database = root.appendingPathComponent("marks.sqlite")
      suite = "ComparisonMarks.\(UUID())"
      defaults = try #require(UserDefaults(suiteName: suite))
      let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
      png = try #require(bitmap.representation(using: .png, properties: [:]))
      let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))
      try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
      for name in ["keep-1.png", "keep-2.png", "keep-3.png", "skip.png"] {
        try png.write(to: photos.appendingPathComponent(name))
      }
      try jpeg.write(to: photos.appendingPathComponent("keep-4.jpg"))
    }

    @MainActor func makeStore() -> AppStore {
      AppStore(defaults: defaults, monitorsSystemResources: false, photoMarkDatabaseURL: database)
    }
  }
}
