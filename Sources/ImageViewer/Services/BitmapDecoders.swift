import CoreGraphics
import Foundation

enum BitmapDecoderError: LocalizedError {
  case invalidHeader(String)
  case unsupportedVariant(String)
  case truncatedData(String)
  case imageTooLarge
  case imageCreationFailed

  var errorDescription: String? {
    switch self {
    case .invalidHeader(let format):
      L10n.format("손상되었거나 올바르지 않은 %@ 파일입니다.", L10n.text(format))
    case .unsupportedVariant(let detail):
      L10n.format("아직 지원하지 않는 이미지 변형입니다: %@", detail)
    case .truncatedData(let format):
      L10n.format("%@ 이미지 데이터가 중간에 끝났습니다.", L10n.text(format))
    case .imageTooLarge: L10n.text("안전한 메모리 한도를 넘는 이미지입니다.")
    case .imageCreationFailed: L10n.text("디코딩한 픽셀로 이미지를 만들지 못했습니다.")
    }
  }
}

/// 단순 RGBA 바이트 버퍼를 Core Graphics 이미지로 감싸는 공용 도우미입니다.
enum RasterImageFactory {
  static func makeRGBA(
    width: Int,
    height: Int,
    pixels: Data,
    colorSpace: CGColorSpace
  ) throws -> CGImage {
    // Core Graphics와 Core Image의 공통 고속 경로는 premultiplied RGBA입니다.
    // QOI는 straight alpha를 저장하므로 여기서 한 번 정규화합니다.
    var premultipliedPixels = pixels
    premultipliedPixels.withUnsafeMutableBytes { rawBuffer in
      guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
      for offset in stride(from: 0, to: rawBuffer.count, by: 4) {
        let alpha = UInt16(bytes[offset + 3])
        bytes[offset] = UInt8((UInt16(bytes[offset]) * alpha + 127) / 255)
        bytes[offset + 1] = UInt8((UInt16(bytes[offset + 1]) * alpha + 127) / 255)
        bytes[offset + 2] = UInt8((UInt16(bytes[offset + 2]) * alpha + 127) / 255)
      }
    }

    guard let provider = CGDataProvider(data: premultipliedPixels as CFData) else {
      throw BitmapDecoderError.imageCreationFailed
    }

    let bitmapInfo: CGBitmapInfo = [
      .byteOrder32Big,
      CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
    ]
    guard
      let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
      )
    else {
      throw BitmapDecoderError.imageCreationFailed
    }

    return image
  }

  /// 압축 폭탄이나 비정상 헤더가 무제한 메모리를 예약하지 못하게 제한합니다.
  static func validatedPixelCount(width: Int, height: Int) throws -> Int {
    guard width > 0, height > 0,
      width <= 100_000, height <= 100_000
    else {
      throw BitmapDecoderError.invalidHeader("이미지")
    }

    let (pixelCount, overflowed) = width.multipliedReportingOverflow(by: height)
    guard !overflowed, pixelCount <= 100_000_000 else {
      throw BitmapDecoderError.imageTooLarge
    }
    return pixelCount
  }
}

/// Custom bitmap parsers run in the Rust core; Core Graphics retains a copied pixel buffer.
enum QOIDecoder {
  static func decode(url: URL) throws -> CGImage {
    try RustImageEngine.decode(Data(contentsOf: url, options: [.mappedIfSafe]), format: 1)
  }
}

enum PCXDecoder {
  static func decode(url: URL) throws -> CGImage {
    try RustImageEngine.decode(Data(contentsOf: url, options: [.mappedIfSafe]), format: 2)
  }
}
