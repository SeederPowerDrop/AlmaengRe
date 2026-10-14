import Foundation

/// Shared language names and copy for the menu bar and the General settings.
enum LanguageSettings {
  static func text(_ key: String, language: String = L10n.languageIdentifier) -> String {
    L10n.text(key, localeIdentifier: language, table: "LanguageSettings")
  }

  static func languageName(for language: String = L10n.languageIdentifier) -> String {
    Locale(identifier: language).localizedString(forIdentifier: language) ?? language
  }
}
