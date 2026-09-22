import CoreGraphics
import Foundation

/// 회전한 이미지의 좌상단을 원점으로 하는, 해상도에 독립적인 자르기 영역입니다.
struct NormalizedCrop: Codable, Hashable, Sendable {
  var x: Double
  var y: Double
  var width: Double
  var height: Double

  static let full = NormalizedCrop(x: 0, y: 0, width: 1, height: 1)

  var normalized: Self {
    guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
      width > 0, height > 0 else { return .full }
    let left = min(1, max(0, x))
    let top = min(1, max(0, y))
    let right = min(1, max(0, x + width))
    let bottom = min(1, max(0, y + height))
    guard right > left, bottom > top else { return .full }
    return Self(x: left, y: top, width: right - left, height: bottom - top)
  }

  var isFullImage: Bool { normalized == .full }

  /// 선택 영역을 포함하는 정수 픽셀 사각형입니다. 유효한 이미지는 최소 한 픽셀을 남깁니다.
  func pixelRect(in size: CGSize) -> CGRect {
    guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1
    else { return .zero }
    let crop = normalized
    let imageWidth = floor(size.width)
    let imageHeight = floor(size.height)
    // 90도 회전의 부동소수점 오차가 정수 경계에서 한 픽셀을 더하지 않게 합니다.
    let left = min(imageWidth - 1, max(0, floor(crop.x * imageWidth + 1e-8)))
    let top = min(imageHeight - 1, max(0, floor(crop.y * imageHeight + 1e-8)))
    let right = min(imageWidth, max(left + 1, ceil((crop.x + crop.width) * imageWidth - 1e-8)))
    let bottom = min(imageHeight, max(top + 1, ceil((crop.y + crop.height) * imageHeight - 1e-8)))
    return CGRect(x: left, y: top, width: right - left, height: bottom - top)
  }

  /// Core Image는 아래쪽이 원점이므로 좌상단 기준 선택 영역의 Y축을 뒤집습니다.
  func coreImageRect(in extent: CGRect) -> CGRect {
    let rect = pixelRect(in: extent.size)
    return CGRect(x: extent.minX + rect.minX, y: extent.maxY - rect.maxY,
      width: rect.width, height: rect.height)
  }

  func rotatedClockwise() -> Self {
    let crop = normalized
    return Self(x: 1 - crop.y - crop.height, y: crop.x,
      width: crop.height, height: crop.width).normalized
  }

  func rotatedCounterclockwise() -> Self {
    let crop = normalized
    return Self(x: crop.y, y: 1 - crop.x - crop.width,
      width: crop.height, height: crop.width).normalized
  }
}

/// 뷰어에서 비파괴적으로 적용하는 기본 이미지 보정값입니다.
///
/// 원본 파일은 사용자가 내보내기를 선택하기 전까지 절대로 수정하지 않습니다.
struct ImageAdjustments: Codable, Hashable, Sendable {
  var brightness: Double = 0
  var contrast: Double = 1
  var saturation: Double = 1
  var highlights: Double = 0
  var sharpness: Double = 0
  var noiseReduction: Double = 0
  var hue: Double = 0
  var temperature: Double = 0
  var vibrance: Double = 0
  var exposure: Double = 0
  var isInverted = false
  var quarterTurns = 0
  var crop: NormalizedCrop? = nil

  static let identity = ImageAdjustments()

  var isIdentity: Bool {
    brightness == 0
      && contrast == 1
      && saturation == 1
      && highlights == 0
      && sharpness == 0
      && noiseReduction == 0
      && hue == 0
      && temperature == 0
      && vibrance == 0
      && exposure == 0
      && !isInverted
      && normalizedQuarterTurns == 0
      && effectiveCrop == nil
  }

  var effectiveCrop: NormalizedCrop? {
    guard let crop else { return nil }
    let normalized = crop.normalized
    return normalized.isFullImage ? nil : normalized
  }

  var normalizedQuarterTurns: Int {
    ((quarterTurns % 4) + 4) % 4
  }

  mutating func rotateClockwise() {
    crop = effectiveCrop?.rotatedClockwise()
    quarterTurns = (normalizedQuarterTurns + 1) % 4
  }

  mutating func rotateCounterclockwise() {
    crop = effectiveCrop?.rotatedCounterclockwise()
    quarterTurns = (normalizedQuarterTurns + 3) % 4
  }

  mutating func reset() {
    self = .identity
  }
}

extension ImageAdjustments {
  private enum CodingKeys: String, CodingKey {
    case brightness, contrast, saturation, highlights, sharpness, noiseReduction
    case hue, temperature, vibrance, exposure, isInverted, quarterTurns, crop
  }

  /// 이전 저장값에 새 키가 없어도 추가 보정은 기본값으로 복원합니다.
  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init()
    brightness = try values.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
    contrast = try values.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
    saturation = try values.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
    highlights = try values.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
    sharpness = try values.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
    noiseReduction = try values.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? 0
    hue = try values.decodeIfPresent(Double.self, forKey: .hue) ?? 0
    temperature = try values.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
    vibrance = try values.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
    exposure = try values.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
    isInverted = try values.decodeIfPresent(Bool.self, forKey: .isInverted) ?? false
    quarterTurns = try values.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0
    crop = try values.decodeIfPresent(NormalizedCrop.self, forKey: .crop)?.normalized
  }
}
