import Foundation

/// Output dimensions refer to the image after its existing crop and rotation.
/// Batch resizing never enlarges a smaller image.
enum BatchResizeOptions: Equatable, Sendable {
  case original
  case longestEdge(Int)
  case percentage(Double)

  func dimensions(width: Int, height: Int) throws -> (width: Int, height: Int) {
    guard width > 0, height > 0 else { throw BatchResizeError.invalidSize }
    let scale: Double
    switch self {
    case .original:
      return (width, height)
    case .longestEdge(let pixels):
      guard (1...65_536).contains(pixels) else { throw BatchResizeError.invalidSize }
      scale = min(1, Double(pixels) / Double(max(width, height)))
    case .percentage(let percent):
      guard percent.isFinite, percent >= 1, percent <= 100 else {
        throw BatchResizeError.invalidSize
      }
      scale = percent / 100
    }
    return (max(1, Int((Double(width) * scale).rounded())),
      max(1, Int((Double(height) * scale).rounded())))
  }
}

enum BatchResizeError: LocalizedError {
  case invalidSize
  case renderingFailed

  var errorDescription: String? {
    switch self {
    case .invalidSize:
      BatchResizeL10n.text("긴 변은 1~65536픽셀, 비율은 1~100%로 입력하세요.")
    case .renderingFailed:
      BatchResizeL10n.text("이미지 크기를 변경하지 못했습니다.")
    }
  }
}
