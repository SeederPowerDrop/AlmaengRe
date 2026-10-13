import SwiftUI

extension PhotoMarkColor {
  var title: String { PhotoMarkL10n.text("color.\(rawValue)") }

  /// Keep text readable in both appearances; use the brighter swatch on dark chrome.
  var tint: Color {
    Color(nsColor: NSColor(name: "PhotoMark.\(rawValue)") { appearance in
      let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      let components = dark ? self.swatchRGB : self.inkRGB
      return NSColor(srgbRed: components.0, green: components.1, blue: components.2, alpha: 1)
    })
  }

  fileprivate var swatchRGB: (Double, Double, Double) {
    switch self {
    case .red: (0.94, 0.43, 0.42)
    case .orange: (0.96, 0.62, 0.32)
    case .yellow: (0.88, 0.75, 0.33)
    case .green: (0.43, 0.76, 0.49)
    case .teal: (0.34, 0.75, 0.72)
    case .blue: (0.40, 0.65, 0.95)
    case .indigo: (0.60, 0.60, 0.92)
    case .purple: (0.76, 0.55, 0.88)
    case .pink: (0.91, 0.52, 0.71)
    case .gray: (0.66, 0.69, 0.73)
    }
  }

  private var inkRGB: (Double, Double, Double) {
    switch self {
    case .red: (0.69, 0.20, 0.20)
    case .orange: (0.66, 0.33, 0.08)
    case .yellow: (0.53, 0.40, 0.04)
    case .green: (0.21, 0.46, 0.25)
    case .teal: (0.10, 0.45, 0.43)
    case .blue: (0.17, 0.38, 0.70)
    case .indigo: (0.38, 0.32, 0.68)
    case .purple: (0.52, 0.27, 0.65)
    case .pink: (0.66, 0.25, 0.44)
    case .gray: (0.39, 0.42, 0.46)
    }
  }
}

/// Native menus can discard SwiftUI foreground styles. A non-template image
/// preserves the same color swatch in menu-bar commands and filter menus.
@MainActor
private enum PhotoMarkMenuImages {
  static let swatches: [PhotoMarkColor: NSImage] = Dictionary(uniqueKeysWithValues:
    PhotoMarkColor.allCases.map { color in
      let rgb = color.swatchRGB
      let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
        let path = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 10, height: 10))
        NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 0.75
        path.stroke()
        return true
      }
      image.isTemplate = false
      return (color, image)
    })
}

struct PhotoMarkMenuLabel: View {
  let name: String
  let color: PhotoMarkColor

  var body: some View {
    Label {
      Text(name)
    } icon: {
      Image(nsImage: PhotoMarkMenuImages.swatches[color]!)
        .renderingMode(.original)
    }
  }
}
