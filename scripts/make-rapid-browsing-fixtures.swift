// 빠른 넘김의 화면 확인용 24MP JPEG 300개 경로를 만듭니다.
// 실행: swift scripts/make-rapid-browsing-fixtures.swift /tmp/새로운-테스트-폴더
// 4종 원본을 하드링크한 합성 자료입니다. 실제 사진 300장의 콜드 디스크 성능을
// 측정하지 않으며, 화면이 계속 바뀌는지와 마지막 사진의 정밀 표시를 확인합니다.
import CoreGraphics
import CoreText
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

let variants: [(label: String, width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat)] = [
  ("A  BRIGHT LANDSCAPE", 6_000, 4_000, 0.95, 0.75, 0.12),
  ("B  DARK LANDSCAPE", 6_000, 4_000, 0.04, 0.10, 0.20),
  ("C  GREEN PORTRAIT", 4_000, 6_000, 0.12, 0.72, 0.37),
  ("D  PINK PORTRAIT", 4_000, 6_000, 0.78, 0.18, 0.38),
]
var sources: [URL] = []
for index in 0..<300 {
  let variant = variants[index % variants.count]
  let name = String(format: "%03d-", index) + variant.label.lowercased()
    .replacingOccurrences(of: "  ", with: "-")
    .replacingOccurrences(of: " ", with: "-") + ".jpg"
  let url = folder.appendingPathComponent(name)
  if index < variants.count {
    try autoreleasepool {
      let context = CGContext(data: nil, width: variant.width, height: variant.height,
        bitsPerComponent: 8, bytesPerRow: variant.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
      for row in stride(from: 0, to: variant.height, by: 16) {
        let brightness = 0.65 + 0.35 * CGFloat(row) / CGFloat(variant.height)
        context.setFillColor(CGColor(red: variant.red * brightness,
          green: variant.green * brightness, blue: variant.blue * brightness, alpha: 1))
        context.fill(CGRect(x: 0, y: row, width: variant.width, height: 16))
      }
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 200, y: 200, width: 300 + index * 200, height: 200))
      let textColor = CGColor(gray: index == 0 ? 0.1 : 1, alpha: 1)
      for (lineIndex, text) in [variant.label,
        "\(variant.width) x \(variant.height)  /  24 MP",
        "SYNTHETIC  -  SHARED HARD LINKS"].enumerated() {
        let fontSize: CGFloat = lineIndex == 0 ? 260 : 130
        let textAttributes = [
          kCTFontAttributeName: CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil),
          kCTForegroundColorAttributeName: textColor,
        ] as CFDictionary
        let attributed = CFAttributedStringCreate(nil, text as CFString, textAttributes)!
        context.textPosition = CGPoint(x: 260, y: variant.height / 2 - lineIndex * 280)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
      }
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
      CGImageDestinationAddImage(destination, context.makeImage()!,
        [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
    sources.append(url)
  } else {
    try FileManager.default.linkItem(at: sources[index % sources.count], to: url)
  }
}
print("\(folder.path)\n24 MP JPEG 300개 경로 · 4종 합성 원본의 하드링크 공유")
