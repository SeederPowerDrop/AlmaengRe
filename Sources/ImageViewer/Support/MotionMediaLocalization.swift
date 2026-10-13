import Foundation

enum MotionMediaL10n {
  static func text(_ key: String) -> String {
    let bundle: Bundle = Bundle.main.url(forResource: "MotionMedia", withExtension: "strings") != nil
      ? .main : .module
    return bundle.localizedString(forKey: key, value: key, table: "MotionMedia")
  }

  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: text(key), locale: Locale.current, arguments: arguments)
  }
}
