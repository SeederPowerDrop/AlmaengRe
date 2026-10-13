import AppKit
import Testing

@testable import ImageViewer

@Suite("여러 장 보기의 방향키와 Option 페이지 단축키")
@MainActor
struct ViewerPageShortcutTests {
  @Test("분류 중에도 기본 좌우와 Option 좌우는 선택한 카드가 아닌 화면을 기준으로 넘긴다")
  func sevenPhotoPagesAndMarkingFocus() async throws {
    let fixture = try Fixture(count: 23)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(7)
    #expect(store.pageStartIndex == 0 && store.visibleAssets.count == 7)

    #expect(store.handleViewerKeyDown(try key(124, modifiers: .option), shortcuts: shortcuts))
    expectPage(store, start: 7, visibleCount: 7)
    #expect(store.handleViewerKeyDown(try key(123, modifiers: .option), shortcuts: shortcuts))
    expectPage(store, start: 0, visibleCount: 7)

    store.isPhotoMarking = true
    store.select(index: 1)
    let focusedSecondPhoto = try #require(store.currentAsset)
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    expectPage(store, start: 7, visibleCount: 7)
    store.select(index: 8)
    #expect(store.handleViewerKeyDown(try key(124, modifiers: .option), shortcuts: shortcuts))
    // Page navigation starts from the visible page, not the focused second tile.
    expectPage(store, start: 14, visibleCount: 7)
    #expect(store.handleViewerKeyDown(try key(123), shortcuts: shortcuts))
    expectPage(store, start: 7, visibleCount: 7)
    #expect(store.handleViewerKeyDown(try key(123, modifiers: .option), shortcuts: shortcuts))
    expectPage(store, start: 0, visibleCount: 7)
    #expect(store.handleViewerKeyDown(try key(124, modifiers: .option, repeating: true), shortcuts: shortcuts))
    expectPage(store, start: 7, visibleCount: 7)
    #expect(store.photoMarks.marks(for: focusedSecondPhoto).isEmpty)
    #expect(store.photoMarks.marksByAssetID.isEmpty)
  }

  @Test("분류 ON/OFF 모두 여섯 장씩 1–6에서 7–12로 넘기고 행 선택과 기존 분류를 보존한다", arguments: [false, true])
  func sixPhotoPagesIgnoreMiddleSelectionAndKeepMarks(marking: Bool) async throws {
    let fixture = try Fixture(count: 18)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(6)
    store.viewerColumnCount = 3
    store.select(index: 2)
    let markedPhoto = try #require(store.currentAsset)
    store.photoMarks.toggle(.one, for: markedPhoto)
    store.photoMarks.toggle(.w, for: markedPhoto)
    let savedMarks = store.photoMarks.marksByAssetID
    store.isPhotoMarking = marking
    #expect(store.visibleAssets.map(\.id) == Array(store.assets[0..<6]).map(\.id))

    #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    expectPage(store, start: 6, visibleCount: 6)
    #expect(store.visibleAssets.map(\.id) == Array(store.assets[6..<12]).map(\.id))
    store.select(index: 8)
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
    #expect(store.currentIndex == 11 && store.pageStartIndex == 6)
    #expect(store.handleViewerKeyDown(try key(126), shortcuts: shortcuts))
    #expect(store.currentIndex == 8 && store.pageStartIndex == 6)

    #expect(store.handleViewerKeyDown(try key(123), shortcuts: shortcuts))
    expectPage(store, start: 0, visibleCount: 6)
    #expect(store.visibleAssets.map(\.id) == Array(store.assets[0..<6]).map(\.id))
    #expect(store.photoMarks.marks(for: markedPhoto) == [.one, .w])
    #expect(store.photoMarks.marksByAssetID == savedMarks)
  }

