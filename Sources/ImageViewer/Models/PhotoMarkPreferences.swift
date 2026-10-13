import Combine
import Foundation

/// Only new copies and exports opt into inheriting tags. Original-file tracking
/// remains independent of these preferences.
@MainActor
final class PhotoMarkPreferences: ObservableObject {
  static let inheritOnCopyKey = "ImageViewer.PhotoMarks.InheritOnCopy.v1"
  static let inheritOnExportKey = "ImageViewer.PhotoMarks.InheritOnExport.v1"

  @Published var inheritOnCopy: Bool {
    didSet { defaults.set(inheritOnCopy, forKey: Self.inheritOnCopyKey) }
  }

  @Published var inheritOnExport: Bool {
    didSet { defaults.set(inheritOnExport, forKey: Self.inheritOnExportKey) }
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    inheritOnCopy = defaults.bool(forKey: Self.inheritOnCopyKey)
    inheritOnExport = defaults.bool(forKey: Self.inheritOnExportKey)
  }
}
