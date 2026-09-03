import SwiftUI

@main
@MainActor
struct ImageViewerApp: App {
  @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
  @StateObject private var store = AppStore()
  @StateObject private var shortcuts = ShortcutStore()

  var body: some Scene {
    WindowGroup("이미지뷰어") {
      RootView(store: store, shortcuts: shortcuts)
        .frame(minWidth: 820, minHeight: 540)
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
