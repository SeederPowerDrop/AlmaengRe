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
        .onAppear {
          applicationDelegate.attachOpenHandler { [weak store] urls in
            _ = store?.openExternally(urls: urls)
          }
        }
    }
    .defaultSize(width: 1_240, height: 800)
    .windowToolbarStyle(.unifiedCompact)
    .commands {
      AppCommands(store: store, shortcuts: shortcuts, appearance: applicationDelegate.appearance)
    }

    Settings {
      SettingsView(store: store, shortcuts: shortcuts, appearance: applicationDelegate.appearance)
    }

    Window("기본 사용법", id: BasicUsageView.windowID) {
      BasicUsageView(shortcuts: shortcuts)
    }
    .windowResizability(.contentMinSize)
    .defaultSize(width: 720, height: 760)
    .defaultPosition(.center)
    .commandsRemoved()

    Window("알맹Re 정보", id: AboutView.windowID) {
      AboutView()
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentMinSize)
    .defaultSize(width: 820, height: 800)
    .defaultPosition(.center)
    .commandsRemoved()
  }
}
