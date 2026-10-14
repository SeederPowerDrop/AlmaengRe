import Foundation

enum MediaPlaybackL10n {
  static func text(_ key: String) -> String {
    L10n.text(key, localeIdentifier: L10n.languageIdentifier, table: "MediaPlayback")
  }
  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: text(key), locale: Locale.current, arguments: arguments)
  }
}
