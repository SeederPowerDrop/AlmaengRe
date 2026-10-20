import AppKit
import SwiftUI
import Testing

@testable import ImageViewer

@Suite("몽땅보기 native 이동과 현재 카드 정밀 보완", .serialized)
@MainActor
struct OverviewScrollMotionTests {
  private enum Deadline: Error { case exceeded }

  private struct Harness: View {
    let gate: OverviewRefinementGate
    var body: some View {
      ScrollView {
        VStack(spacing: 0) {
          ForEach(0..<100, id: \.self) { _ in Color.blue.frame(height: 30) }
        }
        .background(alignment: .topLeading) {
          OverviewScrollMotionObserver(gate: gate).frame(width: 0, height: 0)
        }
      }
    }
  }

  @Test("Geometry preference 없이 clip 이동과 live gesture가 보완을 막고 끝난 뒤 현재 카드만 허용한다")
  func nativeNotificationsDriveCurrentVisibleAdmission() async throws {
    let gate = OverviewRefinementGate(quietInterval: .milliseconds(80), requiresVisibleMembership: true)
    let first = URL(fileURLWithPath: "/tmp/overview-motion-first.png")
    let second = URL(fileURLWithPath: "/tmp/overview-motion-second.png")
    gate.updateVisibleAssets([first])
    #expect(gate.allowsRefinement(for: first))
    #expect(!gate.allowsRefinement(for: second))
    let scroll = makeScroll()
    let observer = OverviewScrollMotionView(frame: .zero)
    observer.gate = gate
    observer.observe(scroll)
    defer { observer.stopObserving(); gate.stop() }
    let oldGeneration = gate.motionGeneration
    scroll.contentView.scroll(to: CGPoint(x: 0, y: 100))
    #expect(gate.isDeferring)
    #expect(!gate.allowsRefinement(since: oldGeneration))
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    gate.updateVisibleAssets([second])
    try await Task.sleep(for: .milliseconds(120))
    #expect(gate.isDeferring, "A live gesture remains deferred through a short pause")
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    try await wait { !gate.isDeferring }
    #expect(gate.allowsRefinement(for: second))
    #expect(!gate.allowsRefinement(for: first), "A retained offscreen card must not start precise work")
  }

  @Test("초기 update에서 scroll이 없어도 나중에 document에 붙으면 native 이동을 관찰한다")
  func attachmentAfterInitialMissingAncestorStartsObservation() throws {
    let gate = OverviewRefinementGate()
    let observer = OverviewScrollMotionView(frame: .zero)
    observer.gate = gate
    observer.observeEnclosingScrollView()
    let scroll = makeScroll()
    let document = try #require(scroll.documentView)
    document.addSubview(observer)
    defer { observer.stopObserving(); gate.stop() }
    scroll.contentView.scroll(to: CGPoint(x: 0, y: 120))
    #expect(gate.isDeferring)
    let generation = gate.motionGeneration
    observer.stopObserving()
    scroll.contentView.scroll(to: CGPoint(x: 0, y: 240))
    #expect(gate.motionGeneration == generation, "A detached observer must stop receiving bounds notifications")
  }

