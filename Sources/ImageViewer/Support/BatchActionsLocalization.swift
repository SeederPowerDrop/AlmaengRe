import Foundation

enum BatchActionsL10n {
  static func text(_ key: String) -> String {
    L10n.text(key, localeIdentifier: L10n.languageIdentifier, table: "BatchActions")
  }
}
