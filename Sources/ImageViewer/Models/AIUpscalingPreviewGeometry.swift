import CoreGraphics
import Foundation

/// The preview always uses the output image's coordinates, including when the
/// original is revealed. `zoom == 1` maps an output pixel to a display pixel.
struct AIUpscalingPreviewGeometry {
  static let minimumZoom: CGFloat = 0.01
  static let maximumZoom: CGFloat = 8

  private(set) var imageSize: CGSize
  private(set) var viewportSize: CGSize
  private(set) var backingScale: CGFloat
  private(set) var zoom: CGFloat = 1
  private(set) var fitsWindow = true
  private(set) var center: CGPoint

  init(imageSize: CGSize, viewportSize: CGSize = .zero, backingScale: CGFloat = 1) {
    self.imageSize = CGSize(width: max(1, imageSize.width), height: max(1, imageSize.height))
    self.viewportSize = viewportSize
    self.backingScale = max(1, backingScale)
    center = CGPoint(x: self.imageSize.width / 2, y: self.imageSize.height / 2)
    fit()
  }

  var pointsPerPixel: CGFloat { zoom / backingScale }
  var fitZoom: CGFloat {
    guard viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
    return min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height) * backingScale
  }
  var zoomRange: ClosedRange<CGFloat> {
    min(Self.minimumZoom, fitZoom)...max(Self.maximumZoom, fitZoom)
  }
  var imageRect: CGRect {
    CGRect(x: viewportSize.width / 2 - center.x * pointsPerPixel,
      y: viewportSize.height / 2 - center.y * pointsPerPixel,
      width: imageSize.width * pointsPerPixel, height: imageSize.height * pointsPerPixel)
  }
  var drawingRect: CGRect {
    var rect = imageRect
    if abs(zoom - 1) < 0.000_001 {
      // A 1:1 image placed between backing pixels would still be interpolated.
      // Snap only its rendered origin; preserve the precise pan/gesture anchor.
      rect.origin.x = (rect.origin.x * backingScale).rounded() / backingScale
      rect.origin.y = (rect.origin.y * backingScale).rounded() / backingScale
    }
    return rect
  }

  mutating func resize(to size: CGSize, backingScale: CGFloat) {
    viewportSize = CGSize(width: max(0, size.width), height: max(0, size.height))
    self.backingScale = max(1, backingScale)
    if fitsWindow { fit() } else { clampCenter() }
  }

  mutating func fit() {
    fitsWindow = true
    zoom = fitZoom
    center = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
  }

  mutating func setZoom(_ requested: CGFloat, around anchor: CGPoint? = nil) {
    guard requested.isFinite, requested > 0 else { return }
    let anchor = anchor ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
    let imageAnchor = imagePoint(at: anchor)
    fitsWindow = false
    zoom = min(zoomRange.upperBound, max(zoomRange.lowerBound, requested))
    center = CGPoint(x: imageAnchor.x - (anchor.x - viewportSize.width / 2) / pointsPerPixel,
      y: imageAnchor.y - (anchor.y - viewportSize.height / 2) / pointsPerPixel)
    clampCenter()
  }

  mutating func pan(by translation: CGSize) {
    guard translation.width.isFinite, translation.height.isFinite else { return }
    center.x -= translation.width / pointsPerPixel
    center.y -= translation.height / pointsPerPixel
    clampCenter()
  }

  func imagePoint(at point: CGPoint) -> CGPoint {
    CGPoint(x: center.x + (point.x - viewportSize.width / 2) / pointsPerPixel,
      y: center.y + (point.y - viewportSize.height / 2) / pointsPerPixel)
  }

  private mutating func clampCenter() {
    func coordinate(_ value: CGFloat, imageExtent: CGFloat, viewportExtent: CGFloat) -> CGFloat {
      let visibleHalf = viewportExtent / (2 * pointsPerPixel)
      guard visibleHalf < imageExtent / 2 else { return imageExtent / 2 }
      return min(imageExtent - visibleHalf, max(visibleHalf, value))
    }
    center.x = coordinate(center.x, imageExtent: imageSize.width, viewportExtent: viewportSize.width)
    center.y = coordinate(center.y, imageExtent: imageSize.height, viewportExtent: viewportSize.height)
  }
}
