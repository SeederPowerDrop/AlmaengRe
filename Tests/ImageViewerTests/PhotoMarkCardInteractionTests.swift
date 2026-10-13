import AppKit
import Testing

@testable import ImageViewer

@Suite("사진·영상 카드에서 직접 분류")
@MainActor
struct PhotoMarkCardInteractionTests {
  @Test("사진과 영상 카드의 12개 분류는 분류 모드를 켠 동안에만 바뀐다",
    arguments: [ImageViewer.PresentationMode.viewer, .overview])
  func cardMarksRequireEnabledMode(mode: ImageViewer.PresentationMode) async throws {
    let fixture = try Fixture()
    let store = fixture.store
    defer { fixture.cleanup() }
    try await open(fixture)
    store.presentationMode = mode
    let targets = [store.assets[0], store.assets[2]]
    let originalBytes = try targets.map { try Data(contentsOf: $0.url) }
    try #require(!targets[0].isVideo && targets[1].isVideo)

    for asset in targets {
      #expect(!store.canMarkPhoto(asset))
      for slot in PhotoMarkSlot.allCases { store.togglePhotoMark(slot, for: asset) }
      #expect(store.photoMarks.marks(for: asset).isEmpty)
    }

    store.togglePhotoMarking()
    try #require(store.isPhotoMarking)
    for asset in targets {
      try #require(store.canMarkPhoto(asset))
      for slot in PhotoMarkSlot.allCases { store.togglePhotoMark(slot, for: asset) }
      #expect(store.photoMarks.marks(for: asset) == Set(PhotoMarkSlot.allCases))
      // Removing one classification must preserve all other memberships.
      store.togglePhotoMark(.q, for: asset)
      #expect(store.photoMarks.marks(for: asset) == Set(PhotoMarkSlot.allCases).subtracting([.q]))
    }

    store.togglePhotoMarking()
    try #require(!store.isPhotoMarking)
    for (index, asset) in targets.enumerated() {
      #expect(!store.canMarkPhoto(asset))
      store.togglePhotoMark(.q, for: asset)
      store.togglePhotoMark(.one, for: asset)
      #expect(store.photoMarks.marks(for: asset) == Set(PhotoMarkSlot.allCases).subtracting([.q]))
      #expect(try Data(contentsOf: asset.url) == originalBytes[index])
    }
  }

  @Test("카드 분류는 현재 선택이나 다중 선택 대신 누른 파일만 바꾸며 보기를 유지한다",
    arguments: [ImageViewer.PresentationMode.viewer, .overview])
  func exactCardDoesNotChangeSelectionOrViewport(mode: ImageViewer.PresentationMode) async throws {
    let fixture = try Fixture()
    let store = fixture.store
    defer { fixture.cleanup() }
    try await open(fixture)
    store.presentationMode = mode
    store.selectForBatch(index: 0, modifiers: [])
    store.selectForBatch(index: 1, modifiers: .command)
    let targets = [store.assets[0], store.assets[2]]
    let current = try #require(store.currentAsset)
    try #require(!targets.contains { $0.id == current.id })
    try #require(store.selectedURLs.count == 2)
    store.togglePhotoMarking()
    store.baseScaleMode = .actualPixels
    store.zoom = 2.5
    store.panOffset = CGSize(width: 13, height: -7)
    let selection = store.selectedURLs
    let page = store.pageStartIndex
    let pan = store.panOffset
    let revision = store.libraryRevision

    for asset in targets {
      try #require(store.canMarkPhoto(asset))
      store.togglePhotoMark(.w, for: asset)
      #expect(store.photoMarks.marks(for: asset) == [.w])
    }
    #expect(store.photoMarks.marks(for: current).isEmpty)
    #expect(store.currentAsset?.id == current.id && store.selectedURLs == selection)
    #expect(store.pageStartIndex == page && store.imagesPerPage == 3)
    #expect(store.presentationMode == mode && !store.isFocusMode && !store.isVideoFullScreenPresented)
    #expect(store.baseScaleMode == .actualPixels && store.zoom == 2.5 && store.panOffset == pan)
    #expect(store.libraryRevision == revision)
  }

