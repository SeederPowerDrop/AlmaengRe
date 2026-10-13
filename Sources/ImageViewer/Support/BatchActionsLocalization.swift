import Foundation

enum BatchActionsL10n {
  static func text(_ key: String) -> String {
    let bundle: Bundle = Bundle.main.url(forResource: "BatchActions", withExtension: "strings") != nil
      ? .main : .module
    return bundle.localizedString(forKey: key, value: key, table: "BatchActions")
  }
}
