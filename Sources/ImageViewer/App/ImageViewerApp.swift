import SwiftUI

@main
@MainActor
struct ImageViewerApp: App {
  @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
  @StateObject private var store = AppStore()
  @StateObject private var shortcuts = ShortcutStore()

  private var windowTitle: String {
    guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
      return "알맹Re"
    }
    return "알맹Re \(version)"
  }

  var body: some Scene {
    WindowGroup(Text(verbatim: windowTitle)) {
      RootView(store: store, shortcuts: shortcuts)
        .frame(minWidth: 960, minHeight: 600)
    }
    .defaultSize(width: 1_240, height: 800)
    .windowToolbarStyle(.unifiedCompact)
    .commands {
      AppCommands(store: store, shortcuts: shortcuts)
    }

    Settings {
      SettingsView(store: store, shortcuts: shortcuts)
    }
  }
}
