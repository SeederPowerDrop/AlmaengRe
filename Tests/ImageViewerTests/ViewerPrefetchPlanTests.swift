import Testing

@testable import ImageViewer

@Suite("Viewer prefetch follows travel direction within the existing budget")
struct ViewerPrefetchPlanTests {
  @Test("The travel direction gets a page before at most two opposite neighbors")
  func pagePriorityInBothDirections() {
    let cases: [(count: Int, forward: [Int], backward: [Int])] = [
      (2, [22, 23, 19, 18], [19, 18, 22, 23]),
      (4, [24, 25, 26, 27, 19, 18], [19, 18, 17, 16, 24, 25]),
      (6, [26, 27, 28, 29, 30, 31, 19, 18], [19, 18, 17, 16, 15, 14, 26, 27]),
      (9, [29, 30, 31, 32, 33, 34, 35, 36, 37, 19],
        [19, 18, 17, 16, 15, 14, 13, 12, 11, 29]),
      (10, [30, 31, 32, 33, 34, 35, 36, 37, 38, 39],
        [19, 18, 17, 16, 15, 14, 13, 12, 11, 10]),
    ]
    for item in cases {
      #expect(plan(count: 50, start: 20, page: item.count, direction: .forward) == item.forward)
      #expect(plan(count: 50, start: 20, page: item.count, direction: .backward) == item.backward)
    }
  }

  @Test("The first and last pages keep non-wrapping speculative boundaries",
    arguments: [2, 4, 6, 9, 10])
  func boundaries(page: Int) {
    #expect(plan(count: 30, start: 0, page: page, direction: .forward)
      == Array(page..<(page * 2)))
    #expect(plan(count: 30, start: 0, page: page, direction: .backward)
      == [page, page + 1])
    let start = 30 - page
    #expect(plan(count: 30, start: start, page: page, direction: .forward)
      == [start - 1, start - 2])
    #expect(plan(count: 30, start: start, page: page, direction: .backward)
      == Array(((start - page)..<start).reversed()))
  }

  @Test("A short trailing page preserves nearest-first priority without filling the opposite side")
  func shortTailAndShortPreviousPage() {
    #expect(plan(count: 23, start: 20, page: 10, direction: .backward)
      == [19, 18, 17, 16, 15, 14, 13, 12, 11, 10])
    #expect(plan(count: 23, start: 20, page: 10, direction: .forward) == [19, 18])
    #expect(plan(count: 23, start: 3, page: 10, direction: .backward) == [2, 1, 0, 13, 14])
    #expect(plan(count: 23, start: 10, page: 10, direction: .forward) == [20, 21, 22, 9, 8])
  }

  @Test("Repeated direction flips never include visible, duplicate or out-of-range indices",
    arguments: [2, 4, 6, 9, 10])
  func flipsRemainBounded(page: Int) {
    for start in 0..<31 {
      let visible = start..<min(31, start + page)
      let directions: [ViewerPrefetchPlan.Direction] = [.forward, .backward, .forward, .backward]
      for direction in directions {
        let indices = plan(count: 31, start: start, page: page, direction: direction)
        #expect(indices.count <= 10)
        #expect(Set(indices).count == indices.count)
        #expect(indices.allSatisfy { (0..<31).contains($0) && !visible.contains($0) })
        let oppositeCount = indices.filter { direction == .forward ? $0 < start : $0 >= visible.upperBound }.count
        #expect(oppositeCount <= 2)
      }
    }
  }

  @Test("Empty and out-of-range inputs stay bounded and the default direction is forward")
  func defensiveInputs() {
    #expect(plan(count: 0, start: 0, page: 10, direction: .forward).isEmpty)
    #expect(plan(count: -1, start: 0, page: 10, direction: .backward).isEmpty)
    #expect(plan(count: 5, start: -10, page: 0, direction: .forward) == [1])
    #expect(plan(count: 5, start: 10, page: 10, direction: .forward) == [4, 3])
    let normal = ViewerPrefetchPlan(assetCount: 50, pageStartIndex: 20, imagesPerPage: 10)
    #expect(normal.indices == plan(count: 50, start: 20, page: 10, direction: .forward))
    let huge = plan(count: .max, start: .max - 1, page: .max, direction: .backward)
    #expect(huge.count == 10 && huge.first == .max - 2)
  }

  private func plan(count: Int, start: Int, page: Int,
    direction: ViewerPrefetchPlan.Direction) -> [Int] {
    ViewerPrefetchPlan(assetCount: count, pageStartIndex: start,
      imagesPerPage: page, direction: direction).indices
  }
}
