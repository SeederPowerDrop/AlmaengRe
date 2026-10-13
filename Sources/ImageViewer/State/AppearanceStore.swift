import AppKit
import Combine

enum AppAppearance: String, CaseIterable, Identifiable {
  case system, light, dark

  var id: String { rawValue }
  var title: String { L10n.text("appearance.\(rawValue)") }

  var systemImage: String {
    switch self {
    case .system: "desktopcomputer"
    case .light: "sun.max"
    case .dark: "moon"
    }
  }

  var nativeAppearance: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }
}

/// One app-wide override keeps SwiftUI content, native controls and new windows in sync.
@MainActor
final class AppearanceStore: ObservableObject {
  static let defaultsKey = "ImageViewer.Appearance.v1"

  @Published var mode: AppAppearance {
    didSet {
      defaults.set(mode.rawValue, forKey: Self.defaultsKey)
      application?.appearance = mode.nativeAppearance
    }
  }

  private let defaults: UserDefaults
  private weak var application: NSApplication?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    mode = defaults.string(forKey: Self.defaultsKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
  }

  func apply(to application: NSApplication) {
    self.application = application
    // nil restores live system following, rather than copying the current system color.
    application.appearance = mode.nativeAppearance
  }
}
