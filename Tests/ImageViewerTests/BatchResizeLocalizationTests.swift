import Testing

@testable import ImageViewer

@Suite("일괄 크기 변경 현지화")
struct BatchResizeLocalizationTests {
  @Test("지원 언어 전체에 같은 크기·용량·공유 안내가 있다")
  func matchingKeys() {
    let keys = BatchResizeL10n.keys(localeIdentifier: "ko")
    #expect(keys.count == 12)
    for locale in L10n.supportedLocalizations {
      #expect(BatchResizeL10n.keys(localeIdentifier: locale) == keys)
      for key in keys {
        let value = BatchResizeL10n.text(key, localeIdentifier: locale)
        #expect(!value.isEmpty)
        if locale != "ko" { #expect(value != key) }
      }
    }
  }
}
