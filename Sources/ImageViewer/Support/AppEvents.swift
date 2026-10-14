import AppKit
import SwiftUI

/// Finder의 “다음으로 열기”와 파일 더블클릭을 SwiftUI 화면으로 전달합니다.
@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, ObservableObject {
  let appearance = AppearanceStore()
  private var pendingOpenURLs: [URL] = []
  private var openHandler: (@MainActor ([URL]) -> Void)?

  func applicationWillFinishLaunching(_ notification: Notification) {
    appearance.apply(to: NSApplication.shared)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NativeMenuLocalization.startObserving()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    guard !urls.isEmpty else { return }
    if let openHandler { openHandler(urls) }
    else { pendingOpenURLs.append(contentsOf: urls) }
  }

  /// Finder can deliver URLs before SwiftUI has installed the root view. Keep
  /// those requests together until the app's store is ready to receive them.
  func attachOpenHandler(_ handler: @escaping @MainActor ([URL]) -> Void) {
    openHandler = handler
    let urls = pendingOpenURLs
    pendingOpenURLs.removeAll()
    if !urls.isEmpty { handler(urls) }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}

/// Space is a tap only until a pointer gesture or another key uses it. Waiting
/// until key-up lets the same key remain a modifier for Space + drag panning.
struct SpaceTapState {
  private(set) var isPending = false
  private var wasUsed = false

  mutating func begin(isRepeat: Bool) {
    guard !isRepeat else { return }
    isPending = true
    wasUsed = false
  }

  mutating func useForGesture() { if isPending { wasUsed = true } }

  mutating func end() -> Bool {
    let isTap = isPending && !wasUsed
    reset()
    return isTap
  }

  mutating func reset() { isPending = false; wasUsed = false }
}

/// 동적으로 바뀌는 단축키와 트랙패드·보조 마우스 입력을 AppKit 이벤트에서 받습니다.
struct InputEventMonitor: NSViewRepresentable {
  let onKeyDown: @MainActor (NSEvent) -> Bool
  let onPointerPan: @MainActor (PanInputKind, CGSize) -> Bool
  let onHorizontalSwipe: @MainActor (CGFloat) -> Void
  var canHandleSpaceTap: @MainActor () -> Bool = { false }
  var onSpaceTap: @MainActor () -> Void = {}

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onKeyDown: onKeyDown,
      onPointerPan: onPointerPan,
      onHorizontalSwipe: onHorizontalSwipe,
      canHandleSpaceTap: canHandleSpaceTap,
      onSpaceTap: onSpaceTap
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
    context.coordinator.canHandleSpaceTap = canHandleSpaceTap
    context.coordinator.onSpaceTap = onSpaceTap
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
    var canHandleSpaceTap: @MainActor () -> Bool
    var onSpaceTap: @MainActor () -> Void
    private var keyMonitor: Any?
    private var dragMonitor: Any?
    private var scrollMonitor: Any?
    private var accumulatedHorizontalDelta: CGFloat = 0
    private var swipeTriggered = false
    private var isSpacePressed = false
    private var spaceTap = SpaceTapState()
    private var resignObserver: NSObjectProtocol?

    init(
      onKeyDown: @escaping @MainActor (NSEvent) -> Bool,
      onPointerPan: @escaping @MainActor (PanInputKind, CGSize) -> Bool,
      onHorizontalSwipe: @escaping @MainActor (CGFloat) -> Void,
      canHandleSpaceTap: @escaping @MainActor () -> Bool = { false },
      onSpaceTap: @escaping @MainActor () -> Void = {}
    ) {
      self.onKeyDown = onKeyDown
      self.onPointerPan = onPointerPan
      self.onHorizontalSwipe = onHorizontalSwipe
      self.canHandleSpaceTap = canHandleSpaceTap
      self.onSpaceTap = onSpaceTap
      resignObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.resetSpaceInput() }
      }

      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
        [weak self] event in
        guard let self else { return event }
        guard belongsToMonitoredWindow(event) else { return event }

        let responder = NSApp.keyWindow?.firstResponder
        return handleKey(event, isTextInput: responder is NSTextView,
          isControl: responder is NSControl) ? nil : event
      }

      dragMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown,
          .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
      ) { [weak self] event in
        guard let self, belongsToMonitoredWindow(event) else { return event }
        if isSpacePressed { spaceTap.useForGesture() }
        guard [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type),
          contains(event) else { return event }
        return observeDrag(event) ? nil : event
      }

      scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
        [weak self] event in
        guard let self else { return event }
        guard contains(event) else { return event }
        if isSpacePressed { spaceTap.useForGesture() }
        return observeScroll(event) ? nil : event
      }
    }

    func handleKey(_ event: NSEvent, isTextInput: Bool, isControl: Bool = false) -> Bool {
      let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
      if event.keyCode == 49 {
        isSpacePressed = event.type == .keyDown
        if isTextInput || isControl {
          spaceTap.reset()
          return false
        }
        if event.type == .keyUp {
          let consumed = spaceTap.isPending
          let tapped = spaceTap.end()
          if tapped, plain, canHandleSpaceTap() { onSpaceTap() }
          return consumed
        }
        if plain, canHandleSpaceTap() {
          spaceTap.begin(isRepeat: event.isARepeat)
          return true
        }
        spaceTap.reset()
      } else if event.type == .keyDown {
        spaceTap.useForGesture()
      }
      guard event.type == .keyDown, !isTextInput else { return false }
      return onKeyDown(event)
    }

    private func resetSpaceInput() { isSpacePressed = false; spaceTap.reset() }

    func stopMonitoring() {
      resetSpaceInput()
      if let resignObserver {
        NotificationCenter.default.removeObserver(resignObserver)
        self.resignObserver = nil
      }
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
