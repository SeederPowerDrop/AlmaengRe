import AVKit
import SwiftUI

/// Use AppKit's player directly. The SwiftUI AVKit overlay can fail while
/// instantiating its generic NSView subclass on supported older macOS releases.
struct NativeVideoPlayerView: NSViewRepresentable {
  let player: AVPlayer
  var isInteractive = true
  var onDoubleClick: (() -> Void)? = nil
  var showsFullScreenToggleButton = true
  var keepsControlsVisibleWhenInactive = false

  func makeNSView(context: Context) -> PlayerView {
    let view = PlayerView()
    view.videoGravity = .resizeAspect
    view.allowsVideoFrameAnalysis = false
    view.allowsPictureInPicturePlayback = false
    view.updatesNowPlayingInfoCenter = false
    view.player = player
    view.onDoubleClick = onDoubleClick
    return view
  }

  func updateNSView(_ view: PlayerView, context: Context) {
    if view.player !== player { view.player = player }
    view.isInteractive = isInteractive
    view.onDoubleClick = onDoubleClick
    let controlsStyle: AVPlayerViewControlsStyle =
      isInteractive || keepsControlsVisibleWhenInactive ? .inline : .none
    if view.controlsStyle != controlsStyle { view.controlsStyle = controlsStyle }
    if view.showsFullScreenToggleButton != showsFullScreenToggleButton {
      view.showsFullScreenToggleButton = showsFullScreenToggleButton
    }
  }

  static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
    view.player?.pause()
    view.player = nil
    view.onDoubleClick = nil
    view.removeDoubleClickMonitor()
  }

  final class PlayerView: AVPlayerView {
    var isInteractive = true
    var onDoubleClick: (() -> Void)?
    private var doubleClickMonitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      removeDoubleClickMonitor()
      guard window != nil else { return }
      doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
        guard let self, let action = self.onDoubleClick,
          event.window === self.window, event.clickCount == 2 else { return event }
        let point = self.convert(event.locationInWindow, from: nil)
        guard self.bounds.contains(point) else { return event }
        // Let native sliders and buttons keep their own double-click behavior.
        guard !self.isOverNativeControl(event.locationInWindow) else { return event }
        action()
        return nil
      }
    }

    func removeDoubleClickMonitor() {
      if let doubleClickMonitor { NSEvent.removeMonitor(doubleClickMonitor) }
      doubleClickMonitor = nil
    }

    private func isOverNativeControl(_ windowPoint: NSPoint) -> Bool {
      let point = superview?.convert(windowPoint, from: nil) ?? windowPoint
      var target = super.hitTest(point)
      while let view = target, view !== self {
        if view is NSControl { return true }
        target = view.superview
      }
      return false
    }

    override var acceptsFirstResponder: Bool { isInteractive && super.acceptsFirstResponder }
    override func hitTest(_ point: NSPoint) -> NSView? {
      isInteractive ? super.hitTest(point) : nil
    }
  }
}
