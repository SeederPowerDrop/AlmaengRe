import SwiftUI

/// A card menu always edits its own asset, independently of the current selection.
struct PhotoMarkCardMenu: View {
  @ObservedObject var store: AppStore
  let asset: ImageAsset

  private var assigned: Set<PhotoMarkSlot> { store.photoMarks.marks(for: asset) }

  var body: some View {
    Menu {
      Text(asset.filename)
      Divider()
      ForEach(PhotoMarkSlot.allCases, id: \.self) { slot in
        Toggle(isOn: Binding(
          get: { assigned.contains(slot) },
          set: { _ in store.togglePhotoMark(slot, for: asset) }
        )) {
          PhotoMarkMenuLabel(name: "\(slot.keyLabel) · \(store.photoMarks.label(for: slot))",
            color: store.photoMarks.color(for: slot))
        }
      }
    } label: {
      Label(assigned.isEmpty ? PhotoMarkL10n.text("card.title")
        : "\(PhotoMarkL10n.text("card.title")) \(assigned.count)",
        systemImage: assigned.isEmpty ? "tag" : "tag.fill")
        .lineLimit(1).fixedSize()
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(!store.canMarkPhoto(asset))
    .help(PhotoMarkL10n.text("card.help"))
    .accessibilityLabel(PhotoMarkL10n.format("card.accessibilityFormat", asset.filename))
    .accessibilityValue(PhotoMarkL10n.format("card.assignedFormat", assigned.count))
    .accessibilityIdentifier("photoMark.card.\(asset.sessionID)")
  }
}
