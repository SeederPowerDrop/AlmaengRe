import SwiftUI

/// The two panes share mark storage, but each chooses its own subset of photos.
struct ComparisonPhotoMarkControls: View {
  @ObservedObject var comparison: FolderComparisonStore
  @ObservedObject var pane: FolderComparisonPane
  @ObservedObject var marks: PhotoMarkStore
  let side: FolderComparisonSide

  private var isPresented: Binding<Bool> {
    Binding(get: { comparison.editingPhotoMarkSide == side }, set: { value in
      if value { comparison.editingPhotoMarkSide = side }
      else if comparison.editingPhotoMarkSide == side { comparison.editingPhotoMarkSide = nil }
    })
  }

  private var selectedSlots: [PhotoMarkSlot] {
    PhotoMarkSlot.allCases.filter { pane.photoMarkFilter.slots.contains($0) }
  }

  private var title: String {
    if pane.photoMarkFilter.unmarkedOnly { return PhotoMarkL10n.text("filter.unmarked") }
    if !pane.photoMarkFilter.isActive { return PhotoMarkL10n.text("comparison.allPhotos") }
    return PhotoMarkL10n.format("filter.activeFormat", pane.photoMarkFilter.conditionCount)
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        filterButton
        ruleSummary
        Spacer(minLength: 0)
        status
      }
      VStack(alignment: .leading, spacing: 5) {
        filterButton
        ruleSummary
        status
      }
    }
    .controlSize(.small)
    .onChange(of: pane.isLocked) { _, locked in
      if locked { isPresented.wrappedValue = false }
    }
  }

  private var filterButton: some View {
    Button { isPresented.wrappedValue.toggle() } label: {
      HStack(spacing: 6) {
        Image(systemName: pane.photoMarkFilter.isActive ? "tag.fill" : "tag")
        Text(title).fixedSize(horizontal: false, vertical: true)
        Image(systemName: "chevron.down").font(ViewerUIMetrics.font(size: 9, weight: .semibold))
      }
      .foregroundStyle(pane.photoMarkFilter.isActive ? ViewerTheme.accent : Color.primary)
    }
    .help(PhotoMarkL10n.text("comparison.filter"))
    .accessibilityLabel(PhotoMarkL10n.format("comparison.titleFormat", side == .first ? "A" : "B"))
    .accessibilityValue(title)
    .disabled(pane.isLocked || pane.isLoading || !marks.isReady)
    .popover(isPresented: isPresented, arrowEdge: .bottom) { filterEditor }
  }

  @ViewBuilder private var ruleSummary: some View {
    if !selectedSlots.isEmpty && !pane.photoMarkFilter.unmarkedOnly {
      Text(PhotoMarkL10n.text(pane.photoMarkFilter.matchesAll ? "filter.all" : "filter.any"))
        .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var status: some View {
    HStack(spacing: 5) {
      if pane.isFiltering { ProgressView().controlSize(.mini) }
      Text(L10n.format("%d개 이미지", pane.assets.count))
        .font(ViewerUIMetrics.font(.caption).monospacedDigit()).foregroundStyle(.secondary).fixedSize()
    }
  }

  private var filterEditor: some View {
    PhotoMarkFilterEditor(filter: $pane.photoMarkFilter, marks: marks,
      title: PhotoMarkL10n.format("comparison.titleFormat", side == .first ? "A" : "B"))
  }
}
