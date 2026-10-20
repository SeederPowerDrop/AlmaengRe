// Original geometric demo artwork, with public landmark coordinates for guide captures.
// swift scripts/make-manual-fixtures.swift <new-output-directory>
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard !FileManager.default.fileExists(atPath: root.path) else { fatalError("Use a new folder") }
let locations = [(48.8584, 2.2945), (48.8629, 2.2870), (48.8606, 2.3376),
  (48.8530, 2.3499), (48.8867, 2.3431), (48.8584, 2.2945)]
for collection in ["Demo Photos", "Compare B"] {
  let directory = root.appendingPathComponent(collection, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  for index in 0..<(collection == "Demo Photos" ? 14 : 10) {
    let width = 1200, height = 800
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let hue = CGFloat(index % 6) / 18 + (collection == "Compare B" ? 0.04 : 0)
    let sky = NSColor(calibratedHue: 0.52 + hue, saturation: 0.25, brightness: 0.96, alpha: 1)
    context.setFillColor(sky.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(NSColor(calibratedRed: 1, green: 0.86, blue: 0.5, alpha: 1).cgColor)
    context.fillEllipse(in: CGRect(x: 880 - index * 14, y: 520, width: 110, height: 110))
    for (level, color) in [NSColor(calibratedHue: 0.48 + hue, saturation: 0.35, brightness: 0.63, alpha: 1),
      NSColor(calibratedHue: 0.49 + hue, saturation: 0.48, brightness: 0.43, alpha: 1)].enumerated() {
      let path = CGMutablePath()
      path.move(to: .zero)
      path.addLine(to: CGPoint(x: 0, y: 330 - level * 80))
      for step in 0...6 {
        path.addLine(to: CGPoint(x: step * 240 - 100,
          y: 260 + ((step * 71 + index * 23) % 230) - level * 85))
      }
      path.addLine(to: CGPoint(x: width, y: 0)); path.closeSubpath()
      context.setFillColor(color.cgColor); context.addPath(path); context.fillPath()
    }
    context.setFillColor(NSColor(calibratedHue: 0.51 + hue, saturation: 0.35, brightness: 0.73, alpha: 1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: 230))
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.28)); context.setLineWidth(3)
    for line in 0..<7 {
      context.move(to: CGPoint(x: 120 + line * 95, y: 40 + line * 23))
      context.addLine(to: CGPoint(x: 410 + line * 90, y: 40 + line * 23))
      context.strokePath()
    }
    let title = String(format: "DEMO  %02d", index + 1)
    let text = NSAttributedString(string: title, attributes: [
      .font: NSFont.systemFont(ofSize: 40, weight: .semibold), .foregroundColor: NSColor.white])
    context.textPosition = CGPoint(x: 48, y: 724)
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
    let destination = CGImageDestinationCreateWithURL(
      directory.appendingPathComponent(String(format: "Scene-%02d.jpg", index + 1)) as CFURL,
      UTType.jpeg.identifier as CFString, 1, nil)!
    let location = locations[index % locations.count]
    let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.94,
      kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: location.0,
        kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: location.1,
        kCGImagePropertyGPSLongitudeRef: "E"],
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "AlmaengRe Demo",
        kCGImagePropertyTIFFImageDescription: "Synthetic illustration for the user guide"]]
    CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
  }
}
print(root.path)
