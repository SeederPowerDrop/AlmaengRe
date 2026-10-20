import Foundation

struct HomeQuote: Decodable, Identifiable, Sendable {
  struct Localization: Decodable, Sendable {
    let text: String
    let author: String
    let work: String
    let isTranslation: Bool
  }

  let id: String
  let sourceURL: URL
  let originalText: String
  let originalLanguage: String
  let publicDomainBasis: String
  let localizations: [String: Localization]

  func localized(for language: String) -> Localization? {
    let identifier = Bundle.preferredLocalizations(
      from: L10n.supportedLocalizations, forPreferences: [language]).first ?? "ko"
    return localizations[identifier] ?? localizations["ko"]
  }
}

/// The bundled collection never needs a network request. One choice is retained
/// for the entire process, including closing a window or returning to Home.
@MainActor
enum HomeInspiration {
  static let previousQuoteKey = "ImageViewer.HomeQuote.PreviousID.v1"
  static let quotes: [HomeQuote] = {
    let url = Bundle.main.url(forResource: "HomeQuotes", withExtension: "json")
      ?? Bundle.module.url(forResource: "HomeQuotes", withExtension: "json")
    guard let url, let data = try? Data(contentsOf: url),
      let collection = try? JSONDecoder().decode([HomeQuote].self, from: data)
    else { return [] }
    return collection
  }()

  static let launchQuote = choose(from: quotes,
    defaults: OverviewReleaseBenchmark.isolatedDefaults ?? ManualViewerQAContext.active?.defaults ?? .standard)

  static func choose(from quotes: [HomeQuote], defaults: UserDefaults) -> HomeQuote? {
    let previousID = defaults.string(forKey: previousQuoteKey)
    let candidates = quotes.filter { $0.id != previousID }
    guard let selected = (candidates.isEmpty ? quotes : candidates).randomElement() else {
      return nil
    }
    defaults.set(selected.id, forKey: previousQuoteKey)
    return selected
  }
}
