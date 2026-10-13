import SwiftUI

/// Valid drafts update the binding immediately, so an Apply button cannot read a
/// stale percentage even when its action precedes the field's focus-loss callback.
struct WatermarkPercentControl: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  @Environment(\.locale) private var locale
  @FocusState private var isFocused: Bool
  @State private var draft = ""

  var body: some View {
    HStack(spacing: 8) {
      Text(title).frame(width: 62, alignment: .leading)
      Slider(value: Binding(get: { value }, set: {
        value = $0
        synchronizeText()
      }), in: range, step: 0.001)
        .accessibilityLabel(title)
        .accessibilityValue(PercentEntry.accessibilityValue(for: value, locale: locale))
      TextField("", text: Binding(get: { draft }, set: { input in
        draft = input
        // Synchronous with the edit event, before any subsequent Apply action.
        if let accepted = PercentEntry.fraction(from: input, in: range, locale: locale) {
          value = accepted
        }
      }))
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .frame(width: 66)
        .focused($isFocused)
        .accessibilityLabel(title + " (%)")
        .onSubmit { commitDraft() }
      Text("%").foregroundStyle(.secondary).accessibilityHidden(true)
    }
    .onAppear { synchronizeText() }
    .onChange(of: value) { _, _ in
      if !isFocused { synchronizeText() }
    }
    .onChange(of: isFocused) { _, focused in
      if !focused { commitDraft() }
    }
    .onChange(of: locale) { _, _ in synchronizeText() }
  }

  private func commitDraft() {
    if let accepted = PercentEntry.fraction(from: draft, in: range, locale: locale) {
      value = accepted
    }
    // Invalid/empty drafts restore the last valid bound value without changing it.
    synchronizeText()
  }

  private func synchronizeText() {
    draft = PercentEntry.string(for: value, locale: locale)
  }
}
