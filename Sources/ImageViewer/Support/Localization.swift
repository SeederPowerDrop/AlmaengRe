import Foundation
import Observation

/// Dynamic labels participate in SwiftUI observation even when they call L10n
/// through a model/helper. Reads also remain safe in background image services.
final class AppLanguagePreference: Observable, @unchecked Sendable {
  static let shared = AppLanguagePreference(
    selection: UserDefaults.standard.string(forKey: L10n.languageDefaultsKey))
  private let registrar = ObservationRegistrar()
  private let lock = NSLock()
  private var storedSelection: String?

  init(selection: String? = nil) { storedSelection = selection }

  var selection: String? {
    get {
      registrar.access(self, keyPath: \.selection)
      return lock.withLock { storedSelection }
    }
    set {
      registrar.withMutation(of: self, keyPath: \.selection) {
        lock.withLock { storedSelection = newValue }
      }
    }
  }
}

/// App resources are immutable for the lifetime of a running build. Resolve the
/// small set of language bundles once; labels need only an in-memory lookup.
struct LocalizationBundleCatalog: Sendable {
  private let bundles: [String: Bundle]

  init(languages: [String], resolve: (String) -> Bundle?) {
    var values: [String: Bundle] = [:]
    for language in languages {
      let normalized = language.lowercased()
      // SwiftPM can normalize zh-Hans.lproj to zh-hans.lproj.
      let bundle = resolve(language) ?? (normalized != language ? resolve(normalized) : nil)
      if let bundle { values[normalized] = bundle }
    }
    bundles = values
  }

  func bundle(for identifier: String) -> Bundle? { bundles[identifier.lowercased()] }
}

/// 앱의 동적 문자열과 오류 문구를 SwiftPM 및 .app 번들 모두에서 현지화합니다.
enum L10n {
  static let supportedLocalizations = ["ko", "en", "ja", "zh-Hans", "vi", "es", "fr", "de", "ru", "ar"]
  static let languageDefaultsKey = "ImageViewer.Language.v1"

  /// Match the app's selected language, rather than the user's region format.
  static var languageIdentifier: String {
    resolvedLanguage(selection: AppLanguagePreference.shared.selection,
      systemLanguage: systemLanguageIdentifier)
  }

  static var systemLanguageIdentifier: String {
    Bundle.preferredLocalizations(from: supportedLocalizations,
      forPreferences: activeBundle.preferredLocalizations).first ?? "ko"
  }

  static func resolvedLanguage(selection: String?, systemLanguage: @autoclosure () -> String) -> String {
    if let selection, supportedLocalizations.contains(selection) { return selection }
    // A manually selected UI language does not need to resolve the system's
    // preferred bundle on every label. The preference itself is still read live.
    let fallback = systemLanguage()
    return supportedLocalizations.contains(fallback) ? fallback : "ko"
  }

  static func text(_ key: String) -> String {
    text(key, localeIdentifier: languageIdentifier)
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

  private static let activeBundle: Bundle = {
    // 배포 앱은 주 번들의 Contents/Resources를, swift run·테스트·Xcode가
    // 별도 리소스 번들을 만들면 SwiftPM 번들을 사용합니다.
    if Bundle.main.url(forResource: "Localizable", withExtension: "strings") != nil {
      return .main
    }
    return .module
  }()

  private static let languageBundles = LocalizationBundleCatalog(languages: supportedLocalizations) { candidate in
    guard let path = activeBundle.path(forResource: candidate, ofType: "lproj") else { return nil }
    return Bundle(path: path)
  }

  private static func languageBundle(for localeIdentifier: String) -> Bundle? {
    languageBundles.bundle(for: localeIdentifier)
  }
}
