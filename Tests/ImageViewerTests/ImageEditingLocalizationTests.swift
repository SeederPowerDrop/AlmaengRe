import Foundation
import Testing

@testable import ImageViewer

@Suite("이미지 편집 다국어")
struct ImageEditingLocalizationTests {
  private let editingKeys: Set<String> = [
    "구도", "잘라내기…", "자르기 해제", "왼쪽 90°", "오른쪽 90°", "빛", "휘도", "노출",
    "좌우 반전하기", "상하 반전하기",
    "현재 보이는 사진의 왼쪽과 오른쪽을 뒤집습니다. 다시 누르면 원래대로 돌아옵니다.",
    "현재 보이는 사진의 위와 아래를 뒤집습니다. 다시 누르면 원래대로 돌아옵니다.",
    "색상", "색조", "색온도", "색선명도", "디테일", "선명도", "노이즈 감소", "잘라내기",
    "드래그해서 영역을 선택하고 모서리로 크기를 조절하세요.", "비율", "자유", "원본 비율",
    "전체 선택", "적용", "영역 이동", "왼쪽 위 모서리", "오른쪽 위 모서리", "왼쪽 아래 모서리",
    "오른쪽 아래 모서리", "자르기 영역", "가로 위치", "세로 위치", "너비", "높이",
    "미리보기를 불러올 수 없음", "차갑게", "따뜻하게",
  ]

  @Test("10개 언어에 모든 편집 조절과 자르기 접근성 문구가 있다")
  func editingControlsAreLocalized() {
    let supported = Set(["ko", "en", "ja", "zh-Hans", "vi", "es", "fr", "de", "ru", "ar"])
    #expect(Set(L10n.supportedLocalizations) == supported)

    for locale in L10n.supportedLocalizations {
      let resourceKeys = L10n.keys(localeIdentifier: locale)
      #expect(editingKeys.isSubset(of: resourceKeys))
      for key in editingKeys {
        let value = L10n.text(key, localeIdentifier: locale)
        #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if locale != "ko" {
          // 누락된 키가 한국어로 대체되어도 빈 문자열 검사는 통과하므로 함께 확인합니다.
          #expect(value != key)
        }
      }
    }
  }

  @Test("편집 문구 추가 후에도 모든 언어의 전체 리소스 키가 일치한다")
  func resourceKeySetsMatch() {
    let koreanKeys = L10n.keys(localeIdentifier: "ko")
    #expect(!koreanKeys.isEmpty)
    for locale in L10n.supportedLocalizations {
      #expect(L10n.keys(localeIdentifier: locale) == koreanKeys)
    }
  }

  @Test("색선명도는 채도와 구분하고 휘도는 밝기 조절로 번역한다")
  func adjustmentNamesMatchTheirMeaning() {
    for locale in L10n.supportedLocalizations {
      #expect(
        L10n.text("색선명도", localeIdentifier: locale)
          != L10n.text("채도", localeIdentifier: locale)
      )
    }
    #expect(L10n.text("색선명도", localeIdentifier: "en") == "Vibrance")
    #expect(L10n.text("휘도", localeIdentifier: "en") == "Brightness")
    #expect(L10n.text("노출", localeIdentifier: "en") == "Exposure")
    #expect(L10n.text("색온도", localeIdentifier: "en") == "Color Temperature")
    #expect(L10n.text("차갑게", localeIdentifier: "en") == "Cooler")
    #expect(L10n.text("따뜻하게", localeIdentifier: "en") == "Warmer")
  }
}
