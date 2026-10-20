import SwiftUI

/// The same layout picker fits the window toolbar and the full-screen controls.
/// Its compact form keeps long translations out of the crowded toolbar while
/// retaining a localized tooltip and an accessibility label.
struct ViewerFrameLayoutMenu: View {
  @ObservedObject var layout: ViewerFrameLayoutStore
  let count: Int
  var compact = true

  var body: some View {
    Menu {
      preset(.balanced, key: "preset.balanced")
      preset(.horizontal, key: "preset.horizontal")
      preset(.vertical, key: "preset.vertical")

      Menu(FrameLayoutL10n.text("columns")) {
        ForEach(1...min(10, max(1, count)), id: \.self) { columns in
          Toggle(FrameLayoutL10n.format("columns.count", columns), isOn: Binding(
            get: {
              let configuration = layout.configuration(for: count)
              return configuration.preset == .customColumns
                && configuration.columnCount == columns
            },
            set: { selected in
              if selected { layout.setColumns(columns, count: count) }
            }
          ))
        }
      }

      Divider()
      Toggle(FrameLayoutL10n.text("edit"), isOn: $layout.isEditing)
      Button(FrameLayoutL10n.text("reset")) { layout.reset(count: count) }
    } label: {
      Group {
        if compact {
          Image(systemName: "rectangle.split.2x2")
            .viewerFrame(width: 18)
        } else {
          Label(FrameLayoutL10n.text("title"), systemImage: "rectangle.split.2x2")
        }
      }
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(count < 2)
    .help(FrameLayoutL10n.text("title"))
    .accessibilityLabel(FrameLayoutL10n.text("title"))
    .accessibilityValue(selectedLayoutTitle)
    .accessibilityIdentifier("viewer.frames.layout")
  }

  private func preset(_ preset: ViewerFrameLayoutPreset, key: String) -> some View {
    Toggle(FrameLayoutL10n.text(key), isOn: Binding(
      get: { layout.configuration(for: count).preset == preset },
      set: { selected in
        if selected { layout.setPreset(preset, count: count) }
      }
    ))
  }

  private var selectedLayoutTitle: String {
    let configuration = layout.configuration(for: count)
    switch configuration.preset {
    case .balanced: return FrameLayoutL10n.text("preset.balanced")
    case .horizontal: return FrameLayoutL10n.text("preset.horizontal")
    case .vertical: return FrameLayoutL10n.text("preset.vertical")
    case .customColumns:
      return FrameLayoutL10n.format("columns.count", configuration.columnCount)
    }
  }
}
