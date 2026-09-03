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

/// 동적으로 바뀌는 단축키와 트랙패드 가로 스와이프를 AppKit 이벤트에서 받습니다.
struct InputEventMonitor: NSViewRepresentable {
  let onKeyDown: @MainActor (NSEvent) -> Bool
  let onHorizontalSwipe: @MainActor (CGFloat) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onKeyDown: onKeyDown, onHorizontalSwipe: onHorizontalSwipe)
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    view.isHidden = true
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.onKeyDown = onKeyDown
    context.coordinator.onHorizontalSwipe = onHorizontalSwipe
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.stopMonitoring()
  }

  @MainActor
  final class Coordinator {
    var onKeyDown: @MainActor (NSEvent) -> Bool
    var onHorizontalSwipe: @MainActor (CGFloat) -> Void
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var accumulatedHorizontalDelta: CGFloat = 0
    private var swipeTriggered = false

    init(
      onKeyDown: @escaping @MainActor (NSEvent) -> Bool,
      onHorizontalSwipe: @escaping @MainActor (CGFloat) -> Void
    ) {
      self.onKeyDown = onKeyDown
      self.onHorizontalSwipe = onHorizontalSwipe

      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else { return event }

        // 설정의 Picker나 다른 텍스트 입력 중에는 일반 타이핑을 가로채지 않습니다.
        if NSApp.keyWindow?.firstResponder is NSTextView {
          return event
        }
        return self.onKeyDown(event) ? nil : event
      }

      scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
        [weak self] event in
        self?.observeScroll(event)
        return event
      }
    }

    func stopMonitoring() {
      if let keyMonitor {
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
      }
      if let scrollMonitor {
        NSEvent.removeMonitor(scrollMonitor)
        self.scrollMonitor = nil
      }
    }

    private func observeScroll(_ event: NSEvent) {
      guard event.hasPreciseScrollingDeltas,
        abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.35
      else {
        return
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
    }
  }
}
