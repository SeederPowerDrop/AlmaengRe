import SwiftUI

/// The title and disclosure arrow are a single target, so fitting is discoverable
/// without adding a row of width/height buttons to each viewing surface.
struct ImageFitMenu: View {
  let mode: BaseScaleMode
  var zoom: CGFloat = 1
  var isFrameLimited = false
  var fontSize: CGFloat = 12
  var minimumHeight: CGFloat = 28
  let identifier: String
  let setMode: (BaseScaleMode) -> Void
  let center: () -> Void

  private var title: String {
    ImageFitL10n.text(isFrameLimited ? "menu.frame" : "menu.image")
  }

  var body: some View {
    Menu {
      scaleItem(.fit)
      if !isFrameLimited {
        scaleItem(.fitWidth)
        scaleItem(.fitHeight)
        scaleItem(.actualPixels)
      }
      Divider()
      Button(ImageFitL10n.text("center.title"), action: center)
        .help(ImageFitL10n.text("center.help"))
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
        Text(verbatim: title)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }
      .font(ViewerUIMetrics.font(size: fontSize, weight: .medium))
      .viewerPadding(.horizontal, 8)
      .frame(minHeight: ViewerUIMetrics.scale(minimumHeight))
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.visible)
    .fixedSize(horizontal: true, vertical: false)
    .help(ImageFitL10n.text(isFrameLimited ? "menu.frameHelp" : "menu.help"))
    .accessibilityLabel(title)
    .accessibilityIdentifier(identifier)
  }

  private func scaleItem(_ value: BaseScaleMode) -> some View {
    Button { setMode(value) } label: {
      if mode == value && abs(zoom - 1) < 0.0001 {
        Label(ImageFitL10n.title(for: value), systemImage: "checkmark")
      } else {
        Text(verbatim: ImageFitL10n.title(for: value))
      }
    }
    .help(isFrameLimited && value == .fit
      ? ImageFitL10n.text("frame.wholeHelp") : ImageFitL10n.help(for: value))
  }
}
