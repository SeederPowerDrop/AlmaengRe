import SwiftUI

@main
@MainActor
struct ImageViewerApp: App {
  @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
  @StateObject private var store: AppStore
  @StateObject private var shortcuts: ShortcutStore
  @StateObject private var language: LanguageStore
  private let releaseBenchmark: OverviewReleaseBenchmark?
  private let manualQA: ManualViewerQAContext?

  init() {
    let benchmark = OverviewReleaseBenchmark.makeFromEnvironment()
    let manual = benchmark == nil ? ManualViewerQAContext.active : nil
    releaseBenchmark = benchmark
    manualQA = manual
    let defaults = benchmark?.defaults ?? manual?.defaults ?? .standard
    _store = StateObject(wrappedValue: benchmark?.store ?? manual?.store ?? AppStore())
    _shortcuts = StateObject(wrappedValue: ShortcutStore(defaults: defaults))
    _language = StateObject(wrappedValue: manual?.makeLanguageStore() ?? LanguageStore(defaults: defaults))
  }

  private var windowTitle: String {
    guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
      return "알맹Re"
    }
    return "알맹Re \(version)"
  }

  var body: some Scene {
    WindowGroup(Text(verbatim: windowTitle)) {
      RootView(store: store, shortcuts: shortcuts, overviewPreloader: releaseBenchmark?.preloader,
        onOverviewBitmapStateApplied: releaseBenchmark.map { benchmark in
          { event in benchmark.bitmapStateApplied(event) }
        }, onSidebarBitmapStateApplied: releaseBenchmark.map { benchmark in
          { event in benchmark.sidebarBitmapStateApplied(event) }
        })
        .background {
          if let releaseBenchmark {
            OverviewReleaseBenchmarkAttachment(benchmark: releaseBenchmark)
              .frame(width: 0, height: 0)
              .allowsHitTesting(false)
          }
        }
        .font(ViewerUIMetrics.font(.body))
        .environment(\.locale, language.locale)
        .frame(minWidth: 960, minHeight: 600)
        .onAppear {
          applicationDelegate.attachOpenHandler { [weak store] urls in
            _ = store?.openExternally(urls: urls)
          }
          manualQA?.start()
        }
        .onChange(of: language.selection) { _, _ in
          // SwiftUI updates its command tree first; then update AppKit's
          // standard menu titles without replacing their native actions.
          DispatchQueue.main.async { NativeMenuLocalization.apply() }
        }
    }
    .defaultSize(width: 1_240, height: 800)
    .windowToolbarStyle(.unifiedCompact)
    .environment(\.locale, language.locale)
    .commands {
      AppCommands(store: store, shortcuts: shortcuts, appearance: applicationDelegate.appearance,
        language: language)
    }

    Settings {
      SettingsView(store: store, shortcuts: shortcuts, appearance: applicationDelegate.appearance,
        language: language)
        .font(ViewerUIMetrics.font(.body))
        .environment(\.locale, language.locale)
    }
    .environment(\.locale, language.locale)

    Window("기본 사용법", id: BasicUsageView.windowID) {
      BasicUsageView(shortcuts: shortcuts)
        .environment(\.locale, language.locale)
    }
    .windowResizability(.contentMinSize)
    .defaultSize(width: 720, height: 760)
    .defaultPosition(.center)
    .commandsRemoved()
    .environment(\.locale, language.locale)

    Window("알맹Re 정보", id: AboutView.windowID) {
      AboutView()
        .font(ViewerUIMetrics.font(.body))
        .environment(\.locale, language.locale)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentSize)
    .defaultSize(width: AboutView.windowWidth, height: 720)
    .defaultPosition(.center)
    .commandsRemoved()
    .environment(\.locale, language.locale)
  }
}
