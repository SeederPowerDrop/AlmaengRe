import AppKit

extension AppStore {
  /// Open the shared panel without replacing the explicitly selected files.
  func presentSelectionClassification() {
    guard canStartBatchOperation, canTogglePhotoMarking else { return }
    if !isPhotoMarking { togglePhotoMarking() }
    else { clearPhotoMarkTextFocus(in: NSApp?.keyWindow) }
  }
}
