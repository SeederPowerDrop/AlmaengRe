import Combine
import Foundation

/// An app-only preference. It never rewrites macOS AppleLanguages or rebuilds
/// the photo workspace when the user changes the language.
@MainActor
final class LanguageStore: ObservableObject {
  static let defaultsKey = L10n.languageDefaultsKey
  @Published var selection: String {
    didSet {
      let normalized = Self.normalized(selection)
      if selection != normalized { selection = normalized }
      defaults.set(selection, forKey: Self.defaultsKey)
      preference?.selection = selection
    }
  }

  private let defaults: UserDefaults
  private let systemLanguage: String
  private let regionalLocale: Locale
  private let preference: AppLanguagePreference?

  init(defaults: UserDefaults = .standard,
    systemLanguage: String = L10n.systemLanguageIdentifier,
    regionalLocale: Locale = .current, preference: AppLanguagePreference? = nil) {
    self.defaults = defaults
    self.systemLanguage = systemLanguage
    self.regionalLocale = regionalLocale
    self.preference = preference ?? (defaults === UserDefaults.standard ? .shared : nil)
    selection = Self.normalized(defaults.string(forKey: Self.defaultsKey))
  }

  var languageIdentifier: String {
    L10n.resolvedLanguage(selection: selection, systemLanguage: systemLanguage)
  }

  var locale: Locale {
    // SwiftUI uses this language for LocalizedStringKey. Keep the user's region,
    // calendar, numbering, currency and hour-cycle preferences separately.
    let language = Locale.Language(identifier: languageIdentifier)
    var components = Locale.Components(languageCode: language.languageCode, script: language.script)
    components.region = regionalLocale.region
    components.calendar = regionalLocale.calendar.identifier
    components.currency = regionalLocale.currency
    components.numberingSystem = regionalLocale.numberingSystem
    components.hourCycle = regionalLocale.hourCycle
    components.firstDayOfWeek = regionalLocale.firstDayOfWeek
    components.measurementSystem = regionalLocale.measurementSystem
    return Locale(components: components)
  }

  private static func normalized(_ selection: String?) -> String {
    guard let selection, L10n.supportedLocalizations.contains(selection) else { return "system" }
    return selection
  }
}
