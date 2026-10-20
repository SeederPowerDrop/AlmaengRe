import Foundation
import Observation
import Testing

@testable import ImageViewer

@Suite("현지화 리소스 재사용과 즉시 언어 변경")
struct LocalizationResourceCacheTests {
  @Test("직접 선택한 언어는 시스템 번들 검색을 하지 않는다")
  func explicitLanguageSkipsSystemResolution() {
    var systemReads = 0
    func systemLanguage() -> String { systemReads += 1; return "fr" }
    for language in L10n.supportedLocalizations {
      #expect(L10n.resolvedLanguage(selection: language, systemLanguage: systemLanguage()) == language)
    }
    #expect(systemReads == 0)
    #expect(L10n.resolvedLanguage(selection: "system", systemLanguage: systemLanguage()) == "fr")
    #expect(systemReads == 1)
    #expect(L10n.resolvedLanguage(selection: nil, systemLanguage: "unsupported") == "ko")
    var followingSystem = "de"
    #expect(L10n.resolvedLanguage(selection: "system", systemLanguage: followingSystem) == "de")
    followingSystem = "ar"
    #expect(L10n.resolvedLanguage(selection: "system", systemLanguage: followingSystem) == "ar")
  }

  @Test("언어 리소스 경로와 누락 결과는 한 번만 확인하고 대소문자 별칭을 재사용한다")
  func bundleLookupsStayBounded() {
    var lookups: [String] = []
    let catalog = LocalizationBundleCatalog(languages: ["en", "zh-Hans", "missing"]) { candidate in
      lookups.append(candidate)
      return ["en", "zh-hans"].contains(candidate) ? Bundle.main : nil
    }
    #expect(lookups == ["en", "zh-Hans", "zh-hans", "missing"])
    for _ in 0..<1_000 {
      #expect(catalog.bundle(for: "en") === Bundle.main)
      #expect(catalog.bundle(for: "EN") === Bundle.main)
      #expect(catalog.bundle(for: "zh-Hans") === Bundle.main)
      #expect(catalog.bundle(for: "zh-hans") === Bundle.main)
      #expect(catalog.bundle(for: "missing") == nil)
      #expect(catalog.bundle(for: "unknown") == nil)
    }
    #expect(lookups.count == 4)
  }

  @Test("리소스를 준비한 후에도 선택 언어와 관찰 알림은 즉시 바뀐다")
  func warmResourcesDoNotCacheLanguageChoice() {
    for language in L10n.supportedLocalizations {
      _ = L10n.text("닫기", localeIdentifier: language)
    }
    let preference = AppLanguagePreference(selection: "en")
    let changes = ObservationCounter()
    for language in L10n.supportedLocalizations + ["system", "unsupported", "en"] {
      let before = withObservationTracking {
        let resolved = L10n.resolvedLanguage(selection: preference.selection, systemLanguage: "fr")
        return L10n.text("닫기", localeIdentifier: resolved)
      } onChange: {
        changes.increment()
      }
      #expect(!before.isEmpty)
      let count = changes.value
      preference.selection = language
      #expect(changes.value == count + 1)
      let resolved = L10n.resolvedLanguage(selection: preference.selection, systemLanguage: "fr")
      let expected = L10n.supportedLocalizations.contains(language) ? language : "fr"
      #expect(resolved == expected)
      #expect(L10n.text("닫기", localeIdentifier: resolved)
        == L10n.text("닫기", localeIdentifier: expected))
    }
  }

  @Test("동시 조회는 지원 언어·이름 있는 번역 표·누락 키를 유지한다")
  func concurrentLookupsPreserveResources() async {
    let expected = Dictionary(uniqueKeysWithValues: L10n.supportedLocalizations.map {
      ($0, L10n.text("menu.image", localeIdentifier: $0, table: "ImageFit"))
    })
    await withTaskGroup(of: Void.self) { group in
      for language in L10n.supportedLocalizations {
        group.addTask {
          for _ in 0..<100 {
            #expect(L10n.text("menu.image", localeIdentifier: language, table: "ImageFit") == expected[language])
            #expect(L10n.text("menu.image", localeIdentifier: language.lowercased(), table: "ImageFit") == expected[language])
            #expect(L10n.text("missing.fixture.key", localeIdentifier: language) == "missing.fixture.key")
          }
        }
      }
    }
    #expect(L10n.text("닫기", localeIdentifier: "unsupported") == "닫기")
  }

  private final class ObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
  }
}
