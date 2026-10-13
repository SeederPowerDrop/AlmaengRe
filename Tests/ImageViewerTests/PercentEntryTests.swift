import Foundation
import Testing

@testable import ImageViewer

@Suite("워터마크 퍼센트 직접 입력")
struct PercentEntryTests {
  @Test("소수 입력과 표시가 일치하며 지역 소수점과 숫자를 읽는다")
  func localizedDecimals() throws {
    let examples: [(String, String)] = [
      ("en_US", "25.5"), ("ko_KR", "25.5%"), ("fr_FR", "25,5 %"),
      ("de_DE", "25,5"), ("ar_EG", "٢٥٫٥٪"), ("fr_FR", "25.5"),
    ]
    for (identifier, input) in examples {
      let locale = Locale(identifier: identifier)
      let value = try #require(PercentEntry.fraction(from: input, in: 0.02...0.9, locale: locale))
      #expect(abs(value - 0.255) < 0.000_000_1)
      let displayed = PercentEntry.string(for: value, locale: locale)
      #expect(PercentEntry.fraction(from: displayed, in: 0.02...0.9, locale: locale) == value)
    }
    #expect(PercentEntry.string(for: 0.255, locale: Locale(identifier: "en_US")) == "25.5")
    #expect(PercentEntry.string(for: 0.255, locale: Locale(identifier: "fr_FR")) == "25,5")
  }

  @Test("세 설정의 각 범위를 적용하고 0을 허용하는 설정은 0으로 저장한다")
  func clampsEachRange() {
    let locale = Locale(identifier: "en_US")
    for (range, low, high) in [(0.02...0.9, 0.02, 0.9), (0.0...0.2, 0.0, 0.2), (0.0...1.0, 0.0, 1.0)] {
      #expect(PercentEntry.fraction(from: "-5", in: range, locale: locale) == low)
      #expect(PercentEntry.fraction(from: "150", in: range, locale: locale) == high)
    }
    #expect(PercentEntry.fraction(from: "0", in: 0...1, locale: locale) == 0)
    #expect(PercentEntry.fraction(from: "2.5", in: 0...0.2, locale: locale) == 0.025)
    #expect(PercentEntry.fraction(from: ".5", in: 0...1, locale: locale) == 0.005)
  }

  @Test("빈칸·비숫자·NaN·무한·숫자 뒤 쓰레기 문자열을 허용하지 않는다")
  func invalidDraftsKeepLastValidValue() {
    var bound = 0.255
    for input in ["", " ", ".", "-", "+", "NaN", "nan", "Infinity", "inf", "∞", "25xyz", "25 5",
      "25.5.1", "25,5", "25%%", "%25", "1e2", String(repeating: "9", count: 400)] {
      let parsed = PercentEntry.fraction(from: input, in: 0.02...0.9, locale: Locale(identifier: "en_US"))
      #expect(parsed == nil)
      if let parsed { bound = parsed }
      #expect(bound == 0.255)
    }
  }

  @Test("입력 중 유효값은 바로 저장되어 포커스 해제 전에도 최신값을 사용한다")
  func liveAcceptedValueIsNeverStale() {
    var bound = 0.25
    for draft in ["", "2", "25", "25.", "25.5"] {
      if let accepted = PercentEntry.fraction(from: draft, in: 0.02...0.9, locale: Locale(identifier: "en_US")) {
        bound = accepted
      }
    }
    #expect(bound == 0.255)
    if let accepted = PercentEntry.fraction(from: "100", in: 0.02...0.9, locale: Locale(identifier: "en_US")) {
      bound = accepted
    }
    #expect(bound == 0.9)
    #expect(PercentEntry.string(for: bound, locale: Locale(identifier: "en_US")) == "90")
  }
}
