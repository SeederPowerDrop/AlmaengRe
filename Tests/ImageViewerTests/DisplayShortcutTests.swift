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
        == .actualPixels)
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
  func panActions() throws {
    let suite = "ImageViewer.ShortcutTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
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