  @Test("메뉴가 열린 뒤 정렬 순서가 바뀌어도 원래 카드의 파일을 분류한다")
  func sortingDoesNotRetargetCardAction() async throws {
    let fixture = try Fixture()
    let store = fixture.store
    defer { fixture.cleanup() }
    try await open(fixture)
    store.presentationMode = .overview
    let target = store.assets[0]
    store.togglePhotoMarking()
    store.libraryQuery.sort = .nameDescending
    try await ready(store)
    try #require(store.assets.last?.id == target.id)
    let current = store.currentAsset?.id
    let selection = store.selectedURLs

    store.togglePhotoMark(.d, for: target)
    #expect(store.photoMarks.marks(for: target) == [.d])
    #expect(store.assets.filter { $0.id != target.id }.allSatisfy { store.photoMarks.marks(for: $0).isEmpty })
    #expect(store.currentAsset?.id == current && store.selectedURLs == selection)
  }

  @Test("여러 장 보기에서 실제 표시가 끝난 카드만 분류하고 이전 프레임 응답은 무시한다")
  func eachCardRequiresItsOwnCurrentPresentation() async throws {
    let fixture = try Fixture()
    let store = fixture.store
    defer { fixture.cleanup() }
    try await open(fixture)
    let photo = store.assets[0]
    let previousFrame = store.assets[1]
    let video = store.assets[2]
    store.togglePhotoMarking()
    store.beginTrackingViewerPresentation()
    defer { store.endTrackingViewerPresentation() }
    store.recordPresentedAsset(photo, slot: 0, requestedAsset: photo)
    store.recordPresentedAsset(nil, slot: 2, requestedAsset: video)
    try #require(store.canMarkPhoto(photo))
    #expect(!store.canMarkPhoto(video))
    store.togglePhotoMark(.one, for: video)
    store.togglePhotoMark(.one, for: photo)
    #expect(store.photoMarks.marks(for: video).isEmpty)
    #expect(store.photoMarks.marks(for: photo) == [.one])

    // A retained frame from another file, or an old version at the same path,
    // cannot prove that this card's requested file has reached the screen.
    store.recordPresentedAsset(previousFrame, slot: 2, requestedAsset: video)
    #expect(!store.canMarkPhoto(video))
    let oldVersion = ImageAsset(url: video.url, byteCount: (video.byteCount ?? 0) + 1,
      modificationDate: (video.modificationDate ?? .distantPast).addingTimeInterval(-1),
      photoMarkIdentity: video.photoMarkIdentity)
    store.recordPresentedAsset(oldVersion, slot: 2, requestedAsset: video)
    #expect(!store.canMarkPhoto(video))
    store.togglePhotoMark(.w, for: video)
    #expect(store.photoMarks.marks(for: video).isEmpty)

    store.recordPresentedAsset(video, slot: 2, requestedAsset: video)
    try #require(store.canMarkPhoto(video))
    store.togglePhotoMark(.w, for: video)
    #expect(store.photoMarks.marks(for: video) == [.w])
    #expect(store.photoMarks.marks(for: photo) == [.one])
    #expect(store.photoMarks.marks(for: previousFrame).isEmpty)

    // Changing the visible page invalidates a callback from its former slot.
    store.setImagesPerPage(1)
    store.recordPresentedAsset(video, slot: 2, requestedAsset: video)
    #expect(!store.canMarkPhoto(video))
    store.togglePhotoMark(.w, for: video)
    #expect(store.photoMarks.marks(for: video) == [.w])
  }

