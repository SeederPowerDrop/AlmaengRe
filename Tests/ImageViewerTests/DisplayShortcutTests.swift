import AppKit
import Testing

@testable import ImageViewer

@Suite("확대 이동·비교 단축키")
@MainActor
struct DisplayShortcutTests {
  @Test("새 기본 단축키는 중복되지 않고 Option 특수 문자와 한글 입력에서도 동작한다")
  func defaultBindingsAndKeyboardLayouts() throws {
    let suite = "ImageViewer.ShortcutTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let shortcuts = ShortcutStore(defaults: defaults)
    #expect(shortcuts.conflictingActions.isEmpty)
    let cases: [(UInt16, String, ShortcutAction)] = [
      (18, "¡", .panPrimaryDrag), (19, "™", .panSpaceDrag),
      (20, "£", .panSecondaryDrag), (21, "¢", .panMiddleDrag),
      (23, "∞", .panTrackpadScroll), (0, "å", .toggleAntialiasing),
      (0, "ㅁ", .toggleAntialiasing), (22, "§", .compareSideBySide),
      (26, "¶", .compareStacked), (29, "º", .endMagnificationComparison),
    ]
    for (code, characters, expected) in cases {
      let event = try makeEvent(code: code, characters: characters, modifiers: [.control, .option])
      #expect(shortcuts.action(matching: event) == expected)
    }
    #expect(
      shortcuts.action(matching: try makeEvent(code: 18, characters: "1", modifiers: []))
        == nil)
    #expect(
      shortcuts.action(matching: try makeEvent(code: 18, characters: "1", modifiers: [.command]))
        == .actualPixels)
  }

  @Test("실제 크기의 이전 기본값만 Command-1로 옮기고 사용자 지정과 충돌을 보존한다")
  func actualPixelsDefaultMigration() throws {
    let suite = "ImageViewer.ShortcutMigrationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let legacy = KeyBinding(key: "1")
    let commandOne = KeyBinding(key: "1", modifiers: [.command])
    let custom = KeyBinding(key: "k", modifiers: [.command, .shift])
    let cases: [(saved: [String: KeyBinding], expected: KeyBinding)] = [
      (["actualPixels": legacy, "previousPage": custom], commandOne),
      (["previousPage": custom], commandOne),
      (["actualPixels": custom], custom),
      (["actualPixels": legacy, "nextPage": commandOne], legacy),
      (["nextPage": commandOne], legacy),
    ]
    for scenario in cases {
      defaults.removePersistentDomain(forName: suite)
      defaults.set(try JSONEncoder().encode(scenario.saved), forKey: "ImageViewer.ShortcutBindings.v1")
      let shortcuts = ShortcutStore(defaults: defaults)
      #expect(shortcuts.binding(for: .actualPixels) == scenario.expected)
      #expect(shortcuts.conflictingActions.isEmpty)
      for (action, binding) in scenario.saved where action != "actualPixels" {
        #expect(shortcuts.binding(for: try #require(ShortcutAction(rawValue: action))) == binding)
      }
      #expect(ShortcutStore(defaults: defaults).binding(for: .actualPixels) == scenario.expected)
      shortcuts.setBinding(legacy, for: .actualPixels)
      #expect(ShortcutStore(defaults: defaults).binding(for: .actualPixels) == legacy)
      shortcuts.reset()
      #expect(ShortcutStore(defaults: defaults).binding(for: .actualPixels) == commandOne)
    }
  }

  @Test("이전 사용자 단축키를 보존하고 새 단축키도 수정·저장·초기화한다")
  func persistenceAndMigration() throws {
    let suite = "ImageViewer.ShortcutTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let saved = KeyBinding(key: "j", modifiers: [.command, .shift])
    defaults.set(
      try JSONEncoder().encode(["previousPage": saved]), forKey: "ImageViewer.ShortcutBindings.v1")
    let shortcuts = ShortcutStore(defaults: defaults)
    #expect(shortcuts.binding(for: .previousPage) == saved)
    #expect(shortcuts.binding(for: .panPrimaryDrag) == ShortcutAction.panPrimaryDrag.defaultBinding)

    let custom = KeyBinding(key: "k", modifiers: [.command, .shift])
    shortcuts.setBinding(custom, for: .compareStacked)
    let restored = ShortcutStore(defaults: defaults)
    #expect(restored.binding(for: .previousPage) == saved)
    #expect(restored.binding(for: .compareStacked) == custom)
    #expect(
      restored.action(
        matching: try makeEvent(code: 40, characters: "K", modifiers: [.command, .shift]))
        == .compareStacked)
    restored.setBinding(custom, for: .compareSideBySide)
    #expect(restored.conflictingActions == [.compareSideBySide, .compareStacked])
    restored.reset()
    #expect(restored.conflictingActions.isEmpty)
    #expect(restored.binding(for: .compareStacked) == ShortcutAction.compareStacked.defaultBinding)
  }

  @Test("다섯 이동 방식의 메뉴 동작과 단축키가 같은 설정을 변경하고 저장한다")
  func panActions() async throws {
    let suite = "ImageViewer.ShortcutTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("pan-shortcut-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let photo = folder.appendingPathComponent("synthetic.qoi")
    try Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
      0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]).write(to: photo)
    store.open(urls: [photo])
    let deadline = ContinuousClock.now + .seconds(5)
    while (store.isLoading || store.isFiltering), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!store.isLoading && !store.isFiltering && store.assets.count == 1)
    try #require(!store.showsHome && store.presentationMode == .viewer)
    for mode in PanInteractionMode.allCases {
      store.perform(mode.shortcutAction)
      #expect(store.panInteractionMode == mode)
      #expect(
        AppStore(defaults: defaults, monitorsSystemResources: false).panInteractionMode == mode)
    }
  }

  private func makeEvent(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) throws
    -> NSEvent
  {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: 0, windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
      ))
  }
}
