import Foundation

/// 앱의 동적 문자열과 오류 문구를 SwiftPM 및 .app 번들 모두에서 현지화합니다.
enum L10n {
  static let supportedLocalizations = ["ko", "en", "ja", "zh-Hans", "vi", "es", "fr", "de", "ru", "ar"]

  /// Match the app's selected language, rather than the user's region format.
  static var languageIdentifier: String {
    Bundle.preferredLocalizations(from: supportedLocalizations,
      forPreferences: activeBundle.preferredLocalizations).first ?? "ko"
  }

  static func text(_ key: String) -> String {
    activeBundle.localizedString(forKey: key, value: key, table: nil)
  }

  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(
      format: text(key),
      locale: Locale.current,
      arguments: arguments
    )
  }

  /// 테스트와 언어별 미리보기가 시스템 언어를 바꾸지 않고 리소스를 확인할 수 있게 합니다.
  static func text(_ key: String, localeIdentifier: String, table: String? = nil) -> String {
    guard let languageBundle = languageBundle(for: localeIdentifier) else {
      return key
    }
    return languageBundle.localizedString(forKey: key, value: key, table: table)
  }

  /// 번역 파일 간 누락을 자동 테스트할 수 있도록 실제 리소스의 키 집합을 반환합니다.
  static func keys(localeIdentifier: String) -> Set<String> {
    guard let languageBundle = languageBundle(for: localeIdentifier),
      let url = languageBundle.url(forResource: "Localizable", withExtension: "strings"),
      let data = try? Data(contentsOf: url),
      let values = try? PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      ) as? [String: String]
    else {
      return []
    }
    return Set(values.keys)
  }

  private static var activeBundle: Bundle {
    // 배포 앱은 주 번들의 Contents/Resources를, swift run·테스트·Xcode가
    // 별도 리소스 번들을 만들면 SwiftPM 번들을 사용합니다.
    if Bundle.main.url(forResource: "Localizable", withExtension: "strings") != nil {
      return .main
    }
    return moduleBundle
  }

  private static var moduleBundle: Bundle {
    .module
  }

  private static func languageBundle(for localeIdentifier: String) -> Bundle? {
    // SwiftPM은 zh-Hans 같은 식별자의 리소스 폴더를 zh-hans.lproj로
    // 정규화할 수 있으므로 원본과 소문자 이름을 모두 확인합니다.
    for candidate in [localeIdentifier, localeIdentifier.lowercased()] {
      if let path = activeBundle.path(forResource: candidate, ofType: "lproj") {
        return Bundle(path: path)
      }
    }
    return nil
  }
}
