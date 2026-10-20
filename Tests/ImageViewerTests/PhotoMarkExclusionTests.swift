import Foundation
import Testing

@testable import ImageViewer

@Suite("분류 포함·제외 조건과 이전 저장 형식")
struct PhotoMarkExclusionTests {
  @Test("제외 분류는 포함 OR·AND보다 우선하며 모든 표시 조합을 판정한다")
  func exclusionsApplyToEveryMarkCombination() {
    let any = PhotoMarkFilter(slots: [.s, .a], excludedSlots: [.e, .q])
    let all = PhotoMarkFilter(slots: [.s, .a], matchesAll: true, excludedSlots: [.e, .q])
    let exclusionsOnly = PhotoMarkFilter(excludedSlots: [.e, .q])
    for mask in 0..<(1 << PhotoMarkSlot.allCases.count) {
      let marks = PhotoMarkSlot.slots(in: mask)
      let allowed = !marks.contains(.e) && !marks.contains(.q)
      #expect(any.matches(marks) == (allowed && (marks.contains(.s) || marks.contains(.a))))
      #expect(all.matches(marks) == (allowed && marks.contains(.s) && marks.contains(.a)))
      #expect(exclusionsOnly.matches(marks) == allowed)
    }
    #expect(exclusionsOnly.isActive && exclusionsOnly.conditionCount == 2)
    #expect(!PhotoMarkFilter(slots: [.s], excludedSlots: [.s]).matches([.s]),
      "A conflicting externally decoded condition must never bypass an exclusion")
  }

  @Test("동일한 분류를 포함·제외로 동시에 선택하지 않고 미분류는 조건을 초기화한다")
  func editorKeepsConditionsUnambiguous() {
    var filter = PhotoMarkFilter(unmarkedOnly: true)
    filter.setIncluded(.s, enabled: true)
    #expect(filter.slots == [.s] && !filter.unmarkedOnly)
    filter.setExcluded(.e, enabled: true)
    #expect(filter.slots == [.s] && filter.excludedSlots == [.e])
    #expect(filter.conditionCount == 2 && filter.matches([.s]) && !filter.matches([.s, .e]))
    filter.setExcluded(.s, enabled: true)
    #expect(filter.slots.isEmpty && filter.excludedSlots == [.s, .e])
    filter.setIncluded(.e, enabled: true)
    #expect(filter.slots == [.e] && filter.excludedSlots == [.s])
    filter.setIncluded(.e, enabled: false)
    filter.setExcluded(.s, enabled: false)
    #expect(!filter.isActive)
    filter.setIncluded(.s, enabled: true)
    filter.setExcluded(.e, enabled: true)
    filter.setUnmarkedOnly(true)
    #expect(filter.slots.isEmpty && filter.excludedSlots.isEmpty && filter.unmarkedOnly)
    #expect(filter.matches([]) && !filter.matches([.s]))
    filter.setUnmarkedOnly(false)
    #expect(!filter.isActive)
  }

  @Test("이전 분류 필터를 유지해서 읽고 제외 조건도 왕복 저장한다")
  func previousAndCurrentSessionsRoundTrip() throws {
    let legacy = Data(#"{"slots":["s","a"],"matchesAll":true,"unmarkedOnly":false}"#.utf8)
    let restored = try JSONDecoder().decode(PhotoMarkFilter.self, from: legacy)
    #expect(restored == PhotoMarkFilter(slots: [.s, .a], matchesAll: true))
    #expect(restored.excludedSlots.isEmpty)
    let filter = PhotoMarkFilter(slots: [.s], excludedSlots: [.e])
    #expect(try JSONDecoder().decode(PhotoMarkFilter.self, from: JSONEncoder().encode(filter)) == filter)
    #expect(try PropertyListDecoder().decode(PhotoMarkFilter.self,
      from: PropertyListEncoder().encode(filter)) == filter)
  }
}
