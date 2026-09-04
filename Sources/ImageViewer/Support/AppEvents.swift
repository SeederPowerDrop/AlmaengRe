import AppKit
import SwiftUI

extension Notification.Name {
  static let imageViewerOpenURLs = Notification.Name("ImageViewer.OpenURLs")
}

/// Finder의 “다음으로 열기”와 파일 더블클릭을 SwiftUI 화면으로 전달합니다.
@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
  func application(_ application: NSApplication, open urls: [URL]) {
    NotificationCenter.default.post(name: .imageViewerOpenURLs, object: urls)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}

/// 동적으로 바뀌는 단축키와 트랙패드·보조 마우스 입력을 AppKit 이벤트에서 받습니다.
struct InputEventMonitor: NSViewRepresentable {
  let onKeyDown: @MainActor (NSEvent) -> Bool
  let onPointerPan: @MainActor (PanInputKind, CGSize) -> Bool
  let onHorizontalSwipe: @MainActor (CGFloat) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onKeyDown: onKeyDown,
      onPointerPan: onPointerPan,
      onHorizontalSwipe: onHorizontalSwipe
    )
  }

  func makeNSView(context: Context) -> NSView {
    let view = InputEventRegionView(frame: .zero)
    context.coordinator.hostView = view
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.hostView = nsView
    context.coordinator.onKeyDown = onKeyDown
    context.coordinator.onPointerPan = onPointerPan
    context.coordinator.onHorizontalSwipe = onHorizontalSwipe
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.hostView = nil
    coordinator.stopMonitoring()
  }

  @MainActor
  final class Coordinator {
    weak var hostView: NSView?
    var onKeyDown: @MainActor (NSEvent) -> Bool
    var onPointerPan: @MainActor (PanInputKind, CGSize) -> Bool
    var onHorizontalSwipe: @MainActor (CGFloat) -> Void
    private var keyMonitor: Any?
    private var dragMonitor: Any?
    private var scrollMonitor: Any?
    private var accumulatedHorizontalDelta: CGFloat = 0
    private var swipeTriggered = false
    private var isSpacePressed = false

    init(
      onKeyDown: @escaping @MainActor (NSEvent) -> Bool,
      onPointerPan: @escaping @MainActor (PanInputKind, CGSize) -> Bool,
      onHorizontalSwipe: @escaping @MainActor (CGFloat) -> Void
    ) {
      self.onKeyDown = onKeyDown
      self.onPointerPan = onPointerPan
      self.onHorizontalSwipe = onHorizontalSwipe

      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
        [weak self] event in
        guard let self else { return event }
        guard belongsToMonitoredWindow(event) else { return event }

        if event.keyCode == 49 {
          isSpacePressed = event.type == .keyDown
        }
        guard event.type == .keyDown else { return event }

        // 설정의 Picker나 다른 텍스트 입력 중에는 일반 타이핑을 가로채지 않습니다.
        if NSApp.keyWindow?.firstResponder is NSTextView {
          return event
        }
        return self.onKeyDown(event) ? nil : event
      }

      dragMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
      ) { [weak self] event in
        guard let self else { return event }
        guard contains(event) else { return event }
        return observeDrag(event) ? nil : event
      }

      scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
        [weak self] event in
        guard let self else { return event }
        guard contains(event) else { return event }
        return observeScroll(event) ? nil : event
      }
    }

    func stopMonitoring() {
      if let keyMonitor {
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
      }
      if let dragMonitor {
        NSEvent.removeMonitor(dragMonitor)
        self.dragMonitor = nil
      }
      if let scrollMonitor {
        NSEvent.removeMonitor(scrollMonitor)
        self.scrollMonitor = nil
      }
    }

    private func observeDrag(_ event: NSEvent) -> Bool {
      let input: PanInputKind
      switch event.buttonNumber {
      case 0 where isSpacePressed:
        input = .spacePrimaryDrag
      case 1:
        input = .secondaryDrag
      case 2:
        input = .middleDrag
      default:
        return false
      }

      // AppKit의 Y축 델타는 SwiftUI 뷰 좌표와 반대이므로 부호를 뒤집습니다.
      let delta = CGSize(width: event.deltaX, height: -event.deltaY)
      return onPointerPan(input, delta)
    }

    private func belongsToMonitoredWindow(_ event: NSEvent) -> Bool {
      guard let monitoredWindow = hostView?.window else { return false }
      return event.window === monitoredWindow
        || (event.window == nil && NSApp.keyWindow === monitoredWindow)
    }

    private func contains(_ event: NSEvent) -> Bool {
      guard belongsToMonitoredWindow(event), let hostView else { return false }
      let localPoint = hostView.convert(event.locationInWindow, from: nil)
      return hostView.bounds.contains(localPoint)
    }

    private func observeScroll(_ event: NSEvent) -> Bool {
      guard event.hasPreciseScrollingDeltas else { return false }

      let panDelta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
      if onPointerPan(.trackpadScroll, panDelta) {
        accumulatedHorizontalDelta = 0
        swipeTriggered = false
        return true
      }

      guard
        abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.35
      else {
        return false
      }

      if event.phase.contains(.began) {
        accumulatedHorizontalDelta = 0
        swipeTriggered = false
      }

      accumulatedHorizontalDelta += event.scrollingDeltaX
      if !swipeTriggered, abs(accumulatedHorizontalDelta) >= 70 {
        swipeTriggered = true
        onHorizontalSwipe(accumulatedHorizontalDelta)
      }

      if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
        accumulatedHorizontalDelta = 0
        swipeTriggered = false
      }
      return false
    }
  }
}

/// 이벤트 영역만 제공하고 SwiftUI의 실제 버튼·제스처 hit testing은 방해하지 않습니다.
private final class InputEventRegionView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}
