import Foundation

enum AIUpscalingError: LocalizedError {
  case modelUnavailable
  case invalidDimensions
  case imageTooLarge
  case pixelConversionFailed
  case invalidModelOutput
  case sourceChanged
  case sourceOverwrite
  case saveFailed

  var errorDescription: String? {
    switch self {
    case .modelUnavailable: L10n.text("AI 확대 모델을 찾을 수 없습니다. 앱을 다시 설치해 주세요.")
    case .invalidDimensions: L10n.text("이미지 크기를 확인할 수 없습니다.")
    case .imageTooLarge: L10n.text("이 이미지는 AI 확대의 메모리 한도를 넘습니다. 더 작은 사본을 사용해 주세요.")
    case .pixelConversionFailed: L10n.text("AI 확대용 이미지 데이터를 만들지 못했습니다.")
    case .invalidModelOutput: L10n.text("AI 확대 모델이 올바른 결과를 반환하지 않았습니다.")
    case .sourceChanged: L10n.text("원본 이미지가 변경되었습니다. 다시 실행해 주세요.")
    case .sourceOverwrite: L10n.text("원본 파일을 덮어쓸 수 없습니다. 다른 이름을 선택해 주세요.")
    case .saveFailed: L10n.text("AI 확대 사본을 저장하지 못했습니다.")
    }
  }
}

enum AIUpscalingPolicy {
  static let scale = 2
  static let tileSize = 128
  // Four 3x3 convolutions have a radius of four pixels. Only this fully
  // contextualized center is copied, preventing seams between inference tiles.
  static let halo = 4
  static let tileContentSize = tileSize - halo * 2
  static let maximumOutputPixels = 64_000_000

  static func outputSize(width: Int, height: Int,
    physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) throws -> (width: Int, height: Int)
  {
    guard width > 0, height > 0 else { throw AIUpscalingError.invalidDimensions }
    let (outputWidth, widthOverflow) = width.multipliedReportingOverflow(by: scale)
    let (outputHeight, heightOverflow) = height.multipliedReportingOverflow(by: scale)
    let (pixels, pixelsOverflow) = outputWidth.multipliedReportingOverflow(by: outputHeight)
    // The estimate reserves room for source, destination, encode and UI buffers,
    // not merely the neural network's small tile workspace.
    let memoryLimit = Int(min(UInt64(maximumOutputPixels), physicalMemory / 64))
    guard !widthOverflow, !heightOverflow, !pixelsOverflow, pixels <= memoryLimit,
      outputWidth <= 32_768, outputHeight <= 32_768
    else { throw AIUpscalingError.imageTooLarge }
    return (outputWidth, outputHeight)
  }
}