  @Test("처음·끝과 남은 사진은 기존 페이지 이동의 반복 설정을 따른다", arguments: [21, 23])
  func boundariesPreserveExistingPageRules(count: Int) async throws {
    let fixture = try Fixture(count: count)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(7)
    let modifierCases: [NSEvent.ModifierFlags] = [[], .option]
    for marking in [false, true] {
      store.isPhotoMarking = marking
      for modifiers in modifierCases {
        for wraps in [false, true] {
          store.wrapsNavigation = wraps
          store.select(index: 0)
          let forward = wraps
            ? (count == 23 ? [7, 14, 21, 0, 7] : [7, 14, 0, 7, 14])
            : [7, 14, count - 7, count - 7, count - 7]
          for expected in forward {
            #expect(store.handleViewerKeyDown(try key(124, modifiers: modifiers), shortcuts: shortcuts))
            expectPage(store, start: expected, visibleCount: min(7, count - expected))
          }
          store.select(index: 0)
          #expect(store.handleViewerKeyDown(try key(123, modifiers: modifiers), shortcuts: shortcuts))
          expectPage(store, start: wraps ? count - 7 : 0, visibleCount: 7)
        }
      }
    }
  }

  @Test("별도로 지정한 일반 단축키가 Option 페이지 이동보다 우선한다")
  func customBindingsTakePriority() async throws {
    let fixture = try Fixture(count: 23)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(7)
    let right = KeyBinding(key: "right", modifiers: .option)
    let left = KeyBinding(key: "left", modifiers: .option)
    #expect(shortcuts.viewerPageBinding(direction: 1) == right)
    #expect(shortcuts.viewerPageBinding(direction: -1) == left)
    shortcuts.setBinding(right, for: .zoomIn)
    #expect(shortcuts.viewerPageBinding(direction: 1) == nil)
    #expect(shortcuts.viewerPageBinding(direction: -1) == left)
    #expect(store.handleViewerKeyDown(try key(124, modifiers: .option), shortcuts: shortcuts))
    #expect(store.zoom > 1 && store.pageStartIndex == 0)

    shortcuts.reset()
    store.navigatePage(1)
    store.navigatePage(1)
    shortcuts.setBinding(right, for: .previousPage)
    #expect(shortcuts.viewerPageBinding(direction: 1) == nil)
    #expect(store.handleViewerKeyDown(try key(124, modifiers: .option), shortcuts: shortcuts))
    expectPage(store, start: 7, visibleCount: 7)

    shortcuts.reset()
    shortcuts.setBinding(KeyBinding(key: "k", modifiers: [.command, .shift]), for: .nextPage)
    #expect(store.handleViewerKeyDown(try key(40, modifiers: [.command, .shift], characters: "K"),
      shortcuts: shortcuts))
    expectPage(store, start: 14, visibleCount: 7)
    #expect(shortcuts.viewerPageBinding(direction: 1) == right)
    // All four A/B commands belong to comparison mode and do not reserve this alias.
    for action in [ShortcutAction.previousFirstFolder, .nextFirstFolder,
      .previousSecondFolder, .nextSecondFolder] {
      shortcuts.setBinding(right, for: action)
    }
    #expect(shortcuts.viewerPageBinding(direction: 1) == right)
    #expect(store.handleViewerKeyDown(try key(124, modifiers: .option), shortcuts: shortcuts))
    expectPage(store, start: 21, visibleCount: 2)
  }

  @Test("페이지 별칭은 여러 장 일반 뷰어의 Option 좌우에만 적용된다")
  func aliasScopeAndExactModifiers() async throws {
    let fixture = try Fixture(count: 23)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    // A single-photo viewer preserves the existing shortcut routes.
    for code in [UInt16(123), 124] {
      _ = store.handleViewerKeyDown(try key(code, modifiers: .option), shortcuts: shortcuts)
      #expect(store.pageStartIndex == 0 && store.currentIndex == 0)
    }
    store.setImagesPerPage(7)
    let modifierCombinations: [NSEvent.ModifierFlags] = [
      [.option, .shift], [.option, .command], [.option, .control],
    ]
    for modifiers in modifierCombinations {
      _ = store.handleViewerKeyDown(try key(124, modifiers: modifiers), shortcuts: shortcuts)
      #expect(store.pageStartIndex == 0 && store.currentIndex == 0)
    }
    for code in [UInt16(125), 126] {
      _ = store.handleViewerKeyDown(try key(code, modifiers: .option), shortcuts: shortcuts)
      #expect(store.pageStartIndex == 0 && store.currentIndex == 0)
    }
    for mode in [PresentationMode.overview, .map] {
      store.presentationMode = mode
      try await ready(store)
      _ = store.handleViewerKeyDown(try key(124, modifiers: .option), shortcuts: shortcuts)
      #expect(store.pageStartIndex == 0 && store.currentIndex == 0)
    }
    store.presentationMode = .viewer
    #expect(store.handleViewerKeyDown(try key(124, modifiers: .option), shortcuts: shortcuts))
    expectPage(store, start: 7, visibleCount: 7)
  }

  @Test("비교 화면에서는 Option 좌우가 여전히 A만 이동하고 Option Shift는 B만 이동한다")
  func comparisonRetainsIndependentNavigation() async throws {
    let fixture = try Fixture(count: 23)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(7)
    store.presentationMode = .folderComparison
    let comparison = store.folderComparison
    comparison.first.load(fixture.photos)
    comparison.second.load(fixture.photos)
    try await wait {
      !comparison.first.isLoading && !comparison.second.isLoading && !comparison.isMatching
    }
    try #require(comparison.first.assets.count == 23 && comparison.second.assets.count == 23)
    for marking in [false, true] {
      store.isPhotoMarking = marking
      #expect(store.handleViewerKeyDown(try key(124, modifiers: .option), shortcuts: shortcuts))
      #expect(comparison.first.index == 1 && comparison.second.index == 0)
      #expect(store.handleViewerKeyDown(try key(124, modifiers: [.option, .shift]), shortcuts: shortcuts))
      #expect(comparison.first.index == 1 && comparison.second.index == 1)
      #expect(store.handleViewerKeyDown(try key(123, modifiers: .option), shortcuts: shortcuts))
      #expect(comparison.first.index == 0 && comparison.second.index == 1)
      #expect(store.handleViewerKeyDown(try key(123, modifiers: [.option, .shift]), shortcuts: shortcuts))
      #expect(comparison.first.index == 0 && comparison.second.index == 0)
      #expect(store.pageStartIndex == 0 && store.currentIndex == 0)
    }
  }

  @Test("텍스트 입력과 키를 놓는 이벤트는 페이지 이동으로 전달하지 않는다")
  func textEditingKeepsOptionArrows() async throws {
    let fixture = try Fixture(count: 23)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(7)
    var routedEvents = 0
    let coordinator = InputEventMonitor.Coordinator(
      onKeyDown: { event in
        routedEvents += 1
        return store.handleViewerKeyDown(event, shortcuts: shortcuts)
      }, onPointerPan: { _, _ in false }, onHorizontalSwipe: { _ in })
    defer { coordinator.stopMonitoring() }
    #expect(!coordinator.handleKey(try key(124, modifiers: .option), isTextInput: true))
    #expect(!coordinator.handleKey(try key(123, modifiers: .option), isTextInput: true))
    #expect(!coordinator.handleKey(try key(124, modifiers: .option, type: .keyUp), isTextInput: false))
    #expect(routedEvents == 0 && store.pageStartIndex == 0)
    #expect(coordinator.handleKey(try key(124, modifiers: .option), isTextInput: false))
    #expect(routedEvents == 1)
    expectPage(store, start: 7, visibleCount: 7)
  }

  @Test("분류 중 로딩·필터·시트·경고·선택 드래그는 기본 좌우와 Option 이동을 막는다")
  func transientStatesPreventNavigation() async throws {
    let fixture = try Fixture(count: 23)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(7)
    store.isPhotoMarking = true
    let forwardEvents = [try key(124), try key(124, modifiers: .option)]
    func expectBlocked() {
      let page = store.pageStartIndex, focus = store.currentIndex, selected = store.selectedURLs
      for forward in forwardEvents {
        _ = store.handleViewerKeyDown(forward, shortcuts: shortcuts)
        #expect(store.pageStartIndex == page && store.currentIndex == focus)
        #expect(store.selectedURLs == selected)
      }
    }
    store.batchSheet = .rename
    expectBlocked()
    store.batchSheet = .export
    expectBlocked()
    store.batchSheet = nil
    store.showsPhotoMarkEditor = true
    expectBlocked()
    store.showsPhotoMarkEditor = false
    store.showsAIUpscaling = true
    expectBlocked()
    store.showsAIUpscaling = false
    store.alert = ViewerAlert(title: "Test", message: "Navigation must wait")
    expectBlocked()
    store.alert = nil
    store.wallpaperRequest = WallpaperRequest(asset: try #require(store.currentAsset),
      adjustments: .identity, displays: [], currentDisplayID: 0)
    expectBlocked()
    store.wallpaperRequest = nil

    store.open(urls: [fixture.photos])
    try #require(store.isLoading)
    expectBlocked()
    try await ready(store)
    store.libraryQuery = LibraryQuery(sort: .nameDescending)
    try #require(store.isFiltering)
    expectBlocked()
    try await ready(store)
    store.resetLibraryQuery()
    try await ready(store)

    store.presentationMode = .overview
    let selection = try #require(store.beginOverviewSelection(modifiers: []))
    store.presentationMode = .viewer
    try #require(store.overviewSelectionSession?.id == selection)
    expectBlocked()
    store.cancelOverviewSelection(selection)
    for forward in forwardEvents {
      store.select(index: 0)
      #expect(store.handleViewerKeyDown(forward, shortcuts: shortcuts))
      expectPage(store, start: 7, visibleCount: 7)
    }
  }

  private func expectPage(_ store: AppStore, start: Int, visibleCount: Int) {
    #expect(store.pageStartIndex == start && store.currentIndex == start)
    #expect(store.visibleAssets.count == visibleCount)
    #expect(store.visibleAssets.first?.id == store.assets[start].id)
    #expect(store.selectedURLs == [store.assets[start].url])
  }

  private func openPhotos(_ store: AppStore, fixture: Fixture) async throws {
    await store.photoMarks.waitUntilReady()
    store.open(urls: [fixture.photos])
    try await ready(store)
    try #require(store.assets.count == fixture.count && store.alert == nil)
  }

  private func ready(_ store: AppStore) async throws {
    try await wait { !store.isLoading && !store.isFiltering }
  }

  private func wait(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.loadingTimedOut
  }

  private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [],
    repeating: Bool = false, characters: String = "", type: NSEvent.EventType = .keyDown) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: 0, context: nil, characters: characters,
      charactersIgnoringModifiers: characters, isARepeat: repeating, keyCode: code))
  }

  private enum FixtureError: Error { case loadingTimedOut }

  private struct Fixture {
    let count: Int
    let photos: URL
    let suite: String
    let defaults: UserDefaults

    init(count: Int) throws {
      self.count = count
      suite = "ViewerPageShortcutTests.\(UUID())"
      defaults = try #require(UserDefaults(suiteName: suite))
      photos = FileManager.default.temporaryDirectory
        .appendingPathComponent("viewer-page-shortcuts-\(UUID())", isDirectory: true)
      try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
      let qoi = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
        0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
      for index in 1...count {
        try qoi.write(to: photos.appendingPathComponent("photo\(index).qoi"))
      }
    }

    @MainActor func makeStore() -> AppStore {
      AppStore(defaults: defaults, monitorsSystemResources: false)
    }

    @MainActor func cleanup(_ store: AppStore) {
      store.folderComparison.cancelLoads()
      store.saveSessionNow()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: photos)
    }
  }
}
