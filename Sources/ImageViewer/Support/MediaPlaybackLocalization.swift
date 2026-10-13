import Foundation

enum MediaPlaybackL10n {
  static func text(_ key: String) -> String {
    let bundle: Bundle = Bundle.main.url(forResource: "MediaPlayback", withExtension: "strings") != nil
      ? .main : .module
    return bundle.localizedString(forKey: key, value: key, table: "MediaPlayback")
  }
  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: text(key), locale: Locale.current, arguments: arguments)
  }
}
