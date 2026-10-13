import Foundation
import Testing

@testable import ImageViewer

@Suite("처음 화면의 출처 있는 예술 문구")
@MainActor
struct HomeInspirationTests {
  @Test("배포 리소스의 30개 문구 모두 원문과 출처 및 10개 언어를 갖는다")
  func bundledCollectionIsComplete() throws {
    let quotes = HomeInspiration.quotes
    #expect(quotes.count == 30)
    #expect(Set(quotes.map(\.id)).count == 30)
    #expect(Set(quotes.map(\.originalText)).count == 30)
    for quote in quotes {
      #expect(quote.sourceURL.scheme == "https")
      #expect(quote.sourceURL.host != nil)
      #expect(!quote.originalText.isEmpty && !quote.originalLanguage.isEmpty)
      #expect(!quote.publicDomainBasis.isEmpty)
      #expect(Set(quote.localizations.keys) == Set(L10n.supportedLocalizations))
      for language in L10n.supportedLocalizations {
        let localized = try #require(quote.localized(for: language))
        #expect(!localized.text.isEmpty && !localized.author.isEmpty && !localized.work.isEmpty)
        if !localized.isTranslation {
          #expect(language == quote.originalLanguage)
          #expect(localized.text == quote.originalText)
        }
      }
    }
  }

  @Test("지역 설정과 관계없이 선택한 앱 언어로 문구와 출처를 표시한다")
  func regionalLanguageResolution() throws {
    let quote = try #require(HomeInspiration.quotes.first)
    for (regional, language) in ["ko-KR": "ko", "en-GB": "en", "ja-JP": "ja",
      "zh-Hans-CN": "zh-Hans", "fr-CA": "fr", "ar-SA": "ar", "vi-VN": "vi",
      "es-MX": "es", "de-AT": "de", "ru-RU": "ru"] {
      let localized = try #require(quote.localized(for: regional))
      let expected = try #require(quote.localizations[language])
      #expect(localized.text == expected.text)
      #expect(localized.author == expected.author && localized.work == expected.work)
    }
  }

  @Test("다음 실행은 직전 문구를 제외하고 선택하며 새 선택을 기록한다")
  func avoidsImmediateRepetition() throws {
    let suite = "HomeInspirationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let quotes = HomeInspiration.quotes
    try #require(quotes.count == 30)
    for previous in quotes {
      defaults.set(previous.id, forKey: HomeInspiration.previousQuoteKey)
      let next = try #require(HomeInspiration.choose(from: quotes, defaults: defaults))
      #expect(next.id != previous.id)
      #expect(defaults.string(forKey: HomeInspiration.previousQuoteKey) == next.id)
    }
    defaults.set("removed-quote", forKey: HomeInspiration.previousQuoteKey)
    #expect(HomeInspiration.choose(from: quotes, defaults: defaults) != nil)
    let single = try #require(quotes.first)
    defaults.set(single.id, forKey: HomeInspiration.previousQuoteKey)
    #expect(HomeInspiration.choose(from: [single], defaults: defaults)?.id == single.id)
    #expect(HomeInspiration.choose(from: [], defaults: defaults) == nil)
  }
}
