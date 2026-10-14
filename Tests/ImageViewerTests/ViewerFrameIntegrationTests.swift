import AppKit
import Testing

@testable import ImageViewer

@Suite("다중보기 프레임과 사진·영상 상태의 통합")
@MainActor
struct ViewerFrameIntegrationTests {
  @Test("프레임 위치를 바꿔도 실제 표시 확인과 분류는 원래 파일 슬롯을 따른다")
  func movingFramesKeepsPresentationAndClassificationIdentity() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.store
    try await fixture.open()
    store.isPhotoMarking = true
    store.beginTrackingViewerPresentation()
    defer { store.endTrackingViewerPresentation() }
    let firstPage = store.visibleAssets
    let photo = firstPage[0]
    let video = firstPage[3]
    for slot in 1..<firstPage.count {
      store.recordPresentedAsset(firstPage[slot], slot: slot, requestedAsset: firstPage[slot])
    }
    let selection = store.selectedURLs
    store.frameLayout.swap(0, with: 3, count: 4)
    #expect(store.visibleAssets == firstPage)
    #expect(store.currentAsset?.id == photo.id && store.selectedURLs == selection)
    #expect(store.canMarkPhoto(video))
    #expect(!store.canMarkPhoto(photo))

    // Moving the photo to visual position 3 does not make source slot 3 its
    // decoder identity. A wrongly routed or late completion must be rejected.
    store.recordPresentedAsset(photo, slot: 3, requestedAsset: photo)
    store.togglePhotoMark(.q, for: photo)
    #expect(store.photoMarks.marks(for: photo).isEmpty)
    #expect(store.canMarkPhoto(video))
    store.recordPresentedAsset(photo, slot: 0, requestedAsset: photo)
    store.togglePhotoMark(.q, for: photo)
    store.togglePhotoMark(.w, for: video)
    #expect(store.photoMarks.marks(for: photo) == [.q])
    #expect(store.photoMarks.marks(for: video) == [.w])
    #expect(firstPage[1...2].allSatisfy { store.photoMarks.marks(for: $0).isEmpty })

