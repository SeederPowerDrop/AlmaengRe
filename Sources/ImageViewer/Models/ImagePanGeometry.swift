import Foundation

/// Uses the image's displayed dimensions, including crop/rotation and Retina 1:1 scale.
struct ImagePanGeometry: Equatable {
  let baseImageSize: CGSize
  let viewportSize: CGSize

  var isValid: Bool {
    [baseImageSize.width, baseImageSize.height, viewportSize.width, viewportSize.height]
      .allSatisfy { $0.isFinite && $0 > 0 }
  }

  func constrained(_ offset: CGSize, zoom: CGFloat) -> CGSize {
    CGSize(
      width: constrainedAxis(offset.width, image: baseImageSize.width, viewport: viewportSize.width, zoom: zoom),
      height: constrainedAxis(offset.height, image: baseImageSize.height, viewport: viewportSize.height, zoom: zoom)
    )
  }

  private func constrainedAxis(_ offset: CGFloat, image: CGFloat, viewport: CGFloat, zoom: CGFloat) -> CGFloat {
    guard offset.isFinite, image.isFinite, viewport.isFinite, zoom.isFinite,
      image > 0, viewport > 0, zoom > 0 else { return 0 }
    let displayed = image * zoom
    guard displayed.isFinite, displayed > viewport else { return 0 }
    let limit = (displayed - viewport) / 2 + min(24, viewport * 0.05)
    return min(limit, max(-limit, offset))
  }
}