  @Test("필터 또는 폴더 전환으로 사라진 카드의 오래된 조작은 다른 파일을 바꾸지 않는다",
    arguments: [false, true])
  func staleCardActionCannotMarkReplacement(changeFolder: Bool) async throws {
    let fixture = try Fixture()
    let store = fixture.store
    defer { fixture.cleanup() }
    try await open(fixture)
    store.presentationMode = .overview
    let stale = store.assets[0]
    store.togglePhotoMarking()
    if changeFolder { store.openFolderFromTree(fixture.other) }
    else { store.libraryQuery.searchText = "02-photo" }
    // Even before the asynchronous replacement commits, a retained card must
    // not write into the library while its target list is being replaced.
    #expect(!store.canMarkPhoto(stale))
    store.togglePhotoMark(.one, for: stale)
    try await ready(store)
    try #require(store.assets.count == 1 && store.currentAsset?.id != stale.id)
    try #require(store.isPhotoMarking)
    let replacement = try #require(store.currentAsset)
    let selection = store.selectedURLs

    #expect(!store.canMarkPhoto(stale))
    store.togglePhotoMark(.q, for: stale)
    #expect(store.photoMarks.marks(for: stale).isEmpty)
    #expect(store.photoMarks.marks(for: replacement).isEmpty)
    #expect(store.currentAsset?.id == replacement.id && store.selectedURLs == selection)
  }

  @Test("영상 표시를 끈 뒤 오래된 영상 카드로 분류할 수 없으며 기존 분류는 유지된다")
  func hiddenVideoRejectsStaleActionWithoutLosingMarks() async throws {
    let fixture = try Fixture()
    let store = fixture.store
    defer { fixture.cleanup() }
    try await open(fixture)
    store.presentationMode = .overview
    let video = try #require(store.assets.first { $0.isVideo })
    store.togglePhotoMarking()
    store.togglePhotoMark(.one, for: video)
    store.showsVideos = false
    try await ready(store)
    try #require(!store.assets.contains { $0.id == video.id })
    #expect(!store.canMarkPhoto(video))
    store.togglePhotoMark(.one, for: video)
    store.togglePhotoMark(.w, for: video)
    #expect(store.photoMarks.marks(for: video) == [.one])
    store.showsVideos = true
    try await ready(store)
    let restored = try #require(store.assets.first { $0.isVideo })
    #expect(store.photoMarks.marks(for: restored) == [.one])
  }

  @Test("카드 분류 중에는 필터 목록을 유지하고 모드를 끄면 최신 결과를 반영한다")
  func filteredCardsStayStableUntilMarkingEnds() async throws {
    let fixture = try Fixture()
    let store = fixture.store
    defer { fixture.cleanup() }
    try await open(fixture)
    store.presentationMode = .overview
    store.photoMarkFilter = PhotoMarkFilter(unmarkedOnly: true)
    try await ready(store)
    let before = store.assets.map(\.id)
    let target = try #require(store.assets.first { $0.isVideo })
    let current = store.currentAsset?.id
    let selection = store.selectedURLs
    let revision = store.libraryRevision
    store.togglePhotoMarking()
    store.togglePhotoMark(.r, for: target)
    // Allow the real Combine revision subscriber to handle the write. It must
    // defer the filter, rather than merely leave it unchanged synchronously.
    await Task.yield()
    try await Task.sleep(for: .milliseconds(150))
    #expect(store.assets.map(\.id) == before && store.libraryRevision == revision)
    #expect(store.currentAsset?.id == current && store.selectedURLs == selection)
    #expect(store.photoMarks.marks(for: target) == [.r])

    store.togglePhotoMarking()
    try await ready(store)
    #expect(store.assets.map(\.id) == before.filter { $0 != target.id })
    #expect(store.allAssets.count == 3 && store.photoMarks.marks(for: target) == [.r])
    #expect(FileManager.default.fileExists(atPath: target.url.path))
  }

