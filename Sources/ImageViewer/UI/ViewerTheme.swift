import SwiftUI

/// Keep the image canvas neutral. The small amount of color belongs to the controls.
enum ViewerTheme {
  static let canvas = Color(white: 0.105)
  static let chrome = neutral("chrome", light: 0.96, dark: 0.185)
  static let panel = neutral("panel", light: 0.995, dark: 0.215)
  static let sidebar = neutral("sidebar", light: 0.945, dark: 0.165)
  static let controlFill = neutral("control", light: 1, dark: 0.255)
  static let controlBorder = Color(nsColor: .separatorColor)
  static let separator = Color(nsColor: .separatorColor).opacity(0.65)
  static let accent = Color(nsColor: NSColor(name: "AlmaengAccent") { appearance in
    let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return dark ? NSColor(srgbRed: 0.40, green: 0.64, blue: 0.98, alpha: 1)
      : NSColor(srgbRed: 0.16, green: 0.36, blue: 0.72, alpha: 1)
  })
  static let selection = accent.opacity(0.12)
  static let selectionBorder = accent.opacity(0.60)

  static var chromeGradient: LinearGradient {
    LinearGradient(colors: [neutral("chromeTop", light: 0.982, dark: 0.205), chrome],
      startPoint: .top, endPoint: .bottom)
  }
  static var panelGradient: LinearGradient {
    LinearGradient(colors: [panel, neutral("panelBottom", light: 0.973, dark: 0.20)],
      startPoint: .top, endPoint: .bottom)
  }

  private static func neutral(_ name: String, light: Double, dark: Double) -> Color {
    Color(nsColor: NSColor(name: "Almaeng.\(name)") { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      return NSColor(white: isDark ? dark : light, alpha: 1)
    })
  }
}

/// Compact, quiet tools: a thin edge on hover and a persistent outline when selected.
struct ViewerToolButtonStyle: ButtonStyle {
  var isSelected = false
  func makeBody(configuration: Configuration) -> some View {
    ToolBody(configuration: configuration, isSelected: isSelected)
  }

  private struct ToolBody: View {
    let configuration: Configuration
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovered = false

    var body: some View {
      let highlighted = isEnabled && (hovered || configuration.isPressed)
      configuration.label
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 9)
        .frame(minWidth: 30, minHeight: 28)
        .foregroundStyle(isSelected ? ViewerTheme.accent : Color.primary)
        .background {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isSelected ? ViewerTheme.selection
              : highlighted ? ViewerTheme.controlFill : Color.clear)
        }
        .overlay {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(isSelected ? ViewerTheme.selectionBorder
              : highlighted ? ViewerTheme.controlBorder : .clear,
              lineWidth: contrast == .increased ? 1.5 : 0.75)
        }
        .overlay {
          if isEnabled && configuration.isPressed {
            RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06))
          }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .opacity(isEnabled ? 1 : 0.38)
        .onHover { hovered = $0 }
    }
  }
}

/// Used sparingly for the next step in a task: opening files or viewing a map selection.
struct ViewerActionButtonStyle: ButtonStyle {
  var prominent = false
  func makeBody(configuration: Configuration) -> some View {
    ActionBody(configuration: configuration, prominent: prominent)
  }

  private struct ActionBody: View {
    let configuration: Configuration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovered = false

    var body: some View {
      configuration.label
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 16)
        .frame(minHeight: 38)
        .foregroundStyle(prominent ? Color.white : Color.primary)
        .background {
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(prominent
              ? LinearGradient(colors: [Color(red: 0.19, green: 0.40, blue: 0.77),
                  Color(red: 0.15, green: 0.34, blue: 0.69)], startPoint: .top, endPoint: .bottom)
              : ViewerTheme.panelGradient)
        }
        .overlay {
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(prominent ? .white.opacity(contrast == .increased ? 0.65 : 0.22)
              : ViewerTheme.controlBorder, lineWidth: contrast == .increased ? 1.5 : 0.75)
        }
        .overlay {
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(configuration.isPressed ? Color.black.opacity(0.10)
              : hovered && isEnabled
                ? (prominent ? Color.black.opacity(0.035) : Color.white.opacity(0.055)) : Color.clear)
        }
        .shadow(color: .black.opacity(isEnabled ? 0.10 : 0), radius: 2, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .opacity(isEnabled ? 1 : 0.38)
        .onHover { hovered = $0 }
    }
  }
}

/// A compact neutral tray separates related controls without another full-width bar.
struct ViewerControlGroup: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(3)
      .background(ViewerTheme.panelGradient, in: RoundedRectangle(cornerRadius: 9))
      .overlay {
        RoundedRectangle(cornerRadius: 9).strokeBorder(ViewerTheme.separator, lineWidth: 0.75)
          .allowsHitTesting(false)
      }
  }
}
