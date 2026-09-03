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
    case .invalidHeader(let format): "손상되었거나 올바르지 않은 \(format) 파일입니다."
    case .unsupportedVariant(let detail): "아직 지원하지 않는 이미지 변형입니다: \(detail)"
    case .truncatedData(let format): "\(format) 이미지 데이터가 중간에 끝났습니다."
    case .imageTooLarge: "안전한 메모리 한도를 넘는 이미지입니다."
    case .imageCreationFailed: "디코딩한 픽셀로 이미지를 만들지 못했습니다."
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

/// QOI(Quite OK Image)는 사양이 작고 명확해 앱 안에 안전한 디코더를 직접 둡니다.
enum QOIDecoder {
  private struct Pixel {
    var r: UInt8 = 0
    var g: UInt8 = 0
    var b: UInt8 = 0
    var a: UInt8 = 255

    var hashIndex: Int {
      (Int(r) * 3 + Int(g) * 5 + Int(b) * 7 + Int(a) * 11) % 64
    }
  }

  static func decode(url: URL) throws -> CGImage {
    let bytes = [UInt8](try Data(contentsOf: url, options: [.mappedIfSafe]))
    guard bytes.count >= 22,
      bytes[0] == 0x71, bytes[1] == 0x6F,
      bytes[2] == 0x69, bytes[3] == 0x66
    else {
      throw BitmapDecoderError.invalidHeader("QOI")
    }

    let width = Int(readBigEndianUInt32(bytes, at: 4))
    let height = Int(readBigEndianUInt32(bytes, at: 8))
    let pixelCount = try RasterImageFactory.validatedPixelCount(width: width, height: height)
    guard bytes[12] == 3 || bytes[12] == 4 else {
      throw BitmapDecoderError.unsupportedVariant("QOI 채널 수 \(bytes[12])")
    }

    var output = Data(count: pixelCount * 4)
    var cursor = 14
    var pixel = Pixel()
    var index = Array(repeating: Pixel(), count: 64)
    var remainingRun = 0

    try output.withUnsafeMutableBytes { rawBuffer in
      guard let destination = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
        throw BitmapDecoderError.imageCreationFailed
      }

      for pixelIndex in 0..<pixelCount {
        if remainingRun > 0 {
          remainingRun -= 1
        } else {
          guard cursor < bytes.count else {
            throw BitmapDecoderError.truncatedData("QOI")
          }

          let tag = bytes[cursor]
          cursor += 1

          switch tag {
          case 0xFE:
            guard cursor + 2 < bytes.count else {
              throw BitmapDecoderError.truncatedData("QOI")
            }
            pixel.r = bytes[cursor]
            pixel.g = bytes[cursor + 1]
            pixel.b = bytes[cursor + 2]
            cursor += 3

          case 0xFF:
            guard cursor + 3 < bytes.count else {
              throw BitmapDecoderError.truncatedData("QOI")
            }
            pixel.r = bytes[cursor]
            pixel.g = bytes[cursor + 1]
            pixel.b = bytes[cursor + 2]
            pixel.a = bytes[cursor + 3]
            cursor += 4

          default:
            switch tag & 0xC0 {
            case 0x00:  // QOI_OP_INDEX
              pixel = index[Int(tag & 0x3F)]

            case 0x40:  // QOI_OP_DIFF
              pixel.r &+= UInt8(truncatingIfNeeded: Int(tag >> 4 & 0x03) - 2)
              pixel.g &+= UInt8(truncatingIfNeeded: Int(tag >> 2 & 0x03) - 2)
              pixel.b &+= UInt8(truncatingIfNeeded: Int(tag & 0x03) - 2)

            case 0x80:  // QOI_OP_LUMA
              guard cursor < bytes.count else {
                throw BitmapDecoderError.truncatedData("QOI")
              }
              let second = bytes[cursor]
              cursor += 1
              let greenDelta = Int(tag & 0x3F) - 32
              let redDelta = greenDelta + Int(second >> 4) - 8
              let blueDelta = greenDelta + Int(second & 0x0F) - 8
              pixel.r &+= UInt8(truncatingIfNeeded: redDelta)
              pixel.g &+= UInt8(truncatingIfNeeded: greenDelta)
              pixel.b &+= UInt8(truncatingIfNeeded: blueDelta)

            default:  // QOI_OP_RUN
              // 현재 픽셀도 한 번 출력하므로 뒤에 남은 반복 수만 저장합니다.
              remainingRun = Int(tag & 0x3F)
            }
          }
        }

        index[pixel.hashIndex] = pixel
        let offset = pixelIndex * 4
        destination[offset] = pixel.r
        destination[offset + 1] = pixel.g
        destination[offset + 2] = pixel.b
        destination[offset + 3] = pixel.a
      }
    }

    let colorSpace: CGColorSpace
    if bytes[13] == 1 {
      colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
    } else {
      colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    }

    return try RasterImageFactory.makeRGBA(
      width: width,
      height: height,
      pixels: output,
      colorSpace: colorSpace
    )
  }

  private static func readBigEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24
      | UInt32(bytes[offset + 1]) << 16
      | UInt32(bytes[offset + 2]) << 8
      | UInt32(bytes[offset + 3])
  }
}

