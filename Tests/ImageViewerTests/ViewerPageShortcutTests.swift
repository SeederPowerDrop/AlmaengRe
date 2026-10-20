import AppKit
import Testing

@testable import ImageViewer

@Suite("여러 장 보기의 페이지 이동과 Option 사진 선택")
@MainActor
struct ViewerPageShortcutTests {
  @Test("기본 좌우는 페이지를 넘기고 Option 좌우는 현재 페이지의 사진만 고른다",
    arguments: [false, true])
  func pageNavigationAndSinglePhotoSelection(marking: Bool) async throws {
    let fixture = try Fixture(count: 23)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(7)
    store.isPhotoMarking = marking
    #expect(store.pageStartIndex == 0 && store.visibleAssets.count == 7)

    #expect(store.handleViewerKeyDown(try key(124, modifiers: .option), shortcuts: shortcuts))
    expectSelection(store, index: 1, page: 0, visibleCount: 7)
    #expect(store.handleViewerKeyDown(try key(123, modifiers: .option), shortcuts: shortcuts))
    expectSelection(store, index: 0, page: 0, visibleCount: 7)

    store.select(index: 1)
    let focusedSecondPhoto = try #require(store.currentAsset)
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    expectPage(store, start: 7, visibleCount: 7)
    store.select(index: 8)
    #expect(store.handleViewerKeyDown(try key(124, modifiers: .option), shortcuts: shortcuts))
    expectSelection(store, index: 9, page: 7, visibleCount: 7)
    // Plain page navigation still starts from the page, not the focused tile.
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    expectPage(store, start: 14, visibleCount: 7)
    #expect(store.handleViewerKeyDown(try key(123), shortcuts: shortcuts))
    expectPage(store, start: 7, visibleCount: 7)
    #expect(store.handleViewerKeyDown(try key(123, modifiers: .option), shortcuts: shortcuts))
    expectSelection(store, index: 9, page: 7, visibleCount: 7)
    #expect(store.handleViewerKeyDown(try key(124, modifiers: .option, repeating: true), shortcuts: shortcuts))
    expectSelection(store, index: 7, page: 7, visibleCount: 7)
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
    store.frameLayout.setColumns(3, count: 6)
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
    for marking in [false, true] {
      store.isPhotoMarking = marking
      for wraps in [false, true] {
        store.wrapsNavigation = wraps
        store.select(index: 0)
        let forward = wraps
          ? (count == 23 ? [7, 14, 21, 0, 7] : [7, 14, 0, 7, 14])
          : [7, 14, count - 7, count - 7, count - 7]
        for expected in forward {
          #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
          expectPage(store, start: expected, visibleCount: min(7, count - expected))
        }
        store.select(index: 0)
        #expect(store.handleViewerKeyDown(try key(123), shortcuts: shortcuts))
        expectPage(store, start: wraps ? count - 7 : 0, visibleCount: 7)
      }
    }
  }

