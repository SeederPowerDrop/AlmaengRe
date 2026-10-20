import Foundation
import Testing

@testable import ImageViewer

@Suite("기본 사용법과 GitHub 설명서")
struct UserGuideTests {
  @Test("일곱 설명서 언어와 지역별 언어 식별자를 고른다")
  func languageSelection() {
    let expected = [
      "ko": "ko", "ko-KR": "ko", "en-US": "en", "en_GB": "en",
      "ja-JP": "ja", "zh-Hans": "zh-Hans", "zh-TW": "zh-Hans",
      "zh_Hant_HK": "zh-Hans", "fr-FR": "fr", "es-MX": "es",
      "vi-VN": "vi", "ar": "en", "ar-SA": "en",
      "de": "en", "de-DE": "en", "ru": "en", "ru-RU": "en", "": "en",
    ]
    for (identifier, language) in expected {
      #expect(UserGuide.language(for: identifier) == language)
      let url = UserGuide.detailedURL(for: identifier)
      #expect(url.scheme == "https")
      #expect(url.host == "github.com")
      #expect(url.path == "/SeederPowerDrop/AlmaengRe/blob/main/docs/user-guide/\(language).md")
    }
    #expect(UserGuide.supportedLanguages == ["ko", "en", "ja", "zh-Hans", "fr", "es", "vi"])
  }

  @Test("기본 도움말과 메뉴를 열 UI 언어에서 제공한다")
  func localizedBasicUsage() {
    let keys = ["기본 사용법", "상세 사용설명서 (GitHub)", "basicUsage.intro",
      "basicUsage.settingsButton", "basicUsage.browse.pages"]
      + BasicUsageTopic.allCases.flatMap { [$0.titleKey, $0.bodyKey] }
    for language in L10n.supportedLocalizations {
      let availableKeys = L10n.keys(localeIdentifier: language)
      for key in keys {
        #expect(availableKeys.contains(key))
        let text = L10n.text(key, localeIdentifier: language)
        #expect(!text.isEmpty)
        if key.hasPrefix("basicUsage.") { #expect(text != key) }
        let reference = L10n.text(key, localeIdentifier: "en")
        #expect(text.components(separatedBy: "%@").count == reference.components(separatedBy: "%@").count)
      }
    }
  }

  @Test("안내는 실제 페이지 단축키를 따르고 사진 선택 별칭과 구분한다")
  @MainActor
  func followsCurrentShortcuts() throws {
    let suite = "UserGuideTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let shortcuts = ShortcutStore(defaults: defaults)
    shortcuts.setBinding(KeyBinding(key: "p", modifiers: [.command, .shift]), for: .openFolder)
    #expect(BasicUsageTopic.open.body(shortcuts: shortcuts).contains("⇧⌘P"))
    shortcuts.setBinding(KeyBinding(key: "v", modifiers: [.command, .option]), for: .exportImage)
    #expect(BasicUsageTopic.edit.body(shortcuts: shortcuts).contains("⌥⌘V"))

    let defaultPageGuidance = L10n.format("basicUsage.browse.pages", "← / →")
    #expect(BasicUsageTopic.browse.body(shortcuts: shortcuts).contains(defaultPageGuidance))
    shortcuts.setBinding(KeyBinding(key: "j", modifiers: [.control, .shift]), for: .previousPage)
    #expect(BasicUsageTopic.browse.body(shortcuts: shortcuts).contains(
      L10n.format("basicUsage.browse.pages", "⌃⇧J / →")))
    shortcuts.setBinding(KeyBinding(key: "k", modifiers: [.command, .shift]), for: .nextPage)
    let customPageGuidance = L10n.format("basicUsage.browse.pages", "⌃⇧J / ⇧⌘K")
    let customBody = BasicUsageTopic.browse.body(shortcuts: shortcuts)
    #expect(customBody.contains(customPageGuidance))
    #expect(!customBody.contains(defaultPageGuidance))

    // Option arrows select photos within a page. Occupying those aliases does
    // not disable either independently configured page-navigation shortcut.
    shortcuts.setBinding(KeyBinding(key: "left", modifiers: [.option]), for: .toggleFocus)
    #expect(shortcuts.viewerSelectionBinding(direction: .left) == nil)
    #expect(shortcuts.viewerSelectionBinding(direction: .right) != nil)
    #expect(BasicUsageTopic.browse.body(shortcuts: shortcuts) == customBody)
    shortcuts.setBinding(KeyBinding(key: "right", modifiers: [.option]), for: .toggleOverview)
    #expect(shortcuts.viewerSelectionBinding(direction: .right) == nil)
    #expect(BasicUsageTopic.browse.body(shortcuts: shortcuts) == customBody)
  }
}
