import Foundation
import Testing

@testable import ImageViewer

@Suite("여러 장 보기 페이지 이동 안내")
struct ViewerPageLocalizationTests {
  @Test("페이지 안내와 화면 안 선택 안내는 다른 키를 표시하며 사용자 지정 키를 존중한다")
  @MainActor
  func hintBindingsMatchNavigationRoutes() throws {
    let suite = "ViewerPageLocalizationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let shortcuts = ShortcutStore(defaults: defaults)
    #expect(ViewerNavigationHintText.pageKeys(shortcuts: shortcuts) == "← / →")
    #expect(ViewerNavigationHintText.selectionKeys(shortcuts: shortcuts) == "⌥← / ⌥→")
    #expect(ViewerNavigationHintText.selectionHelp(shortcuts: shortcuts) != nil)
    shortcuts.setBinding(KeyBinding(key: "left", modifiers: .option), for: .zoomOut)
    #expect(ViewerNavigationHintText.selectionKeys(shortcuts: shortcuts) == "⌥→")
    shortcuts.setBinding(KeyBinding(key: "right", modifiers: .option), for: .zoomIn)
    #expect(ViewerNavigationHintText.selectionHelp(shortcuts: shortcuts) == nil)
    #expect(!ViewerNavigationHintText.markingPanelHint(shortcuts: shortcuts).contains("⌥"))
    #expect(ViewerNavigationHintText.pageKeys(shortcuts: shortcuts) == "← / →")
  }

  @Test("10개 언어의 안내와 도움말이 단축키·장수 인수를 올바르게 표시한다", arguments: [3, 6, 10])
  func localizedPageHintsPreserveArguments(count: Int) {
    let shortcut = "← / →"
    let cases: [(String, [String], [CVarArg])] = [
      ("%@ · %d장씩 이동", ["%@", "%d"], [shortcut, count]),
      ("%@로 한 화면에 설정한 %d장씩 넘깁니다. 분류 모드에서도 사용할 수 있습니다.",
        ["%@", "%d"], [shortcut, count]),
      ("이전 %d장 보기 (%@)", ["%d", "%@"], [count, shortcut]),
      ("다음 %d장 보기 (%@)", ["%d", "%@"], [count, shortcut]),
    ]
    for locale in L10n.supportedLocalizations {
      for (key, placeholders, arguments) in cases {
        #expect(L10n.keys(localeIdentifier: locale).contains(key))
        let format = L10n.text(key, localeIdentifier: locale)
        if locale != "ko" { #expect(format != key) }
        let first = format.range(of: placeholders[0])
        let second = format.range(of: placeholders[1])
        #expect(first != nil && second != nil)
        if let first, let second { #expect(first.lowerBound < second.lowerBound) }
        let result = String(format: format, locale: Locale(identifier: "en_US"), arguments: arguments)
        #expect(result.contains(shortcut) && result.contains(String(count)))
        #expect(!result.contains("%@") && !result.contains("%d"))
      }
    }
  }
}
