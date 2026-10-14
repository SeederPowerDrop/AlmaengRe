import Foundation

enum FileOperationsL10n {
  static func text(_ key: String) -> String {
    L10n.text(key, localeIdentifier: L10n.languageIdentifier, table: "FileOperations")
  }

  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: text(key), locale: Locale.current, arguments: arguments)
  }

  static func text(_ key: String, localeIdentifier: String) -> String {
    languageBundle(for: localeIdentifier)?.localizedString(
      forKey: key, value: key, table: "FileOperations"
    ) ?? key
  }

  static func keys(localeIdentifier: String) -> Set<String> {
    guard let bundle = languageBundle(for: localeIdentifier),
      let url = bundle.url(forResource: "FileOperations", withExtension: "strings"),
      let data = try? Data(contentsOf: url),
      let values = try? PropertyListSerialization.propertyList(
        from: data, options: [], format: nil
      ) as? [String: String]
    else { return [] }
    return Set(values.keys)
  }

  private static var activeBundle: Bundle {
    if Bundle.main.url(forResource: "FileOperations", withExtension: "strings") != nil {
      return .main
    }
    return .module
  }

  private static func languageBundle(for identifier: String) -> Bundle? {
    for candidate in [identifier, identifier.lowercased()] {
      if let path = activeBundle.path(forResource: candidate, ofType: "lproj") {
        return Bundle(path: path)
      }
    }
    return nil
  }
}
