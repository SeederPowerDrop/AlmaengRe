import Combine
import Foundation

/// Only the overview observes size changes. Broadcasting each slider action
/// through AppStore also invalidates the root toolbar, sidebars and every card.
@MainActor
final class OverviewThumbnailSizeState: ObservableObject {
  private static let defaultsKey = "ImageViewer.OverviewThumbnailSize.v1"
  @Published private(set) var value: CGFloat
  private let defaults: UserDefaults
  private var pendingLayout: Task<Void, Never>?

  init(defaults: UserDefaults) {
    self.defaults = defaults
    let saved = defaults.object(forKey: Self.defaultsKey) == nil
      ? OverviewThumbnailSizing.defaultSize : CGFloat(defaults.double(forKey: Self.defaultsKey))
    value = OverviewThumbnailSizing.normalized(saved)
  }

  /// The native slider supplies continuous values. Pause grid layout until the
  /// pointer settles briefly, and let the slider itself display the live value.
  func previewAfterDragPause(_ requested: CGFloat) {
    pendingLayout?.cancel()
    let size = OverviewThumbnailSizing.normalized(requested)
    pendingLayout = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
      guard !Task.isCancelled, let self else { return }
      self.publishSize(size)
    }
  }

  func set(_ requested: CGFloat) {
    pendingLayout?.cancel()
    pendingLayout = nil
    let size = OverviewThumbnailSizing.normalized(requested)
    publishSize(size)
    if defaults.object(forKey: Self.defaultsKey) == nil
      || defaults.double(forKey: Self.defaultsKey) != Double(size) {
      defaults.set(Double(size), forKey: Self.defaultsKey)
    }
  }

  private func publishSize(_ size: CGFloat) {
    if value != size { value = size }
  }
}
