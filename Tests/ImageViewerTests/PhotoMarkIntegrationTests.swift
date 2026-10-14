import AppKit
import SQLite3
import Testing

@testable import ImageViewer

@Suite("사진 분류 작업 흐름")
@MainActor
struct PhotoMarkIntegrationTests {
  @Test("분류 저장이 대기 중이어도 자동 세션 저장이 진행되고 종료 저장은 분류를 완료한다")
  func automaticSessionSaveDoesNotWaitForMarkWrites() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    let photo = try #require(store.currentAsset)
    store.saveSessionNow()
    store.togglePhotoMarking()

    var connection: OpaquePointer?
    let opened = sqlite3_open_v2(fixture.database.path, &connection,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    defer { if let connection { sqlite3_close(connection) } }
    try #require(opened == SQLITE_OK)
    let database = try #require(connection)
    try #require(sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
    var isLocked = true
    defer {
      if isLocked { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
    }

    // The production mark queue cannot commit while this independent writer
    // holds its lock. The ordinary 500 ms session debounce must still finish.
    store.togglePhotoMark(.one)
    store.zoom = 2
    let sessions = ViewerSessionPersistence(defaults: fixture.defaults)
    let deadline = ContinuousClock.now + .seconds(10)
    while sessions.loadSession()?.zoom != 2, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let sessionSavedWhileLocked = sessions.loadSession()?.zoom == 2
    var statement: OpaquePointer?
    let prepared = sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM asset_marks", -1, &statement, nil)
    var markCountWhileLocked: Int32?
    if prepared == SQLITE_OK, let statement, sqlite3_step(statement) == SQLITE_ROW {
      markCountWhileLocked = sqlite3_column_int(statement, 0)
    }
    if let statement { sqlite3_finalize(statement) }
    // Release before assertions and explicit flushes, including failure paths.
    let released = sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
    isLocked = released != SQLITE_OK
    try #require(released == SQLITE_OK)

    #expect(sessionSavedWhileLocked)
    #expect(markCountWhileLocked == 0)
    store.saveSessionNow()
    #expect(store.photoMarks.isReady && store.photoMarks.errorMessage == nil)
    let reopened = PhotoMarkStore(databaseURL: fixture.database)
    await reopened.waitUntilReady()
    #expect(reopened.isReady)
    #expect(reopened.marks(for: photo) == [.one])
  }

  @Test("분류 모드는 왼손 물리 키와 화면 단위 이동을 쓰고 원래 단축키를 보존한다")
  func keyboardMarkingAndPageNavigation() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    let original = try #require(store.currentAsset)
    let originalBytes = try Data(contentsOf: original.url)

    #expect(!store.handleViewerKeyDown(try key(18, characters: "1"), shortcuts: shortcuts))
    #expect(store.baseScaleMode == .fit)
    #expect(store.handleViewerKeyDown(try key(18, characters: "1", modifiers: .command), shortcuts: shortcuts))
    #expect(store.baseScaleMode == .actualPixels)
    #expect(store.photoMarks.marks(for: original).isEmpty)
    store.setFitToWindow()
    store.setImagesPerPage(2)
    store.togglePhotoMarking()
    #expect(store.isPhotoMarking && store.canMarkPhoto)

    for (code, characters) in [(UInt16(18), "1"), (12, "ㅂ"), (3, "ㄹ")] {
      #expect(store.handleViewerKeyDown(try key(code, characters: characters), shortcuts: shortcuts))
    }
    #expect(store.photoMarks.marks(for: original) == [.one, .q, .f])
    #expect(store.currentAsset?.sessionID == original.sessionID)
    #expect(!store.isFocusMode && store.baseScaleMode == .fit)
    #expect(store.handleViewerKeyDown(try key(18, characters: "1", repeatKey: true), shortcuts: shortcuts))
    #expect(store.photoMarks.marks(for: original) == [.one, .q, .f])

    #expect(store.handleViewerKeyDown(try key(18, characters: "1", modifiers: .command), shortcuts: shortcuts))
    // Multi-view keeps frame fitting even when the legacy 1:1 shortcut is used;
    // the same shortcut's single-image behavior is verified before entering it.
    #expect(store.baseScaleMode == .fit)
    #expect(store.photoMarks.marks(for: original) == [.one, .q, .f])
    store.setFitToWindow()

    #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    #expect(store.currentIndex == 2 && store.pageStartIndex == 2 && store.imagesPerPage == 2)
    let next = try #require(store.currentAsset)
    #expect(store.photoMarks.marks(for: next).isEmpty)
    #expect(store.handleViewerKeyDown(try key(123), shortcuts: shortcuts))
    #expect(store.currentIndex == 0)
    #expect(FileManager.default.fileExists(atPath: original.url.path))
    #expect(try Data(contentsOf: original.url) == originalBytes)

    store.togglePhotoMarking()
    #expect(!store.isPhotoMarking)
    #expect(!store.handleViewerKeyDown(try key(18, characters: "1"), shortcuts: shortcuts))
    #expect(store.baseScaleMode == .fit)
    #expect(store.handleViewerKeyDown(try key(18, characters: "1", modifiers: .command), shortcuts: shortcuts))
    #expect(store.baseScaleMode == .fit)
    #expect(store.photoMarks.marks(for: original) == [.one, .q, .f])
  }

