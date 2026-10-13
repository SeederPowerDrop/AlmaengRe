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
    if selectedSlots.isEmpty { return PhotoMarkL10n.text("comparison.allPhotos") }
    return selectedSlots.map(\.keyLabel).joined(separator: " · ")
  }

  var body: some View {
    HStack(spacing: 10) {
      Button { isPresented.wrappedValue.toggle() } label: {
        HStack(spacing: 6) {
          Image(systemName: pane.photoMarkFilter.isActive ? "tag.fill" : "tag")
          Text(title).lineLimit(1)
          Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(pane.photoMarkFilter.isActive ? ViewerTheme.accent : Color.primary)
      }
      .help(PhotoMarkL10n.text("comparison.filter"))
      .accessibilityLabel(PhotoMarkL10n.format("comparison.titleFormat", side == .first ? "A" : "B"))
      .accessibilityValue(title)
      .disabled(pane.isLocked || pane.isLoading || !marks.isReady)
      .popover(isPresented: isPresented, arrowEdge: .bottom) { filterEditor }
      if !selectedSlots.isEmpty && !pane.photoMarkFilter.unmarkedOnly {
        Text(PhotoMarkL10n.text(pane.photoMarkFilter.matchesAll ? "filter.all" : "filter.any"))
          .font(.caption).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.tail)
      }
      Spacer(minLength: 0)
      if pane.isFiltering {
        ProgressView().controlSize(.mini)
      }
      Text(L10n.format("%d개 이미지", pane.assets.count))
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
    }
    .controlSize(.small)
    .onChange(of: pane.isLocked) { _, locked in
      if locked { isPresented.wrappedValue = false }
    }
  }

  private var filterEditor: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(PhotoMarkL10n.format("comparison.titleFormat", side == .first ? "A" : "B"))
        .font(.headline)
      Text(PhotoMarkL10n.text("comparison.selectionHelp"))
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
        ForEach(PhotoMarkSlot.allCases, id: \.self) { slot in
          Toggle(isOn: Binding(get: { pane.photoMarkFilter.slots.contains(slot) }, set: { selected in
            var filter = pane.photoMarkFilter
            if selected { filter.slots.insert(slot); filter.unmarkedOnly = false }
            else { filter.slots.remove(slot) }
            pane.photoMarkFilter = filter
          })) {
            HStack(spacing: 6) {
              Text(slot.keyLabel)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(marks.color(for: slot).tint)
                .frame(width: 23, height: 22)
                .background(marks.color(for: slot).tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
              Text(marks.label(for: slot)).lineLimit(1).truncationMode(.tail)
            }
          }
          .toggleStyle(.checkbox)
          .help("\(slot.keyLabel) · \(marks.label(for: slot))")
          .accessibilityLabel("\(slot.keyLabel) · \(marks.label(for: slot))")
        }
      }
      Divider()
      Picker(PhotoMarkL10n.text("filter.title"), selection: $pane.photoMarkFilter.matchesAll) {
        Text(PhotoMarkL10n.text("filter.any")).tag(false)
        Text(PhotoMarkL10n.text("filter.all")).tag(true)
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()
      .disabled(pane.photoMarkFilter.unmarkedOnly)
      Toggle(PhotoMarkL10n.text("filter.unmarked"), isOn: Binding(
        get: { pane.photoMarkFilter.unmarkedOnly }, set: { selected in
          var filter = pane.photoMarkFilter
          filter.unmarkedOnly = selected
          if selected { filter.slots = [] }
          pane.photoMarkFilter = filter
        }))
      Button(PhotoMarkL10n.text("comparison.reset")) { pane.photoMarkFilter = PhotoMarkFilter() }
        .disabled(!pane.photoMarkFilter.isActive)
    }
    .toggleStyle(.checkbox)
    .padding(18)
    .frame(width: 390)
  }
}
