import AppKit
import Testing

@testable import ImageViewer

@Suite("선택한 사진·영상 일괄 분류")
@MainActor
struct BatchPhotoMarkIntegrationTests {
  @Test("다중보기의 선택한 사진·영상에만 키와 패널로 분류를 적용하고 혼합 상태를 통일한다")
  func viewerSelectionUsesMixedAndAllToggleSemantics() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openLibrary(store, fixture: fixture)
    let assets = store.assets
    let image = assets[0]
    let video = try #require(assets.last)
    try #require(video.isVideo)
    store.setImagesPerPage(5)
    store.selectForBatch(index: 4, modifiers: .command)
    let selected = Set([image.url, video.url])
    #expect(store.selectedURLs == selected)
    #expect(Set(store.photoMarkAssets.map(\.url)) == selected)

    // Selecting files is not enough to enter classification mode.
    store.togglePhotoMark(.q)
    #expect(assets.allSatisfy { store.photoMarks.marks(for: $0).isEmpty })
    store.photoMarks.toggle(.q, for: image)
    store.photoMarks.toggle(.w, for: video)
    store.togglePhotoMarking()
    try #require(store.canMarkPhoto)
    #expect(store.photoMarkSelectionState(for: .q) == .mixed)

    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    #expect(store.handleViewerKeyDown(try key(12, characters: "ㅂ"), shortcuts: shortcuts))
    #expect(store.photoMarkSelectionState(for: .q) == .all)
    #expect(store.photoMarks.marks(for: image) == [.q])
    #expect(store.photoMarks.marks(for: video) == [.q, .w])
    #expect(store.handleViewerKeyDown(try key(12, characters: "ㅂ", repeatKey: true), shortcuts: shortcuts))
    #expect(store.photoMarkSelectionState(for: .q) == .all)

