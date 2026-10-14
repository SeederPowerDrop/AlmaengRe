import CoreGraphics
import Foundation

enum ViewerFrameLayoutPreset: String, Codable, CaseIterable, Identifiable, Sendable {
  case balanced, horizontal, vertical, customColumns

  var id: Self { self }
}

/// Slot IDs refer to the unchanged source page, rather than to files or sort order.
/// Changing a layout only moves those IDs between visual positions.
struct ViewerFrameLayoutConfiguration: Codable, Equatable, Sendable {
  struct Row: Codable, Equatable, Sendable {
    var slots: [Int]
    var widths: [Double]

    init(slots: [Int], widths: [Double] = []) {
      self.slots = slots
      self.widths = widths
    }
  }

  var preset: ViewerFrameLayoutPreset
  var columnCount: Int
  var rows: [Row]
  var heights: [Double]

  var count: Int { rows.reduce(0) { $0 + $1.slots.count } }
  var visualSlots: [Int] { rows.flatMap(\.slots) }

  init(count: Int, preset: ViewerFrameLayoutPreset = .balanced, columns requestedColumns: Int? = nil) {
    let count = Self.safeCount(count)
    self.preset = preset
    let columns: Int
    switch preset {
    case .balanced: columns = max(1, Int(ceil(sqrt(Double(count)))))
    case .horizontal: columns = max(1, count)
    case .vertical: columns = 1
    case .customColumns: columns = min(max(1, count), max(1, requestedColumns ?? 2))
    }
    columnCount = columns
    rows = []
    heights = []
    guard count > 0 else { return }

    let rowCount = (count + columns - 1) / columns
    var firstSlot = 0
    for rowIndex in 0..<rowCount {
      let rowSlots: Int
      if preset == .balanced {
        rowSlots = count / rowCount + (rowIndex < count % rowCount ? 1 : 0)
      } else {
        rowSlots = min(columns, count - firstSlot)
      }
      rows.append(Row(slots: Array(firstSlot..<(firstSlot + rowSlots)),
        widths: Array(repeating: 1 / Double(rowSlots), count: rowSlots)))
      firstSlot += rowSlots
    }
    heights = Array(repeating: 1 / Double(rowCount), count: rowCount)
  }

  /// Keeps valid saved geometry while rejecting duplicate/missing source slots,
  /// invalid sizes, and data from an incompatible page size.
  func normalized(count requestedCount: Int) -> Self {
    let expected = Self.safeCount(requestedCount)
    guard expected > 0 else { return Self(count: 0, preset: preset) }
    let slots = visualSlots
    guard !rows.isEmpty, rows.count <= expected,
      rows.allSatisfy({ !$0.slots.isEmpty && $0.slots.count <= expected }),
      slots.count == expected, Set(slots) == Set(0..<expected) else {
      return Self(count: expected, preset: preset, columns: columnCount)
    }
    var result = self
    result.columnCount = rows.map(\.slots.count).max() ?? 1
    result.heights = Self.normalizedWeights(heights, count: rows.count)
    for index in result.rows.indices {
      result.rows[index].widths = Self.normalizedWeights(rows[index].widths,
        count: rows[index].slots.count)
    }
    return result
  }

  func geometry(in size: CGSize) -> ViewerFrameLayoutGeometry {
    let clean = normalized(count: count)
    guard !clean.rows.isEmpty else { return .init(frames: [], dividers: []) }
    let width = Self.finiteExtent(size.width)
    let height = Self.finiteExtent(size.height)
    let insetX = min(3, width / 2)
    let insetY = min(3, height / 2)
    let innerWidth = max(0, width - insetX * 2)
    let innerHeight = max(0, height - insetY * 2)
    let rowGap = Self.gap(extent: innerHeight, count: clean.rows.count)
    let rowSizes = Self.allocatedSizes(weights: clean.heights,
      available: max(0, innerHeight - rowGap * CGFloat(clean.rows.count - 1)))
    var frames: [ViewerFrameLayoutFrame] = []
    var dividers: [ViewerFrameLayoutDivider] = []
    var y = insetY
    for (rowIndex, row) in clean.rows.enumerated() {
      let columnGap = Self.gap(extent: innerWidth, count: row.slots.count)
      let columnSizes = Self.allocatedSizes(weights: row.widths,
        available: max(0, innerWidth - columnGap * CGFloat(row.slots.count - 1)))
      var x = insetX
      for (columnIndex, slot) in row.slots.enumerated() {
        let rect = CGRect(x: x, y: y, width: columnSizes[columnIndex], height: rowSizes[rowIndex])
        frames.append(.init(slot: slot, rect: rect))
        x += columnSizes[columnIndex]
        if columnIndex + 1 < row.slots.count {
          dividers.append(.init(axis: .vertical, index: columnIndex, row: rowIndex,
            rect: CGRect(x: x, y: y, width: columnGap, height: rowSizes[rowIndex])))
          x += columnGap
        }
      }
      y += rowSizes[rowIndex]
      if rowIndex + 1 < clean.rows.count {
        dividers.append(.init(axis: .horizontal, index: rowIndex, row: nil,
          rect: CGRect(x: insetX, y: y, width: innerWidth, height: rowGap)))
        y += rowGap
      }
    }
    return .init(frames: frames.sorted { $0.slot < $1.slot }, dividers: dividers)
  }

  func swapping(_ sourceSlot: Int, with targetSlot: Int) -> Self {
    var result = normalized(count: count)
    guard sourceSlot != targetSlot, result.visualSlots.contains(sourceSlot),
      result.visualSlots.contains(targetSlot) else { return result }
    for rowIndex in result.rows.indices {
      result.rows[rowIndex].slots = result.rows[rowIndex].slots.map {
        $0 == sourceSlot ? targetSlot : ($0 == targetSlot ? sourceSlot : $0)
      }
    }
    return result
  }

