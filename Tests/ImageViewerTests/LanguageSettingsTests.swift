import AppKit
import Testing

@testable import ImageViewer

@Suite("macOS 앱 언어 설정 안내")
@MainActor
struct LanguageSettingsTests {
  @Test("모든 지원 언어의 설정 버튼과 현재 언어가 설정 창 한 줄에 들어간다",
    arguments: L10n.supportedLocalizations)
  func languageControlsFit(language: String) {
    let title = LanguageSettings.text("open", language: language)
    #expect(!title.isEmpty && title != "open")
    #expect(!title.contains("\n"))
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let buttonWidth = (title as NSString).size(withAttributes: [.font: font]).width + 52
    #expect(buttonWidth < 600, "\(language): \(buttonWidth)")

    let name = LanguageSettings.languageName(for: language)
    let current = LanguageSettings.text("current", language: language)
    let rowWidth = ((current + "  " + name) as NSString)
      .size(withAttributes: [.font: font]).width
    #expect(!name.isEmpty && name != language)
    #expect(rowWidth < 600, "\(language): \(rowWidth)")
  }

  @Test("현재 언어 안내는 실제 UI 문자열과 같은 번들 언어를 사용한다")
  func currentLanguageMatchesUI() {
    #expect(LanguageSettings.text("title") == L10n.text("title",
      localeIdentifier: L10n.languageIdentifier, table: "LanguageSettings"))
    #expect(LanguageSettings.languageName() == LanguageSettings.languageName(
      for: L10n.languageIdentifier))
    #expect(LanguageSettings.systemSettingsURL.scheme == "x-apple.systempreferences")
    #expect(LanguageSettings.systemSettingsURL.absoluteString
      .contains("com.apple.Localization-Settings.extension"))
  }
}
