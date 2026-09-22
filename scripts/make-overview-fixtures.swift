// 몽땅보기의 번호/영역 선택 검증용 파일입니다. 원본 사진 없이 1·2·3자리 번호와
// 정사각형/세로/파노라마를 함께 검사합니다. 기존 폴더는 절대로 덮어쓰지 않습니다.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else { fatalError("새 출력 폴더를 지정하세요.") }
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard !FileManager.default.fileExists(atPath: folder.path) else { fatalError("기존 폴더입니다.") }
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for index in 1...120 {
  let dimensions = [(96, 96), (40, 120), (160, 32), (80, 120)][(index - 1) % 4]
  let (width, height) = dimensions
  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(red: CGFloat(index % 3) * 0.22 + 0.1, green: 0.4, blue: 0.6, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1))
  context.fillEllipse(in: CGRect(x: width / 5, y: height / 4, width: width / 2, height: height / 2))
  context.setStrokeColor(CGColor(gray: 1, alpha: 1))
  context.setLineWidth(2)
  context.stroke(CGRect(x: 2, y: 2, width: width - 4, height: height - 4))
  let url = folder.appendingPathComponent(String(format: "%03d-%dx%d.png", index, width, height))
  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, context.makeImage()!, nil)
  guard CGImageDestinationFinalize(destination) else { fatalError("PNG 저장 실패") }
}
print(folder.path)
