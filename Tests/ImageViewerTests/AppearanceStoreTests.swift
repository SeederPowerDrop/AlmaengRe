import AppKit
import Testing

@testable import ImageViewer

@Suite("앱 화면 모드", .serialized)
@MainActor
struct AppearanceStoreTests {
  @Test("처음 실행과 잘못된 저장값은 시스템 모드로 시작한다")
  func defaultAndInvalidValue() throws {
    let suite = "ImageViewer.AppearanceTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(AppearanceStore(defaults: defaults).mode == .system)
    defaults.set("unknown-mode", forKey: AppearanceStore.defaultsKey)
    #expect(AppearanceStore(defaults: defaults).mode == .system)
  }

  @Test("세 모드는 재실행 후 복원되며 창 생성 전 적용된다")
  func restoresOnLaunch() throws {
    let suite = "ImageViewer.AppearanceTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let application = NSApplication.shared
    let previousAppearance = application.appearance
    defer { application.appearance = previousAppearance }

    for mode in AppAppearance.allCases {
      AppearanceStore(defaults: defaults).mode = mode
      let restored = AppearanceStore(defaults: defaults)
      #expect(restored.mode == mode)
      restored.apply(to: application)
      let window = makeWindow()
      defer { window.close() }
      #expect(application.appearance?.name == mode.nativeAppearance?.name)
      #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        == application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
    }
  }

  @Test("열린 창과 새 창이 함께 바뀌고 시스템 모드는 명시적 재정의를 해제한다")
  func updatesAllWindowsAndReleasesOverride() async throws {
    let suite = "ImageViewer.AppearanceTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let application = NSApplication.shared
    let previousAppearance = application.appearance
    defer { application.appearance = previousAppearance }
    let appearance = AppearanceStore(defaults: defaults)
    appearance.apply(to: application)
    let existingWindow = makeWindow()
    defer { existingWindow.close() }

    for mode in [AppAppearance.dark, .light, .system] {
      appearance.mode = mode
      // AppKit delivers appearance changes to existing windows on the next run-loop turn.
      try await Task.sleep(for: .milliseconds(50))
      let newWindow = makeWindow()
      defer { newWindow.close() }
      let expected = mode.nativeAppearance ?? application.effectiveAppearance
      for window in [existingWindow, newWindow] {
        #expect(window.appearance == nil)
        #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
          == expected.bestMatch(from: [.aqua, .darkAqua]), "\(mode): existing=\(window === existingWindow)")
      }
    }
    #expect(application.appearance == nil)
    #expect(AppearanceStore(defaults: defaults).mode == .system)
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // Only windows registered with the running application receive its appearance changes.
    window.orderBack(nil)
    return window
  }
}
