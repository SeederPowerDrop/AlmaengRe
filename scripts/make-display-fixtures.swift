// 화면 확대/썸네일 검증용 작은 원본을 만듭니다. 사용자 사진은 사용하지 않습니다.
// 실행: swift scripts/make-display-fixtures.swift /tmp/새로운-테스트-폴더
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
  fatalError("출력할 새 폴더 경로를 지정하세요.")
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard !FileManager.default.fileExists(atPath: folder.path) else {
  fatalError("기존 폴더는 덮어쓰지 않습니다.")
}
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

for (index, size) in [32, 48, 64, 96, 128].enumerated() {
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  // 픽셀 단위 대각선과 원을 넣어 nearest/linear의 경계 차이를 쉽게 확인합니다.
  context.setShouldAntialias(false)
  context.setFillColor(CGColor(red: 0.03, green: 0.1, blue: 0.22, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: size, height: size))
  context.setStrokeColor(CGColor(red: 0.2, green: 0.85, blue: 1, alpha: 1))
  context.setLineWidth(1)
  context.move(to: CGPoint(x: 2, y: 2))
  context.addLine(to: CGPoint(x: size - 2, y: size - 2))
  context.strokePath()
  context.setStrokeColor(CGColor(gray: 1, alpha: 1))
  context.strokeEllipse(in: CGRect(x: size / 4, y: size / 4, width: size / 2, height: size / 2))
  let url = folder.appendingPathComponent("\(index + 1)-확대 비교-\(size)px.png")
  let destination = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, context.makeImage()!, nil)
  guard CGImageDestinationFinalize(destination) else { fatalError("PNG 저장 실패") }
}
print(folder.path)
