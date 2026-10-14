import Foundation
import Testing

@testable import ImageViewer

@Suite("사진 위 분류 이름 표시")
struct PhotoMarkCardSummaryTests {
  @Test("분류를 붙인 순서와 관계없이 키 순서로 두 이름만 보이고 추가 분류를 알린다")
  func namesUseStableOrderAndKeepAllNamesForAccessibility() {
    let names: [PhotoMarkSlot: String] = [.one: "인화", .two: "가족", .q: "공유", .f: "보관"]
    let summary = PhotoMarkCardSummary(assigned: [.f, .q, .two, .one]) { names[$0]! }
    #expect(summary.visibleNames == ["인화", "가족"])
    #expect(summary.hasMore)
    #expect(summary.fullTitle == "인화 · 가족 · 공유 · 보관")
  }

  @Test("0~2개는 추가 분류 표시 없이 실제 이름을 보여준다", arguments: [0, 1, 2])
  func noExtraIndicatorThroughTwoMarks(count: Int) {
    let selected = Set(PhotoMarkSlot.allCases.prefix(count))
    let summary = PhotoMarkCardSummary(assigned: selected) { "이름 \($0.keyLabel)" }
    #expect(summary.visibleNames.count == count)
    #expect(!summary.hasMore)
    #expect(summary.visibleNames == Array(["이름 1", "이름 2"].prefix(count)))
  }

  @Test("빈 분류 이름은 현지화된 이름 없음 표시를 사용하고 긴 유니코드 이름은 보존한다")
  func emptyAndUnicodeNamesRemainReadable() {
    let longName = "가족 👨‍👩‍👧‍👦 · Souvenirs de voyage · ذكريات العائلة"
    let summary = PhotoMarkCardSummary(assigned: [.one, .two]) {
      $0 == .one ? " \n " : longName
    }
    #expect(summary.visibleNames == [PhotoMarkL10n.text("labels.unnamed"), longName])
    #expect(summary.fullTitle.contains(longName))
  }
}
