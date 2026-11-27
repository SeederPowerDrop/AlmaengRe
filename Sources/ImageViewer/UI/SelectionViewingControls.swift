import SwiftUI

/// A temporary view of the existing selection. It does not create a new source.
struct SelectionViewingEntryBar: View {
  @ObservedObject var store: AppStore

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        title
        Spacer(minLength: 8)
        actions
      }
      VStack(alignment: .leading, spacing: 8) {
        title
        actions
      }
    }
    .font(ViewerUIMetrics.font(size: 12))
    .controlSize(.small)
    .viewerPadding(.horizontal, 12)
    .viewerPadding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ViewerTheme.panelGradient)
    .help(BatchActionsL10n.text("selection.view.help"))
  }

  private var title: some View {
    Text(BatchActionsL10n.text("selection.view.title"))
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var actions: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        singleButton
        multipleButton
      }
      .fixedSize(horizontal: true, vertical: false)
      VStack(alignment: .leading, spacing: 8) {
        singleButton
        multipleButton
      }
    }
    .buttonStyle(ViewerActionButtonStyle())
    .disabled(!store.canViewSelectedFiles)
  }

  private var singleButton: some View {
    Button { store.viewSelectedFiles() } label: {
      Label(BatchActionsL10n.text("selection.view.single"), systemImage: "rectangle")
    }
  }
  private var multipleButton: some View {
    Button { store.viewSelectedFiles(together: true) } label: {
      Label(BatchActionsL10n.text("selection.view.multiple"), systemImage: "square.grid.2x2")
    }
  }
}

struct SelectionViewingBanner: View {
  @ObservedObject var store: AppStore

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        title
        Spacer(minLength: 8)
        returnButton
      }
      VStack(alignment: .leading, spacing: 8) {
        title
        returnButton
      }
    }
    .font(ViewerUIMetrics.font(size: 12))
    .controlSize(.small)
    .viewerPadding(.horizontal, 12)
    .viewerPadding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ViewerTheme.panelGradient)
  }

  private var title: some View {
    Label(BatchActionsL10n.format("selection.view.active", store.assets.count),
      systemImage: "checkmark.circle.fill")
      .fixedSize(horizontal: false, vertical: true)
  }

  private var returnButton: some View {
    Button { store.returnToOverview() } label: {
      Label(BatchActionsL10n.text("selection.view.return"), systemImage: "square.grid.3x3")
    }
    .buttonStyle(ViewerActionButtonStyle())
    .help(BatchActionsL10n.text("selection.view.help"))
  }
}

struct SelectionViewingMenuItems: View {
  @ObservedObject var store: AppStore
  var body: some View {
    Menu(BatchActionsL10n.text("selection.view.title")) {
      Button { store.viewSelectedFiles() } label: {
        Label(BatchActionsL10n.text("selection.view.single"), systemImage: "rectangle")
      }
      Button { store.viewSelectedFiles(together: true) } label: {
        Label(BatchActionsL10n.text("selection.view.multiple"), systemImage: "square.grid.2x2")
      }
    }
    .disabled(!store.canViewSelectedFiles)
  }
}
