import SwiftUI

/// 메뉴 막대와 뷰어 조작부가 동일한 설정·사용자 지정 단축키를 표시합니다.
struct PanModeMenuItems: View {
  @ObservedObject var store: AppStore
  @ObservedObject var shortcuts: ShortcutStore

  var body: some View {
    ForEach(PanInteractionMode.allCases) { mode in
      Button {
        store.perform(mode.shortcutAction)
      } label: {
        Label(
          L10n.format(
            "%@  %@", mode.title, shortcuts.binding(for: mode.shortcutAction).displayText),
          systemImage: store.panInteractionMode == mode ? "checkmark" : "hand.draw"
        )
      }
    }
  }
}

struct MagnificationMenuItems: View {
  @ObservedObject var store: AppStore
  @ObservedObject var shortcuts: ShortcutStore

  var body: some View {
    Button {
      store.perform(.toggleAntialiasing)
    } label: {
      Label(
        L10n.format(
          "%@  %@", L10n.text("고화질 확대"),
          shortcuts.binding(for: .toggleAntialiasing).displayText),
        systemImage: store.isAntialiasingEnabled ? "checkmark" : "circle"
      )
    }
    Divider()
    ForEach(MagnificationComparisonLayout.allCases) { layout in
      Button {
        store.perform(layout.shortcutAction)
      } label: {
        Label(
          L10n.format(
            "%@  %@", layout.title, shortcuts.binding(for: layout.shortcutAction).displayText),
          systemImage: store.comparisonLayout == layout ? "checkmark" : "rectangle.split.2x1"
        )
      }
    }
  }
}
