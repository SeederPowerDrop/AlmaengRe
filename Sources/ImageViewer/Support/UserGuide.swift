import AppKit
import Foundation

/// Detailed documentation lives on GitHub; the app's basic help is a native view.
enum UserGuide {
  static let supportedLanguages = ["ko", "en", "ja", "zh-Hans", "fr", "es", "vi"]

  static func language(for localeIdentifier: String) -> String {
    let base = localeIdentifier.replacingOccurrences(of: "_", with: "-")
      .split(separator: "-").first?.lowercased() ?? ""
    if base == "zh" { return "zh-Hans" }
    return supportedLanguages.contains(base) ? base : "en"
  }

  static var currentLanguage: String {
    // Select the existing guide for the live app language. Languages without a
    // detailed guide retain the existing English fallback.
    language(for: L10n.languageIdentifier)
  }

  static func detailedURL(for localeIdentifier: String) -> URL {
    URL(string: "https://github.com/SeederPowerDrop/AlmaengRe/blob/main/docs/user-guide/\(language(for: localeIdentifier)).md")!
  }

  @MainActor
  static func openDetailedGuide() {
    if !NSWorkspace.shared.open(detailedURL(for: currentLanguage)) {
      NSSound.beep()
    }
  }
}
