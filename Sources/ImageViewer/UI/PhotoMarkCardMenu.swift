import SwiftUI

/// A card menu always edits its own asset, independently of the current selection.
struct PhotoMarkCardMenu: View {
  @ObservedObject var store: AppStore
  let asset: ImageAsset
  var inMenu = false
  @State private var showsMarks = false

  private var assigned: Set<PhotoMarkSlot> { store.photoMarks.marks(for: asset) }
  private var summary: PhotoMarkCardSummary {
    PhotoMarkCardSummary(assigned: assigned, label: store.photoMarks.label(for:))
  }

  var body: some View {
    if inMenu {
      Menu { menuContents } label: {
        Label(PhotoMarkL10n.text("card.title"), systemImage: assigned.isEmpty ? "tag" : "tag.fill")
      }
      .disabled(!store.canMarkPhoto(asset))
    } else {
      // A native Menu flattens the label into one string, hiding the second
      // name and the extra-marks indicator. A plain button preserves each name.
      Button { showsMarks.toggle() } label: {
        PhotoMarkCardLabel(summary: summary).viewerPadding(.vertical, 3)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(store.canMarkPhoto(asset) ? Color.accentColor : Color.secondary)
      .disabled(!store.canMarkPhoto(asset))
      .help(summary.orderedNames.isEmpty ? PhotoMarkL10n.text("card.help")
        : summary.fullTitle + "\n" + PhotoMarkL10n.text("card.help"))
      .accessibilityLabel(PhotoMarkL10n.format("card.accessibilityFormat", asset.filename))
      .accessibilityValue(summary.orderedNames.isEmpty
        ? PhotoMarkL10n.format("card.assignedFormat", 0) : summary.fullTitle)
      .accessibilityIdentifier("photoMark.card.\(asset.sessionID)")
      .popover(isPresented: $showsMarks) {
        VStack(alignment: .leading, spacing: 10) {
          Text(asset.filename).font(ViewerUIMetrics.font(.headline)).lineLimit(2).truncationMode(.middle)
          Divider()
          ScrollView {
            VStack(alignment: .leading, spacing: 10) {
              ForEach(PhotoMarkSlot.allCases, id: \.self) { slot in
                Toggle(isOn: binding(for: slot)) {
                  HStack(spacing: 8) {
                    Circle().fill(store.photoMarks.color(for: slot).tint).viewerFrame(width: 8, height: 8)
                    Text(slot.keyLabel).font(ViewerUIMetrics.font(.caption).monospaced()).viewerFrame(width: 14)
                    Text(displayName(for: slot)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                  }
                }
                .toggleStyle(.checkbox)
                .help(displayName(for: slot))
              }
            }.viewerPadding(2)
          }.viewerFrame(maxHeight: 380)
        }
        .viewerPadding(14).viewerFrame(width: 320)
      }
      .onChange(of: store.canMarkPhoto(asset)) { _, allowed in
        if !allowed { showsMarks = false }
      }
      .onChange(of: asset.id) { _, _ in showsMarks = false }
    }
  }

  @ViewBuilder private var menuContents: some View {
      Text(asset.filename)
      Divider()
      ForEach(PhotoMarkSlot.allCases, id: \.self) { slot in
        Toggle(isOn: binding(for: slot)) {
          PhotoMarkMenuLabel(name: "\(slot.keyLabel) · \(displayName(for: slot))",
            color: store.photoMarks.color(for: slot))
        }
      }
  }

  private func binding(for slot: PhotoMarkSlot) -> Binding<Bool> {
    Binding(get: { assigned.contains(slot) }, set: { _ in store.togglePhotoMark(slot, for: asset) })
  }

  private func displayName(for slot: PhotoMarkSlot) -> String {
    let name = store.photoMarks.label(for: slot)
    return name.isEmpty ? PhotoMarkL10n.text("labels.unnamed") : name
  }
}

/// Use stable key order, independently of the order in which marks were added.
struct PhotoMarkCardSummary {
  let orderedNames: [String]

  init(assigned: Set<PhotoMarkSlot>, label: (PhotoMarkSlot) -> String) {
    orderedNames = PhotoMarkSlot.allCases.filter { assigned.contains($0) }.map {
      let name = label($0).trimmingCharacters(in: .whitespacesAndNewlines)
      return name.isEmpty ? PhotoMarkL10n.text("labels.unnamed") : name
    }
  }

  var visibleNames: [String] { Array(orderedNames.prefix(2)) }
  var hasMore: Bool { orderedNames.count > 2 }
  var fullTitle: String { orderedNames.joined(separator: " · ") }
}

struct PhotoMarkCardLabel: View {
  let summary: PhotoMarkCardSummary

  var body: some View {
    PhotoMarkLabelWidthLimit {
      HStack(spacing: 4) {
        Image(systemName: summary.orderedNames.isEmpty ? "tag" : "tag.fill")
          .fixedSize()
        if summary.orderedNames.isEmpty {
          Text(PhotoMarkL10n.text("card.title")).lineLimit(1)
        } else {
          ForEach(Array(summary.visibleNames.enumerated()), id: \.offset) { index, name in
            if index > 0 { Text("·").fixedSize() }
            Text(name).lineLimit(1).truncationMode(.tail)
          }
          // Keep the additional-marks indicator separate, so long names cannot hide it.
          if summary.hasMore { Text("…").fixedSize() }
        }
        Image(systemName: "chevron.down").font(ViewerUIMetrics.font(size: 8, weight: .semibold)).fixedSize()
      }
    }
  }
}

/// Keep short labels at their natural width; compress long labels within a tile.
private struct PhotoMarkLabelWidthLimit: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let label = subviews.first else { return .zero }
    let width = min(240, max(0, proposal.width ?? 240), label.sizeThatFits(.unspecified).width)
    return label.sizeThatFits(ProposedViewSize(width: width, height: nil))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
      proposal: ProposedViewSize(bounds.size))
  }
}