  @Test("텍스트 입력·보조 키·시트에서는 사진 분류나 모드 전환이 일어나지 않는다")
  func textAndModalInputAreProtected() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    let original = try #require(store.currentAsset)
    store.togglePhotoMarking()
    let coordinator = InputEventMonitor.Coordinator(
      onKeyDown: { store.handleViewerKeyDown($0, shortcuts: shortcuts) },
      onPointerPan: { _, _ in false }, onHorizontalSwipe: { _ in })
    defer { coordinator.stopMonitoring() }

    #expect(!coordinator.handleKey(try key(12, characters: "ㅂ"), isTextInput: true))
    let modifiers: [NSEvent.ModifierFlags] = [.command, .control, .option, .shift]
    for modifier in modifiers {
      _ = coordinator.handleKey(try key(18, characters: "1", modifiers: modifier), isTextInput: false)
    }
    #expect(store.photoMarks.marks(for: original).isEmpty)

    store.presentPhotoMarkEditor()
    #expect(store.showsPhotoMarkEditor && !store.canEditPhotoMarkLabels)
    #expect(!coordinator.handleKey(try key(18, characters: "1"), isTextInput: false))
    store.togglePhotoMarking()
    #expect(store.isPhotoMarking)
    store.showsPhotoMarkEditor = false

    store.batchSheet = .rename
    #expect(!store.canEditPhotoMarkLabels)
    store.presentPhotoMarkEditor()
    #expect(!store.showsPhotoMarkEditor)
    #expect(!coordinator.handleKey(try key(18, characters: "1"), isTextInput: false))
    store.togglePhotoMarking()
    #expect(store.isPhotoMarking)
    store.batchSheet = nil

    store.showsAIUpscaling = true
    #expect(!store.canEditPhotoMarkLabels && !store.canTogglePhotoMarking)
    store.presentPhotoMarkEditor()
    #expect(!store.showsPhotoMarkEditor)
    #expect(!coordinator.handleKey(try key(18, characters: "1"), isTextInput: false))
    store.togglePhotoMarking()
    #expect(store.isPhotoMarking)
    store.showsAIUpscaling = false
    #expect(store.canEditPhotoMarkLabels)
    #expect(store.photoMarks.marks(for: original).isEmpty)

