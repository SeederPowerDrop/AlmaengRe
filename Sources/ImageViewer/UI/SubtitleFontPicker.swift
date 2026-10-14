import AppKit
import CoreText
import SwiftUI

/// Font discovery is shared and off the main thread. Opening subtitle settings
/// only constructs the selected row; the native menu fills when it is opened.
@MainActor
final class SubtitleFontCatalog: ObservableObject {
  static let shared = SubtitleFontCatalog()
  @Published private(set) var families: [String] = []
  private var task: Task<Void, Never>?
  private var started = false

  func prepare() {
    guard !started else { return }
    started = true
    task = Task { [weak self] in
      let names = await Task.detached(priority: .utility) {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted {
          $0.localizedStandardCompare($1) == .orderedAscending
        }
      }.value
      self?.families = names
      self?.task = nil
    }
  }
}

struct SubtitleFontPicker: NSViewRepresentable {
  @Binding var selection: String
  @Environment(\.isEnabled) private var isEnabled
  @ObservedObject private var catalog = SubtitleFontCatalog.shared
  let accessibilityID: String

  func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

  func makeNSView(context: Context) -> NSPopUpButton {
    let button = NSPopUpButton(frame: .zero, pullsDown: false)
    button.controlSize = .regular
    button.font = .systemFont(ofSize: 13)
    button.setContentHuggingPriority(.defaultLow, for: .horizontal)
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    button.target = context.coordinator
    button.action = #selector(Coordinator.choose(_:))
    button.menu?.autoenablesItems = false
    button.menu?.delegate = context.coordinator
    context.coordinator.button = button
    return button
  }

  func updateNSView(_ button: NSPopUpButton, context: Context) {
    button.isEnabled = isEnabled
    context.coordinator.selection = $selection
    context.coordinator.families = catalog.families
    button.setAccessibilityIdentifier(accessibilityID)
    button.setAccessibilityLabel(MotionMediaL10n.text("study.font"))
    context.coordinator.showSelection()
  }

  @MainActor
  final class Coordinator: NSObject, NSMenuDelegate {
    var selection: Binding<String>
    var families: [String] = []
    weak var button: NSPopUpButton?

    init(selection: Binding<String>) { self.selection = selection }

    func showSelection() {
      guard let button else { return }
      let name = selection.wrappedValue
      if let item = button.itemArray.first(where: { $0.representedObject as? String == name }) {
        if name.isEmpty { item.title = MotionMediaL10n.text("study.systemFont") }
        button.select(item)
      } else {
        let title = name.isEmpty ? MotionMediaL10n.text("study.systemFont") : name
        button.addItem(withTitle: title)
        button.lastItem?.representedObject = name
        button.select(button.lastItem)
      }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
      menu.removeAllItems()
      addItem("", title: MotionMediaL10n.text("study.systemFont"), to: menu)
      for family in families { addItem(family, title: family, to: menu) }
      if families.isEmpty {
        let pending = NSMenuItem(title: MotionMediaL10n.text("study.fontsLoading"), action: nil,
          keyEquivalent: "")
        pending.isEnabled = false
        menu.addItem(pending)
        SubtitleFontCatalog.shared.prepare()
      }
      showSelection()
    }

    private func addItem(_ name: String, title: String, to menu: NSMenu) {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.representedObject = name
      menu.addItem(item)
    }

    @objc func choose(_ sender: NSPopUpButton) {
      guard let name = sender.selectedItem?.representedObject as? String else { return }
      selection.wrappedValue = name
    }
  }
}