/// 오래된 스캔·그래픽 자료에서 아직 자주 만나는 PCX의 대표 변형을 지원합니다.
enum PCXDecoder {
  static func decode(url: URL) throws -> CGImage {
    let bytes = [UInt8](try Data(contentsOf: url, options: [.mappedIfSafe]))
    guard bytes.count >= 128, bytes[0] == 0x0A, bytes[2] == 1 else {
      throw BitmapDecoderError.invalidHeader("PCX")
    }

    let bitsPerPixel = Int(bytes[3])
    let width = littleEndianUInt16(bytes, at: 8) - littleEndianUInt16(bytes, at: 4) + 1
    let height = littleEndianUInt16(bytes, at: 10) - littleEndianUInt16(bytes, at: 6) + 1
    let planeCount = Int(bytes[65])
    let bytesPerLine = littleEndianUInt16(bytes, at: 66)
    let pixelCount = try RasterImageFactory.validatedPixelCount(width: width, height: height)

    guard bytesPerLine > 0, planeCount > 0 else {
      throw BitmapDecoderError.invalidHeader("PCX")
    }

    let rowByteCount = bytesPerLine * planeCount
    let decodedByteCount = rowByteCount * height
    var decoded = [UInt8]()
    decoded.reserveCapacity(decodedByteCount)
    var cursor = 128

    while decoded.count < decodedByteCount {
      guard cursor < bytes.count else {
        throw BitmapDecoderError.truncatedData("PCX")
      }
      let value = bytes[cursor]
      cursor += 1

      if value & 0xC0 == 0xC0 {
        let count = Int(value & 0x3F)
        guard cursor < bytes.count else {
          throw BitmapDecoderError.truncatedData("PCX")
        }
        let repeated = bytes[cursor]
        cursor += 1
        decoded.append(
          contentsOf: repeatElement(repeated, count: min(count, decodedByteCount - decoded.count)))
      } else {
        decoded.append(value)
      }
    }

    var output = Data(count: pixelCount * 4)
    try output.withUnsafeMutableBytes { rawBuffer in
      guard let destination = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
        throw BitmapDecoderError.imageCreationFailed
      }

      for y in 0..<height {
        let rowStart = y * rowByteCount
        for x in 0..<width {
          let rgba = try color(
            x: x,
            rowStart: rowStart,
            bitsPerPixel: bitsPerPixel,
            planeCount: planeCount,
            bytesPerLine: bytesPerLine,
            decoded: decoded,
            originalBytes: bytes
          )
          let offset = (y * width + x) * 4
          destination[offset] = rgba.0
          destination[offset + 1] = rgba.1
          destination[offset + 2] = rgba.2
          destination[offset + 3] = 255
        }
      }
    }

    return try RasterImageFactory.makeRGBA(
      width: width,
      height: height,
      pixels: output,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    )
  }

  private static func color(
    x: Int,
    rowStart: Int,
    bitsPerPixel: Int,
    planeCount: Int,
    bytesPerLine: Int,
    decoded: [UInt8],
    originalBytes: [UInt8]
  ) throws -> (UInt8, UInt8, UInt8) {
    if bitsPerPixel == 8, planeCount >= 3 {
      return (
        decoded[rowStart + x],
        decoded[rowStart + bytesPerLine + x],
        decoded[rowStart + bytesPerLine * 2 + x]
      )
    }

    if bitsPerPixel == 8, planeCount == 1 {
      let paletteOffset = originalBytes.count - 769
      guard paletteOffset >= 0, originalBytes[paletteOffset] == 0x0C else {
        throw BitmapDecoderError.truncatedData("PCX 팔레트")
      }
      let colorIndex = Int(decoded[rowStart + x])
      let base = paletteOffset + 1 + colorIndex * 3
      return (originalBytes[base], originalBytes[base + 1], originalBytes[base + 2])
    }

    if bitsPerPixel == 1, (1...4).contains(planeCount) {
      var colorIndex = 0
      let byteIndex = x / 8
      let mask = UInt8(0x80 >> (x % 8))
      for plane in 0..<planeCount
      where decoded[rowStart + plane * bytesPerLine + byteIndex] & mask != 0 {
        colorIndex |= 1 << plane
      }
      return headerPaletteColor(index: colorIndex, bytes: originalBytes)
    }

    if bitsPerPixel == 4, planeCount == 1 {
      let packed = decoded[rowStart + x / 2]
      let colorIndex = x.isMultiple(of: 2) ? Int(packed >> 4) : Int(packed & 0x0F)
      return headerPaletteColor(index: colorIndex, bytes: originalBytes)
    }

    throw BitmapDecoderError.unsupportedVariant(
      "PCX \(bitsPerPixel)비트 × \(planeCount)플레인"
    )
  }

  private static func headerPaletteColor(index: Int, bytes: [UInt8]) -> (UInt8, UInt8, UInt8) {
    let base = 16 + min(index, 15) * 3
    return (bytes[base], bytes[base + 1], bytes[base + 2])
  }

  private static func littleEndianUInt16(_ bytes: [UInt8], at offset: Int) -> Int {
    Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
  }
}
