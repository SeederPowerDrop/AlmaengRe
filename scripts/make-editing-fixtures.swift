// User-photo-free fixtures for crop, rotation, light/color/detail and 10-image UI QA.
// swift scripts/make-editing-fixtures.swift /tmp/new-editing-fixtures
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else { fatalError("새 출력 폴더를 지정하세요.") }
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard !FileManager.default.fileExists(atPath: folder.path) else { fatalError("기존 폴더입니다.") }
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for index in 1...10 {
  let width = index.isMultiple(of: 2) ? 800 : 1200
  let height = index.isMultiple(of: 2) ? 1200 : 800
  let dark = index.isMultiple(of: 3)
  var pixels = [UInt8](repeating: 255, count: width * height * 4)
  for y in 0..<height {
    for x in 0..<width {
      let noise = (x * 17 + y * 29 + x * y) % 21 - 10
      let base = dark ? 15 : 70
      var channels = [base + x * 120 / width, base + y * 100 / height, base + 40]
      if x < width / 4 && y < height / 4 { channels = [220, 30, 30] }
      if x > width * 3 / 4 && y < height / 4 { channels = [30, 220, 30] }
      if x < width / 4 && y > height * 3 / 4 { channels = [30, 30, 220] }
      if x > width * 3 / 4 && y > height * 3 / 4 { channels = [220, 220, 30] }
      if x % 100 < 2 || y % 100 < 2 { channels = [230, 230, 230] }
      for channel in 0..<3 {
        pixels[(y * width + x) * 4 + channel] = UInt8(min(255, max(0, channels[channel] + noise)))
      }
    }
  }
  let provider = CGDataProvider(data: Data(pixels) as CFData)!
  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
  let url = folder.appendingPathComponent(String(format: "%02d-%dx%d.png", index, width, height))
  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { fatalError("PNG 저장 실패") }
}
print(folder.path)