  /// Call on the configuration captured when the drag began, using the gesture's
  /// total translation. Neighbouring frames absorb the change; other frames stay put.
  func resizing(_ divider: ViewerFrameLayoutDivider, translation: CGSize, in size: CGSize) -> Self {
    var result = normalized(count: count)
    let geometry = result.geometry(in: size)
    guard geometry.dividers.contains(where: { $0.id == divider.id }) else { return result }
    let framesBySlot = Dictionary(uniqueKeysWithValues: geometry.frames.map { ($0.slot, $0.rect) })
    let sizes: [CGFloat]
    let delta: CGFloat
    switch divider.axis {
    case .horizontal:
      sizes = result.rows.map { framesBySlot[$0.slots[0]]?.height ?? 0 }
      delta = translation.height
    case .vertical:
      guard let row = divider.row, result.rows.indices.contains(row) else { return result }
      sizes = result.rows[row].slots.map { framesBySlot[$0]?.width ?? 0 }
      delta = translation.width
    }
    guard delta.isFinite, divider.index >= 0, divider.index + 1 < sizes.count else { return result }
    let total = sizes.reduce(0, +)
    guard total > 0 else { return result }
    let minimum = min(80, total / CGFloat(sizes.count))
    let pairSize = sizes[divider.index] + sizes[divider.index + 1]
    let first = min(max(minimum, sizes[divider.index] + delta), max(minimum, pairSize - minimum))
    var adjusted = sizes
    adjusted[divider.index] = first
    adjusted[divider.index + 1] = max(0, pairSize - first)
    let weights = adjusted.map { Double($0 / total) }
    switch divider.axis {
    case .horizontal: result.heights = weights
    case .vertical: result.rows[divider.row!].widths = weights
    }
    return result
  }

  /// Follows the displayed row and nearest physical column even after swaps and
  /// unequal resizing. It never wraps past the top or bottom of the page.
  func rowTarget(from sourceSlot: Int, direction: Int, in size: CGSize? = nil) -> Int {
    let clean = normalized(count: count)
    guard let currentRow = clean.rows.firstIndex(where: { $0.slots.contains(sourceSlot) }),
      direction != 0 else { return sourceSlot }
    let targetRow = currentRow + (direction < 0 ? -1 : 1)
    guard clean.rows.indices.contains(targetRow) else { return sourceSlot }
    let centers = clean.geometry(in: size ?? CGSize(width: 10_000, height: 10_000)).frames
    guard let currentX = centers.first(where: { $0.slot == sourceSlot })?.rect.midX else { return sourceSlot }
    let candidates = centers.filter { clean.rows[targetRow].slots.contains($0.slot) }
    return candidates.min {
      let lhs = abs($0.rect.midX - currentX)
      let rhs = abs($1.rect.midX - currentX)
      return abs(lhs - rhs) < 0.000_001 ? $0.rect.minX < $1.rect.minX : lhs < rhs
    }?.slot ?? sourceSlot
  }

  private static func safeCount(_ count: Int) -> Int { min(10, max(0, count)) }

  private static func normalizedWeights(_ values: [Double], count: Int) -> [Double] {
    guard count > 0 else { return [] }
    guard values.count == count, values.allSatisfy({ $0.isFinite && $0 > 0 }),
      let maximum = values.max(), maximum > 0 else {
      return Array(repeating: 1 / Double(count), count: count)
    }
    // Scaling first also makes extremely large persisted numbers harmless.
    let scaled = values.map { max(Double.leastNormalMagnitude, $0 / maximum) }
    let sum = scaled.reduce(0, +)
    return scaled.map { $0 / sum }
  }

  private static func finiteExtent(_ extent: CGFloat) -> CGFloat {
    extent.isFinite ? max(0, extent) : 0
  }

  private static func gap(extent: CGFloat, count: Int) -> CGFloat {
    guard count > 1 else { return 0 }
    return min(6, extent * 0.15 / CGFloat(count - 1))
  }

  private static func allocatedSizes(weights: [Double], available: CGFloat) -> [CGFloat] {
    guard !weights.isEmpty else { return [] }
    let weights = normalizedWeights(weights, count: weights.count)
    let available = finiteExtent(available)
    let minimum = min(80, available / CGFloat(weights.count))
    var result = Array(repeating: CGFloat(0), count: weights.count)
    var pending = Array(weights.indices)
    var remaining = available
    while !pending.isEmpty {
      let weightSum = pending.reduce(0) { $0 + weights[$1] }
      let tooSmall = pending.filter { remaining * CGFloat(weights[$0] / weightSum) < minimum }
      if tooSmall.isEmpty {
        for index in pending { result[index] = remaining * CGFloat(weights[index] / weightSum) }
        break
      }
      for index in tooSmall {
        result[index] = minimum
        remaining = max(0, remaining - minimum)
      }
      pending.removeAll { tooSmall.contains($0) }
    }
    return result
  }
}

struct ViewerFrameLayoutFrame: Identifiable, Equatable, Sendable {
  let slot: Int
  let rect: CGRect
  var id: Int { slot }
}

struct ViewerFrameLayoutDivider: Identifiable, Equatable, Sendable {
  enum Axis: String, Sendable { case horizontal, vertical }
  let axis: Axis
  let index: Int
  let row: Int?
  let rect: CGRect

  var id: String {
    axis == .horizontal ? "row:\(index)" : "column:\(row ?? -1):\(index)"
  }
}

struct ViewerFrameLayoutGeometry: Equatable, Sendable {
  let frames: [ViewerFrameLayoutFrame]
  let dividers: [ViewerFrameLayoutDivider]
}