    store.togglePhotoMark(.q)
    #expect(store.photoMarkSelectionState(for: .q) == .none)
    #expect(store.photoMarks.marks(for: image).isEmpty)
    #expect(store.photoMarks.marks(for: video) == [.w])
    #expect(assets[1...3].allSatisfy { store.photoMarks.marks(for: $0).isEmpty })
    #expect(store.selectedURLs == selected)
    #expect(store.currentAsset?.url == video.url)
    #expect(store.baseScaleMode == .fit)
  }

  @Test("몽땅보기의 영역 선택을 마친 사진·영상에 함께 분류한다")
  func overviewMarqueeSelectionMarksOnlyCommittedSelection() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openLibrary(store, fixture: fixture)
    let assets = store.assets
    store.presentationMode = .overview
    store.togglePhotoMarking()
    let selected = Set([assets[1].url, assets[2].url, assets[4].url])
    let drag = try #require(store.beginOverviewSelection(modifiers: []))
    store.updateOverviewSelection(drag, hits: selected)
    #expect(store.selectedURLs == selected)
    #expect(!store.canMarkPhoto)
    store.togglePhotoMark(.one)
    #expect(assets.allSatisfy { store.photoMarks.marks(for: $0).isEmpty })

    store.finishOverviewSelection(drag)
    try #require(store.canMarkPhoto)
    #expect(Set(store.photoMarkAssets.map(\.url)) == selected)
    store.togglePhotoMark(.one)
    for asset in assets {
      #expect(store.photoMarks.marks(for: asset) == (selected.contains(asset.url) ? [.one] : []))
    }
    #expect(store.photoMarkSelectionState(for: .one) == .all)
    #expect(store.selectedURLs == selected)
    // The focused first file was outside the marquee and must remain untouched.
    #expect(store.currentAsset?.url == assets[0].url)
    #expect(store.photoMarks.marks(for: assets[0]).isEmpty)
  }

  @Test("선택을 모두 해제하면 현재 사진이 남아 있어도 일괄 분류하지 않는다")
  func clearedSelectionDoesNotFallBackToFocusedAsset() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openLibrary(store, fixture: fixture)
    store.togglePhotoMarking()
    let focused = try #require(store.currentAsset)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)

    for mode in [PresentationMode.viewer, .overview] {
      store.presentationMode = mode
      store.selectAllAssets()
      store.clearSelection()
      #expect(store.currentAsset?.url == focused.url)
      #expect(store.photoMarkAssets.isEmpty && !store.canMarkPhoto)
      #expect(store.photoMarkSelectionState(for: .one) == .none)
      store.togglePhotoMark(.one)
      #expect(store.handleViewerKeyDown(try key(18, characters: "1"), shortcuts: shortcuts))
      #expect(store.assets.allSatisfy { store.photoMarks.marks(for: $0).isEmpty })
    }
  }

  @Test("다중보기에서 선택한 화면 하나라도 이전 프레임이면 전체 일괄 분류를 기다린다")
  func staleSelectedFrameBlocksEntireBatch() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openLibrary(store, fixture: fixture)
    let assets = store.assets
    store.setImagesPerPage(3)
    store.selectForBatch(index: 1, modifiers: .command)
    store.togglePhotoMarking()
    store.beginTrackingViewerPresentation()
    defer { store.endTrackingViewerPresentation() }
    store.recordPresentedAsset(assets[0], slot: 0, requestedAsset: assets[0])
    // Slot 1 retains a previously decoded frame for a different requested file.
    store.recordPresentedAsset(assets[0], slot: 1, requestedAsset: assets[1])
    #expect(!store.canMarkPhoto)
    store.togglePhotoMark(.one)
    #expect(assets.allSatisfy { store.photoMarks.marks(for: $0).isEmpty })

    store.recordPresentedAsset(assets[1], slot: 1, requestedAsset: assets[1])
    // Unselected slot 2 has no presented frame and does not hold up the batch.
    try #require(store.canMarkPhoto)
    store.togglePhotoMark(.one)
    #expect(store.photoMarks.marks(for: assets[0]) == [.one])
    #expect(store.photoMarks.marks(for: assets[1]) == [.one])
    #expect(assets[2...4].allSatisfy { store.photoMarks.marks(for: $0).isEmpty })
  }

  @Test("같은 파일의 하드 링크 두 장을 선택해도 모든 선택 카드의 표시를 확인한다")
  func selectedHardLinksRequireBothVisibleFrames() async throws {
    let fixture = try Fixture()
    let originalURL = fixture.media.appendingPathComponent("photo1.png")
    let linkedURL = fixture.media.appendingPathComponent("photo1_link.png")
    try FileManager.default.linkItem(at: originalURL, to: linkedURL)
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openLibrary(store, fixture: fixture, count: 6)
    store.setImagesPerPage(6)
    let indices = store.assets.indices.filter {
      [originalURL.lastPathComponent, linkedURL.lastPathComponent].contains(store.assets[$0].filename)
    }
    try #require(indices.count == 2)
    store.selectForBatch(index: indices[0], modifiers: [])
    store.selectForBatch(index: indices[1], modifiers: .command)
    let first = store.assets[indices[0]]
    let second = store.assets[indices[1]]
    try #require(first.id != second.id && first.photoMarkID == second.photoMarkID)
    #expect(store.photoMarkAssets.count == 1)
    store.togglePhotoMarking()
    store.beginTrackingViewerPresentation()
    defer { store.endTrackingViewerPresentation() }
    store.recordPresentedAsset(first, slot: indices[0], requestedAsset: first)
    #expect(!store.canMarkPhoto)
    store.togglePhotoMark(.one)
    #expect(store.photoMarks.marks(for: first).isEmpty)

    store.recordPresentedAsset(second, slot: indices[1], requestedAsset: second)
    try #require(store.canMarkPhoto)
    store.togglePhotoMark(.one)
    #expect(store.photoMarks.marks(for: first) == [.one])
    #expect(store.photoMarks.marks(for: second) == [.one])
    store.togglePhotoMark(.one)
    #expect(store.photoMarks.marks(for: first).isEmpty)
    #expect(store.photoMarks.marks(for: second).isEmpty)
  }

  @Test("페이지를 넘어 범위 선택한 파일은 현재 화면이 준비되면 함께 분류한다")
  func rangeSelectionIncludesPreviouslySelectedOffPageAssets() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openLibrary(store, fixture: fixture)
    let assets = store.assets
    store.setImagesPerPage(2)
    store.selectForBatch(index: 4, modifiers: .shift)
    #expect(store.selectedURLs == Set(assets.map(\.url)))
    #expect(store.visibleAssets.map(\.url) == [assets[4].url])
    store.togglePhotoMarking()
    store.beginTrackingViewerPresentation()
    defer { store.endTrackingViewerPresentation() }
    #expect(!store.canMarkPhoto)
    store.recordPresentedAsset(assets[4], slot: 0, requestedAsset: assets[4])
    try #require(store.canMarkPhoto)
    store.togglePhotoMark(.w)
    #expect(assets.allSatisfy { store.photoMarks.marks(for: $0) == [.w] })
    #expect(store.photoMarkSelectionState(for: .w) == .all)
  }

  @Test("분류로 모은 목록의 전체 선택은 해당 목록만 바꾸고 검토가 끝날 때 필터를 갱신한다")
  func filteredCollectionSelectAllKeepsStableReviewTargets() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openLibrary(store, fixture: fixture)
    let originalAssets = store.assets
    let grouped = [originalAssets[1], originalAssets[4]]
    for asset in grouped { store.photoMarks.toggle(.one, for: asset) }
    store.selectAllAssets()
    store.presentationMode = .overview
    store.photoMarkFilter = PhotoMarkFilter(slots: [.one])
    try await ready(store)
    #expect(Set(store.assets.map(\.url)) == Set(grouped.map(\.url)))
    store.selectAllAssets()
    store.togglePhotoMarking()
    store.togglePhotoMark(.w)
    store.togglePhotoMark(.one)
    await Task.yield()
    try await Task.sleep(for: .milliseconds(150))
    #expect(Set(store.assets.map(\.url)) == Set(grouped.map(\.url)))
    #expect(Set(store.photoMarkAssets.map(\.url)) == Set(grouped.map(\.url)))
    #expect(grouped.allSatisfy { store.photoMarks.marks(for: $0) == [.w] })
    #expect(originalAssets.filter { !grouped.contains($0) }.allSatisfy {
      store.photoMarks.marks(for: $0).isEmpty
    })

    store.togglePhotoMarking()
    try await ready(store)
    #expect(store.assets.isEmpty && store.photoMarkAssets.isEmpty)
    store.resetLibraryQuery()
    try await ready(store)
    #expect(store.assets.count == 5)
  }

  @Test("개별 카드 분류는 다른 선택 항목과 초점을 바꾸지 않는다")
  func cardActionRemainsIndependentOfBatchSelection() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openLibrary(store, fixture: fixture)
    let assets = store.assets
    store.setImagesPerPage(5)
    store.selectForBatch(index: 4, modifiers: .command)
    let selection = store.selectedURLs
    let focused = store.currentAsset?.url
    store.togglePhotoMarking()
    store.togglePhotoMark(.q, for: assets[2])
    #expect(store.photoMarks.marks(for: assets[2]) == [.q])
    #expect(store.selectedAssets.allSatisfy { store.photoMarks.marks(for: $0).isEmpty })
    #expect(store.selectedURLs == selection && store.currentAsset?.url == focused)
    store.togglePhotoMark(.w)
    #expect(store.selectedAssets.allSatisfy { store.photoMarks.marks(for: $0) == [.w] })
    #expect(store.photoMarks.marks(for: assets[2]) == [.q])
  }

  @Test("일괄 분류는 재실행해도 유지되고 이미지와 영상의 원본 바이트는 보존한다")
  func batchMarksPersistWithoutChangingOriginalFiles() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openLibrary(store, fixture: fixture)
    let originals = try Dictionary(uniqueKeysWithValues: store.assets.map {
      ($0.filename, try Data(contentsOf: $0.url))
    })
    store.presentationMode = .overview
    store.selectForBatch(index: 4, modifiers: .command)
    let names = Set(store.selectedAssets.map(\.filename))
    store.togglePhotoMarking()
    store.togglePhotoMark(.one)
    store.togglePhotoMark(.r)
    store.saveSessionNow()
    try #require(store.photoMarks.errorMessage == nil)

    let reopened = fixture.makeStore()
    defer { reopened.folderComparison.cancelLoads(); reopened.saveSessionNow() }
    try await openLibrary(reopened, fixture: fixture)
    for asset in reopened.assets {
      #expect(reopened.photoMarks.marks(for: asset) == (names.contains(asset.filename) ? [.one, .r] : []))
      #expect(try Data(contentsOf: asset.url) == originals[asset.filename])
    }
  }

  private func openLibrary(_ store: AppStore, fixture: Fixture, count: Int = 5) async throws {
    await store.photoMarks.waitUntilReady()
    try #require(store.photoMarks.isReady)
    store.showsVideos = true
    store.open(urls: [fixture.media])
    try await ready(store)
    try #require(store.assets.count == count && store.alert == nil)
  }

  private func ready(_ store: AppStore) async throws {
    for _ in 0..<500 {
      if !store.isLoading && !store.isFiltering { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.loadingTimedOut
  }

  private func key(_ code: UInt16, characters: String = "", repeatKey: Bool = false) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, characters: characters,
      charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: code))
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
    let media: URL
    let database: URL
    let suite: String
    let defaults: UserDefaults

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("BatchPhotoMark-\(UUID())")
      media = root.appendingPathComponent("Media")
      database = root.appendingPathComponent("marks.sqlite")
      suite = "BatchPhotoMark.\(UUID())"
      defaults = try #require(UserDefaults(suiteName: suite))
      let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
      for index in 1...4 { try png.write(to: media.appendingPathComponent("photo\(index).png")) }
      // This suite exercises selection, identity, and persistence without playback.
      try Data("Synthetic classification video".utf8).write(to: media.appendingPathComponent("video.mp4"))
    }

    @MainActor func makeStore() -> AppStore {
      AppStore(defaults: defaults, monitorsSystemResources: false, photoMarkDatabaseURL: database)
    }
  }
}
