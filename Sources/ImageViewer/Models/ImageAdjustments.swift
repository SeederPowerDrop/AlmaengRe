import Foundation

/// 뷰어에서 비파괴적으로 적용하는 기본 이미지 보정값입니다.
///
/// 원본 파일은 사용자가 내보내기를 선택하기 전까지 절대로 수정하지 않습니다.
struct ImageAdjustments: Codable, Hashable, Sendable {
  var brightness: Double = 0
  var contrast: Double = 1
  var saturation: Double = 1
  var highlights: Double = 0
  var isInverted = false
  var quarterTurns = 0

  static let identity = ImageAdjustments()

  var isIdentity: Bool {
    brightness == 0
      && contrast == 1
      && saturation == 1
      && highlights == 0
      && !isInverted
      && normalizedQuarterTurns == 0
  }

  var normalizedQuarterTurns: Int {
    ((quarterTurns % 4) + 4) % 4
  }

  mutating func rotateClockwise() {
    quarterTurns = (normalizedQuarterTurns + 1) % 4
  }

  mutating func rotateCounterclockwise() {
    quarterTurns = (normalizedQuarterTurns + 3) % 4
  }

  mutating func reset() {
    self = .identity
  }
}
