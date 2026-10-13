import Foundation
import Testing

@testable import ImageViewer

@Suite("여러 장 보기 페이지 이동 안내")
struct ViewerPageLocalizationTests {
  @Test("10개 언어의 안내와 도움말이 단축키·장수 인수를 올바르게 표시한다")
  func localizedPageHintsPreserveArguments() {
    let shortcut = "⌥← / ⌥→"
    let cases: [(String, [String], [CVarArg])] = [
      ("%@ · %d장씩 이동", ["%@", "%d"], [shortcut, 7]),
      ("%@로 한 화면에 설정한 %d장씩 넘깁니다. 분류 모드에서도 사용할 수 있습니다.",
        ["%@", "%d"], [shortcut, 7]),
      ("이전 %d장 보기 (%@)", ["%d", "%@"], [7, shortcut]),
      ("다음 %d장 보기 (%@)", ["%d", "%@"], [7, shortcut]),
    ]
    for locale in L10n.supportedLocalizations {
      for (key, placeholders, arguments) in cases {
        #expect(L10n.keys(localeIdentifier: locale).contains(key))
        let format = L10n.text(key, localeIdentifier: locale)
        if locale != "ko" { #expect(format != key) }
        let first = format.range(of: placeholders[0])
        let second = format.range(of: placeholders[1])
        #expect(first != nil && second != nil)
        if let first, let second { #expect(first.lowerBound < second.lowerBound) }
        let result = String(format: format, locale: Locale(identifier: "en_US"), arguments: arguments)
        #expect(result.contains(shortcut) && result.contains("7"))
        #expect(!result.contains("%@") && !result.contains("%d"))
      }
    }
  }
}
