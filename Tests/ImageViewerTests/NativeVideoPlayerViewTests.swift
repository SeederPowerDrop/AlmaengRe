import AppKit
import AVKit
import SwiftUI
import Testing

@testable import ImageViewer

/// Exercise the real SwiftUI-to-AppKit bridge: constructing an AVPlayer alone
/// does not catch the AVKit SwiftUI metadata crash seen on macOS 15.7.5.
@Suite("네이티브 영상 플레이어의 SwiftUI 호스팅", .serialized)
@MainActor
struct NativeVideoPlayerViewTests {
  @Test("첫 프레임을 기다리는 플레이어는 검은 로딩 화면으로 미리보기를 가리지 않는다")
  func unreadyVideoSurfaceKeepsPosterVisible() async throws {
    _ = NSApplication.shared
    let player = AVPlayer()
    let host = NSHostingView(rootView: NativeVideoPlayerView(player: player,
      waitsForFirstVideoFrame: true))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 480, height: 270),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    try await waitUntil { host.layoutSubtreeIfNeeded(); return playerViews(in: host).count == 1 }
    let view = try #require(playerViews(in: host).first)
    #expect(!view.isReadyForDisplay && view.alphaValue == 0)
    // Audio uses the same bridge, but has no video frame to wait for.
    host.rootView = NativeVideoPlayerView(player: player)
    try await waitUntil { view.alphaValue == 1 }
    host.rootView = NativeVideoPlayerView(player: player, waitsForFirstVideoFrame: true)
    try await waitUntil { view.alphaValue == 0 }
    #expect(playerViews(in: host).first === view)
    NativeVideoPlayerView.dismantleNSView(view, coordinator: ())
    #expect(view.player == nil)
  }

  @Test("호스팅·플레이어 교체·입력 비활성화·해제가 네이티브 AVPlayerView로 이어진다")
  func hostsUpdatesAndDismantlesNativePlayer() async throws {
    _ = NSApplication.shared
    let firstPlayer = AVPlayer()
    let host = NSHostingView(rootView: NativeVideoPlayerView(player: firstPlayer))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 480, height: 270),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }

    try await waitUntil {
      host.layoutSubtreeIfNeeded()
      return playerViews(in: host).count == 1
    }
    let view = try #require(playerViews(in: host).first)
    #expect(view.player === firstPlayer)
    #expect(view.bounds.width > 0 && view.bounds.height > 0)
    #expect(view.isInteractive && view.controlsStyle == .inline)
    #expect(view.videoGravity == .resizeAspect)
    #expect(!view.allowsVideoFrameAnalysis && !view.allowsPictureInPicturePlayback)
    #expect(!view.updatesNowPlayingInfoCenter)

    let replacementPlayer = AVPlayer()
    host.rootView = NativeVideoPlayerView(player: replacementPlayer, isInteractive: false)
    try await waitUntil {
      host.layoutSubtreeIfNeeded()
      return view.player === replacementPlayer && !view.isInteractive
        && view.controlsStyle == .none
    }
    #expect(playerViews(in: host).count == 1)
    #expect(playerViews(in: host).first === view)
    #expect(!view.acceptsFirstResponder)
    #expect(view.hitTest(NSPoint(x: view.frame.midX, y: view.frame.midY)) == nil)

    host.rootView = NativeVideoPlayerView(player: replacementPlayer, isInteractive: true)
    try await waitUntil {
      host.layoutSubtreeIfNeeded()
      return view.isInteractive && view.controlsStyle == .inline
    }

    // Invoke the representable's teardown contract on the hosted native view.
    // This checks cleanup without relying on SwiftUI's deferred host release.
    replacementPlayer.play()
    NativeVideoPlayerView.dismantleNSView(view, coordinator: ())
    #expect(view.player == nil)
    #expect(replacementPlayer.rate == 0)
  }

  private func playerViews(in view: NSView) -> [NativeVideoPlayerView.PlayerView] {
    if let player = view as? NativeVideoPlayerView.PlayerView { return [player] }
    return view.subviews.flatMap { playerViews(in: $0) }
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(predicate(), "The hosted AVPlayerView did not reach the expected state")
  }
}