    #expect(coordinator.handleKey(try key(12, characters: "ㅂ"), isTextInput: false))
    #expect(store.photoMarks.marks(for: original) == [.q])
  }

  @Test("하나라도·모두·미분류 필터와 복수 마킹 중 현재 사진 유지가 연결된다")
  func collectionFiltersAndStableMarkingList() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    let photos = store.assets
    store.photoMarks.toggle(.one, for: photos[0])
    store.photoMarks.toggle(.w, for: photos[1])
    store.photoMarks.toggle(.one, for: photos[2])
    store.photoMarks.toggle(.w, for: photos[2])

    store.photoMarkFilter = PhotoMarkFilter(slots: [.one, .w])
    try await ready(store)
    #expect(store.assets.map(\.filename) == ["photo1.png", "photo2.png", "photo3.png"])
    store.photoMarkFilter.matchesAll = true
    try await ready(store)
    #expect(store.assets.map(\.filename) == ["photo3.png"])
    store.photoMarkFilter = PhotoMarkFilter(unmarkedOnly: true)
    try await ready(store)
    #expect(store.assets.map(\.filename) == ["photo4.png"])
    #expect(store.hasLibraryQuery)

    // Filtering removed the prior selection. Explicitly choose the remaining
    // file before marking; an empty selection must not mark the focused item.
    #expect(store.selectedURLs.isEmpty)
    store.select(index: 0)
    store.togglePhotoMarking()
    let current = try #require(store.currentAsset)
    store.togglePhotoMark(.one)
    store.togglePhotoMark(.w)
    // Let the asynchronous mark-change subscriber run; it must keep this review list intact.
    await Task.yield()
    try await Task.sleep(for: .milliseconds(150))
    #expect(store.assets.map(\.sessionID) == [current.sessionID])
    #expect(store.currentAsset?.sessionID == current.sessionID && !store.isFiltering)
    #expect(store.photoMarks.marks(for: current) == [.one, .w])

    store.togglePhotoMarking()
    try await ready(store)
    #expect(store.assets.isEmpty && store.allAssets.count == 4)
    store.resetLibraryQuery()
    try await ready(store)
    #expect(store.assets.count == 4 && !store.hasLibraryQuery)
  }

  @Test("실제 파일명 일괄 변경 뒤에도 사진 분류를 새 경로로 옮기고 재실행해 읽는다")
  func appRenameTransfersPersistentMarks() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    let original = try #require(store.currentAsset)
    let originalBytes = try Data(contentsOf: original.url)
    store.togglePhotoMarking()
    store.togglePhotoMark(.one)
    store.togglePhotoMark(.w)
    var options = BatchRenameOptions()
    options.prefix = "selected_"
    let plan = BatchRenamePlanner.plan(urls: [original.url], options: options)
    try #require(plan.canApply)

    try await store.renameSelectedFiles(using: plan)
    try await ready(store)
    let renamed = try #require(store.assets.first { $0.filename == "selected_photo1.png" })
    #expect(!FileManager.default.fileExists(atPath: original.url.path))
    #expect(try Data(contentsOf: renamed.url) == originalBytes)
    #expect(renamed.photoMarkID == original.photoMarkID)
    #expect(store.photoMarks.marks(for: renamed) == [.one, .w])
    #expect(store.currentAsset?.sessionID == renamed.sessionID)
    store.saveSessionNow()
    #expect(store.photoMarks.errorMessage == nil)

    let reopened = fixture.makeStore()
    defer { reopened.folderComparison.cancelLoads(); reopened.saveSessionNow() }
    try await openPhotos(reopened, fixture: fixture)
    let reopenedPhoto = try #require(reopened.assets.first { $0.filename == renamed.filename })
    #expect(reopened.photoMarks.marks(for: reopenedPhoto) == [.one, .w])
    #expect(reopenedPhoto.photoMarkID == original.photoMarkID)
  }

  @Test("명시한 A·B에 분류하고 대응 사진이 없는 비교 행도 방향키로 벗어난다")
  func explicitComparisonTargetAndMissingRowNavigation() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    let a = try fixture.makeFolder("A", names: ["b.png"])
    let b = try fixture.makeFolder("B", names: ["a.png", "b.png"])
    let comparison = store.folderComparison
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.presentationMode = .folderComparison
    comparison.open(urls: [a], for: .first)
    comparison.open(urls: [b], for: .second)
    try await ready(comparison)
    let first = try #require(comparison.first.currentAsset)
    let second = try #require(comparison.second.currentAsset)
    store.togglePhotoMarking()
    comparison.activeSide = .first
    #expect(store.handleViewerKeyDown(try key(18, characters: "1"), shortcuts: shortcuts))
    comparison.activeSide = .second
    comparison.photoMarkTarget = .second
    #expect(store.handleViewerKeyDown(try key(13, characters: "ㅈ"), shortcuts: shortcuts))
    #expect(store.photoMarks.marks(for: first) == [.one])
    #expect(store.photoMarks.marks(for: second) == [.w])

    comparison.alignment = .filename
    try await ready(comparison)
    comparison.jump(.second, number: 1)
    comparison.activeSide = .first
    comparison.photoMarkTarget = .first
    try #require(comparison.first.showsMissingCounterpart && store.photoMarkAsset == nil)
    try #require(comparison.canNavigate(.first, direction: 1))
    #expect(!store.canMarkPhoto)
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    #expect(comparison.first.currentAsset?.filename == "b.png")
    #expect(comparison.second.currentAsset?.filename == "b.png")
    #expect(comparison.activeSide == .first && store.canMarkPhoto)
    #expect(store.photoMarks.marks(for: first) == [.one])

    #expect(store.handleViewerKeyDown(try key(53), shortcuts: shortcuts))
    #expect(!store.isPhotoMarking && store.presentationMode == .folderComparison)
    #expect(store.handleViewerKeyDown(try key(53), shortcuts: shortcuts))
    #expect(store.presentationMode == .viewer)
  }

  @Test("비교 화면이 이전 사진을 유지하며 읽는 동안 새 사진에 잘못 분류하지 않는다")
  func comparisonMarkingWaitsForSelectedImagePresentation() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    let comparison = store.folderComparison
    store.presentationMode = .folderComparison
    comparison.open(urls: [fixture.photos], for: .first)
    try await ready(comparison)
    let pane = comparison.first
    let original = try #require(pane.currentAsset)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.togglePhotoMarking()

    // SwiftUI may deliver the child's initial presentation before parent onAppear.
    pane.recordPresentedAsset(original)
    pane.beginTrackingPresentation()
    #expect(store.canMarkPhoto)
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    let selected = try #require(pane.currentAsset)
    try #require(selected.id != original.id)
    #expect(!store.canMarkPhoto)
    comparison.toggleLock(on: .first)
    #expect(!pane.isLocked)
    #expect(store.handleViewerKeyDown(try key(18, characters: "1"), shortcuts: shortcuts))
    #expect(store.photoMarks.marks(for: selected).isEmpty)
    #expect(store.photoMarks.marks(for: original).isEmpty)

    // A late old preview cannot enable classification of the pending target.
    pane.recordPresentedAsset(original)
    #expect(!store.canMarkPhoto)
    pane.recordPresentedAsset(selected)
    #expect(store.canMarkPhoto)
    comparison.toggleLock(on: .first)
    #expect(pane.isLocked)
    // Locking A moves active navigation to B, while the explicit classification
    // target stays on A and may still mark that visible, fixed photo.
    #expect(comparison.activeSide == .second && comparison.photoMarkTarget == .first)
    #expect(store.handleViewerKeyDown(try key(18, characters: "1"), shortcuts: shortcuts))
    #expect(store.photoMarks.marks(for: selected) == [.one])
    #expect(store.photoMarks.marks(for: original).isEmpty)
    pane.recordPresentedAsset(nil)
    #expect(!store.canMarkPhoto)
    comparison.toggleLock(on: .first)
    #expect(!pane.isLocked)
    pane.endTrackingPresentation()
    #expect(store.canMarkPhoto)
  }

  @Test("12개 키의 분류 이름을 모두 바꿔도 기존 표시와 재실행 후 키 입력이 이어진다")
  func editableKeyAssignmentsKeepMembershipAndKeyboardRouting() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    let photo = try #require(store.currentAsset)
    store.togglePhotoMarking()
    _ = store.handleViewerKeyDown(try key(18, characters: "1"), shortcuts: shortcuts)
    _ = store.handleViewerKeyDown(try key(13, characters: "w"), shortcuts: shortcuts)
    let labels = Dictionary(uniqueKeysWithValues: PhotoMarkSlot.allCases.map {
      ($0, "직접 정한 \($0.keyLabel) 분류")
    })
    store.photoMarks.setLabels(labels)
    #expect(store.photoMarks.marks(for: photo) == [.one, .w])
    #expect(store.handleViewerKeyDown(try key(12, characters: "ㅂ"), shortcuts: shortcuts))
    #expect(store.photoMarks.marks(for: photo) == [.one, .w, .q])
    store.saveSessionNow()

    let reopened = fixture.makeStore()
    defer { reopened.folderComparison.cancelLoads(); reopened.saveSessionNow() }
    try await openPhotos(reopened, fixture: fixture)
    for slot in PhotoMarkSlot.allCases {
      #expect(reopened.photoMarks.label(for: slot) == labels[slot])
    }
    let reopenedPhoto = try #require(reopened.currentAsset)
    #expect(reopened.photoMarks.marks(for: reopenedPhoto) == [.one, .w, .q])
    reopened.togglePhotoMarking()
    #expect(reopened.handleViewerKeyDown(try key(18, characters: "1"), shortcuts: shortcuts))
    #expect(reopened.photoMarks.marks(for: reopenedPhoto) == [.w, .q])
  }

  @Test("분류 입력의 포커스 정리는 실제 검색 편집을 종료하고 이후 키를 사진에 적용한다")
  func classificationFocusCleanupEndsSearchEditing() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    let asset = try #require(store.currentAsset)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 400, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.orderOut(nil); window.close() }
    let search = NSSearchField(frame: NSRect(x: 20, y: 20, width: 300, height: 24))
    window.contentView?.addSubview(search)
    window.orderFront(nil)
    try #require(window.makeFirstResponder(search))
    try #require(window.firstResponder is NSTextView)
    search.stringValue = "photo"
    let coordinator = InputEventMonitor.Coordinator(
      onKeyDown: { store.handleViewerKeyDown($0, shortcuts: shortcuts) },
      onPointerPan: { _, _ in false }, onHorizontalSwipe: { _ in })
    defer { coordinator.stopMonitoring() }

    // Test the exact window operation used by the toolbar/card actions. A test
    // executable does not become the active app's key window merely by ordering
    // its window front; the real application supplies NSApp.keyWindow here.
    store.clearPhotoMarkTextFocus(in: window)
    store.togglePhotoMarking()
    #expect(store.isPhotoMarking)
    #expect(!(window.firstResponder is NSTextView))
    #expect(coordinator.handleKey(try key(18, characters: "1"),
      isTextInput: window.firstResponder is NSTextView,
      isControl: window.firstResponder is NSControl))
    #expect(store.photoMarks.marks(for: asset) == [.one])
    #expect(search.stringValue == "photo")

    // A card action leaves the selected keyboard target unchanged.
    store.setImagesPerPage(2)
    let other = store.assets[1]
    store.togglePhotoMark(.q, for: other)
    #expect(!(window.firstResponder is NSTextView))
    #expect(store.currentAsset?.id == asset.id)
    #expect(coordinator.handleKey(try key(13, characters: "w"),
      isTextInput: window.firstResponder is NSTextView))
    #expect(store.photoMarks.marks(for: asset) == [.one, .w])
    #expect(store.photoMarks.marks(for: other) == [.q])
  }

  @Test("빠른 다음 사진 이동은 화면에 도착한 프레임에만 분류 키를 적용한다")
  func keyboardWaitsForCurrentViewerPresentation() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    let first = try #require(store.currentAsset)
    store.togglePhotoMarking()
    // A child's first callback can precede the viewer's onAppear.
    store.recordPresentedAsset(first, slot: 0, requestedAsset: first)
    store.beginTrackingViewerPresentation()
    defer { store.endTrackingViewerPresentation() }
    try #require(store.canMarkPhoto)
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    let second = try #require(store.currentAsset)
    try #require(second.id != first.id)
    #expect(!store.canMarkPhoto)
    #expect(store.handleViewerKeyDown(try key(18, characters: "1"), shortcuts: shortcuts))
    #expect(store.photoMarks.marks(for: second).isEmpty)
    #expect(store.photoMarks.marks(for: first).isEmpty)

    store.recordPresentedAsset(first, slot: 0, requestedAsset: second)
    #expect(!store.canMarkPhoto)
    store.recordPresentedAsset(second, slot: 0, requestedAsset: second)
    try #require(store.canMarkPhoto)
    // An old task completing or disappearing cannot replace the new slot.
    store.recordPresentedAsset(first, slot: 0, requestedAsset: first)
    store.recordPresentedAsset(nil, slot: 0, requestedAsset: first)
    try #require(store.canMarkPhoto)
    #expect(store.handleViewerKeyDown(try key(18, characters: "1"), shortcuts: shortcuts))
    #expect(store.photoMarks.marks(for: second) == [.one])
    #expect(store.photoMarks.marks(for: first).isEmpty)
  }

  @Test("영상에서도 12개 물리 키는 ON에서만 분류하며 반복·보조 키·기존 이동키를 구분한다")
  func videoClassificationKeysPreserveOtherShortcuts() async throws {
    let fixture = try Fixture()
    let videoURL = fixture.photos.appendingPathComponent("video.mp4")
    // Library and classification metadata require no decoder or media playback.
    try Data("Synthetic classification video".utf8).write(to: videoURL)
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    await store.photoMarks.waitUntilReady()
    store.open(urls: [fixture.photos])
    try await ready(store)
    let video = try #require(store.assets.first { $0.isVideo })
    store.setImagesPerPage(2)
    store.select(asset: video)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    shortcuts.setBinding(KeyBinding(key: "1"), for: .nextPage)
    let coordinator = InputEventMonitor.Coordinator(
      onKeyDown: { store.handleViewerKeyDown($0, shortcuts: shortcuts) },
      onPointerPan: { _, _ in false }, onHorizontalSwipe: { _ in })
    defer { coordinator.stopMonitoring() }
    store.togglePhotoMarking()
    let codes: [UInt16] = [18, 19, 20, 21, 12, 13, 14, 15, 0, 1, 2, 3]
    for code in codes {
      #expect(coordinator.handleKey(try key(code, characters: "한"),
        isTextInput: false, isControl: true))
    }
    #expect(store.photoMarks.marks(for: video) == Set(PhotoMarkSlot.allCases))
    #expect(store.currentAsset?.id == video.id)
    #expect(coordinator.handleKey(try key(18, characters: "1", repeatKey: true),
      isTextInput: false, isControl: true))
    let modifiedKeys: [NSEvent.ModifierFlags] = [.command, .control, .option, .shift]
    for modifiers in modifiedKeys {
      _ = coordinator.handleKey(try key(12, characters: "q", modifiers: modifiers),
        isTextInput: false, isControl: true)
    }
    #expect(store.photoMarks.marks(for: video) == Set(PhotoMarkSlot.allCases))
    store.togglePhotoMarking()
    #expect(!store.isPhotoMarking)
    #expect(coordinator.handleKey(try key(18, characters: "1"), isTextInput: false))
    #expect(store.currentAsset?.id != video.id)
    #expect(store.photoMarks.marks(for: video) == Set(PhotoMarkSlot.allCases))
  }

  private func openPhotos(_ store: AppStore, fixture: Fixture) async throws {
    await store.photoMarks.waitUntilReady()
    try #require(store.photoMarks.isReady)
    store.open(urls: [fixture.photos])
    try await ready(store)
    try #require(store.assets.count == 4 && store.alert == nil)
  }

  private func ready(_ store: AppStore) async throws {
    for _ in 0..<500 {
      if !store.isLoading && !store.isFiltering { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.loadingTimedOut
  }

  private func ready(_ comparison: FolderComparisonStore) async throws {
    for _ in 0..<500 {
      if !comparison.first.isLoading && !comparison.second.isLoading
        && !comparison.first.isFiltering && !comparison.second.isFiltering && !comparison.isMatching { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.loadingTimedOut
  }

  private func key(_ code: UInt16, characters: String = "", repeatKey: Bool = false,
    modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
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
    let photos: URL
    let database: URL
    let suite: String
    let defaults: UserDefaults
    let png: Data

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoMarkIntegration-\(UUID())")
      photos = root.appendingPathComponent("Photos")
      database = root.appendingPathComponent("marks.sqlite")
      suite = "PhotoMarkIntegration.\(UUID())"
      defaults = try #require(UserDefaults(suiteName: suite))
      let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
      png = try #require(bitmap.representation(using: .png, properties: [:]))
      try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
      for index in 1...4 { try png.write(to: photos.appendingPathComponent("photo\(index).png")) }
    }

    @MainActor func makeStore() -> AppStore {
      AppStore(defaults: defaults, monitorsSystemResources: false, photoMarkDatabaseURL: database)
    }

    func makeFolder(_ name: String, names: [String]) throws -> URL {
      let folder = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for name in names { try png.write(to: folder.appendingPathComponent(name)) }
      return folder
    }
  }
}
