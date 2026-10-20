/// Keeps speculative viewer work bounded and puts the last travel direction first.
struct ViewerPrefetchPlan: Equatable, Sendable {
  enum Direction: Equatable, Sendable {
    case forward
    case backward
  }

  let indices: [Int]

  init(assetCount: Int, pageStartIndex: Int, imagesPerPage: Int,
    direction: Direction = .forward) {
    guard assetCount > 0 else {
      indices = []
      return
    }
    let pageCount = min(10, max(1, imagesPerPage))
    let pageStart = min(assetCount, max(0, pageStartIndex))
    let visibleEnd = pageStart + min(pageCount, assetCount - pageStart)
    let nextEnd = visibleEnd + min(pageCount, assetCount - visibleEnd)
    let previousStart = max(0, pageStart - pageCount)
    let next = Array(visibleEnd..<nextEnd)
    let previous = Array((previousStart..<pageStart).reversed())
    let primary = direction == .forward ? next : previous
    let opposite = direction == .forward ? previous : next
    // Preserve the existing non-wrapping prefetch boundary. Actual page navigation
    // continues to apply the user's wrapping setting independently.
    indices = primary + Array(opposite.prefix(min(2, 10 - primary.count)))
  }
}
