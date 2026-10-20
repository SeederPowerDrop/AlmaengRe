import AppKit
import Testing

@testable import ImageViewer

@Suite("몽땅보기 Shift 방향키 범위 선택", .serialized)
@MainActor
struct OverviewRangeArrowSelectionTests {
  @Test("Shift 상하좌우는 고정 기준점에서 확대·축소·역방향 선택한다", arguments: [false, true])
  func fixedAnchorExpandsShrinksAndReverses(marking: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await fixture.open()
    let store = fixture.store
    let urls = store.assets.map(\.url)
    store.isPhotoMarking = marking
    store.select(index: 5)
    let steps: [(UInt16, Int, ClosedRange<Int>)] = [
      (124, 6, 5...6), (125, 10, 5...10), (123, 9, 5...9),
      (126, 5, 5...5), (123, 4, 4...5), (126, 0, 0...5),
    ]
    for (code, index, range) in steps {
      #expect(store.handleViewerKeyDown(try key(code), shortcuts: fixture.shortcuts))
      #expect(store.currentIndex == index && store.selectedURLs == Set(urls[range]))
      #expect(store.isPhotoMarking == marking && store.presentationMode == .overview)
    }
  }

  @Test("Command+Shift는 관계없는 선택과 이미 추가한 범위를 유지하고 Shift만 누르면 수축한다")
  func additiveRangeKeepsExistingSelections() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await fixture.open()
    let store = fixture.store
    let urls = store.assets.map(\.url)
    store.select(index: 0)
    store.selectForBatch(index: 5, modifiers: .command)
    #expect(store.handleViewerKeyDown(try key(124, modifiers: [.command, .shift]), shortcuts: fixture.shortcuts))
    #expect(store.selectedURLs == [urls[0], urls[5], urls[6]])
    #expect(store.handleViewerKeyDown(try key(125, modifiers: [.command, .shift]), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 10 && store.selectedURLs == Set(urls[5...10]).union([urls[0]]))
    #expect(store.handleViewerKeyDown(try key(123, modifiers: [.command, .shift]), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 9 && store.selectedURLs == Set(urls[5...10]).union([urls[0]]))
    #expect(store.handleViewerKeyDown(try key(123), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 8 && store.selectedURLs == Set(urls[5...8]))
  }

  @Test("Shift 클릭·Command 클릭·선택 해제와 방향키가 같은 기준점을 공유한다")
  func keyboardRangesShareClickAnchor() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await fixture.open()
    let store = fixture.store
    let urls = store.assets.map(\.url)
    store.select(index: 4)
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: fixture.shortcuts))
    #expect(store.selectOverviewCard(url: urls[7], modifiers: .shift))
    #expect(store.selectedURLs == Set(urls[4...7]))
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 11 && store.selectedURLs == Set(urls[4...11]))
    #expect(store.selectOverviewCard(url: urls[0], modifiers: .command))
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 1 && store.selectedURLs == Set(urls[0...1]))
    store.clearSelection()
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 5 && store.selectedURLs == Set(urls[1...5]))
    #expect(store.handleViewerKeyDown(try key(123), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 4 && store.selectedURLs == Set(urls[1...4]))
  }

  @Test("짧은 마지막 행·RTL·반복 입력에서 공간 방향과 끝 경계를 유지한다", arguments: [false, true])
  func shortRowsAndRightToLeft(additive: Bool) async throws {
    let fixture = try Fixture(count: 10)
    defer { fixture.cleanup() }
    try await fixture.open()
    let store = fixture.store
    let urls = store.assets.map(\.url)
    let modifiers: NSEvent.ModifierFlags = additive ? [.command, .shift] : .shift
    store.wrapsNavigation = true
    store.select(index: 6)
    #expect(store.handleViewerKeyDown(try key(125, modifiers: modifiers), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 9 && store.selectedURLs == Set(urls[6...9]))
    for code: UInt16 in [125, 124, 124] {
      #expect(store.handleViewerKeyDown(try key(code, modifiers: modifiers, repeating: true), shortcuts: fixture.shortcuts))
      #expect(store.currentIndex == 9 && store.selectedURLs == Set(urls[6...9]))
    }
    #expect(store.handleViewerKeyDown(try key(123, modifiers: modifiers), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 8 && store.selectedURLs == Set(urls[6...(additive ? 9 : 8)]))
    #expect(store.handleViewerKeyDown(try key(126, modifiers: modifiers), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 4 && store.selectedURLs == Set(urls[4...(additive ? 9 : 6)]))

    store.select(index: 1)
    store.overviewIsRightToLeft = true
    #expect(store.handleViewerKeyDown(try key(123, modifiers: modifiers), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 2 && store.selectedURLs == Set(urls[1...2]))
    #expect(store.handleViewerKeyDown(try key(124, modifiers: modifiers), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 1 && store.selectedURLs == Set(urls[1...(additive ? 2 : 1)]))
    #expect(store.handleViewerKeyDown(try key(124, modifiers: modifiers), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 0 && store.selectedURLs == Set(urls[0...(additive ? 2 : 1)]))
    let baseline = store.selectedURLs
    #expect(store.handleViewerKeyDown(try key(124, modifiers: modifiers, repeating: true), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 0 && store.selectedURLs == baseline)
  }

  @Test("한 항목 또는 빈 선택의 경계에서는 Shift 조합이 현재 항목을 새로 선택하지 않는다", arguments: [false, true])
  func singleItemAndEmptySelection(additive: Bool) async throws {
    let fixture = try Fixture(count: 1)
    defer { fixture.cleanup() }
    try await fixture.open()
    let store = fixture.store
    let modifiers: NSEvent.ModifierFlags = additive ? [.command, .shift] : .shift
    for selected in [true, false] {
      if !selected { store.clearSelection() }
      let baseline = store.selectedURLs
      for code: UInt16 in [123, 124, 125, 126] {
        #expect(store.handleViewerKeyDown(try key(code, modifiers: modifiers, repeating: true), shortcuts: fixture.shortcuts))
        #expect(store.currentIndex == 0 && store.selectedURLs == baseline)
      }
    }
  }

  @Test("사진·영상·음성 범위 선택을 분류 작업의 정확한 대상 목록으로 전달한다")
  func mixedMediaRangeIsBatchTarget() async throws {
    let fixture = try Fixture(count: 6, mixed: true)
    defer { fixture.cleanup() }
    try await fixture.open()
    let store = fixture.store
    await store.photoMarks.waitUntilReady()
    try #require(store.photoMarks.isReady)
    store.overviewColumnCount = 3
    store.isPhotoMarking = true
    let urls = store.assets.map(\.url)
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 3 && store.selectedURLs == Set(urls[0...3]))
    #expect(store.selectedAssets.contains(where: \.isVideo) && store.selectedAssets.contains(where: \.isAudio))
    #expect(store.photoMarkAssets.map(\.url) == Array(urls[0...3]) && store.canMarkPhoto)
    store.togglePhotoMark(.s)
    #expect(store.assets[0...3].allSatisfy { store.photoMarks.marks(for: $0) == [.s] })
    #expect(store.assets[4...5].allSatisfy { store.photoMarks.marks(for: $0).isEmpty })
    #expect(store.handleViewerKeyDown(try key(124, modifiers: [.command, .shift]), shortcuts: fixture.shortcuts))
    #expect(store.selectedAssets.map(\.url) == Array(urls[0...4]))
  }

  @Test("사용자 지정 Shift 조합을 우선하고 필터·정렬된 현재 목록에서만 범위를 만든다", arguments: [false, true])
  func customBindingsAndFilteredOrder(additive: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await fixture.open()
    let store = fixture.store
    let modifiers: NSEvent.ModifierFlags = additive ? [.command, .shift] : .shift
    let bindingModifiers: ShortcutModifiers = additive ? [.command, .shift] : .shift
    fixture.shortcuts.setBinding(KeyBinding(key: "right", modifiers: bindingModifiers), for: .zoomIn)
    let before = store.selectedURLs
    #expect(store.handleViewerKeyDown(try key(124, modifiers: modifiers), shortcuts: fixture.shortcuts))
    #expect(store.zoom > 1 && store.currentIndex == 0 && store.selectedURLs == before)
    fixture.shortcuts.reset()
    #expect(store.handleViewerKeyDown(try key(124, modifiers: modifiers.union([.numericPad, .function])),
      shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 1 && store.selectedURLs.count == 2)
    for extra: NSEvent.ModifierFlags in [.option, .control] {
      let selected = store.selectedURLs
      #expect(!store.handleOverviewSelectionKeyDown(try key(124, modifiers: modifiers.union(extra))))
      #expect(store.currentIndex == 1 && store.selectedURLs == selected)
    }

    store.libraryQuery.sort = .nameDescending
    try await fixture.ready()
    let descending = store.assets.map(\.url)
    store.select(index: 1)
    #expect(store.handleViewerKeyDown(try key(125, modifiers: modifiers), shortcuts: fixture.shortcuts))
    #expect(store.selectedAssets.map(\.url) == Array(descending[1...5]))
    let previous = store.selectedURLs
    store.libraryQuery.searchText = "shot-0"
    #expect(store.handleViewerKeyDown(try key(125, modifiers: modifiers), shortcuts: fixture.shortcuts))
    #expect(store.selectedURLs == previous)
    try await fixture.ready()
    try #require(store.assets.count == 9)
    let visible = store.assets.map(\.url)
    store.select(index: 0)
    #expect(store.handleViewerKeyDown(try key(125, modifiers: modifiers), shortcuts: fixture.shortcuts))
    #expect(store.selectedAssets.map(\.url) == Array(visible[0...4]))
    #expect(store.selectedURLs.isSubset(of: Set(visible)))
  }

  @Test("텍스트 편집·키 해제·시트·영역 드래그·다른 보기에서는 범위 선택을 가로채지 않는다", arguments: [false, true])
  func inputAndModalGuards(additive: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await fixture.open()
    let store = fixture.store
    let modifiers: NSEvent.ModifierFlags = additive ? [.command, .shift] : .shift
    let before = store.selectedURLs
    var routed = 0
    let coordinator = InputEventMonitor.Coordinator(
      onKeyDown: { event in
        routed += 1
        return store.handleViewerKeyDown(event, shortcuts: fixture.shortcuts)
      }, onPointerPan: { _, _ in false }, onHorizontalSwipe: { _ in })
    defer { coordinator.stopMonitoring() }
    for code: UInt16 in [123, 124, 125, 126] {
      #expect(!coordinator.handleKey(try key(code, modifiers: modifiers), isTextInput: true))
    }
    #expect(!coordinator.handleKey(try key(124, modifiers: modifiers, type: .keyUp), isTextInput: false))
    #expect(routed == 0 && store.selectedURLs == before)
    store.batchSheet = .rename
    #expect(!store.handleViewerKeyDown(try key(124, modifiers: modifiers), shortcuts: fixture.shortcuts))
    store.batchSheet = nil
    store.alert = ViewerAlert(title: "Synthetic", message: "Paused")
    #expect(!store.handleViewerKeyDown(try key(124, modifiers: modifiers), shortcuts: fixture.shortcuts))
    store.alert = nil
    let drag = try #require(store.beginOverviewSelection(modifiers: []))
    #expect(store.handleViewerKeyDown(try key(124, modifiers: modifiers), shortcuts: fixture.shortcuts))
    #expect(store.currentIndex == 0 && store.selectedURLs == before)
    store.cancelOverviewSelection(drag)
    for mode in [ImageViewer.PresentationMode.viewer, .map, .folderComparison] {
      store.presentationMode = mode
      #expect(!store.handleOverviewSelectionKeyDown(try key(124, modifiers: modifiers)))
      #expect(store.selectedURLs == before)
    }
  }

  private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = .shift,
    repeating: Bool = false, type: NSEvent.EventType = .keyDown) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: repeating, keyCode: code))
  }

  @Test("Command+A는 한국어 입력·Caps Lock에서도 모두 선택하고 텍스트 편집과 다른 단축키를 유지한다",
    arguments: [false, true])
  func selectAllSupportsInputMethodsAndLockState(marking: Bool) async throws {
    let fixture = try Fixture(count: 6, mixed: true)
    defer { fixture.cleanup() }
    try await fixture.open()
    let store = fixture.store
    store.isPhotoMarking = marking
    let all = Set(store.assets.map(\.url))
    func event(_ characters: String, flags: NSEvent.ModifierFlags = .command,
      code: UInt16 = 0) throws -> NSEvent {
      try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: 0, windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
    for characters in ["a", "A", "ㅁ"] {
      for flags: NSEvent.ModifierFlags in [.command, [.command, .capsLock], [.command, .function]] {
        store.select(index: 0)
        #expect(store.handleViewerKeyDown(try event(characters, flags: flags), shortcuts: fixture.shortcuts))
        #expect(store.selectedURLs == all && store.isPhotoMarking == marking)
      }
    }
    store.select(index: 0)
    let before = store.selectedURLs
    var routed = 0
    let coordinator = InputEventMonitor.Coordinator(onKeyDown: { event in
      routed += 1
      return store.handleViewerKeyDown(event, shortcuts: fixture.shortcuts)
    }, onPointerPan: { _, _ in false }, onHorizontalSwipe: { _ in })
    defer { coordinator.stopMonitoring() }
    #expect(!coordinator.handleKey(try event("ㅁ", flags: [.command, .capsLock]), isTextInput: true))
    #expect(routed == 0 && store.selectedURLs == before)

    // A Latin layout's actual character retains precedence over hardware A.
    #expect(!store.handleViewerKeyDown(try event("q"), shortcuts: fixture.shortcuts))
    #expect(store.selectedURLs == before)
    fixture.shortcuts.setBinding(KeyBinding(key: "w", modifiers: .command), for: .zoomIn)
    let zoom = store.zoom
    #expect(store.handleViewerKeyDown(try event("w"), shortcuts: fixture.shortcuts))
    #expect(store.zoom > zoom && store.selectedURLs == before)
    fixture.shortcuts.setBinding(KeyBinding(key: "a", modifiers: [.command, .shift]), for: .zoomIn)
    let nextZoom = store.zoom
    #expect(store.handleViewerKeyDown(try event("a", flags: [.command, .shift]), shortcuts: fixture.shortcuts))
    #expect(store.zoom > nextZoom && store.selectedURLs == before)
  }

  @MainActor private struct Fixture {
    let suite = "OverviewRangeArrowSelectionTests.\(UUID())"
    let folder: URL
    let defaults: UserDefaults
    let store: AppStore
    let shortcuts: ShortcutStore
    let count: Int

    init(count: Int = 12, mixed: Bool = false) throws {
      self.count = count
      folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
      defaults = try #require(UserDefaults(suiteName: suite))
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let png = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII="))
      for index in 1...count {
        let ext = mixed && index == 2 ? "mp4" : mixed && index == 3 ? "wav" : "png"
        let data = ext == "png" ? png : Data("Synthetic range selection fixture".utf8)
        try data.write(to: folder.appendingPathComponent(String(format: "shot-%02d.%@", index, ext)))
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
      store.overviewColumnCount = 4
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
