// Synthetic mixed-media artwork with gentle motion and a quiet test tone.
// Requires ffmpeg on PATH. Never overwrites an existing output directory.
// swift scripts/make-mixed-media-fixture.swift [new-output-directory]
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
  ?? "/private/tmp/Almaeng-Mixed-Media-Demo", isDirectory: true)
guard !FileManager.default.fileExists(atPath: root.path) else {
  fatalError("Choose a new output directory; existing files will not be overwritten.")
}
let mixed = root.appendingPathComponent("Mixed Photos and Videos", isDirectory: true)
let videos = root.appendingPathComponent("Videos Only", isDirectory: true)
let photos = root.appendingPathComponent("Photos Only", isDirectory: true)
for directory in [mixed, videos, photos] {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}

func artwork(_ index: Int, title: String) -> CGImage {
  let width = 960, height = 640
  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  let hue = CGFloat(index) * 0.075
  context.setFillColor(NSColor(calibratedHue: 0.52 + hue, saturation: 0.28,
    brightness: 0.91, alpha: 1).cgColor)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  context.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.47, alpha: 1))
  context.fillEllipse(in: CGRect(x: 705, y: 428, width: 94, height: 94))
  for level in 0..<3 {
    let path = CGMutablePath()
    path.move(to: .zero)
    path.addLine(to: CGPoint(x: 0, y: 190 + level * 18))
    for step in 0...6 {
      path.addLine(to: CGPoint(x: step * 180 - 80,
        y: 285 + ((step * 83 + index * 29) % 170) - level * 64))
    }
    path.addLine(to: CGPoint(x: width, y: 0)); path.closeSubpath()
    context.setFillColor(NSColor(calibratedHue: 0.51 + hue,
      saturation: 0.30 + CGFloat(level) * 0.11, brightness: 0.70 - CGFloat(level) * 0.13,
      alpha: 1).cgColor)
    context.addPath(path); context.fillPath()
  }
  context.setFillColor(CGColor(red: 0.12, green: 0.27, blue: 0.37, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: 150))
  context.setStrokeColor(CGColor(gray: 1, alpha: 0.22)); context.setLineWidth(2)
  for row in 0..<5 {
    context.move(to: CGPoint(x: 140 + row * 30, y: 35 + row * 21))
    context.addLine(to: CGPoint(x: 710 + row * 25, y: 35 + row * 21)); context.strokePath()
  }
  let labels: [(String, CGFloat, CGFloat)] = [
    (title, 570, 34), ("ALMAENG  /  SYNTHETIC DEMO", 28, 17),
  ]
  for (label, y, size) in labels {
    let attributed = NSAttributedString(string: label, attributes: [
      .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.white])
    context.textPosition = CGPoint(x: 44, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
  }
  return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) throws {
  let type = url.pathExtension == "png" ? UTType.png : UTType.jpeg
  guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
    type.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
  CGImageDestinationAddImage(destination, image,
    [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
  guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

for (index, name) in ["01-Photo.jpg", "03-Photo.png", "05-Photo.jpg"].enumerated() {
  let image = artwork(index, title: String(format: "STILL STUDY  %02d", index + 1))
  try write(image, to: mixed.appendingPathComponent(name))
  try write(image, to: photos.appendingPathComponent(name))
}
let motionSource = root.appendingPathComponent("Motion-Source.png")
try write(artwork(1, title: "MOTION STUDY  /  4 SECONDS"), to: motionSource)

func ffmpeg(_ arguments: [String]) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-n"] + arguments
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
}

let mp4 = mixed.appendingPathComponent("02-Motion.mp4")
let mov = mixed.appendingPathComponent("04-Motion.mov")
try ffmpeg([
  "-loop", "1", "-framerate", "24", "-i", motionSource.path,
  "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000",
  "-filter_complex",
  "[0:v]zoompan=z='1.08+0.04*sin(on/18)':x='iw/2-iw/zoom/2+20*sin(on/12)':y='ih/2-ih/zoom/2':d=1:s=960x640:fps=24,format=yuv420p[v];[1:a]volume=0.12,afade=t=in:d=0.2,afade=t=out:st=3.8:d=0.2[a]",
  "-map", "[v]", "-map", "[a]", "-t", "4", "-c:v", "libx264",
  "-preset", "veryfast", "-crf", "20", "-c:a", "aac", "-b:a", "96k",
  "-movflags", "+faststart", mp4.path,
])
try ffmpeg(["-i", mp4.path, "-c", "copy", "-movflags", "+faststart", mov.path])
try FileManager.default.copyItem(at: mp4, to: videos.appendingPathComponent("01-Motion.mp4"))
try FileManager.default.copyItem(at: mov, to: videos.appendingPathComponent("02-Motion.mov"))
for directory in [mixed, videos, photos] { print(directory.path) }
print("Videos: 960 x 640, H.264 + AAC, 4 seconds, 24 fps, quiet 660 Hz tone.")
