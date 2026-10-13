import Foundation
import Testing

@testable import ImageViewer

@Suite("지도 영역 편집 현지화")
struct MapSelectionLocalizationTests {
  @Test("10개 언어의 영역 도구와 열기 안내 및 번호 형식이 일치한다")
  func allLocalesHaveMatchingKeysAndArguments() {
    let keys = MapSelectionL10n.keys(localeIdentifier: "ko")
    #expect(keys.count == 21)
    for locale in L10n.supportedLocalizations {
      #expect(MapSelectionL10n.keys(localeIdentifier: locale) == keys)
      for key in keys {
        let value = MapSelectionL10n.text(key, localeIdentifier: locale)
        #expect(!value.isEmpty)
        if locale != "ko" { #expect(value != key) }
        #expect(value.components(separatedBy: "%lld").count == key.components(separatedBy: "%lld").count)
      }
    }
  }
}
