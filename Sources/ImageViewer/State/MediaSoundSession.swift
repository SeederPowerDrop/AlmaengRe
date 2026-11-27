import Combine

enum MediaSoundMode: CaseIterable {
  case muted, currentFile, session
}

/// Shared by the viewer, map and comparison players for this app instance.
/// Deliberately absent from preferences and saved work: a new launch is muted.
@MainActor
final class MediaSoundSession: ObservableObject {
  @Published private(set) var isEnabled = false

  func setEnabled(_ enabled: Bool) {
    guard isEnabled != enabled else { return }
    isEnabled = enabled
  }
}
