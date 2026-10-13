/// Vertical selection follows the displayed grid, without wrapping across its edges.
enum GridRowNavigation {
  static func target(from index: Int, direction: Int, count: Int, columns: Int) -> Int {
    guard count > 0 else { return 0 }
    let current = min(max(0, index), count - 1)
    guard direction != 0 else { return current }
    let width = min(count, max(1, columns))
    let row = current / width
    let lastRow = (count - 1) / width
    guard direction < 0 ? row > 0 : row < lastRow else { return current }
    let targetRow = row + (direction < 0 ? -1 : 1)
    return min(targetRow * width + current % width, count - 1)
  }
}
