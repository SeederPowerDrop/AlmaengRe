import Foundation

/// Maps the exported canvas to the editor stage while reserving room around the
/// photo for dragging. All placements remain relative to the original photo.
struct WatermarkPreviewGeometry {
  let originalSize: CGSize
  let canvasBounds: CGRect
  let scale: CGFloat
  let origin: CGPoint

  init(originalSize: CGSize, canvasBounds: CGRect, stageSize: CGSize) {
    self.originalSize = originalSize
    self.canvasBounds = canvasBounds
    let padding = min(60, max(12, min(stageSize.width, stageSize.height) * 0.12))
    scale = max(0.000_001, min(max(1, stageSize.width - 2 * padding) / max(1, canvasBounds.width),
      max(1, stageSize.height - 2 * padding) / max(1, canvasBounds.height)))
    origin = CGPoint(x: (stageSize.width - canvasBounds.width * scale) / 2 - canvasBounds.minX * scale,
      y: (stageSize.height - canvasBounds.height * scale) / 2 - canvasBounds.minY * scale)
  }

  func stageRect(for rect: CGRect) -> CGRect {
    CGRect(x: origin.x + rect.minX * scale, y: origin.y + rect.minY * scale,
      width: rect.width * scale, height: rect.height * scale)
  }

  func movedPosition(rect: CGRect, translation: CGSize) -> WatermarkPoint {
    WatermarkPoint(x: min(5, max(-4, (rect.midX + translation.width / scale) / originalSize.width)),
      y: min(5, max(-4, (rect.midY + translation.height / scale) / originalSize.height)))
  }

  static func rect(center: WatermarkPoint, overlaySize: CGSize, originalSize: CGSize) -> CGRect {
    CGRect(x: center.x * originalSize.width - overlaySize.width / 2,
      y: center.y * originalSize.height - overlaySize.height / 2,
      width: overlaySize.width, height: overlaySize.height)
  }

  static func clampedPosition(_ point: WatermarkPoint, overlaySize: CGSize,
    originalSize: CGSize) -> WatermarkPoint {
    let rect = rect(center: point, overlaySize: overlaySize, originalSize: originalSize)
    let x = min(max(0, originalSize.width - rect.width), max(0, rect.minX))
    let y = min(max(0, originalSize.height - rect.height), max(0, rect.minY))
    return WatermarkPoint(x: (x + rect.width / 2) / originalSize.width,
      y: (y + rect.height / 2) / originalSize.height)
  }
}
