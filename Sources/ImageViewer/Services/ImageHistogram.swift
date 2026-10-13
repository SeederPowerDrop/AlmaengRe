import CoreGraphics
import Foundation

/// Histograms describe the edited, color-managed SDR preview, not source HDR scene values.
/// A sample contributes its opacity; fully transparent pixels never contribute hidden RGB.
struct ImageHistogram: Equatable, Sendable {
  var red = [Double](repeating: 0, count: 256)
  var green = [Double](repeating: 0, count: 256)
  var blue = [Double](repeating: 0, count: 256)
  var luminance = [Double](repeating: 0, count: 256)
  var sampleWeight: Double = 0
  var blackWeight: Double = 0
  var whiteWeight: Double = 0

  var isEmpty: Bool { sampleWeight == 0 }
  var blackPercentage: Double { sampleWeight > 0 ? blackWeight / sampleWeight * 100 : 0 }
  var whitePercentage: Double { sampleWeight > 0 ? whiteWeight / sampleWeight * 100 : 0 }
}

struct ImageHistogramRequest: Hashable, Sendable {
  let asset: ImageAsset
  let adjustments: ImageAdjustments
}

enum ImageHistogramError: Error {
  case renderingFailed
}

/// One bounded CPU worker is shared by both inspectors. The pipeline owns decoded-frame
/// caching and resource budgets; this worker deliberately retains no images or result cache.
actor ImageHistogramAnalyzer {
  static let shared = ImageHistogramAnalyzer()
  static let maximumPixelSize = 512

  func histogram(for request: ImageHistogramRequest, pipeline: ImagePipeline) async throws
    -> ImageHistogram
  {
    try Task.checkCancellation()
    let frame = try await pipeline.renderFrame(
      url: request.asset.url, maxPixelSize: Self.maximumPixelSize,
      adjustments: request.adjustments, prefersHDR: false, priority: .visible)
    try Task.checkCancellation()
    return try analyze(frame)
  }

  /// Actor isolation keeps color conversion, rasterization and the pixel loop off the UI.
  func analyze(_ frame: RenderedFrame) throws -> ImageHistogram {
    try Task.checkCancellation()
    let image = frame.image
    guard image.width > 0, image.height > 0 else { throw ImageHistogramError.renderingFailed }
    let scale = min(1, Double(Self.maximumPixelSize) / Double(max(image.width, image.height)))
    let width = max(1, Int(Double(image.width) * scale))
    let height = max(1, Int(Double(image.height) * scale))
    let rowBytes = width * 4
    var bytes = [UInt8](repeating: 0, count: rowBytes * height)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw ImageHistogramError.renderingFailed
    }
    return try bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) throws -> ImageHistogram in
      guard let context = CGContext(
        data: buffer.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: rowBytes, space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.premultipliedLast.rawValue)
      else { throw ImageHistogramError.renderingFailed }
      context.interpolationQuality = .medium
      context.setBlendMode(.copy)
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      try Task.checkCancellation()
      return try countBins(in: buffer.bindMemory(to: UInt8.self), width: width, height: height)
    }
  }

  private func countBins(in pixels: UnsafeMutableBufferPointer<UInt8>, width: Int, height: Int)
    throws -> ImageHistogram
  {
    let rowBytes = width * 4
    var result = ImageHistogram()
    for y in 0..<height {
      try Task.checkCancellation()
      for x in 0..<width {
        let offset = y * rowBytes + x * 4
        let alpha = Double(pixels[offset + 3])
        guard alpha > 0 else { continue }
        let weight = alpha / 255.0
        // CGContext returns premultiplied RGB. Unpremultiplication prevents a translucent
        // white pixel from being counted as gray; the sample still carries less weight.
        let red = unpremultiply(pixels[offset], alpha: alpha)
        let green = unpremultiply(pixels[offset + 1], alpha: alpha)
        let blue = unpremultiply(pixels[offset + 2], alpha: alpha)
        // Conventional SDR luma histogram, computed from nonlinear sRGB code values.
        let redLuma: Double = 0.2126 * Double(red)
        let greenLuma: Double = 0.7152 * Double(green)
        let blueLuma: Double = 0.0722 * Double(blue)
        let luma = min(255, Int((redLuma + greenLuma + blueLuma).rounded()))
        result.red[red] += weight
        result.green[green] += weight
        result.blue[blue] += weight
        result.luminance[luma] += weight
        result.sampleWeight += weight
        if red == 0 && green == 0 && blue == 0 { result.blackWeight += weight }
        if red == 255 && green == 255 && blue == 255 { result.whiteWeight += weight }
      }
    }
    try Task.checkCancellation()
    return result
  }

  private func unpremultiply(_ value: UInt8, alpha: Double) -> Int {
    let unassociated: Double = Double(value) * 255.0 / alpha
    return min(255, Int(unassociated.rounded()))
  }
}
