import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum AboutContent {
  static var languageIdentifier: String {
    L10n.languageIdentifier
  }

  static func languageIdentifier(for preferences: [String]) -> String {
    for identifier in preferences {
      if let language = supportedLanguage(for: identifier) { return language }
    }
    return "ko"
  }

  private static func supportedLanguage(for identifier: String) -> String? {
    let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    if ["zh", "zh-cn", "zh-sg"].contains(normalized) { return "zh-Hans" }
    return L10n.supportedLocalizations.first {
      normalized == $0.lowercased() || normalized.hasPrefix($0.lowercased() + "-")
    }
  }

  /// The About window follows the app's language, with the Korean original as fallback.
  static func text(_ key: String, localeIdentifier: String = languageIdentifier) -> String {
    let language = supportedLanguage(for: localeIdentifier) ?? "ko"
    let translated = L10n.text(key, localeIdentifier: language, table: "About")
    return translated == key ? L10n.text(key, localeIdentifier: "ko", table: "About") : translated
  }
}

enum AboutSupport {
  // Public support destinations shared with ZipLens.
  static let buyMeACoffeeURL = URL(string: "https://buymeacoffee.com/master_chief")!
  static let koFiURL = URL(string: "https://ko-fi.com/seederpower")!
  static let bitcoinAddress = "BC1QUEUAX3FJP77NZUKF732AEWVFE0YVS9ZPKUMLTV"
  static let bitcoinURL = URL(string: "bitcoin:\(bitcoinAddress)")!

  /// Encode the displayed address directly so the QR and copy action cannot drift apart.
  static func makeBitcoinQRCode() -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(bitcoinURL.absoluteString.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
    return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(scaled, from: scaled.extent)
  }
}
