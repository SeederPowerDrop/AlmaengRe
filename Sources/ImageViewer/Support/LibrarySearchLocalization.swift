import Foundation

enum LibrarySearchL10n {
  static func text(_ key: String) -> String {
    let bundle = Bundle.main.url(forResource: "LibrarySearch", withExtension: "strings") != nil
      ? Bundle.main : Bundle.module
    return bundle.localizedString(forKey: key, value: key, table: "LibrarySearch")
  }
}
