import SwiftUI
import Testing

@testable import ImageViewer

@Suite("통합 열기 메뉴와 명칭")
struct UnifiedOpenUITests {
  @Test("시작 화면의 열기 메뉴는 기본·사용자 지정 단축키를 실제 메뉴 키로 변환한다")
  func menuShortcutsMatchSavedBindings() throws {
    let standard = try #require(ShortcutAction.openFolder.defaultBinding.menuShortcut)
    #expect(standard.key == KeyEquivalent("o"))
    #expect(standard.modifiers == [.command])
    let custom = try #require(KeyBinding(key: "right", modifiers: [.control, .option]).menuShortcut)
    #expect(custom.key == .rightArrow)
    #expect(custom.modifiers == [.control, .option])
    #expect(KeyBinding(key: "space", modifiers: [.shift]).menuShortcut?.key == .space)
    #expect(KeyBinding(key: "invalid").menuShortcut == nil)
    // 저장된 단축키 식별자는 기존 버전과 호환됩니다.
    #expect(ShortcutAction.openFolder.rawValue == "openFolder")
  }

  @Test("모든 언어에 통합 열기와 이미지 비교 명칭을 제공한다")
  func unifiedLabelsAreLocalized() {
    let required: Set<String> = ["열기", "열기…", "이미지 또는 폴더를 선택하세요.", "%@ 열기",
      "선택한 이미지", "이미지나 폴더를 열거나 이 창에 놓으세요.", "이미지 비교", "이미지 비교 시작"]
    for locale in L10n.supportedLocalizations {
      let keys = L10n.keys(localeIdentifier: locale)
      #expect(required.isSubset(of: keys))
      #expect(!keys.contains("폴더 비교 시작") && !keys.contains("비교 보기 시작"))
    }
    #expect(L10n.text("이미지 비교 시작", localeIdentifier: "ko") == "이미지 비교 시작")
    #expect(ShortcutAction.openFolder.title == L10n.text("열기"))
    #expect(PresentationMode.folderComparison.title == L10n.text("이미지 비교"))
  }
}
