import AppKit
import Testing

@testable import ImageViewer

@Suite("전체 화면 영상의 자막 설정 포커스", .serialized)
@MainActor
struct VideoFullScreenFocusTests {
  @Test("소유한 자식 설정 창에서는 재생을 유지하고 다른 창·앱에서는 멈춘다")
  func ownedChildFocusKeepsPlaybackEligible() {
    _ = NSApplication.shared
    let player = window()
    let settings = window()
    let nestedControl = window()
    let unrelated = window()
    player.addChildWindow(settings, ordered: .above)
    settings.addChildWindow(nestedControl, ordered: .above)
    defer {
      settings.removeChildWindow(nestedControl)
      if settings.parent === player { player.removeChildWindow(settings) }
      [nestedControl, settings, unrelated, player].forEach { $0.orderOut(nil); $0.close() }
    }

    #expect(!VideoFullScreenController.shouldPauseForFocusChange(isAppActive: true,
      keyWindow: player, playerWindow: player))
    #expect(!VideoFullScreenController.shouldPauseForFocusChange(isAppActive: true,
      keyWindow: settings, playerWindow: player))
    #expect(!VideoFullScreenController.shouldPauseForFocusChange(isAppActive: true,
      keyWindow: nestedControl, playerWindow: player))
    #expect(VideoFullScreenController.shouldPauseForFocusChange(isAppActive: true,
      keyWindow: unrelated, playerWindow: player))
    #expect(VideoFullScreenController.shouldPauseForFocusChange(isAppActive: true,
      keyWindow: nil, playerWindow: player))
    #expect(VideoFullScreenController.shouldPauseForFocusChange(isAppActive: false,
      keyWindow: settings, playerWindow: player))

    // Once a settings window no longer belongs to the player, it must not keep
    // hidden playback alive merely because it used to be an owned control.
    player.removeChildWindow(settings)
    #expect(VideoFullScreenController.shouldPauseForFocusChange(isAppActive: true,
      keyWindow: nestedControl, playerWindow: player))
  }

  private func window() -> NSWindow {
    let result = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 100, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    result.isReleasedWhenClosed = false
    return result
  }
}
