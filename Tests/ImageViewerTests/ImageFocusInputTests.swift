import AppKit
import Testing

@testable import ImageViewer

@Suite("더블클릭과 Space 집중 보기")
@MainActor
struct ImageFocusInputTests {
  @Test("Space는 키를 놓을 때 한 번 전환하고 반복 입력은 추가 전환하지 않는다")
  func tapOnRelease() throws {
    var taps = 0
    var ordinaryKeys = 0
    let coordinator = InputEventMonitor.Coordinator(
      onKeyDown: { _ in ordinaryKeys += 1; return false },
      onPointerPan: { _, _ in false }, onHorizontalSwipe: { _ in },
      canHandleSpaceTap: { true }, onSpaceTap: { taps += 1 })
    defer { coordinator.stopMonitoring() }
    #expect(coordinator.handleKey(try key(.keyDown), isTextInput: false))
    #expect(taps == 0)
    for _ in 0..<3 {
      #expect(coordinator.handleKey(try key(.keyDown, repeatKey: true), isTextInput: false))
    }
    #expect(coordinator.handleKey(try key(.keyUp), isTextInput: false))
    #expect(taps == 1 && ordinaryKeys == 0)
    #expect(!coordinator.handleKey(try key(.keyUp), isTextInput: false))
    #expect(taps == 1)
  }

  @Test("텍스트·버튼 입력과 사용자 Space 단축키는 기존 동작을 유지한다")
  func inputAndAssignedShortcut() throws {
    let suite = "ImageFocusInput.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let shortcuts = ShortcutStore(defaults: defaults)
    var taps = 0
    var actions: [ShortcutAction] = []
    let coordinator = InputEventMonitor.Coordinator(
      onKeyDown: { event in
        guard let action = shortcuts.action(matching: event) else { return false }
        actions.append(action); return true
      }, onPointerPan: { _, _ in false }, onHorizontalSwipe: { _ in },
      canHandleSpaceTap: { !shortcuts.hasPlainSpaceBinding }, onSpaceTap: { taps += 1 })
    defer { coordinator.stopMonitoring() }
    #expect(!coordinator.handleKey(try key(.keyDown), isTextInput: true))
    #expect(!coordinator.handleKey(try key(.keyUp), isTextInput: true))
    #expect(!coordinator.handleKey(try key(.keyDown), isTextInput: false, isControl: true))
    #expect(!coordinator.handleKey(try key(.keyDown, modifiers: .shift), isTextInput: false))
    shortcuts.setBinding(KeyBinding(key: "space"), for: .nextPage)
    #expect(coordinator.handleKey(try key(.keyDown), isTextInput: false))
    #expect(!coordinator.handleKey(try key(.keyUp), isTextInput: false))
    #expect(actions == [.nextPage] && taps == 0)
  }

  @Test("드래그·다른 키·창 전환 또는 작업 시트로 중단된 Space는 집중 보기를 바꾸지 않는다")
  func interruptedTap() throws {
    var gesture = SpaceTapState()
    gesture.begin(isRepeat: false)
    gesture.useForGesture()
    gesture.begin(isRepeat: true)
    let draggedTap = gesture.end()
    #expect(!draggedTap)
    gesture.begin(isRepeat: false)
    let plainTap = gesture.end()
    #expect(plainTap)

    var taps = 0
    var enabled = true
    let coordinator = InputEventMonitor.Coordinator(
      onKeyDown: { _ in false }, onPointerPan: { _, _ in false }, onHorizontalSwipe: { _ in },
      canHandleSpaceTap: { enabled }, onSpaceTap: { taps += 1 })
    defer { coordinator.stopMonitoring() }
    _ = coordinator.handleKey(try key(.keyDown), isTextInput: false)
    _ = coordinator.handleKey(try key(.keyDown, code: 123), isTextInput: false)
    _ = coordinator.handleKey(try key(.keyUp), isTextInput: false)
    _ = coordinator.handleKey(try key(.keyDown), isTextInput: false)
    enabled = false
    _ = coordinator.handleKey(try key(.keyUp), isTextInput: false)
    enabled = true
    _ = coordinator.handleKey(try key(.keyDown), isTextInput: false)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: nil)
    _ = coordinator.handleKey(try key(.keyUp), isTextInput: false)
    #expect(taps == 0)
  }

  @Test("현재 사진의 집중 보기 전환은 확대 위치를 보존하고 클릭한 다른 사진을 선택한다")
  func focusedImageAndGuards() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImageFocus-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=")!
    for name in ["a.png", "b.png"] { try png.write(to: root.appendingPathComponent(name)) }
    let suite = "ImageFocusInput.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    #expect(!store.canToggleImageFocus)
    store.open(urls: [root])
    for _ in 0..<300 where store.isLoading { try await Task.sleep(for: .milliseconds(10)) }
    try #require(store.assets.count == 2 && !store.isLoading)
    store.zoomIn()
    store.panOffset = CGSize(width: 10, height: 20)
    let zoom = store.zoom
    store.toggleImageFocus(on: store.currentAsset)
    #expect(store.isFocusMode && store.zoom == zoom && store.panOffset == CGSize(width: 10, height: 20))
    store.toggleImageFocus()
    #expect(!store.isFocusMode)
    store.toggleImageFocus(on: store.assets[1])
    #expect(store.isFocusMode && store.currentIndex == 1)
    #expect(store.handleEscapeKey() && !store.isFocusMode)
    store.select(index: 0)
    store.zoomIn()
    store.panInteractionMode = .spacePrimaryDrag
    let shortcuts = ShortcutStore(defaults: defaults)
    shortcuts.setBinding(KeyBinding(key: "space"), for: .nextPage)
    #expect(store.handleViewerKeyDown(try key(.keyDown), shortcuts: shortcuts))
    #expect(store.currentIndex == 1 && !store.isFocusMode)
    store.select(index: 0)
    store.zoomIn()
    shortcuts.setBinding(KeyBinding(key: "space", modifiers: .shift), for: .nextPage)
    #expect(store.handleViewerKeyDown(try key(.keyDown, modifiers: .shift), shortcuts: shortcuts))
    #expect(store.currentIndex == 1 && !store.isFocusMode)
    store.showsAIUpscaling = true
    store.toggleImageFocus()
    #expect(!store.isFocusMode && !store.canToggleImageFocus)
    store.showsAIUpscaling = false
    store.presentationMode = .folderComparison
    store.toggleImageFocus()
    #expect(!store.isFocusMode && store.presentationMode == .folderComparison)
    store.presentationMode = .overview
    #expect(!store.canToggleImageFocus)
  }

  private func key(_ type: NSEvent.EventType, code: UInt16 = 49, repeatKey: Bool = false,
    modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: 0, context: nil, characters: " ",
      charactersIgnoringModifiers: " ", isARepeat: repeatKey, keyCode: code))
  }
}
