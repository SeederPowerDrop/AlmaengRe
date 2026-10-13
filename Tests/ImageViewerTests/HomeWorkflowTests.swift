import AppKit
import ImageIO
import Testing

@testable import ImageViewer

@Suite("처음 화면과 최근 본 사진 작업 흐름", .serialized)
@MainActor
struct HomeWorkflowTests {
  @Test("저장된 작업이 없는 실행은 처음 화면에 머물고 직접 열면 사진을 보여준다")
  func freshLaunchAndExplicitOpen() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()
    #expect(store.showsHome && !store.canResumeWorkspace)
    #expect(store.assets.isEmpty && store.recentPhotos.items.isEmpty)

    await store.resumeWorkspace()
    #expect(store.showsHome && store.assets.isEmpty)

    store.open(urls: [fixture.photos.appendingPathComponent("photo-02.png")])
    try await ready(store)
    #expect(!store.showsHome && store.canResumeWorkspace)
    #expect(store.currentAsset?.filename == "photo-02.png")
    #expect(store.assets.count == 3)
  }

  @Test("사진을 직접 열거나 폴더 트리로 이동하면 폴더만 기록하고 실제 표시 전에는 최근 사진을 만들지 않는다")
  func successfulOpenRecordsFoldersBeforeDisplayedPhotos() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()

    store.open(urls: [fixture.photos.appendingPathComponent("photo-02.png")])
    try await ready(store)
    let first = try #require(store.recentPhotos.folders.first)
    #expect(first.location.url.resolvingSymlinksInPath() == fixture.photos.resolvingSymlinksInPath())
    #expect(first.photos.isEmpty && store.recentPhotos.items.isEmpty)

    store.openFolderFromTree(fixture.otherPhotos)
    try await ready(store)
    #expect(store.recentPhotos.folders.map(\.name) == ["Other", "Photos"])
    #expect(store.recentPhotos.folders.allSatisfy { $0.photos.isEmpty })
    #expect(store.recentPhotos.items.isEmpty)

    store.openFolderFromTree(fixture.photos)
    try await ready(store)
    #expect(store.recentPhotos.folders.map(\.name) == ["Photos", "Other"])
    #expect(store.recentPhotos.folders.first?.id == first.id)
    #expect(store.recentPhotos.folders.count == 2)
    #expect(RecentPhotoStore(defaults: fixture.defaults).folders.map(\.id) == store.recentPhotos.folders.map(\.id))
  }

  @Test("최근 폴더를 열면 필터를 해제하고 마지막으로 본 사진을 일반 보기에서 선택한다")
  func recentFolderOpenClearsFiltersAndFocusesLatestPhoto() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()
    await store.photoMarks.waitUntilReady()
    store.open(urls: [fixture.photos])
    try await ready(store)
    store.recordRecentlyViewed(try #require(store.currentAsset))
    store.select(index: 2)
    let latest = try #require(store.currentAsset)
    store.recordRecentlyViewed(latest)
    let recent = try #require(store.recentPhotos.folders.first)
    #expect(recent.photos.first?.id == latest.sessionID)

    store.open(urls: [fixture.otherPhotos])
    try await ready(store)
    store.libraryQuery = LibraryQuery(searchText: "does-not-match", sort: .nameDescending,
      formats: [.jpeg], geographicSelection: .radius(
        center: GeoCoordinate(latitude: 0, longitude: 0), meters: 100))
    store.photoMarkFilter = PhotoMarkFilter(slots: [.one], matchesAll: true)
    try await ready(store)
    store.presentationMode = .overview
    store.showHome()

    await store.openRecentFolder(recent)
    try await ready(store)
    #expect(!store.showsHome && store.alert == nil && store.presentationMode == .viewer)
    #expect(store.libraryQuery.searchText.isEmpty && store.libraryQuery.formats.isEmpty)
    #expect(store.libraryQuery.geographicSelection == nil && !store.photoMarkFilter.isActive)
    let reopened = try #require(store.currentAsset)
    #expect(store.assets.count == 3 && reopened.sessionID == latest.sessionID)
    #expect(store.selectedURLs == [reopened.url])
    #expect(store.recentPhotos.folders.first?.id == recent.id)
  }

  @Test("없어진 최근 폴더를 열지 못하면 홈과 기존 작업 및 최근 기록을 보존한다")
  func missingRecentFolderPreservesHistoryAndWorkspace() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()
    store.open(urls: [fixture.photos])
    try await ready(store)
    let target = try #require(store.currentAsset)
    store.recordRecentlyViewed(target)
    let recent = try #require(store.recentPhotos.folders.first)
    store.open(urls: [fixture.otherPhotos])
    try await ready(store)
    store.libraryQuery = LibraryQuery(searchText: "other", sort: .nameDescending)
    try await ready(store)
    let currentID = store.currentAsset?.sessionID
    let revision = store.libraryRevision
    let query = store.libraryQuery
    let folders = store.recentPhotos.folders.map(\.id)
    store.showHome()
    try FileManager.default.removeItem(at: fixture.photos)

    await store.openRecentFolder(recent)
    try await ready(store)
    #expect(store.showsHome && store.alert != nil && store.canResumeWorkspace)
    #expect(store.currentAsset?.sessionID == currentID && store.libraryRevision == revision)
    #expect(store.libraryQuery == query)
    #expect(store.recentPhotos.folders.map(\.id) == folders)
    #expect(store.recentPhotos.items.map(\.id) == [target.sessionID])
  }

  @Test("폴더 기록을 지우면 예약된 미리보기가 기록을 되살리지 않고 다른 폴더는 남는다")
  func removingRecentFolderDoesNotResurrectPendingPreview() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()
    store.open(urls: [fixture.photos])
    try await ready(store)
    let retainedPhoto = try #require(store.currentAsset)
    store.recordRecentlyViewed(retainedPhoto)
    _ = try await recentPreview(in: store, id: retainedPhoto.sessionID)
    let retainedFolder = try #require(store.recentPhotos.folders.first)

    store.open(urls: [try fixture.largePhoto()])
    try await ready(store)
    let removedPhoto = try #require(store.currentAsset)
    store.recordRecentlyViewed(removedPhoto)
    let removedFolder = try #require(store.recentPhotos.folders.first)
    // Remove synchronously before the just-scheduled preview task can complete.
    store.removeRecentFolder(removedFolder.id)
    _ = try await store.thumbnailPipeline.thumbnail(for: removedPhoto, maxPixelSize: 384)
    await Task.yield()

    #expect(store.recentPhotos.folders.map(\.id) == [retainedFolder.id])
    #expect(store.recentPhotos.items.map(\.id) == [retainedPhoto.sessionID])
    #expect(RecentPhotoStore(defaults: fixture.defaults).folders.map(\.id) == [retainedFolder.id])
    #expect(RecentPhotoStore(defaults: fixture.defaults).items.map(\.id) == [retainedPhoto.sessionID])
    #expect(store.currentAsset?.sessionID == removedPhoto.sessionID, "Removing history must not close the displayed photo")
  }

  @Test("현재 표시된 사진의 늦은 콜백도 제거되거나 밀려난 폴더를 최근 목록에 되살리지 않는다", arguments: [false, true])
  func displayedPhotoCannotRestoreRemovedOrEvictedFolder(evict: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()
    store.open(urls: [fixture.photos])
    try await ready(store)
    let displayed = try #require(store.currentAsset)
    store.recordRecentlyViewed(displayed)
    let original = try #require(store.recentPhotos.folders.first)
    if evict {
      for index in 0..<RecentPhotoStore.maximumFolderCount {
        store.recentPhotos.recordFolder(url: fixture.root.appendingPathComponent("Later-\(index)",
          isDirectory: true))
      }
    } else {
      store.removeRecentFolder(original.id)
    }
    let remainingIDs = store.recentPhotos.folders.map(\.id)
    try #require(!remainingIDs.contains(original.id))

    store.recordRecentlyViewed(displayed)
    #expect(store.recentPhotos.folders.map(\.id) == remainingIDs)
    #expect(!store.recentPhotos.items.contains { $0.id == displayed.sessionID })
    #expect(store.currentAsset?.sessionID == displayed.sessionID)
  }

  @Test("새 실행은 저장된 작업을 자동으로 열지 않고 이어보기에서만 선택·검색·확대를 복원한다")
  func savedWorkspaceRequiresExplicitResume() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let original = fixture.makeStore()
    original.open(urls: [fixture.photos])
    try await ready(original)
    original.libraryQuery = LibraryQuery(searchText: "photo", sort: .nameDescending, formats: [.png])
    try await ready(original)
    original.select(index: 1)
    original.presentationMode = .overview
    original.baseScaleMode = .actualPixels
    original.zoom = 2.5
    original.panOffset = CGSize(width: 17, height: -8)
    original.saveSessionNow()
    let selectedID = original.currentAsset?.sessionID
    let query = original.libraryQuery
    let pan = original.panOffset

    let restored = fixture.makeStore()
    #expect(restored.showsHome && restored.canResumeWorkspace)
    #expect(restored.assets.isEmpty && restored.allAssets.isEmpty)
    #expect(restored.currentFolderURL == nil)
    #expect(restored.recentPhotos.items.isEmpty)

    await restored.resumeWorkspace()
    try await ready(restored)
    #expect(!restored.showsHome)
    #expect(restored.currentAsset?.sessionID == selectedID)
    // Bookmark resolution may expand /var to /private/var for the same file.
    #expect(Set(restored.selectedAssets.map(\.sessionID)) == Set(original.selectedAssets.map(\.sessionID)))
    #expect(restored.presentationMode == .overview && restored.libraryQuery == query)
    #expect(restored.baseScaleMode == .actualPixels && restored.zoom == 2.5)
    #expect(restored.panOffset == pan)
    #expect(restored.assets.count == 3 && restored.recentPhotos.items.isEmpty)
  }

  @Test("처음 화면에서는 탐색 단축키가 숨은 사진을 바꾸지 않고 이어보기는 기존 작업을 그대로 사용한다")
  func homePreservesLoadedWorkspaceAndBlocksViewerCommands() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()
    store.open(urls: [fixture.photos])
    try await ready(store)
    store.select(index: 1)
    store.baseScaleMode = .actualPixels
    store.zoom = 3
    store.panOffset = CGSize(width: 21, height: -13)
    let selectedID = store.currentAsset?.sessionID
    let selection = store.selectedURLs
    let source = store.allAssets.map(\.sessionID)
    let revision = store.libraryRevision
    let pan = store.panOffset

    store.showHome()
    #expect(store.showsHome && store.canResumeWorkspace)
    for action in [ShortcutAction.nextPage, .zoomIn, .fitToWindow, .toggleOverview,
      .toggleFolderComparison, .moreImages, .toggleSlideshow] {
      store.perform(action)
    }
    #expect(store.currentAsset?.sessionID == selectedID && store.selectedURLs == selection)
    #expect(store.allAssets.map(\.sessionID) == source && store.libraryRevision == revision)
    #expect(store.zoom == 3 && store.panOffset == pan && store.baseScaleMode == .actualPixels)
    #expect(store.presentationMode == .viewer && store.imagesPerPage == 1)
    #expect(!store.isSlideshowPlaying)

    await store.resumeWorkspace()
    #expect(!store.showsHome)
    #expect(store.currentAsset?.sessionID == selectedID && store.selectedURLs == selection)
    #expect(store.libraryRevision == revision, "Resuming the loaded workspace must not reopen its collection")
    #expect(store.zoom == 3 && store.panOffset == pan && store.baseScaleMode == .actualPixels)
  }

  @Test("처음 화면으로 돌아가면 전자 앨범 재생을 멈춘다")
  func goingHomePausesSlideshow() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()
    store.open(urls: [fixture.photos])
    try await ready(store)
    store.toggleSlideshow()
    try #require(store.isSlideshowPlaying)

    store.showHome()
    #expect(store.showsHome && !store.isSlideshowPlaying)
    await store.resumeWorkspace()
    #expect(!store.showsHome && !store.isSlideshowPlaying)
  }

  @Test("선택이나 목록 열기만으로 기록하지 않고 홈에서 늦게 도착한 표시 콜백은 지운 기록을 되살리지 않는다")
  func historyRequiresDisplayedPhotoAndIgnoresLateHomeCallback() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()
    store.open(urls: [fixture.photos])
    try await ready(store)
    store.presentationMode = .overview
    store.select(index: 1)
    #expect(store.recentPhotos.items.isEmpty)
    let displayed = try #require(store.currentAsset)
    store.recordRecentlyViewed(displayed)
    #expect(store.recentPhotos.items.isEmpty, "An overview selection is not a displayed viewer photo")

    store.presentationMode = .viewer
    // This is the callback made after ViewerImageTile has a displayed frame.
    store.recordRecentlyViewed(displayed)
    #expect(store.recentPhotos.items.map(\.id) == [displayed.sessionID])
    store.showHome()
    store.clearRecentPhotos()
    store.recordRecentlyViewed(displayed)
    #expect(store.recentPhotos.items.isEmpty)
    #expect(RecentPhotoStore(defaults: fixture.defaults).items.isEmpty)

    await store.resumeWorkspace()
    store.recordRecentlyViewed(displayed)
    #expect(store.recentPhotos.items.map(\.id) == [displayed.sessionID])
  }

  @Test("큰 사진의 최근 미리보기는 더 큰 캐시를 재사용해도 384픽셀 JPEG로 저장된다", arguments: [false, true])
  func recentPreviewPersistsWithinBoundsAfterLargeCacheHit(warmLargerCache: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()
    store.open(urls: [try fixture.largePhoto()])
    try await ready(store)
    let asset = try #require(store.currentAsset)
    try #require(store.assets.count == 1)
    if warmLargerCache {
      let larger = try await store.thumbnailPipeline.thumbnail(for: asset, maxPixelSize: 1_024)
      try #require(max(larger.width, larger.height) > RecentPhotoStore.maximumThumbnailPixelDimension)
      let reused = try await store.thumbnailPipeline.thumbnail(for: asset, maxPixelSize: 384)
      try #require(reused === larger, "Exercise the larger shared cache hit that used to prevent persistence")
    }

    store.recordRecentlyViewed(asset)
    let data = try await recentPreview(in: store, id: asset.sessionID)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect((1...RecentPhotoStore.maximumThumbnailPixelDimension).contains(image.width))
    #expect((1...RecentPhotoStore.maximumThumbnailPixelDimension).contains(image.height))
    #expect(data.count <= RecentPhotoStore.maximumThumbnailBytes)
    #expect(RecentPhotoStore(defaults: fixture.defaults).items.first { $0.id == asset.sessionID }?.thumbnailData == data)
  }

  @Test("최근 사진 열기는 검색·형식·지도·분류 필터를 해제하고 정확한 사진을 선택한다")
  func recentOpenClearsExcludingFiltersAndFocusesPhoto() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()
    await store.photoMarks.waitUntilReady()
    store.open(urls: [fixture.photos])
    try await ready(store)
    store.select(index: 1)
    let target = try #require(store.currentAsset)
    store.recordRecentlyViewed(target)
    let recent = try #require(store.recentPhotos.items.first)
    store.libraryQuery = LibraryQuery(searchText: "does-not-match", sort: .nameDescending,
      formats: [.jpeg], geographicSelection: .radius(
        center: GeoCoordinate(latitude: 0, longitude: 0), meters: 100))
    store.photoMarkFilter = PhotoMarkFilter(slots: [.one], matchesAll: true)
    try await ready(store)
    try #require(store.assets.isEmpty && store.allAssets.count == 3)
    store.showHome()

    await store.openRecentPhoto(recent)
    try await ready(store)
    #expect(!store.showsHome && store.alert == nil)
    #expect(store.presentationMode == .viewer)
    #expect(store.libraryQuery.searchText.isEmpty && store.libraryQuery.formats.isEmpty)
    #expect(store.libraryQuery.geographicSelection == nil && !store.photoMarkFilter.isActive)
    #expect(store.assets.count == 3 && store.currentAsset?.sessionID == target.sessionID)
    #expect(store.selectedURLs == [target.url])
  }

  @Test("비교 작업에서 홈의 최근 사진을 열면 비교 칸을 바꾸지 않고 일반 보기로 연다")
  func recentOpenBypassesComparisonPaneRouting() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()
    store.open(urls: [fixture.photos])
    try await ready(store)
    store.select(index: 1)
    let target = try #require(store.currentAsset)
    store.recordRecentlyViewed(target)
    let recent = try #require(store.recentPhotos.items.first)
    store.toggleFolderComparison()
    store.folderComparison.activeSide = .first
    store.open(urls: [fixture.otherPhotos])
    try await ready(store)
    try #require(store.presentationMode == .folderComparison)
    let comparisonSource = store.folderComparison.first.sourceURLs
    let comparisonPhotos = store.folderComparison.first.assets.map(\.sessionID)
    store.showHome()

    await store.openRecentPhoto(recent)
    try await ready(store)
    #expect(!store.showsHome && store.presentationMode == .viewer)
    #expect(store.currentAsset?.sessionID == target.sessionID)
    #expect(store.folderComparison.first.sourceURLs == comparisonSource)
    #expect(store.folderComparison.first.assets.map(\.sessionID) == comparisonPhotos)
  }

  @Test("없어진 최근 사진은 오류를 알리고 홈·기록·현재 작업을 보존한다")
  func missingRecentPhotoPreservesHistoryAndWorkspace() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()
    store.open(urls: [fixture.photos])
    try await ready(store)
    store.select(index: 1)
    let target = try #require(store.currentAsset)
    store.recordRecentlyViewed(target)
    let recent = try #require(store.recentPhotos.items.first)
    store.open(urls: [fixture.otherPhotos])
    try await ready(store)
    let currentID = store.currentAsset?.sessionID
    let revision = store.libraryRevision
    store.showHome()
    try FileManager.default.removeItem(at: target.url)

    await store.openRecentPhoto(recent)
    try await ready(store)
    #expect(store.showsHome && store.alert != nil)
    #expect(store.recentPhotos.items.map(\.id) == [recent.id])
    #expect(store.currentAsset?.sessionID == currentID && store.libraryRevision == revision)
    #expect(store.canResumeWorkspace)
  }

  @Test("ZIP의 최근 사진은 추출 임시 경로 대신 원본 ZIP의 정확한 구성원을 다시 연다")
  func archiveRecentReopensLogicalMember() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()
    let archive = try fixture.archive()
    store.open(urls: [archive])
    try await ready(store)
    try #require(store.assets.count == 2)
    store.select(index: 1)
    let target = try #require(store.currentAsset)
    store.recordRecentlyViewed(target)
    let recent = try #require(store.recentPhotos.items.first)
    #expect(recent.location.url.standardizedFileURL == archive.standardizedFileURL)
    #expect(recent.archiveEntryPath == "02.png")
    store.open(urls: [fixture.otherPhotos])
    try await ready(store)
    store.showHome()

    await store.openRecentPhoto(recent)
    try await ready(store)
    let reopened = try #require(store.currentAsset)
    #expect(!store.showsHome && store.alert == nil && store.assets.count == 2)
    #expect(reopened.sessionID == target.sessionID && reopened.filename == "02.png")
    #expect(reopened.url != target.url && reopened.isReadOnly)
    #expect(reopened.archiveOrigin?.archiveURL.standardizedFileURL == archive.standardizedFileURL)
    #expect(store.selectedURLs == [reopened.url])
  }

  @Test("선택과 변화 없는 조정은 기록하지 않고 실제 회전·자르기·초기화만 최근 작업으로 기록한다")
  func actualAdjustmentsRecordWorkWithoutCountingSelections() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()
    store.open(urls: [fixture.photos])
    try await ready(store)
    store.presentationMode = .overview
    store.select(index: 1)
    let rotated = try #require(store.currentAsset)
    store.updateAdjustments { _ in }
    store.resetAdjustments()
    #expect(store.recentPhotos.items.isEmpty)

    store.rotateClockwise()
    #expect(store.recentPhotos.items.map(\.id) == [rotated.sessionID])
    store.select(index: 2)
    let cropped = try #require(store.currentAsset)
    #expect(store.recentPhotos.items.map(\.id) == [rotated.sessionID])
    store.applyCrop(NormalizedCrop(x: 0.1, y: 0.1, width: 0.5, height: 0.5), to: cropped)
    #expect(store.recentPhotos.items.map(\.id) == [cropped.sessionID, rotated.sessionID])
    store.select(index: 1)
    store.resetAdjustments()
    #expect(store.recentPhotos.items.first?.id == rotated.sessionID)
    #expect(store.currentAdjustments.isIdentity)
  }

  @Test("연속 슬라이더 조정은 기록 시각을 유지하되 다른 사진과 파일 버전은 즉시 기록한다")
  func rapidAdjustmentValuesCoalesceOnlyTheSameHistoryLeader() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()
    store.open(urls: [fixture.photos])
    try await ready(store)
    store.presentationMode = .overview
    let first = try #require(store.currentAsset)
    store.updateAdjustments { $0.brightness = 0.1 }
    let initialVisit = try #require(store.recentPhotos.items.first?.lastViewed)
    // Keep the burst in a single main-actor turn. Preview tasks and session-save
    // tasks cannot interleave and affect the history assertions.
    for step in 1...40 {
      store.updateAdjustments { $0.brightness = Double(step) / 100 }
    }
    #expect(store.currentAdjustments.brightness == 0.4)
    #expect(store.recentPhotos.items.first?.lastViewed == initialVisit)

    store.select(index: 1)
    let second = try #require(store.currentAsset)
    store.updateAdjustments { $0.brightness = 0.2 }
    #expect(store.recentPhotos.items.first?.id == second.sessionID)
    store.select(index: 0)
    store.updateAdjustments { $0.brightness = 0.5 }
    #expect(store.recentPhotos.items.first?.id == first.sessionID)
    #expect(store.recentPhotos.items.first?.lastViewed != initialVisit)

    // A stale entry for the same path must not suppress the current file version.
    let stale = ImageAsset(url: first.url, byteCount: (first.byteCount ?? 0) + 1,
      modificationDate: first.modificationDate)
    store.recentPhotos.record(stale)
    store.updateAdjustments { $0.brightness = 0.6 }
    #expect(store.recentPhotos.items.first?.hasSameVersion(as: first) == true)
  }

  @Test("몽땅보기의 분류는 실제로 저장된 대상만 기록하며 최신 폴더 열기 순서를 유지한다")
  func committedOverviewClassificationRecordsWorkedImages() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()
    await store.photoMarks.waitUntilReady()
    store.open(urls: [fixture.otherPhotos])
    try await ready(store)
    store.open(urls: [fixture.photos])
    try await ready(store)
    let folders = store.recentPhotos.folders.map(\.id)
    let openedDates = store.recentPhotos.folders.map(\.lastOpened)
    store.presentationMode = .overview
    store.select(index: 1)
    let target = try #require(store.currentAsset)
    #expect(store.recentPhotos.items.isEmpty)
    store.togglePhotoMark(.one)
    #expect(store.recentPhotos.items.isEmpty, "Classification is inactive")
    store.togglePhotoMarking()
    store.togglePhotoMark(.one)
    try await waitForHistory(in: store) { $0.map(\.id) == [target.sessionID] }
    #expect(store.photoMarks.marks(for: target) == [.one])
    #expect(store.recentPhotos.folders.map(\.id) == folders)
    #expect(store.recentPhotos.folders.map(\.lastOpened) == openedDates)
  }

  @Test("내보내기가 실패하면 기록하지 않고 성공하면 원본 이미지만 최근 작업으로 기록한다")
  func exportHistoryRequiresSuccessfulOutput() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()
    await store.photoMarks.waitUntilReady()
    store.open(urls: [fixture.photos])
    try await ready(store)
    store.presentationMode = .overview
    let target = try #require(store.currentAsset)
    let occupied = fixture.root.appendingPathComponent("not-a-directory")
    try Data("occupied".utf8).write(to: occupied)
    do {
      try await store.exportEditedImage(target, to: occupied.appendingPathComponent("image.png"),
        format: .png, quality: 1, adjustments: .identity)
      Issue.record("Export into a regular file unexpectedly succeeded")
    } catch {}
    #expect(store.recentPhotos.items.isEmpty)

    let output = fixture.root.appendingPathComponent("exported.png")
    try await store.exportEditedImage(target, to: output,
      format: .png, quality: 1, adjustments: .identity)
    #expect(FileManager.default.fileExists(atPath: output.path))
    #expect(store.recentPhotos.items.map(\.id) == [target.sessionID])
    #expect(store.recentPhotos.folders.map(\.name) == ["Photos"])
  }

  @Test("늦은 작업 완료는 삭제한 기록이나 새로 연 폴더를 변경하지 않는다")
  func pendingWorkDoesNotResurrectHistoryOrCrossCollections() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()
    store.open(urls: [fixture.photos])
    try await ready(store)
    let target = try #require(store.currentAsset)
    let pending = store.makeRecentWorkRecorder()
    store.clearRecentPhotos()
    // Even recreating the same folder must not accept the old completion.
    store.recentPhotos.recordFolder(url: fixture.photos)
    pending([target])
    #expect(store.recentPhotos.items.isEmpty)

    let fromOldCollection = store.makeRecentWorkRecorder()
    store.open(urls: [fixture.otherPhotos])
    try await ready(store)
    let folders = store.recentPhotos.folders.map(\.id)
    fromOldCollection([target])
    #expect(store.recentPhotos.items.isEmpty)
    #expect(store.recentPhotos.folders.map(\.id) == folders)

    let current = try #require(store.currentAsset)
    store.removeRecentFolder(try #require(store.recentPhotos.folders.first?.id))
    store.rotateClockwise()
    #expect(store.recentPhotos.items.isEmpty)
    #expect(!store.recentPhotos.folders.contains { $0.photos.contains { $0.id == current.sessionID } })
  }

  @Test("작업 완료는 같은 경로의 오래된 파일 버전이나 홈 화면에서 기록하지 않는다")
  func workHistoryRequiresCurrentImageVersion() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore()
    store.open(urls: [fixture.photos])
    try await ready(store)
    let target = try #require(store.currentAsset)
    let stale = ImageAsset(url: target.url, byteCount: (target.byteCount ?? 0) + 1,
      modificationDate: target.modificationDate)
    store.makeRecentWorkRecorder()([stale])
    #expect(store.recentPhotos.items.isEmpty)
    store.showHome()
    store.makeRecentWorkRecorder()([target])
    #expect(store.recentPhotos.items.isEmpty)
  }

  private func waitForHistory(in store: AppStore,
    matching condition: ([RecentPhoto]) -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while ContinuousClock.now < deadline {
      if condition(store.recentPhotos.items) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.loadingTimedOut
  }

  private func ready(_ store: AppStore) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while ContinuousClock.now < deadline {
      let comparison = store.folderComparison
      if !store.isLoading && !store.isFiltering && !store.isIndexingLocations
        && !comparison.first.isLoading && !comparison.second.isLoading
        && !comparison.first.isFiltering && !comparison.second.isFiltering && !comparison.isMatching { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.loadingTimedOut
  }

  private func recentPreview(in store: AppStore, id: String) async throws -> Data {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while ContinuousClock.now < deadline {
      if let data = store.recentPhotos.items.first(where: { $0.id == id })?.thumbnailData { return data }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.previewTimedOut
  }

  private enum FixtureError: Error { case loadingTimedOut, previewTimedOut }

  @MainActor private final class Fixture {
    let root: URL
    let photos: URL
    let otherPhotos: URL
    let suite: String
    let defaults: UserDefaults
    private var stores: [AppStore] = []

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("HomeWorkflow-\(UUID())")
      photos = root.appendingPathComponent("Photos", isDirectory: true)
      otherPhotos = root.appendingPathComponent("Other", isDirectory: true)
      suite = "HomeWorkflowTests.\(UUID())"
      defaults = try #require(UserDefaults(suiteName: suite))
      try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: otherPhotos, withIntermediateDirectories: true)
      let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 256, bitsPerPixel: 32))
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      for index in 1...3 {
        try png.write(to: photos.appendingPathComponent("photo-0\(index).png"))
        try png.write(to: otherPhotos.appendingPathComponent("other-0\(index).png"))
      }
    }

    func makeStore() -> AppStore {
      let store = AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: root.appendingPathComponent("marks-\(UUID()).sqlite"))
      stores.append(store)
      return store
    }

    func largePhoto() throws -> URL {
      let folder = root.appendingPathComponent("Large", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let context = try #require(CGContext(data: nil, width: 1_600, height: 1_200,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(CGColor(red: 0.1, green: 0.45, blue: 0.6, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 1_600, height: 1_200))
      context.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.15, alpha: 1))
      context.fill(CGRect(x: 240, y: 180, width: 1_000, height: 700))
      let image = try #require(context.makeImage())
      let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
      let url = folder.appendingPathComponent("synthetic-large.png")
      try data.write(to: url)
      return url
    }

    func archive() throws -> URL {
      // Two synthetic one-pixel PNGs; no external ZIP tool or user photo is needed.
      let encoded = "UEsDBBQAAAAAAF0CN12P/VI7RAAAAEQAAAAGAAAAMDEucG5niVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYIJQSwMEFAAAAAAAXQI3XY/9UjtEAAAARAAAAAYAAAAwMi5wbmeJUE5HDQoaCgAAAA1JSERSAAAAAQAAAAEIBAAAALUcDAIAAAALSURBVHjaY/z/HwADAwIA75ovWwAAAABJRU5ErkJgglBLAQIUAxQAAAAAAF0CN12P/VI7RAAAAEQAAAAGAAAAAAAAAAAAAACAAQAAAAAwMS5wbmdQSwECFAMUAAAAAABdAjddj/1SO0QAAABEAAAABgAAAAAAAAAAAAAAgAFoAAAAMDIucG5nUEsFBgAAAAACAAIAaAAAANAAAAAAAA=="
      let url = root.appendingPathComponent("album.zip")
      try #require(Data(base64Encoded: encoded)).write(to: url)
      return url
    }

    func cleanup() {
      for store in stores {
        store.pauseSlideshow()
        store.folderComparison.cancelLoads()
        store.saveSessionNow()
        store.clearRecentPhotos()
      }
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
