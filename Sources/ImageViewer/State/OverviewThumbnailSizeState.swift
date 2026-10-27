import Combine
import Foundation

/// Only the overview observes size changes. Broadcasting each slider action
/// through AppStore also invalidates the root toolbar, sidebars and every card.
@MainActor
final class OverviewThumbnailSizeState: ObservableObject {
  private static let defaultsKey = "ImageViewer.OverviewThumbnailSize.v1"
  @Published private(set) var value: CGFloat
  private let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
    let saved = defaults.object(forKey: Self.defaultsKey) == nil
      ? OverviewThumbnailSizing.defaultSize : CGFloat(defaults.double(forKey: Self.defaultsKey))
    value = OverviewThumbnailSizing.normalized(saved)
  }

  func set(_ requested: CGFloat) {
    let normalized = OverviewThumbnailSizing.normalized(requested)
    // Publish only the normalized value, once. Repeated native slider values
    // need no second layout transaction.
    if value != normalized { value = normalized }
    defaults.set(Double(normalized), forKey: Self.defaultsKey)
  }
}
