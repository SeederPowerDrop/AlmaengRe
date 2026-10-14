import AppKit
import Testing

@testable import ImageViewer

@Suite("격자의 위아래 행 탐색")
@MainActor
struct GridRowNavigationTests {
  @Test("없는 행에서는 머물고 짧은 마지막 행에 들어갈 때만 끝 카드로 맞춘다")
  func rowTargetsAndBounds() {
    let cases: [(from: Int, direction: Int, count: Int, columns: Int, expected: Int)] = [
      (0, -1, 10, 3, 0), (1, -1, 10, 3, 1), (2, -1, 10, 3, 2),
      (1, 1, 10, 3, 4), (4, -1, 10, 3, 1),
      (7, 1, 10, 3, 9), (8, 1, 10, 3, 9), (9, 1, 10, 3, 9),
      (9, -1, 10, 3, 6),
      (6, 1, 8, 3, 6), (7, 1, 8, 3, 7),
      (1, 1, 2, 5, 1), (1, -1, 2, 5, 1),
      (1, 1, 3, 1, 2), (1, -1, 3, 1, 0),
      (4, 0, 10, 3, 4), (0, 1, 0, 3, 0),
    ]
    for item in cases {
      #expect(GridRowNavigation.target(from: item.from, direction: item.direction,
        count: item.count, columns: item.columns) == item.expected)
    }
  }

  @Test("여러 장 뷰어는 페이지 시작을 기준으로 행을 이동하고 프레임 열 수 변경을 따른다", arguments: [false, true])
  func viewerUsesVisiblePageAndConfiguredColumns(marking: Bool) async throws {
    let fixture = try Fixture(count: 23)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await open(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(7)
    store.navigatePage(1)
    try #require(store.pageStartIndex == 7)
    store.frameLayout.setColumns(3, count: 7)
    store.isPhotoMarking = marking
    store.select(index: 8) // Visible slot 1, despite global index 8.

    #expect(store.handleViewerKeyDown(try key(126), shortcuts: shortcuts))
    #expect(store.currentIndex == 8 && store.pageStartIndex == 7)
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
    #expect(store.currentIndex == 11 && store.pageStartIndex == 7)
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
    #expect(store.currentIndex == 13 && store.pageStartIndex == 7)
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
    #expect(store.currentIndex == 13 && store.pageStartIndex == 7)
    #expect(store.handleViewerKeyDown(try key(126), shortcuts: shortcuts))
    // The last row's sole frame spans the whole width. Moving up selects
    // the center frame immediately above it, rather than the source ordinal.
    #expect(store.currentIndex == 11 && store.pageStartIndex == 7)

    store.select(index: 8)
    store.frameLayout.setColumns(4, count: 7)
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
    #expect(store.currentIndex == 12 && store.pageStartIndex == 7)
    #expect(store.handleViewerKeyDown(try key(126), shortcuts: shortcuts))
    #expect(store.currentIndex == 8 && store.pageStartIndex == 7)
    #expect(store.selectedURLs == [store.assets[8].url])
    #expect(store.photoMarks.marksByAssetID.isEmpty)
  }

  @Test("행 끝에서는 확대와 이동을 유지하고 Option 좌우는 계속 화면을 넘긴다", arguments: [false, true])
  func blockedRowPreservesViewportAndOptionPaging(marking: Bool) async throws {
    let fixture = try Fixture(count: 23)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await open(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(7)
    store.frameLayout.setColumns(3, count: 7)
    store.isPhotoMarking = marking
    store.select(index: 1)
    store.zoom = 2
    store.panOffset = CGSize(width: 18, height: -24)
    #expect(store.handleViewerKeyDown(try key(126), shortcuts: shortcuts))
    #expect(store.currentIndex == 1 && store.pageStartIndex == 0)
    #expect(store.zoom == 2 && store.panOffset == CGSize(width: 18, height: -24))

    store.select(index: 6)
    store.zoom = 2
    store.panOffset = CGSize(width: -14, height: 12)
    store.wrapsNavigation = true
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
    #expect(store.currentIndex == 6 && store.pageStartIndex == 0)
    #expect(store.zoom == 2 && store.panOffset == CGSize(width: -14, height: 12))
    #expect(store.handleViewerKeyDown(try key(124, modifiers: .option), shortcuts: shortcuts))
    #expect(store.currentIndex == 7 && store.pageStartIndex == 7)
    #expect(store.handleViewerKeyDown(try key(123, modifiers: .option), shortcuts: shortcuts))
    #expect(store.currentIndex == 0 && store.pageStartIndex == 0)
  }

  @Test("사진과 영상이 섞인 몽땅보기에서도 분류 중 위아래는 같은 열의 항목을 고른다")
  func mixedMediaUsesRowsWithoutTaggingOrPlaying() async throws {
    let fixture = try Fixture(count: 10, videoIndices: [4, 7])
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await open(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.presentationMode = .overview
    store.overviewColumnCount = 3
    store.isPhotoMarking = true
    store.select(index: 1)
    try #require(store.assets[4].isVideo && store.assets[7].isVideo)
    for expected in [4, 7, 9] {
      #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
      #expect(store.currentIndex == expected)
      #expect(store.selectedURLs == [store.assets[expected].url])
    }
    #expect(store.motionMediaAsset == nil && !store.isVideoFullScreenPresented)
    #expect(store.photoMarks.marksByAssetID.isEmpty)
  }

  @Test("기본 보기에서는 사용자 지정 위아래가 우선하고 분류 중에는 행 선택이 우선한다")
  func shortcutPriorityAndModifierScope() async throws {
    let fixture = try Fixture(count: 10)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await open(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(7)
    store.frameLayout.setColumns(3, count: 7)
    shortcuts.setBinding(KeyBinding(key: "down"), for: .zoomIn)
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
    #expect(store.currentIndex == 0 && store.zoom > 1)
    store.isPhotoMarking = true
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
    #expect(store.currentIndex == 3 && store.pageStartIndex == 0)
    let modifiers: [NSEvent.ModifierFlags] = [.option, .shift, .command, .control]
    for modifier in modifiers {
      _ = store.handleViewerKeyDown(try key(125, modifiers: modifier), shortcuts: shortcuts)
      #expect(store.currentIndex == 3 && store.pageStartIndex == 0)
    }
  }

  @Test("분류 중 한 장 뷰어의 위아래는 이전과 다음 항목 이동을 유지한다")
  func singleImageMarkingKeepsSequentialNavigation() async throws {
    let fixture = try Fixture(count: 10)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await open(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.isPhotoMarking = true
    store.frameLayout.setColumns(4, count: 7) // A saved multi-image layout must not affect single mode.
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
    #expect(store.currentIndex == 1 && store.pageStartIndex == 1)
    #expect(store.handleViewerKeyDown(try key(126), shortcuts: shortcuts))
    #expect(store.currentIndex == 0 && store.pageStartIndex == 0)
  }

  private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: code))
  }

  private func open(_ store: AppStore, fixture: Fixture) async throws {
    await store.photoMarks.waitUntilReady()
    store.open(urls: [fixture.folder])
    let deadline = ContinuousClock.now + .seconds(8)
    while store.isLoading || store.isFiltering {
      try #require(ContinuousClock.now < deadline, "The grid fixture did not finish loading")
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(store.assets.count == fixture.count && store.alert == nil)
  }

  private struct Fixture {
    let folder: URL
    let defaults: UserDefaults
    let count: Int
    let suite = "GridRowNavigationTests-\(UUID())"

    init(count: Int, videoIndices: Set<Int> = []) throws {
      self.count = count
      defaults = try #require(UserDefaults(suiteName: suite))
      folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let qoi = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
        0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
      for index in 0..<count {
        // Invalid video bytes deliberately test library navigation independently of playback readiness.
        let ext = videoIndices.contains(index) ? "mp4" : "qoi"
        let data = videoIndices.contains(index) ? Data("Synthetic video list fixture".utf8) : qoi
        try data.write(to: folder.appendingPathComponent(String(format: "item%02d.%@", index, ext)))
      }
    }

    @MainActor func makeStore() -> AppStore {
      AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: folder.appendingPathComponent("marks.sqlite"))
    }

    @MainActor func cleanup(_ store: AppStore) {
      store.folderComparison.cancelLoads()
      store.saveSessionNow()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }
  }
}
