import Foundation
import Testing

@testable import ImageViewer

@Suite("단축키 기능 도움말")
struct ShortcutHelpTests {
  @Test("모든 설정 동작과 보조 키 설명이 10개 언어에 존재한다")
  func everyActionHasLocalizedHelp() {
    let keys = ShortcutHelpL10n.keys(localeIdentifier: "ko")
    let controls: Set<String> = ["settings.hint", "key.helpFormat", "modifiers.control",
      "modifiers.option", "modifiers.shift", "modifiers.command", "conflict.helpFormat",
      "available.helpFormat", "reset.help"]
    #expect(controls.isSubset(of: keys))
    for action in ShortcutAction.allCases {
      let key = "action.\(action.rawValue).help"
      #expect(keys.contains(key))
      #expect(action.helpDescription != key && !action.helpDescription.isEmpty)
    }
    for locale in L10n.supportedLocalizations {
      #expect(ShortcutHelpL10n.keys(localeIdentifier: locale) == keys)
      for key in keys {
        let text = ShortcutHelpL10n.text(key, localeIdentifier: locale)
        #expect(text != key && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  @Test("설정된 단축키를 설명에 넣는 형식 인수가 모든 언어에서 일치한다")
  func shortcutFormatArgumentsStayCompatible() {
    for locale in L10n.supportedLocalizations {
      for key in ["key.helpFormat", "conflict.helpFormat", "available.helpFormat"] {
        let text = ShortcutHelpL10n.text(key, localeIdentifier: locale)
        #expect(text.components(separatedBy: "%@").count == 2)
        #expect(!text.replacingOccurrences(of: "%@", with: "").contains("%"))
      }
    }
  }
}
