import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Audio has no still-image frame. A single small, shared waveform tile keeps
/// large mixed libraries cheap: no waveform analysis, artwork extraction or
/// audio decoding happens while scrolling. The player reports playback errors.
enum AudioMediaPreview {
  private static let shared: RenderedFrame? = {
    let side = 256
    guard let context = CGContext(data: nil, width: side, height: side,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 0.10, green: 0.16, blue: 0.25, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    context.setStrokeColor(CGColor(red: 0.55, green: 0.76, blue: 1, alpha: 1))
    context.setLineWidth(12)
    context.setLineCap(.round)
    for (index, height) in [28.0, 68.0, 112.0, 56.0, 92.0, 40.0, 20.0].enumerated() {
      let x = 62.0 + Double(index) * 22
      context.move(to: CGPoint(x: x, y: 128 - height / 2))
      context.addLine(to: CGPoint(x: x, y: 128 + height / 2))
      context.strokePath()
    }
    guard let image = context.makeImage() else { return nil }
    return RenderedFrame(image: image, frameIndex: 0, frameCount: 1, duration: nil,
      sourcePixelSize: nil)
  }()

  static func frame(for url: URL, maxPixelSize: Int) throws -> RenderedFrame {
    try Task.checkCancellation()
    guard MediaFormatRegistry.isAudio(url), let shared else {
      throw ImagePipelineError.unsupported(url)
    }
    let limit = max(1, maxPixelSize)
    if limit >= shared.image.width { return shared }
    guard let smaller = ThumbnailBitmapDecoder.rasterized(shared.image, maxPixelSize: limit) else {
      throw ImagePipelineError.renderingFailed(url)
    }
    return RenderedFrame(image: smaller.image, frameIndex: 0, frameCount: 1,
      duration: nil, sourcePixelSize: nil)
  }

  static func metadata(for url: URL) -> ImageMetadata {
    // Leave photo dimensions/EXIF unknown instead of reporting the icon's size.
    ImageMetadata(typeIdentifier: UTType(filenameExtension: url.pathExtension)?.identifier
      ?? UTType.audio.identifier)
  }
}
