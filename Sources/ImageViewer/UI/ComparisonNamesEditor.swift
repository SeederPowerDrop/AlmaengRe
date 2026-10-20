import SwiftUI

/// Fixed segments let long folder names truncate without widening the toolbar.
struct ComparisonNavigationSelector: View {
  @ObservedObject var comparison: FolderComparisonStore

  var body: some View {
    HStack(spacing: 1) {
      ForEach(ComparisonNavigationTarget.allCases) { target in
        let title = comparison.navigationTitle(for: target)
        Button { comparison.navigationTarget = target } label: {
          Text(title)
            .font(ViewerUIMetrics.font(size: 12, weight: .medium))
            .lineLimit(1).truncationMode(.middle)
            .viewerFrame(maxWidth: .infinity, minHeight: 24)
            .viewerPadding(.horizontal, 5)
            .contentShape(Rectangle())
            .background(comparison.navigationTarget == target
              ? Color.primary.opacity(0.16) : Color.clear,
              in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(comparison.navigationTarget == target ? .isSelected : [])
      }
    }
    .viewerPadding(2)
    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7).strokeBorder(ViewerTheme.separator, lineWidth: 0.75)
        .allowsHitTesting(false)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L10n.text("방향키로 넘길 대상"))
  }
}

struct ComparisonNamesEditor: View {
  @ObservedObject var comparison: FolderComparisonStore
  @Environment(\.dismiss) private var dismiss
  @State private var firstName: String
  @State private var secondName: String

  init(comparison: FolderComparisonStore) {
    self.comparison = comparison
    _firstName = State(initialValue: comparison.customName(for: .first))
    _secondName = State(initialValue: comparison.customName(for: .second))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(ComparisonNamesL10n.text("editor.title")).font(ViewerUIMetrics.font(.title2).bold())
      nameField(.first, text: $firstName)
      nameField(.second, text: $secondName)
      Text(ComparisonNamesL10n.text("editor.help"))
        .font(ViewerUIMetrics.font(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Button(ComparisonNamesL10n.text("editor.reset")) {
          firstName = ""
          secondName = ""
        }
        Spacer()
        Button(ComparisonNamesL10n.text("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(ComparisonNamesL10n.text("action.save")) { save() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .viewerPadding(24)
    .viewerFrame(width: 470)
  }

  private func nameField(_ side: FolderComparisonSide, text: Binding<String>) -> some View {
    let position: String = switch (side, comparison.arrangement) {
    case (.first, .horizontal): "editor.left"
    case (.second, .horizontal): "editor.right"
    case (.first, .vertical): "editor.top"
    case (.second, .vertical): "editor.bottom"
    }
    let automatic = comparison.automaticName(for: side)
    return VStack(alignment: .leading, spacing: 6) {
      Text(ComparisonNamesL10n.text(position)).font(ViewerUIMetrics.font(.headline))
      TextField(automatic, text: text)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel(ComparisonNamesL10n.text(position))
        .onChange(of: text.wrappedValue) { _, value in
          if value.count > 80 { text.wrappedValue = String(value.prefix(80)) }
        }
        .onSubmit { save() }
      Text(ComparisonNamesL10n.format("automatic.label", automatic))
        .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
        .lineLimit(2).truncationMode(.middle).help(automatic)
    }
  }

  private func save() {
    comparison.setCustomName(firstName, for: .first)
    comparison.setCustomName(secondName, for: .second)
    dismiss()
  }
}

extension FolderComparisonStore {
  func namedSideTitle(for side: FolderComparisonSide) -> String {
    let position: String = switch (side, arrangement) {
    case (.first, .horizontal): "target.left"
    case (.second, .horizontal): "target.right"
    case (.first, .vertical): "target.top"
    case (.second, .vertical): "target.bottom"
    }
    return ComparisonNamesL10n.format(position, displayName(for: side))
  }
}