    store.navigatePage(1)
    let nextPhoto = try #require(store.visibleAssets.first)
    try #require(nextPhoto.id != photo.id)
    store.recordPresentedAsset(photo, slot: 0, requestedAsset: photo)
    #expect(!store.canMarkPhoto(nextPhoto))
    store.togglePhotoMark(.e, for: nextPhoto)
    #expect(store.photoMarks.marks(for: nextPhoto).isEmpty)
    store.recordPresentedAsset(nextPhoto, slot: 0, requestedAsset: nextPhoto)
    store.togglePhotoMark(.e, for: nextPhoto)
    #expect(store.photoMarks.marks(for: nextPhoto) == [.e])
    #expect(store.photoMarks.marks(for: photo) == [.q])
  }

  @Test("경계 크기와 위치 변경은 확대·선택·페이지·영상 재생 및 소리 대상을 보존한다")
  func resizingKeepsViewerAndVideoCommands() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.store
    try await fixture.open()
    store.selectForBatch(index: 0, modifiers: [])
    store.selectForBatch(index: 1, modifiers: .command)
    store.zoom = 2.5
    store.panOffset = CGSize(width: 17, height: -9)
    let visible = store.visibleAssets
    let videos = visible.filter(\.isVideo)
    try #require(videos.count == 2)
    store.videoGridPlayback.updateVisibleAssets(visible)
    store.videoGridPlayback.toggleSelection(videos[0].id)
    store.videoGridPlayback.playAll()
    store.videoGridPlayback.toggleSound(videos[0].id)
    let commands = videos.map { store.videoGridPlayback.command(for: $0.id) }
    let selection = store.selectedURLs
    let current = store.currentAsset?.id
    let pan = store.panOffset
    let page = store.pageStartIndex
    let revision = store.libraryRevision
    let size = CGSize(width: 1_200, height: 800)
    let initial = store.frameLayout.configuration(for: 4)
    let before = store.frameLayout.geometry(for: 4, in: size)
    let divider = try #require(before.dividers.first)
    let resized = initial.resizing(divider,
      translation: CGSize(width: 120, height: 90), in: size)
    store.frameLayout.commit(resized, count: 4)
    let after = store.frameLayout.geometry(for: 4, in: size)
    #expect(before.frames.map(\.rect) != after.frames.map(\.rect))
    store.frameLayout.swap(0, with: 3, count: 4)
    store.videoGridPlayback.updateVisibleAssets(store.visibleAssets)

    #expect(store.visibleAssets == visible && store.libraryRevision == revision)
    #expect(store.selectedURLs == selection && store.currentAsset?.id == current)
    #expect(store.pageStartIndex == page && store.imagesPerPage == 4)
    #expect(store.zoom == 2.5 && store.panOffset == pan)
    #expect(store.videoGridPlayback.selectedIDs == [videos[0].id])
    #expect(store.videoGridPlayback.playingIDs == Set(videos.map(\.id)))
    #expect(store.videoGridPlayback.audioID == videos[0].id)
    #expect(videos.map { store.videoGridPlayback.command(for: $0.id) } == commands)
    #expect(store.presentationMode == .viewer && !store.isVideoFullScreenPresented)
  }

  @Test("프레임 재배치 후 위아래 키는 화면 위치를 따르고 원본 순서와 페이지는 보존한다",
    arguments: [false, true])
  func verticalNavigationFollowsMovedFrame(marking: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.store
    try await fixture.open()
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    let originalOrder = store.assets.map(\.id)
    store.frameLayout.swap(0, with: 3, count: 4)
    store.isPhotoMarking = marking
    for page in [0, 4] {
      if page > 0 { store.navigatePage(1) }
      store.select(index: page)
      #expect(store.handleViewerKeyDown(try key(126), shortcuts: shortcuts))
      #expect(store.currentIndex == page + 1 && store.pageStartIndex == page)
      #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
      #expect(store.currentIndex == page && store.pageStartIndex == page)
      store.select(index: page + 3)
      #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
      #expect(store.currentIndex == page + 2 && store.pageStartIndex == page)
      #expect(store.handleViewerKeyDown(try key(126), shortcuts: shortcuts))
      #expect(store.currentIndex == page + 3 && store.pageStartIndex == page)
    }
    #expect(store.assets.map(\.id) == originalOrder)
    #expect(store.photoMarks.marksByAssetID.isEmpty)
    #expect(store.videoGridPlayback.playingIDs.isEmpty)
  }

  @Test("프레임 편집 중 조작은 사진을 바꾸지 않고 Escape는 편집만 종료한다")
  func editingOwnsInputAndEscapePreservesOtherModes() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.store
    try await fixture.open()
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.isPhotoMarking = true
    store.isFocusMode = true
    store.zoom = 2
    store.panOffset = CGSize(width: 12, height: -6)
    store.panInteractionMode = .spacePrimaryDrag
    store.frameLayout.isEditing = true
    let current = store.currentAsset?.id
    let selected = store.selectedURLs
    let pan = store.panOffset
    #expect(store.isEditingViewerFrames && !store.canPan && !store.canToggleImageFocus)
    for code in [UInt16(12), 49, 123, 124, 125, 126] {
      #expect(!store.handleViewerKeyDown(try key(code), shortcuts: shortcuts))
    }
    #expect(!store.handleViewerKeyDown(try key(124, modifiers: .option), shortcuts: shortcuts))
    #expect(!store.handlePanInput(.spacePrimaryDrag, delta: CGSize(width: 50, height: 10)))
    store.toggleImageFocus(on: store.assets[1])
    #expect(store.currentAsset?.id == current && store.selectedURLs == selected)
    #expect(store.zoom == 2 && store.panOffset == pan && store.pageStartIndex == 0)
    #expect(store.photoMarks.marksByAssetID.isEmpty)

    #expect(store.handleViewerKeyDown(try key(53), shortcuts: shortcuts))
    #expect(!store.frameLayout.isEditing && !store.isEditingViewerFrames)
    #expect(store.isFocusMode && store.isPhotoMarking && store.presentationMode == .viewer)
    #expect(store.currentAsset?.id == current && store.selectedURLs == selected)
    #expect(store.zoom == 2 && store.panOffset == pan)

    store.frameLayout.isEditing = true
    store.setImagesPerPage(3)
    #expect(!store.frameLayout.isEditing)
    store.frameLayout.isEditing = true
    store.presentationMode = .overview
    #expect(!store.frameLayout.isEditing && !store.isEditingViewerFrames)
  }

  private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: code))
  }

  @MainActor private struct Fixture {
    let root: URL
    let media: URL
    let suite = "ViewerFrameIntegrationTests.\(UUID())"
    let defaults: UserDefaults
    let store: AppStore

    init() throws {
      defaults = try #require(UserDefaults(suiteName: suite))
      root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
      media = root.appendingPathComponent("Media", isDirectory: true)
      try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
      let qoi = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
        0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
      for index in 0..<8 {
        // These tests exercise library identity and playback commands. Actual
        // decoding remains covered by the video controller and native tests.
        let video = [2, 3].contains(index)
        let name = String(format: "item%02d.%@", index, video ? "mp4" : "qoi")
        try (video ? Data("Synthetic frame video".utf8) : qoi)
          .write(to: media.appendingPathComponent(name))
      }
      store = AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: root.appendingPathComponent("marks.sqlite"))
    }

    func open() async throws {
      await store.photoMarks.waitUntilReady()
      store.open(urls: [media])
      let deadline = ContinuousClock.now + .seconds(8)
      while store.isLoading || store.isFiltering {
        try #require(ContinuousClock.now < deadline, "Frame integration fixture did not load")
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(store.assets.count == 8 && store.alert == nil)
      store.setImagesPerPage(4)
    }

    func cleanup() {
      store.endTrackingViewerPresentation()
      store.videoGridPlayback.reset()
      store.folderComparison.cancelLoads()
      store.photoMarks.flush()
      store.saveSessionNow()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
