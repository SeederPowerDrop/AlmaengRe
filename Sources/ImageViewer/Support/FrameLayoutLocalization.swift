import Foundation

/// Multi-view frame controls use the selected app language and retain the user's
/// regional number formatting independently of that language.
enum FrameLayoutL10n {
  static func text(_ key: String, language: String = L10n.languageIdentifier) -> String {
    L10n.text(key, localeIdentifier: language, table: "FrameLayout")
  }

  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: text(key), locale: Locale.current, arguments: arguments)
  }
}
