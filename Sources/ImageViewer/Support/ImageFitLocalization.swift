import Foundation

/// Plain-language image fitting labels, independent of the legacy scale-mode
/// titles used by saved settings and other controls.
enum ImageFitL10n {
  static func text(_ key: String, language: String = L10n.languageIdentifier) -> String {
    L10n.text(key, localeIdentifier: language, table: "ImageFit")
  }

  static func title(for mode: BaseScaleMode, language: String = L10n.languageIdentifier) -> String {
    text("\(key(for: mode)).title", language: language)
  }

  static func help(for mode: BaseScaleMode, language: String = L10n.languageIdentifier) -> String {
    text("\(key(for: mode)).help", language: language)
  }

  private static func key(for mode: BaseScaleMode) -> String {
    switch mode {
    case .fit: "whole"
    case .fitWidth: "width"
    case .fitHeight: "height"
    case .actualPixels: "actual"
    }
  }
}
