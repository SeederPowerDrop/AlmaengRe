import Foundation
import Observation
import Testing

@testable import ImageViewer

@Suite("앱 언어 선택과 지역 설정 보존")
@MainActor
struct LanguageStoreTests {
  @Test("처음 실행은 시스템 언어를 따르고 미지원 언어는 한국어로 표시한다")
  func defaultSelectionFollowsSystem() throws {
    try withDefaults { defaults in
      let store = LanguageStore(defaults: defaults, systemLanguage: "fr")
      #expect(store.selection == "system")
      #expect(store.languageIdentifier == "fr")
      #expect(LanguageStore(defaults: defaults, systemLanguage: "it").languageIdentifier == "ko")
      #expect(defaults.object(forKey: LanguageStore.defaultsKey) == nil)
    }
  }

  @Test("잘못 저장된 선택값은 시스템 언어로 안전하게 돌아간다",
    arguments: ["", "invalid", "fr-FR", "SYSTEM", "system"])
  func invalidStoredSelectionFallsBack(selection: String) throws {
    try withDefaults { defaults in
      defaults.set(selection, forKey: LanguageStore.defaultsKey)
      let store = LanguageStore(defaults: defaults, systemLanguage: "ja")
      #expect(store.selection == "system")
      #expect(store.languageIdentifier == "ja")
    }
  }

  @Test("지원하는 10개 언어를 선택하고 다음 실행에서 복원한다",
    arguments: L10n.supportedLocalizations)
  func supportedSelectionPersists(language: String) throws {
    try withDefaults { defaults in
      let store = LanguageStore(defaults: defaults, systemLanguage: "ko")
      store.selection = language
      #expect(store.selection == language)
      #expect(store.languageIdentifier == language)
      #expect(defaults.string(forKey: LanguageStore.defaultsKey) == language)

      let restored = LanguageStore(defaults: defaults, systemLanguage: "en")
      #expect(restored.selection == language)
      #expect(restored.languageIdentifier == language)
    }
  }

  @Test("언어를 직접 선택한 뒤 시스템 설정 따르기로 복귀할 수 있다")
  func returnToSystemLanguage() throws {
    try withDefaults { defaults in
      let store = LanguageStore(defaults: defaults, systemLanguage: "de")
      store.selection = "ar"
      #expect(store.languageIdentifier == "ar")
      store.selection = "system"
      #expect(store.selection == "system")
      #expect(store.languageIdentifier == "de")
      #expect(defaults.string(forKey: LanguageStore.defaultsKey) == "system")
      #expect(LanguageStore(defaults: defaults, systemLanguage: "es").languageIdentifier == "es")

      store.selection = "unsupported"
      #expect(store.selection == "system")
      #expect(store.languageIdentifier == "de")
      #expect(defaults.string(forKey: LanguageStore.defaultsKey) == "system")
    }
  }

  @Test("앱 언어 선택은 macOS 언어와 지역 설정을 덮어쓰지 않는다")
  func doesNotChangeSystemPreferences() throws {
    let originalLanguages = UserDefaults.standard.stringArray(forKey: "AppleLanguages")
    let originalLocale = UserDefaults.standard.string(forKey: "AppleLocale")
    try withDefaults { defaults in
      defaults.set(["fr-FR", "en-GB"], forKey: "AppleLanguages")
      defaults.set("fr_FR@currency=EUR", forKey: "AppleLocale")
      let store = LanguageStore(defaults: defaults, systemLanguage: "fr")
      for language in L10n.supportedLocalizations + ["system"] {
        store.selection = language
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["fr-FR", "en-GB"])
        #expect(defaults.string(forKey: "AppleLocale") == "fr_FR@currency=EUR")
      }
    }
    #expect(UserDefaults.standard.stringArray(forKey: "AppleLanguages") == originalLanguages)
    #expect(UserDefaults.standard.string(forKey: "AppleLocale") == originalLocale)
  }

  @Test("UI 언어를 바꿔도 지역·숫자·달력·통화·시간 형식은 유지한다",
    arguments: L10n.supportedLocalizations)
  func preservesRegionalFormatting(language: String) throws {
    let original = Locale(identifier: "en-GB-u-ca-buddhist-cu-jpy-fw-mon-hc-h23-ms-ussystem-nu-thai")
    // Distinct preferences make accidental replacement with the language's
    // default locale visible; a plain en_US fixture would hide that regression.
    #expect(original.region?.identifier == "GB")
    #expect(original.calendar.identifier == .buddhist)
    #expect(original.currency?.identifier == "JPY")
    #expect(original.numberingSystem.identifier == "thai")
    #expect(original.hourCycle == .zeroToTwentyThree)

    try withDefaults { defaults in
      let store = LanguageStore(defaults: defaults, systemLanguage: "en", regionalLocale: original)
      store.selection = language
      let actual = store.locale
      let expectedLanguage = Locale.Language(identifier: language)
      #expect(actual.language.languageCode == expectedLanguage.languageCode)
      #expect(actual.language.script == expectedLanguage.script)
      #expect(actual.region == original.region)
      #expect(actual.calendar.identifier == original.calendar.identifier)
      #expect(actual.currency == original.currency)
      #expect(actual.numberingSystem == original.numberingSystem)
      #expect(actual.hourCycle == original.hourCycle)
      #expect(actual.firstDayOfWeek == original.firstDayOfWeek)
      #expect(actual.measurementSystem == original.measurementSystem)
    }
  }

  @Test("선택 변경을 주입된 관찰 객체에 즉시 전달한다")
  func selectionNotifiesLiveObservers() throws {
    try withDefaults { defaults in
      let preference = AppLanguagePreference(selection: "system")
      let store = LanguageStore(defaults: defaults, systemLanguage: "fr", preference: preference)
      let signal = LanguageObservationSignal()
      let before = withObservationTracking {
        L10n.resolvedLanguage(selection: preference.selection, systemLanguage: "fr")
      } onChange: {
        signal.increment()
      }
      #expect(before == "fr")

      store.selection = "ar"
      #expect(signal.count == 1)
      #expect(preference.selection == "ar")
      let after = withObservationTracking {
        L10n.resolvedLanguage(selection: preference.selection, systemLanguage: "fr")
      } onChange: {
        signal.increment()
      }
      #expect(after == "ar")

      store.selection = "system"
      #expect(signal.count == 2)
      #expect(preference.selection == "system")
      #expect(L10n.resolvedLanguage(selection: preference.selection, systemLanguage: "fr") == "fr")
    }
  }

  @Test("언어 해석은 직접 선택·시스템 언어·한국어 순으로 결정한다")
  func languageResolutionFallbacks() {
    for language in L10n.supportedLocalizations {
      #expect(L10n.resolvedLanguage(selection: language, systemLanguage: "invalid") == language)
    }
    let fallbackSelections: [String?] = [nil, "", "system", "unsupported", "fr-FR"]
    for selection in fallbackSelections {
      #expect(L10n.resolvedLanguage(selection: selection, systemLanguage: "de") == "de")
      #expect(L10n.resolvedLanguage(selection: selection, systemLanguage: "invalid") == "ko")
    }
  }

  private func withDefaults(_ operation: (UserDefaults) throws -> Void) throws {
    let suite = "LanguageStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try operation(defaults)
  }
}

private final class LanguageObservationSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  var count: Int { lock.withLock { value } }
  func increment() { lock.withLock { value += 1 } }
}