  @Test("별도로 지정한 일반 단축키가 Option 사진 선택보다 우선하고 페이지 키 안내를 갱신한다",
    arguments: [false, true])
  func customBindingsTakePriority(marking: Bool) async throws {
    let fixture = try Fixture(count: 23)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(7)
    store.isPhotoMarking = marking
    let right = KeyBinding(key: "right", modifiers: .option)
    let left = KeyBinding(key: "left", modifiers: .option)
    #expect(shortcuts.viewerPageBinding(direction: 1) == KeyBinding(key: "right"))
    #expect(shortcuts.viewerPageBinding(direction: -1) == KeyBinding(key: "left"))
    #expect(shortcuts.viewerSelectionBinding(direction: .right) == right)
    #expect(shortcuts.viewerSelectionBinding(direction: .left) == left)
    #expect(shortcuts.viewerPageBinding(direction: 0) == nil)
    shortcuts.setBinding(right, for: .zoomIn)
    #expect(shortcuts.viewerSelectionBinding(direction: .right) == nil)
    #expect(shortcuts.viewerSelectionBinding(direction: .left) == left)
    #expect(shortcuts.viewerPageBinding(direction: 1) == KeyBinding(key: "right"))
    #expect(store.handleViewerKeyDown(try key(124, modifiers: .option), shortcuts: shortcuts))
    #expect(store.zoom > 1 && store.pageStartIndex == 0)

    shortcuts.reset()
    store.navigatePage(1)
    store.navigatePage(1)
    shortcuts.setBinding(right, for: .previousPage)
    #expect(shortcuts.viewerSelectionBinding(direction: .right) == nil)
    #expect(shortcuts.viewerPageBinding(direction: -1) == right)
    #expect(store.handleViewerKeyDown(try key(124, modifiers: .option), shortcuts: shortcuts))
    expectPage(store, start: 7, visibleCount: 7)

    shortcuts.reset()
    let customNext = KeyBinding(key: "k", modifiers: [.command, .shift])
    shortcuts.setBinding(customNext, for: .nextPage)
    #expect(store.handleViewerKeyDown(try key(40, modifiers: [.command, .shift], characters: "K"),
      shortcuts: shortcuts))
    expectPage(store, start: 14, visibleCount: 7)
    #expect(shortcuts.viewerPageBinding(direction: 1) == customNext)
    #expect(shortcuts.viewerSelectionBinding(direction: .right) == right)
    // All four A/B commands belong to comparison mode and do not reserve this alias.
    for action in [ShortcutAction.previousFirstFolder, .nextFirstFolder,
      .previousSecondFolder, .nextSecondFolder] {
      shortcuts.setBinding(right, for: action)
    }
    #expect(shortcuts.viewerSelectionBinding(direction: .right) == right)
    #expect(store.handleViewerKeyDown(try key(124, modifiers: .option), shortcuts: shortcuts))
    expectSelection(store, index: 15, page: 14, visibleCount: 7)
  }

  @Test("사용자가 Option 위·아래를 다른 기능에 지정하면 그 기능이 공간 선택보다 우선한다",
    arguments: [false, true], [UInt16(125), 126])
  func verticalOptionCustomBindingsTakePriority(marking: Bool, code: UInt16) async throws {
    let fixture = try Fixture(count: 18)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(6)
    store.isPhotoMarking = marking
    let direction: ViewerSelectionDirection = code == 125 ? .down : .up
    let binding = KeyBinding(key: direction.key, modifiers: .option)
    shortcuts.setBinding(binding, for: .zoomIn)
    #expect(shortcuts.viewerSelectionBinding(direction: direction) == nil)
    for other in ViewerSelectionDirection.allCases where other != direction {
      #expect(shortcuts.viewerSelectionBinding(direction: other) != nil)
    }
    #expect(store.handleViewerKeyDown(try key(code, modifiers: .option), shortcuts: shortcuts))
    expectSelection(store, index: 0, page: 0, visibleCount: 6)
    #expect(store.zoom > 1)

    shortcuts.reset()
    store.navigatePage(1)
    shortcuts.setBinding(binding, for: .previousPage)
    #expect(shortcuts.viewerSelectionBinding(direction: direction) == nil)
    #expect(shortcuts.viewerPageBinding(direction: -1) == binding)
    #expect(store.handleViewerKeyDown(try key(code, modifiers: .option), shortcuts: shortcuts))
    expectPage(store, start: 0, visibleCount: 6)
  }

  @Test("여섯 장의 Option 네 방향은 같은 행과 열을 따라 현재 화면 안에서 순환한다",
    arguments: [false, true], [false, true])
  func sixFramesFollowSpatialDirections(marking: Bool, wraps: Bool) async throws {
    let fixture = try Fixture(count: 18)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(6)
    store.isPhotoMarking = marking
    store.wrapsNavigation = wraps
    store.navigatePage(1)
    let cases: [(from: Int, code: UInt16, to: Int)] = [
      (6, 124, 7), (8, 124, 6), (6, 123, 8), (7, 123, 6),
      (9, 123, 11), (11, 124, 9),
      (7, 125, 10), (10, 126, 7), (7, 126, 10), (10, 125, 7),
      (8, 125, 11), (11, 126, 8),
    ]
    for item in cases {
      store.select(index: item.from)
      #expect(store.handleViewerKeyDown(try key(item.code, modifiers: .option), shortcuts: shortcuts))
      expectSelection(store, index: item.to, page: 6, visibleCount: 6)
    }
    #expect(store.photoMarks.marksByAssetID.isEmpty)
  }

  @Test("위치를 바꾼 프레임의 공간 배치로 네 방향 이동하고 다른 페이지로 나가지 않는다",
    arguments: [false, true], [false, true])
  func selectionFollowsReorderedFrames(marking: Bool, wraps: Bool) async throws {
    let fixture = try Fixture(count: 12)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(4)
    store.isPhotoMarking = marking
    store.wrapsNavigation = wraps
    store.navigatePage(1)
    store.frameLayout.swap(0, with: 3, count: 4)
    let visible = store.visibleAssets
    try #require(store.frameLayout.configuration(for: 4).visualSlots == [3, 1, 2, 0])
    store.select(index: 7)
    let path: [(code: UInt16, target: Int)] = [
      (124, 5), (124, 7), (123, 5), (125, 4), (123, 6),
      (123, 4), (126, 5), (126, 4), (124, 6), (125, 7),
    ]
    for step in path {
      #expect(store.handleViewerKeyDown(try key(step.code, modifiers: .option), shortcuts: shortcuts))
      expectSelection(store, index: step.target, page: 4, visibleCount: 4)
      #expect(store.visibleAssets == visible)
    }
    #expect(store.photoMarks.marksByAssetID.isEmpty)
  }

  @Test("Option 위아래 선택은 현재 창의 실제 프레임 너비를 사용한다", arguments: [false, true])
  func verticalSelectionUsesCurrentViewport(marking: Bool) async throws {
    let fixture = try Fixture(count: 12)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(4)
    store.navigatePage(1)
    store.isPhotoMarking = marking
    var layout = ViewerFrameLayoutConfiguration(count: 4)
    layout.rows[0].widths = [0.8, 0.2]
    layout.rows[1].widths = [0.2, 0.8]
    store.frameLayout.set(layout, for: 4, persist: false)
    for code in [UInt16(125), 126] {
      store.viewerViewportSize = CGSize(width: 1_200, height: 800)
      store.select(index: 4)
      #expect(store.handleViewerKeyDown(try key(code, modifiers: .option), shortcuts: shortcuts))
      expectSelection(store, index: 7, page: 4, visibleCount: 4)
      store.viewerViewportSize = CGSize(width: 200, height: 400)
      store.select(index: 4)
      #expect(store.handleViewerKeyDown(try key(code, modifiers: .option), shortcuts: shortcuts))
      expectSelection(store, index: 6, page: 4, visibleCount: 4)
    }
  }

  @Test("한 행의 위아래와 한 열의 좌우는 확대를 유지하고 다중선택만 정리한다", arguments: [false, true])
  func unavailableAxisPreservesViewportAndClearsBatch(marking: Bool) async throws {
    let fixture = try Fixture(count: 12)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(4)
    store.navigatePage(1)
    store.isPhotoMarking = marking
    let cases: [(preset: ViewerFrameLayoutPreset, codes: [UInt16])] = [
      (.horizontal, [125, 126]), (.vertical, [123, 124]),
    ]
    for item in cases {
      store.frameLayout.setPreset(item.preset, count: 4)
      store.select(index: 5)
      for code in item.codes {
        store.selectAllAssets()
        #expect(store.handleViewerKeyDown(try key(code, modifiers: .option), shortcuts: shortcuts))
        expectSelection(store, index: 5, page: 4, visibleCount: 4)
        store.zoom = 2.5
        store.panOffset = CGSize(width: -17, height: 23)
        #expect(store.handleViewerKeyDown(try key(code, modifiers: .option), shortcuts: shortcuts))
        expectSelection(store, index: 5, page: 4, visibleCount: 4)
        #expect(store.zoom == 2.5 && store.panOffset == CGSize(width: -17, height: 23))
      }
    }
  }

  @Test("Option 선택은 여러 파일 선택을 해제하고 분류 ON일 때 새로 고른 사진에만 즉시 분류한다",
    arguments: [false, true], [UInt16(123), 124, 125, 126])
  func selectionClearsBatchAndTargetsClassification(marking: Bool, code: UInt16) async throws {
    let fixture = try Fixture(count: 12)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(4)
    store.navigatePage(1)
    store.frameLayout.swap(0, with: 3, count: 4)
    store.isPhotoMarking = marking
    store.beginTrackingViewerPresentation()
    defer { store.endTrackingViewerPresentation() }
    for (slot, asset) in store.visibleAssets.enumerated() {
      store.recordPresentedAsset(asset, slot: slot, requestedAsset: asset)
    }
    store.selectForBatch(index: 6, modifiers: [])
    store.selectForBatch(index: 7, modifiers: .command)
    try #require(store.selectedURLs == [store.assets[6].url, store.assets[7].url])
    let target = code == 123 || code == 124 ? 5 : 6
    #expect(store.handleViewerKeyDown(try key(code, modifiers: .option), shortcuts: shortcuts))
    expectSelection(store, index: target, page: 4, visibleCount: 4)
    try #require(store.canMarkPhoto(store.assets[target]) == marking)
    _ = store.handleViewerKeyDown(try key(18, characters: "1"), shortcuts: shortcuts)
    _ = store.handleViewerKeyDown(try key(18, repeating: true, characters: "1"), shortcuts: shortcuts)
    for (index, asset) in store.assets.enumerated() {
      let expected: Set<PhotoMarkSlot> = marking && index == target ? [.one] : []
      #expect(store.photoMarks.marks(for: asset) == expected)
    }
    expectSelection(store, index: target, page: 4, visibleCount: 4)
  }

  @Test("일곱 장 보기의 마지막 두 장도 재배치한 표시 순서로 순환한다", arguments: [false, true])
  func shortFinalPageCyclesOnlyItsTwoFrames(marking: Bool) async throws {
    let fixture = try Fixture(count: 23)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(7)
    store.isPhotoMarking = marking
    store.wrapsNavigation = true
    for _ in 0..<3 {
      #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    }
    expectPage(store, start: 21, visibleCount: 2)
    store.frameLayout.swap(0, with: 1, count: 2)
    try #require(store.frameLayout.configuration(for: 2).visualSlots == [1, 0])
    for wraps in [false, true] {
      store.wrapsNavigation = wraps
      store.select(index: 22)
      store.selectAllAssets()
      let path: [(code: UInt16, target: Int)] = [
        (124, 21), (124, 22), (123, 21), (123, 22), (125, 22), (126, 22),
      ]
      for step in path {
        #expect(store.handleViewerKeyDown(try key(step.code, modifiers: .option), shortcuts: shortcuts))
        expectSelection(store, index: step.target, page: 21, visibleCount: 2)
      }
    }
    #expect(store.photoMarks.marksByAssetID.isEmpty)
  }

  @Test("마지막 한 장은 제자리에 머물며 확대를 유지하고 여러 파일 선택만 정리한다",
    arguments: [false, true])
  func oneRemainingFrameKeepsViewportAndClearsBatch(marking: Bool) async throws {
    let fixture = try Fixture(count: 22)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.setImagesPerPage(7)
    store.isPhotoMarking = marking
    store.wrapsNavigation = true
    for _ in 0..<3 {
      #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    }
    expectPage(store, start: 21, visibleCount: 1)
    for wraps in [false, true] {
      store.wrapsNavigation = wraps
      for code in [UInt16(123), 124, 125, 126] {
        store.selectAllAssets()
        try #require(store.selectedURLs.count == 22)
        #expect(store.handleViewerKeyDown(try key(code, modifiers: .option), shortcuts: shortcuts))
        expectSelection(store, index: 21, page: 21, visibleCount: 1)
        store.zoom = 2.5
        store.panOffset = CGSize(width: 12, height: -9)
        #expect(store.handleViewerKeyDown(try key(code, modifiers: .option), shortcuts: shortcuts))
        expectSelection(store, index: 21, page: 21, visibleCount: 1)
        #expect(store.zoom == 2.5 && store.panOffset == CGSize(width: 12, height: -9))
      }
    }
  }

  @Test("사진 선택 별칭은 여러 장 일반 뷰어의 정확한 Option 네 방향에만 적용된다")
  func aliasScopeAndExactModifiers() async throws {
    let fixture = try Fixture(count: 23)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    // A single-photo viewer preserves the existing shortcut routes.
    for code in [UInt16(123), 124, 125, 126] {
      _ = store.handleViewerKeyDown(try key(code, modifiers: .option), shortcuts: shortcuts)
      #expect(store.pageStartIndex == 0 && store.currentIndex == 0)
    }
    store.setImagesPerPage(7)
    let modifierCombinations: [NSEvent.ModifierFlags] = [
      [.option, .shift], [.option, .command], [.option, .control],
    ]
    for modifiers in modifierCombinations {
      for code in [UInt16(123), 124, 125, 126] {
        let event = try key(code, modifiers: modifiers)
        #expect(shortcuts.viewerSelectionDirection(matching: event) == nil)
        _ = store.handleViewerKeyDown(event, shortcuts: shortcuts)
        #expect(store.pageStartIndex == 0 && store.currentIndex == 0)
      }
    }
    #expect(shortcuts.viewerSelectionDirection(matching: try key(124, modifiers: .option)) == .right)
    #expect(shortcuts.viewerSelectionDirection(matching: try key(123, modifiers: .option)) == .left)
    #expect(shortcuts.viewerSelectionDirection(matching: try key(125, modifiers: .option)) == .down)
    #expect(shortcuts.viewerSelectionDirection(matching: try key(126, modifiers: .option)) == .up)
    #expect(shortcuts.viewerSelectionDirection(matching: try key(124)) == nil)
    #expect(shortcuts.viewerSelectionDirection(matching: try key(124, modifiers: .option, type: .keyUp)) == nil)
    for mode in [PresentationMode.overview, .map] {
      store.presentationMode = mode
      try await ready(store)
      for code in [UInt16(123), 124, 125, 126] {
        _ = store.handleViewerKeyDown(try key(code, modifiers: .option), shortcuts: shortcuts)
        #expect(store.pageStartIndex == 0 && store.currentIndex == 0)
      }
    }
    store.presentationMode = .viewer
    #expect(store.handleViewerKeyDown(try key(124, modifiers: .option), shortcuts: shortcuts))
    expectSelection(store, index: 1, page: 0, visibleCount: 7)
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
      for code in [UInt16(125), 126] {
        _ = store.handleViewerKeyDown(try key(code, modifiers: .option), shortcuts: shortcuts)
        #expect(comparison.first.index == 0 && comparison.second.index == 0)
      }
      #expect(store.pageStartIndex == 0 && store.currentIndex == 0)
    }
  }

  @Test("텍스트 입력과 키를 놓는 이벤트는 선택 이동으로 전달하지 않고 반복 누름은 한 장씩 고른다")
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
    for code in [UInt16(123), 124, 125, 126] {
      #expect(!coordinator.handleKey(try key(code, modifiers: .option), isTextInput: true))
    }
    #expect(!coordinator.handleKey(try key(124, modifiers: .option, type: .keyUp), isTextInput: false))
    #expect(routedEvents == 0 && store.pageStartIndex == 0)
    #expect(coordinator.handleKey(try key(124, modifiers: .option), isTextInput: false))
    #expect(routedEvents == 1)
    expectSelection(store, index: 1, page: 0, visibleCount: 7)
    for expected in [2, 0, 1, 2, 0] {
      #expect(coordinator.handleKey(try key(124, modifiers: .option, repeating: true), isTextInput: false))
      expectSelection(store, index: expected, page: 0, visibleCount: 7)
    }
    #expect(coordinator.handleKey(try key(124, modifiers: .option, repeating: true), isTextInput: false))
    expectSelection(store, index: 1, page: 0, visibleCount: 7)
    #expect(!coordinator.handleKey(try key(124, modifiers: .option, type: .keyUp), isTextInput: false))
    #expect(store.photoMarks.marksByAssetID.isEmpty)
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
    let forwardEvents = [try key(124), try key(123, modifiers: .option),
      try key(124, modifiers: .option), try key(125, modifiers: .option), try key(126, modifiers: .option)]
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
    store.showsPhotoMarkTrackingReport = true
    expectBlocked()
    store.showsPhotoMarkTrackingReport = false
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
    store.motionMediaAsset = try #require(store.currentAsset)
    expectBlocked()
    store.motionMediaAsset = nil
    store.frameLayout.isEditing = true
    expectBlocked()
    store.frameLayout.isEditing = false

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
    store.select(index: 0)
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    expectPage(store, start: 7, visibleCount: 7)
    store.select(index: 0)
    #expect(store.handleViewerKeyDown(try key(124, modifiers: .option), shortcuts: shortcuts))
    expectSelection(store, index: 1, page: 0, visibleCount: 7)
  }

  private func expectSelection(_ store: AppStore, index: Int, page: Int, visibleCount: Int) {
    #expect(store.currentIndex == index && store.pageStartIndex == page)
    #expect(store.visibleAssets.count == visibleCount)
    #expect(store.selectedURLs == [store.assets[index].url])
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
      AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: photos.appendingPathComponent("marks.sqlite"))
    }

    @MainActor func cleanup(_ store: AppStore) {
      store.folderComparison.cancelLoads()
      store.photoMarks.flush()
      store.saveSessionNow()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: photos)
    }
  }
}
