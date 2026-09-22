import Foundation

enum CropCorner: String, CaseIterable, Identifiable {
  case topLeft, topRight, bottomLeft, bottomRight
  var id: Self { self }
  var isLeft: Bool { self == .topLeft || self == .bottomLeft }
  var isTop: Bool { self == .topLeft || self == .topRight }
  var title: String {
    switch self {
    case .topLeft: L10n.text("왼쪽 위 모서리")
    case .topRight: L10n.text("오른쪽 위 모서리")
    case .bottomLeft: L10n.text("왼쪽 아래 모서리")
    case .bottomRight: L10n.text("오른쪽 아래 모서리")
    }
  }
}

/// Crop gestures use normalized top-left coordinates, independent of Retina scale.
/// The optional ratio is a width/height ratio in these normalized coordinates.
enum CropSelectionGeometry {
  static func move(_ crop: NormalizedCrop, by delta: CGSize) -> NormalizedCrop {
    let crop = crop.normalized
    return NormalizedCrop(
      x: min(max(0, crop.x + delta.width), 1 - crop.width),
      y: min(max(0, crop.y + delta.height), 1 - crop.height),
      width: crop.width, height: crop.height)
  }

  static func draw(from start: CGPoint, to end: CGPoint, ratio: Double?) -> NormalizedCrop {
    let x = min(max(start.x, 0), 1)
    let y = min(max(start.y, 0), 1)
    let endX = min(max(end.x, 0), 1)
    let endY = min(max(end.y, 0), 1)
    let sx: Double = endX > x || (endX == x && x < 1) ? 1 : -1
    let sy: Double = endY > y || (endY == y && y < 1) ? 1 : -1
    let availableWidth = sx > 0 ? 1 - x : x
    let availableHeight = sy > 0 ? 1 - y : y
    // Crossing an anchor must not turn an empty rectangle into a full-image crop.
    var width = min(availableWidth, max(0.001, abs(endX - x)))
    var height = min(availableHeight, max(0.001, abs(endY - y)))
    if let ratio, ratio > 0, ratio.isFinite {
      width = max(width, height * ratio)
      width = min(width, availableWidth, availableHeight * ratio)
      height = width / ratio
    }
    return NormalizedCrop(
      x: sx > 0 ? x : x - width, y: sy > 0 ? y : y - height,
      width: width, height: height).normalized
  }

  static func resize(_ crop: NormalizedCrop, corner: CropCorner,
    by delta: CGSize, ratio: Double?) -> NormalizedCrop
  {
    let anchor = CGPoint(
      x: corner.isLeft ? crop.x + crop.width : crop.x,
      y: corner.isTop ? crop.y + crop.height : crop.y)
    let end = CGPoint(
      x: (corner.isLeft ? crop.x : crop.x + crop.width) + delta.width,
      y: (corner.isTop ? crop.y : crop.y + crop.height) + delta.height)
    return draw(from: anchor, to: end, ratio: ratio)
  }

  static func fit(_ crop: NormalizedCrop, ratio: Double) -> NormalizedCrop {
    guard ratio > 0, ratio.isFinite else { return crop.normalized }
    let crop = crop.normalized
    let width = min(crop.width, crop.height * ratio)
    let height = width / ratio
    return NormalizedCrop(
      x: crop.x + (crop.width - width) / 2,
      y: crop.y + (crop.height - height) / 2,
      width: width, height: height).normalized
  }
}