  @Test("시트·경고·드래그 선택·홈에서는 남아 있는 카드 조작을 적용하지 않는다")
  func cardMutationRespectsInteractionGuards() async throws {
    let fixture = try Fixture()
    let store = fixture.store
    defer { fixture.cleanup() }
    try await open(fixture)
    store.presentationMode = .overview
    let target = try #require(store.assets.first { $0.isVideo })
    store.togglePhotoMarking()
    try #require(store.canMarkPhoto(target))

    let blockers: [ReferenceWritableKeyPath<AppStore, Bool>] = [
      \.showsPhotoMarkEditor, \.showsPhotoMarkTrackingReport, \.showsAIUpscaling,
    ]
    for blocker in blockers {
      store[keyPath: blocker] = true
      #expect(!store.canMarkPhoto(target))
      store.togglePhotoMark(.a, for: target)
      store[keyPath: blocker] = false
      #expect(store.photoMarks.marks(for: target).isEmpty)
    }
    store.batchSheet = .rename
    #expect(!store.canMarkPhoto(target))
    store.togglePhotoMark(.a, for: target)
    store.batchSheet = nil
    store.motionMediaAsset = target
    #expect(!store.canMarkPhoto(target))
    store.togglePhotoMark(.a, for: target)
    store.motionMediaAsset = nil
    store.alert = ViewerAlert(title: "Synthetic test", message: "Interaction paused")
    #expect(!store.canMarkPhoto(target))
    store.togglePhotoMark(.a, for: target)
    store.alert = nil
    let drag = try #require(store.beginOverviewSelection(modifiers: []))
    #expect(!store.canMarkPhoto(target))
    store.togglePhotoMark(.a, for: target)
    store.finishOverviewSelection(drag)
    #expect(store.photoMarks.marks(for: target).isEmpty)

    store.showHome()
    try #require(store.showsHome)
    #expect(!store.canMarkPhoto(target))
    store.togglePhotoMark(.a, for: target)
    #expect(store.photoMarks.marks(for: target).isEmpty)
    await store.resumeWorkspace()
    try #require(!store.showsHome && store.isPhotoMarking)
    #expect(store.canMarkPhoto(target))
    store.togglePhotoMark(.a, for: target)
    #expect(store.photoMarks.marks(for: target) == [.a])
  }

  private func open(_ fixture: Fixture) async throws {
    await fixture.store.photoMarks.waitUntilReady()
    try #require(fixture.store.photoMarks.isReady)
    fixture.store.open(urls: [fixture.mixed])
    try await ready(fixture.store)
    try #require(fixture.store.alert == nil && fixture.store.assets.count == 3)
    fixture.store.setImagesPerPage(3)
  }

  private func ready(_ store: AppStore) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while store.isLoading || store.isFiltering {
      guard ContinuousClock.now < deadline else { throw FixtureError.loadingTimedOut }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private enum FixtureError: Error { case loadingTimedOut }

  @MainActor private struct Fixture {
    let root: URL
    let mixed: URL
    let other: URL
    let suite: String
    let defaults: UserDefaults
    let store: AppStore

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoMarkCards-\(UUID())")
      mixed = root.appendingPathComponent("Mixed", isDirectory: true)
      other = root.appendingPathComponent("Other", isDirectory: true)
      suite = "PhotoMarkCards.\(UUID())"
      defaults = try #require(UserDefaults(suiteName: suite))
      try FileManager.default.createDirectory(at: mixed, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
      let png = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII="))
      for name in ["01-photo.png", "02-photo.png"] { try png.write(to: mixed.appendingPathComponent(name)) }
      try png.write(to: other.appendingPathComponent("01-photo.png"))
      // Classification uses file identity and never needs video decoding.
      try Data("Synthetic classification video".utf8).write(to: mixed.appendingPathComponent("03-video.mp4"))
      store = AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: root.appendingPathComponent("marks.sqlite"))
    }

    func cleanup() {
      store.folderComparison.cancelLoads()
      store.saveSessionNow()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
