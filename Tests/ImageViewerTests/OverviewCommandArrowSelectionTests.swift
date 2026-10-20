import AppKit
import Testing

@testable import ImageViewer

@Suite("몽땅보기 Command 방향키 선택", .serialized)
@MainActor
struct OverviewCommandArrowSelectionTests {
  @Test("상하좌우 목적지의 선택만 반전하고 나머지 선택과 분류 모드를 유지한다", arguments: [false, true])
  func arrowsToggleOnlyDestination(marking: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await fixture.open()
    let store = fixture.store
    let urls = store.assets.map(\.url)
    store.isPhotoMarking = marking
    store.select(index: 7)
    store.selectForBatch(index: 4, modifiers: .command)
    #expect(store.selectedURLs == [urls[4], urls[7]])

    let steps: [(UInt16, Int, Set<Int>)] = [
      (124, 5, [4, 5, 7]),
      (125, 8, [4, 5, 7, 8]),
      (123, 7, [4, 5, 8]),
      (126, 4, [5, 8]),
      (123, 3, [3, 5, 8]),
    ]
    for (code, index, selected) in steps {
      #expect(store.handleViewerKeyDown(try key(code), shortcuts: fixture.shortcuts))
      #expect(store.currentIndex == index)
      #expect(store.selectedURLs == Set(selected.map { urls[$0] }))
      #expect(store.isPhotoMarking == marking && store.presentationMode == .overview)
    }
    // The destination stays focused even if it was deselected; returning to
    // it adds it again without touching the other chosen files.
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 4 && store.selectedURLs == [urls[3], urls[4], urls[5], urls[8]])
  }

  @Test("행 끝과 마지막 행에서는 순환하지 않고 반복 입력도 현재 사진을 반전하지 않는다")
  func edgesAndRepeats() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await fixture.open()
    let store = fixture.store
    let urls = store.assets.map(\.url)
    store.wrapsNavigation = true
    for code: UInt16 in [123, 126] {
      #expect(store.handleViewerKeyDown(try key(code), shortcuts: fixture.shortcuts))
      #expect(store.currentIndex == 0 && store.selectedURLs == [urls[0]])
    }
    for index in 1...2 {
      #expect(store.handleViewerKeyDown(try key(124, repeating: true), shortcuts: fixture.shortcuts))
      #expect(store.currentIndex == index)
    }
    for _ in 0..<3 {
      #expect(store.handleViewerKeyDown(try key(124, repeating: true), shortcuts: fixture.shortcuts))
      #expect(store.currentIndex == 2 && store.selectedURLs == Set(urls[0...2]))
    }
    store.select(index: 8)
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 9 && store.selectedURLs == [urls[8], urls[9]])
    for code: UInt16 in [123, 124, 125] {
      #expect(store.handleViewerKeyDown(try key(code), shortcuts: fixture.shortcuts))
      #expect(store.currentIndex == 9 && store.selectedURLs == [urls[8], urls[9]])
    }
    // Thumbnail resizing changes the number of columns used for the next key.
    store.overviewColumnCount = 2
    #expect(store.handleViewerKeyDown(try key(126), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 7 && store.selectedURLs == [urls[7], urls[8], urls[9]])
  }

  @Test("RTL 배치에서도 물리적 좌우를 따르고 전체 선택에서 목적지만 해제한다")
  func rightToLeftAndSelectedDestinations() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await fixture.open()
    let store = fixture.store
    let urls = store.assets.map(\.url)
    store.overviewIsRightToLeft = true
    store.selectAllAssets()
    #expect(store.handleViewerKeyDown(try key(123), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 1)
    #expect(store.selectedURLs == Set(urls).subtracting([urls[1]]))
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 0)
    #expect(store.selectedURLs == Set(urls[2...9]))
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 0 && store.selectedURLs == Set(urls[2...9]))
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 3 && !store.selectedURLs.contains(urls[3]))
  }

  @Test("한 항목뿐이면 선택 유무와 관계없이 모든 방향키를 안전하게 소비한다")
  func singleItemNeverTogglesAtAnEdge() async throws {
    let fixture = try Fixture(count: 1)
    defer { fixture.cleanup() }
    try await fixture.open()
    let store = fixture.store
    for selected in [true, false] {
      if !selected { store.clearSelection() }
      let baseline = store.selectedURLs
      for code: UInt16 in [123, 124, 125, 126, 123, 124] {
        #expect(store.handleViewerKeyDown(try key(code, repeating: true), shortcuts: fixture.shortcuts))
        #expect(store.currentIndex == 0 && store.selectedURLs == baseline)
      }
    }
  }

  @Test("사진·영상·음성을 함께 선택해 분류하고 모두 해제하면 초점 파일에 분류하지 않는다")
  func mixedMediaAndEmptySelectionDoNotFallbackToFocus() async throws {
    let fixture = try Fixture(count: 3, mixed: true)
    defer { fixture.cleanup() }
    try await fixture.open()
    let store = fixture.store
    await store.photoMarks.waitUntilReady()
    try #require(store.photoMarks.isReady)
    try #require(store.assets.contains(where: \.isAudio) && store.assets.contains(where: \.isVideo))
    store.isPhotoMarking = true
    for _ in 0..<2 {
      #expect(store.handleViewerKeyDown(try key(124), shortcuts: fixture.shortcuts))
    }
    #expect(store.photoMarkAssets.count == 3 && store.canMarkPhoto)
    store.togglePhotoMark(.s)
    #expect(store.assets.allSatisfy { store.photoMarks.marks(for: $0).contains(.s) })
    for code: UInt16 in [123, 123, 124, 124, 123] {
      #expect(store.handleViewerKeyDown(try key(code), shortcuts: fixture.shortcuts))
    }
    #expect(store.currentIndex == 1 && store.currentAsset != nil)
    #expect(store.selectedURLs.isEmpty && store.photoMarkAssets.isEmpty && !store.canMarkPhoto)
    store.togglePhotoMark(.e)
    #expect(store.assets.allSatisfy { store.photoMarks.marks(for: $0) == [.s] })
  }

  @Test("사용자 단축키를 우선하고 Fn·숫자패드 플래그를 허용하며 다른 모드는 바꾸지 않는다")
  func customizedShortcutsAndModifierRouting() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await fixture.open()
    let store = fixture.store
    let urls = store.assets.map(\.url)
    fixture.shortcuts.setBinding(KeyBinding(key: "right", modifiers: [.command]), for: .zoomIn)
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: fixture.shortcuts))
    #expect(store.zoom > 1 && store.currentIndex == 0 && store.selectedURLs == [urls[0]])
    fixture.shortcuts.reset()
    #expect(store.handleViewerKeyDown(try key(124, modifiers: [.command, .numericPad, .function]),
      shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 1 && store.selectedURLs == [urls[0], urls[1]])
    for modifiers: NSEvent.ModifierFlags in [[.command, .option], [.command, .control]] {
      #expect(!store.handleOverviewSelectionKeyDown(try key(124, modifiers: modifiers)))
      #expect(store.currentIndex == 1 && store.selectedURLs == [urls[0], urls[1]])
    }
    // Plain navigation keeps its existing single-selection behavior.
    #expect(store.handleViewerKeyDown(try key(124, modifiers: []), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 2 && store.selectedURLs == [urls[2]])
    for mode in [ImageViewer.PresentationMode.viewer, .map, .folderComparison] {
      store.presentationMode = mode
      let previous = store.selectedURLs
      #expect(!store.handleOverviewSelectionKeyDown(try key(124)))
      #expect(store.selectedURLs == previous)
    }
  }

  @Test("텍스트 입력·키 해제·시트·경고·영역 드래그·필터 갱신 중에는 선택을 바꾸지 않는다")
  func interactionGuards() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await fixture.open()
    let store = fixture.store
    let original = store.selectedURLs
    var routed = 0
    let coordinator = InputEventMonitor.Coordinator(
      onKeyDown: { event in
        routed += 1
        return store.handleViewerKeyDown(event, shortcuts: fixture.shortcuts)
      }, onPointerPan: { _, _ in false }, onHorizontalSwipe: { _ in })
    defer { coordinator.stopMonitoring() }
    for code: UInt16 in [123, 124, 125, 126] {
      #expect(!coordinator.handleKey(try key(code), isTextInput: true))
    }
    #expect(!coordinator.handleKey(try key(124, type: .keyUp), isTextInput: false))
    #expect(routed == 0 && store.selectedURLs == original)
    store.batchSheet = .rename
    #expect(!store.handleViewerKeyDown(try key(124), shortcuts: fixture.shortcuts))
    store.batchSheet = nil
    store.alert = ViewerAlert(title: "Synthetic", message: "Paused")
    #expect(!store.handleViewerKeyDown(try key(124), shortcuts: fixture.shortcuts))
    store.alert = nil
    let drag = try #require(store.beginOverviewSelection(modifiers: []))
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: fixture.shortcuts))
    #expect(store.selectedURLs == original && store.currentIndex == 0)
    store.cancelOverviewSelection(drag)
    store.libraryQuery.sort = .nameDescending
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: fixture.shortcuts))
    #expect(store.selectedURLs == original && store.currentIndex == 0)
    try await fixture.ready()
    store.showHome()
    let beforeHome = store.selectedURLs
    #expect(!store.handleViewerKeyDown(try key(124), shortcuts: fixture.shortcuts))
    #expect(store.selectedURLs == beforeHome)
  }

  private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = .command,
    repeating: Bool = false, type: NSEvent.EventType = .keyDown) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: repeating, keyCode: code))
  }

  @MainActor private struct Fixture {
    let suite = "OverviewCommandArrowSelectionTests.\(UUID())"
    let folder: URL
    let defaults: UserDefaults
    let store: AppStore
    let shortcuts: ShortcutStore
    let count: Int

    init(count: Int = 10, mixed: Bool = false) throws {
      self.count = count
      folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
      defaults = try #require(UserDefaults(suiteName: suite))
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let png = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII="))
      for index in 1...count {
        let ext = mixed && index == 2 ? "mp4" : mixed && index == 3 ? "wav" : "png"
        let data = ext == "png" ? png : Data("Synthetic selection fixture".utf8)
        try data.write(to: folder.appendingPathComponent("photo\(index).\(ext)"))
      }
      store = AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: folder.appendingPathComponent("marks.sqlite"))
      shortcuts = ShortcutStore(defaults: defaults)
    }

    func open() async throws {
      store.showsVideos = true
      store.open(urls: [folder])
      try await ready()
      store.presentationMode = .overview
      store.overviewColumnCount = 3
      try #require(store.assets.count == count)
    }

    func ready() async throws {
      let deadline = ContinuousClock.now + .seconds(8)
      while store.isLoading || store.isFiltering {
        try #require(ContinuousClock.now < deadline)
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    func cleanup() {
      store.folderComparison.cancelLoads()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }
  }
}
