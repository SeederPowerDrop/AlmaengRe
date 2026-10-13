// Generates synthetic image pixels and public landmark coordinates for map/editing QA.
// Usage: swift scripts/make-map-editing-fixtures.swift /tmp/new-folder
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else { fatalError("Specify a new output folder") }
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard !FileManager.default.fileExists(atPath: folder.path) else { fatalError("Output folder already exists") }
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let places: [(String, Double?, Double?)] = [
  ("paris-eiffel", 48.8584, 2.2945), ("paris-trocadero", 48.8629, 2.2870),
  ("paris-louvre", 48.8606, 2.3376), ("paris-notre-dame", 48.8530, 2.3499),
  ("paris-montmartre", 48.8867, 2.3431), ("paris-eiffel-evening", 48.8584, 2.2945),
  ("lyon-old-town", 45.7623, 4.8270), ("lyon-river", 45.7640, 4.8357),
  ("no-gps-landscape", nil, nil), ("no-gps-portrait", nil, nil),
]
for (index, place) in places.enumerated() {
  let width = index.isMultiple(of: 3) ? 800 : 1200
  let height = index.isMultiple(of: 3) ? 1200 : 800
  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  for x in stride(from: 0, to: width, by: 4) {
    let value = CGFloat(x) / CGFloat(width)
    let saturation: CGFloat = index.isMultiple(of: 2) ? 0.8 : 0.45
    let color = NSColor(calibratedHue: value, saturation: saturation,
      brightness: 0.25 + value * 0.7, alpha: 1).cgColor
    context.setFillColor(color)
    context.fill(CGRect(x: x, y: 0, width: 4, height: height))
  }
  context.setFillColor(CGColor(gray: 0, alpha: 1))
  context.fill(CGRect(x: 30, y: 30, width: 80, height: 80))
  context.setFillColor(CGColor(gray: 1, alpha: 1))
  context.fill(CGRect(x: 130, y: 30, width: 80, height: 80))
  for row in 0..<8 {
    context.setFillColor(CGColor(gray: CGFloat(row) / 7, alpha: 1))
    context.fill(CGRect(x: 30 + row * 70, y: height / 2, width: 60, height: 100))
  }
  let label = String(format: "%02d  %@", index + 1, place.0)
  let text = NSAttributedString(string: label, attributes: [
    .font: NSFont.systemFont(ofSize: 38, weight: .bold), .foregroundColor: NSColor.white,
  ])
  context.textPosition = CGPoint(x: 32, y: height - 90)
  CTLineDraw(CTLineCreateWithAttributedString(text), context)
  let url = folder.appendingPathComponent(label.replacingOccurrences(of: "  ", with: "-") + ".jpg")
  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
  var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
  if let latitude = place.1, let longitude = place.2 {
    properties[kCGImagePropertyGPSDictionary] = [
      kCGImagePropertyGPSLatitude: abs(latitude), kCGImagePropertyGPSLatitudeRef: latitude < 0 ? "S" : "N",
      kCGImagePropertyGPSLongitude: abs(longitude), kCGImagePropertyGPSLongitudeRef: longitude < 0 ? "W" : "E",
    ] as [CFString: Any]
  }
  CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
  guard CGImageDestinationFinalize(destination) else { fatalError("JPEG save failed") }
}
print(folder.path)
