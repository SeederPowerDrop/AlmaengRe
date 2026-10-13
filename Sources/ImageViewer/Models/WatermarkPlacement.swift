import Foundation

/// Overlay CENTER, normalized by the original image size. Coordinates start at
/// the original image's top-left and may extend outside its 0...1 range.
struct WatermarkPoint: Codable, Equatable, Sendable {
  var x: Double
  var y: Double
}

/// Every stored rectangle uses top-left original-image pixel coordinates.
/// Only originalRectInCanvas translates to the exported canvas's origin.
struct WatermarkLayout: Equatable, Sendable {
  let originalSize: CGSize
  let requestedRect: CGRect
  let effectiveRect: CGRect
  let canvasBounds: CGRect

  var isOutsideOriginal: Bool {
    requestedRect.minX < 0 || requestedRect.minY < 0
      || requestedRect.maxX > originalSize.width || requestedRect.maxY > originalSize.height
  }

  var originalRectInCanvas: CGRect {
    CGRect(x: -canvasBounds.minX, y: -canvasBounds.minY,
      width: originalSize.width, height: originalSize.height)
  }

  static func make(originalSize: CGSize, overlaySize: CGSize,
    position: WatermarkPosition, marginFraction: Double,
    customPosition: WatermarkPoint?, expandsCanvas: Bool
  ) throws -> WatermarkLayout {
    guard originalSize.width.isFinite, originalSize.height.isFinite,
      originalSize.width > 0, originalSize.height > 0,
      overlaySize.width.isFinite, overlaySize.height.isFinite,
      overlaySize.width > 0, overlaySize.height > 0,
      marginFraction.isFinite, (0...0.2).contains(marginFraction)
    else { throw WatermarkError.invalidOptions }
    if let customPosition {
      guard customPosition.x.isFinite, customPosition.y.isFinite,
        (-4...5).contains(customPosition.x), (-4...5).contains(customPosition.y)
      else { throw WatermarkError.invalidOptions }
    }
    if !expandsCanvas,
      overlaySize.width > originalSize.width || overlaySize.height > originalSize.height {
      throw WatermarkError.contentOverflow(fittingScale: Double(min(
        originalSize.width / overlaySize.width, originalSize.height / overlaySize.height)))
    }

    let inset = min(originalSize.width, originalSize.height) * CGFloat(marginFraction)
    let x: CGFloat
    let y: CGFloat
    if let customPosition {
      x = CGFloat(customPosition.x) * originalSize.width - overlaySize.width / 2
      y = CGFloat(customPosition.y) * originalSize.height - overlaySize.height / 2
    } else {
      switch position {
      case .topLeading, .leading, .bottomLeading: x = inset
      case .top, .center, .bottom: x = (originalSize.width - overlaySize.width) / 2
      case .topTrailing, .trailing, .bottomTrailing: x = originalSize.width - inset - overlaySize.width
      }
      switch position {
      case .topLeading, .top, .topTrailing: y = inset
      case .leading, .center, .trailing: y = (originalSize.height - overlaySize.height) / 2
      case .bottomLeading, .bottom, .bottomTrailing: y = originalSize.height - inset - overlaySize.height
      }
    }
    let requested = CGRect(origin: CGPoint(x: x, y: y), size: overlaySize)
    guard x.isFinite, y.isFinite, requested.maxX.isFinite, requested.maxY.isFinite else {
      throw WatermarkError.unsafeCanvas
    }
    let original = CGRect(origin: .zero, size: originalSize)
    if !expandsCanvas {
      // Margins position presets; a user drag can reach every physical image edge.
      // Keep fractional coordinates intact so dragging does not acquire rounding jitter.
      let clamped = CGRect(x: min(max(0, x), originalSize.width - overlaySize.width),
        y: min(max(0, y), originalSize.height - overlaySize.height),
        width: overlaySize.width, height: overlaySize.height)
      return WatermarkLayout(originalSize: originalSize, requestedRect: requested,
        effectiveRect: clamped, canvasBounds: original)
    }

    let left = floor(min(0, requested.minX))
    let top = floor(min(0, requested.minY))
    let right = ceil(max(originalSize.width, requested.maxX))
    let bottom = ceil(max(originalSize.height, requested.maxY))
    let canvas = CGRect(x: left, y: top, width: right - left, height: bottom - top)
    guard canvas.width.isFinite, canvas.height.isFinite else { throw WatermarkError.unsafeCanvas }
    let layout = WatermarkLayout(originalSize: originalSize, requestedRect: requested,
      effectiveRect: requested, canvasBounds: canvas)
    // Merely enabling the preference must not reject a large existing photo
    // whose watermark fits. The budget limits newly expanded canvases only.
    if layout.isOutsideOriginal,
      canvas.width > 32_768 || canvas.height > 32_768
        || Double(canvas.width) * Double(canvas.height) > 64_000_000 {
      throw WatermarkError.unsafeCanvas
    }
    return layout
  }
}
