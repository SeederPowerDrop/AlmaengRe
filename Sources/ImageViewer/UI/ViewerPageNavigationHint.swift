import SwiftUI

/// Shares the same shortcut sources as the input handler and the page buttons.
/// The compact fallback keeps the hint usable beside a narrow folder title.
struct ViewerPageNavigationHint: View {
  @ObservedObject var store: AppStore
  @ObservedObject var shortcuts: ShortcutStore

  var body: some View {
    let keys = ViewerNavigationHintText.pageKeys(shortcuts: shortcuts)
    if store.imagesPerPage > 1, !keys.isEmpty {
      let pageKeys = ViewerNavigationHintText.isolated(keys)
      let pageHelp = L10n.format("%@로 한 화면에 설정한 %d장씩 넘깁니다. 분류 모드에서도 사용할 수 있습니다.",
        pageKeys, store.imagesPerPage)
      let help = [pageHelp, ViewerNavigationHintText.selectionHelp(shortcuts: shortcuts)]
        .compactMap { $0 }.joined(separator: "\n")
      ViewThatFits(in: .horizontal) {
        Text(L10n.format("%@ · %d장씩 이동", pageKeys, store.imagesPerPage)).fixedSize()
        Text(verbatim: pageKeys).fixedSize()
      }
      .font(.system(size: 10))
      .foregroundStyle(.secondary)
      .help(help)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(help)
      .accessibilityIdentifier("viewer.pageHint")
    }
  }
}

@MainActor
enum ViewerNavigationHintText {
  static func pageKeys(shortcuts: ShortcutStore) -> String {
    [-1, 1].compactMap { shortcuts.viewerPageBinding(direction: $0)?.displayText }
      .joined(separator: " / ")
  }

  static func selectionKeys(shortcuts: ShortcutStore) -> String {
    [-1, 1].compactMap { shortcuts.viewerSelectionBinding(direction: $0)?.displayText }
      .joined(separator: " / ")
  }

  /// Keyboard directions retain their physical order in right-to-left text.
  static func isolated(_ keys: String) -> String { "\u{2066}\(keys)\u{2069}" }

  static func selectionHelp(shortcuts: ShortcutStore) -> String? {
    let keys = selectionKeys(shortcuts: shortcuts)
    guard !keys.isEmpty else { return nil }
    return PhotoMarkL10n.format("panel.viewerSelectionHelp", isolated(keys))
  }

  static func markingPanelHint(shortcuts: ShortcutStore) -> String {
    let pageHint = PhotoMarkL10n.format("panel.viewerGridHint", isolated(pageKeys(shortcuts: shortcuts)))
    let keys = selectionKeys(shortcuts: shortcuts)
    guard !keys.isEmpty else { return pageHint }
    return PhotoMarkL10n.format("panel.viewerSelectionHint", isolated(keys)) + "\n" + pageHint
  }
}
