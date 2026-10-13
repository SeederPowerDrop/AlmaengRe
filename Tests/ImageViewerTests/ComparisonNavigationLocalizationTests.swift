import Foundation
import Testing

@testable import ImageViewer

@Suite("이미지 비교 이동 대상 현지화")
struct ComparisonNavigationLocalizationTests {
  private let navigationKeys: Set<String> = [
    "이미지 넘기기", "A만", "양쪽", "B만", "적은 쪽 반복", "방향키로 넘길 대상",
    "방향키와 공통 이동 버튼으로 넘길 사진을 고릅니다. A/B만 선택하면 목록 순서로 전환합니다.",
    "잠금에 맞춰 이동 대상이 바뀝니다. 잠금을 모두 풀면 양쪽으로 돌아갑니다.",
    "켜면 적은 쪽은 처음부터 반복하고, 끄면 마지막 이미지에 머뭅니다. 많은 쪽의 끝까지 함께 넘깁니다.",
    "파일명 비교에서는 같은 이름의 쌍으로 이동합니다. 반복은 목록 순서에서 사용할 수 있습니다.",
    "이동 대상: %@", "잠금에 따라 자동 선택",
  ]

  @Test("10개 언어에 이동 대상과 반복 설정 안내가 있다")
  func navigationControlsAreLocalized() {
    for locale in L10n.supportedLocalizations {
      #expect(navigationKeys.isSubset(of: L10n.keys(localeIdentifier: locale)))
      for key in navigationKeys {
        let value = L10n.text(key, localeIdentifier: locale)
        #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if locale != "ko" { #expect(value != key) }
      }
      let targets = ["A만", "양쪽", "B만"].map {
        L10n.text($0, localeIdentifier: locale)
      }
      #expect(Set(targets).count == 3)
    }
  }

  @Test("이동 대상 형식 문자열은 모든 언어에서 인수 하나를 유지한다")
  func navigationTargetFormatPreservesItsArgument() {
    for locale in L10n.supportedLocalizations {
      let format = L10n.text("이동 대상: %@", localeIdentifier: locale)
      #expect(format.components(separatedBy: "%@").count == 2)
      #expect(!format.replacingOccurrences(of: "%@", with: "").contains("%"))
      let target = L10n.text("양쪽", localeIdentifier: locale)
      let result = String(format: format, locale: Locale(identifier: locale), target)
      #expect(result.contains(target))
      #expect(!result.contains("%@"))
    }
  }

  @Test("이전과 다음 단축키 안내는 같은 언어의 세 이동 대상을 설명한다")
  func shortcutHelpMatchesTheNavigationSelector() {
    for locale in L10n.supportedLocalizations {
      for key in ["action.previousPage.help", "action.nextPage.help"] {
        #expect(ShortcutHelpL10n.keys(localeIdentifier: locale).contains(key))
        let help = ShortcutHelpL10n.text(key, localeIdentifier: locale)
        for targetKey in ["A만", "양쪽", "B만"] {
          #expect(help.contains(L10n.text(targetKey, localeIdentifier: locale)))
        }
        if locale != "ko" {
          #expect(help != ShortcutHelpL10n.text(key, localeIdentifier: "ko"))
        }
      }
    }
  }
}
