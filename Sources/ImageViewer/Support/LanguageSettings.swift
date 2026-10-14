import AppKit

/// macOS owns the per-app language preference. Keep all app windows on the same
/// bundle localization instead of introducing a separate in-app language switch.
enum LanguageSettings {
  static let systemSettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!

  static func text(_ key: String, language: String = L10n.languageIdentifier) -> String {
    L10n.text(key, localeIdentifier: language, table: "LanguageSettings")
  }

  static func languageName(for language: String = L10n.languageIdentifier) -> String {
    Locale(identifier: language).localizedString(forIdentifier: language) ?? language
  }

  @MainActor
  static func openSystemSettings() {
    if !NSWorkspace.shared.open(systemSettingsURL),
      let settings = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.systempreferences") {
      NSWorkspace.shared.open(settings)
    }
  }
}
