import AppKit

/// Keep the native picker and archive leases alive until the chosen service ends.
@MainActor
final class FileSharingService: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
  static let shared = FileSharingService()
  private var picker: NSSharingServicePicker?
  private var retainedAssets: [ImageAsset] = []
  private var activeService: NSSharingService?

  func share(urls: [URL], retaining assets: [ImageAsset] = []) {
    guard !urls.isEmpty, picker == nil, activeService == nil,
      let view = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView else { return }
    guard urls.allSatisfy({ $0.isFileURL && FileManager.default.isReadableFile(atPath: $0.path) }) else {
      let alert = NSAlert()
      alert.messageText = BatchActionsL10n.text("share.unavailable")
      alert.informativeText = BatchActionsL10n.text("share.unavailableHint")
      alert.runModal()
      return
    }
    retainedAssets = assets
    let picker = NSSharingServicePicker(items: urls)
    self.picker = picker
    picker.delegate = self
    picker.show(relativeTo: NSRect(x: view.bounds.maxX - 48, y: view.bounds.midY, width: 24, height: 24),
      of: view, preferredEdge: .minX)
  }

  func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
    didChoose service: NSSharingService?) {
    activeService = service
    picker = nil
    if service == nil { retainedAssets = [] }
  }

  func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
    delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? { self }

  func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
    finish()
  }

  func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
    finish()
    let alert = NSAlert()
    alert.messageText = BatchActionsL10n.text("share.failed")
    alert.informativeText = error.localizedDescription
    alert.runModal()
  }

  private func finish() {
    activeService = nil
    picker = nil
    retainedAssets = []
  }
}
