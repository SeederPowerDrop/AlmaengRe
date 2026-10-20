import AppKit
import SwiftUI

/// App chrome grows in layout points, so drawing and hit testing stay aligned.
/// Never use these metrics for media pixels, canvas geometry, or the user's zoom.
enum ViewerUIMetrics {
  static let multiplier: CGFloat = 1.03

  static func scale(_ value: CGFloat) -> CGFloat { value * multiplier }

  static func font(size: CGFloat, weight: Font.Weight = .regular,
    design: Font.Design = .default) -> Font {
    .system(size: scale(size), weight: weight, design: design)
  }

  static func font(_ style: Font.TextStyle, design: Font.Design = .default) -> Font {
    let nativeStyle: NSFont.TextStyle
    switch style {
    case .largeTitle: nativeStyle = .largeTitle
    case .title: nativeStyle = .title1
    case .title2: nativeStyle = .title2
    case .title3: nativeStyle = .title3
    case .headline: nativeStyle = .headline
    case .subheadline: nativeStyle = .subheadline
    case .callout: nativeStyle = .callout
    case .caption: nativeStyle = .caption1
    case .caption2: nativeStyle = .caption2
    case .footnote: nativeStyle = .footnote
    default: nativeStyle = .body
    }
    // macOS caption2 uses Medium; changing it to Regular would cancel most
    // of the intended increase and weaken small secondary controls.
    let weight: Font.Weight = style == .headline ? .bold : style == .caption2 ? .medium : .regular
    return font(size: NSFont.preferredFont(forTextStyle: nativeStyle).pointSize,
      weight: weight, design: design)
  }
}

extension View {
  func viewerPadding(_ edges: Edge.Set = .all, _ length: CGFloat = 16) -> some View {
    padding(edges, ViewerUIMetrics.scale(length))
  }

  func viewerPadding(_ length: CGFloat) -> some View {
    padding(ViewerUIMetrics.scale(length))
  }

  func viewerFrame(width: CGFloat? = nil, height: CGFloat? = nil,
    alignment: Alignment = .center) -> some View {
    frame(width: width.map(ViewerUIMetrics.scale), height: height.map(ViewerUIMetrics.scale),
      alignment: alignment)
  }

  func viewerFrame(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil,
    maxWidth: CGFloat? = nil, minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil,
    maxHeight: CGFloat? = nil, alignment: Alignment = .center) -> some View {
    frame(minWidth: minWidth.map(ViewerUIMetrics.scale),
      idealWidth: idealWidth.map(ViewerUIMetrics.scale),
      maxWidth: maxWidth.map(ViewerUIMetrics.scale),
      minHeight: minHeight.map(ViewerUIMetrics.scale),
      idealHeight: idealHeight.map(ViewerUIMetrics.scale),
      maxHeight: maxHeight.map(ViewerUIMetrics.scale), alignment: alignment)
  }
}
