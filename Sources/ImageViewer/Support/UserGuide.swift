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
    // Honor the language assigned to this app in macOS. SwiftPM keeps its
    // localizations in a separate bundle, while the packaged app uses main.
    let bundle: Bundle = Bundle.main.url(forResource: "Localizable", withExtension: "strings") != nil
      ? .main : .module
    return language(for: bundle.preferredLocalizations.first
      ?? Locale.preferredLanguages.first ?? "en")
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
