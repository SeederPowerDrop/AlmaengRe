import Foundation

enum PhotoMarkL10n {
  static func text(_ key: String) -> String {
    activeBundle.localizedString(forKey: key, value: key, table: "PhotoMarks")
  }

  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: text(key), locale: Locale.current, arguments: arguments)
  }

  static func text(_ key: String, localeIdentifier: String) -> String {
    languageBundle(for: localeIdentifier)?.localizedString(
      forKey: key, value: key, table: "PhotoMarks"
    ) ?? key
  }

  static func keys(localeIdentifier: String) -> Set<String> {
    guard let bundle = languageBundle(for: localeIdentifier),
      let url = bundle.url(forResource: "PhotoMarks", withExtension: "strings"),
      let data = try? Data(contentsOf: url),
      let values = try? PropertyListSerialization.propertyList(
        from: data, options: [], format: nil
      ) as? [String: String]
    else { return [] }
    return Set(values.keys)
  }

  private static var activeBundle: Bundle {
    if Bundle.main.url(forResource: "PhotoMarks", withExtension: "strings") != nil {
      return .main
    }
    // 배포 앱에 SwiftPM 리소스 번들이 없을 수 있으므로 필요할 때만 접근합니다.
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