  @Test("live gesture 도중 호스트가 바뀌어도 이전 종료 알림 없이 새 viewport의 보완이 재개된다")
  func reparentingDoesNotLeaveLiveGesturePermanentlyDeferred() async throws {
    let gate = OverviewRefinementGate(quietInterval: .milliseconds(60))
    let first = makeScroll()
    let second = makeScroll()
    let observer = OverviewScrollMotionView(frame: .zero)
    observer.gate = gate
    observer.observe(first)
    defer { observer.stopObserving(); gate.stop() }
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: first)
    #expect(gate.isDeferring)
    observer.observe(second)
    second.contentView.scroll(to: CGPoint(x: 0, y: 150))
    try await wait { !gate.isDeferring }
    #expect(gate.allowsRefinement(since: gate.motionGeneration))
  }

  @Test("실제 NSHostingView ScrollView에 생성된 단일 observer가 native clip 변경을 연결한다")
  func hostingBridgeBindsAfterSwiftUIAttachment() async throws {
    _ = NSApplication.shared
    let gate = OverviewRefinementGate(quietInterval: .milliseconds(100), observesWindowVisibility: false)
    let host = NSHostingView(rootView: Harness(gate: gate))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 340, height: 300),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer {
      window.orderOut(nil); window.contentView = nil; window.close()
      gate.stop()
    }
    try await wait {
      host.layoutSubtreeIfNeeded()
      return self.descendants(of: OverviewScrollMotionView.self, in: host).count == 1
        && self.descendants(of: NSScrollView.self, in: host).first?.documentView != nil
    }
    let scroll = try #require(descendants(of: NSScrollView.self, in: host).first)
    let document = try #require(scroll.documentView)
    let current = scroll.contentView.bounds.origin.y
    let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
    try #require(maximum > 200)
    let target = current < maximum * 0.5 ? current + 100 : current - 100
    scroll.contentView.scroll(to: CGPoint(x: 0, y: target))
    scroll.reflectScrolledClipView(scroll.contentView)
    #expect(gate.isDeferring)
    try await wait { !gate.isDeferring }
  }

  @Test("완전히 가려진 비활성 창만 정밀 작업을 연기하고 일부 노출·앱 복귀 뒤 quiet 후 재개한다")
  func fullyOccludedInactiveWindowDefersOnlyPreciseWork() async throws {
    let gate = OverviewRefinementGate(quietInterval: .milliseconds(80), requiresVisibleMembership: true)
    defer { gate.stop() }
    let asset = URL(fileURLWithPath: "/tmp/overview-window-visibility.png")
    gate.updateVisibleAssets([asset])
    let initialGeneration = gate.motionGeneration
    gate.windowVisibilityChanged(isApplicationActive: false, isWindowVisible: false)
    #expect(gate.isDeferring)
    #expect(!gate.allowsRefinement(for: asset))
    #expect(!gate.allowsRefinement(for: asset, since: initialGeneration))
    try await Task.sleep(for: .milliseconds(120))
    #expect(gate.isDeferring, "An occluded window stays deferred even after scrolling has been quiet")
    gate.windowVisibilityChanged(isApplicationActive: false, isWindowVisible: true)
    #expect(gate.isDeferring, "A newly exposed window first waits for stable visibility")
    try await wait { gate.allowsRefinement(for: asset) }
    gate.windowVisibilityChanged(isApplicationActive: false, isWindowVisible: false)
    #expect(!gate.allowsRefinement(for: asset))
    gate.windowVisibilityChanged(isApplicationActive: true, isWindowVisible: false)
    #expect(gate.isDeferring)
    try await wait { gate.allowsRefinement(for: asset) }
    gate.liveScrollBegan()
    gate.windowVisibilityChanged(isApplicationActive: false, isWindowVisible: false)
    gate.windowVisibilityChanged(isApplicationActive: true, isWindowVisible: true)
    try await Task.sleep(for: .milliseconds(120))
    #expect(gate.isDeferring, "Returning during a live gesture never admits precision early")
    gate.liveScrollEnded()
    try await wait { gate.allowsRefinement(for: asset) }
  }

  @Test("native 창 가림 알림은 해당 overview gate에만 연결되고 분리하면 관찰을 중단한다")
  func nativeWindowOcclusionBridgeUsesOwnWindow() async throws {
    _ = NSApplication.shared
    let gate = OverviewRefinementGate(quietInterval: .milliseconds(60))
    let observer = OverviewScrollMotionView(frame: .zero)
    observer.gate = gate
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 340, height: 300),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = observer
    window.orderBack(nil)
    defer {
      observer.stopObservingWindowVisibility()
      window.orderOut(nil); window.contentView = nil; window.close(); gate.stop()
    }
    observer.observeWindowVisibility()
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    let suppressed = !NSApp.isActive && !window.occlusionState.contains(.visible)
    if !suppressed { try await wait { !gate.isDeferring } }
    #expect(gate.isDeferring == suppressed)
    if suppressed {
      observer.stopObservingWindowVisibility()
      gate.windowVisibilityChanged(isApplicationActive: true, isWindowVisible: true)
      try await wait { !gate.isDeferring }
      NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
      #expect(!gate.isDeferring, "A detached native observer must not suppress a reused gate")
    }
  }

  private func makeScroll() -> NSScrollView {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 300))
    scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 3_000))
    scroll.tile()
    return scroll
  }

  private func descendants<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
    (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants(of: type, in: $0) }
  }

  private func wait(until condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw Deadline.exceeded
  }
}
