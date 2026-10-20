import AppKit
import Testing

@testable import ImageViewer

@Suite("몽땅보기 native 셀 기하와 약한 registry 수명", .serialized)
@MainActor
struct OverviewNativeCellGeometryTests {
  private final class Observer: OverviewNativeCellGeometryObserver {
    var callbacks = 0
    var onChange: (() -> Void)?
    func nativeCellGeometryDidChange() { callbacks += 1; onChange?() }
  }
  private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
  }
  @MainActor
  private struct Host {
    let window: NSWindow
    let scroll: NSScrollView
    let document: NSView
    init() {
      _ = NSApplication.shared
      window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 200, height: 100),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
      scroll.borderType = .noBorder
      scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
      document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 200, height: 1_000))
      scroll.documentView = document
      window.contentView = scroll
      scroll.tile()
      window.contentView?.layoutSubtreeIfNeeded()
    }
    func close() {
      window.orderOut(nil); window.contentView = nil; window.close()
    }
  }
  private func scope(revision: UUID = UUID(), size: CGFloat = 150,
    width: CGFloat = 200, rtl: Bool = false) -> OverviewNativeCellGeometryScope {
    OverviewNativeCellGeometryScope(collectionRevision: revision, pointSize: size,
      paneWidth: width, isRightToLeft: rtl)
  }
  private func cell(_ ordinal: Int, registry: OverviewNativeCellGeometryRegistry,
    scope: OverviewNativeCellGeometryScope, frame: CGRect) -> OverviewNativeCellGeometryView {
    let view = OverviewNativeCellGeometryView(frame: frame)
    view.configure(registry: registry,
      assetID: URL(fileURLWithPath: "/synthetic-native-geometry/asset-\(ordinal).jpg"), scope: scope)
    return view
  }
  private func nextMainQueueTurn() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  @Test("실제 NSClipView의 가시 영역을 읽고 frame 변경·스크롤·숨김·분리를 반영한다")
  func nativeClippingUsesCurrentCellGeometry() async throws {
    let host = Host(); defer { host.close() }
    let registry = OverviewNativeCellGeometryRegistry(); defer { registry.stop() }
    let current = scope()
    let first = cell(0, registry: registry, scope: current,
      frame: CGRect(x: 10, y: 10, width: 100, height: 60))
    let second = cell(1, registry: registry, scope: current,
      frame: CGRect(x: 10, y: 210, width: 100, height: 60))
    host.document.addSubview(first); host.document.addSubview(second)
    #expect(registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: current) == [first.assetID!])
    host.scroll.contentView.scroll(to: CGPoint(x: 0, y: 200))
    host.scroll.reflectScrolledClipView(host.scroll.contentView)
    #expect(registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: current) == [second.assetID!])
    second.setFrameOrigin(CGPoint(x: 10, y: 410))
    #expect(registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: current).isEmpty)
    second.frame.origin.y = 210
    second.isHidden = true
    #expect(registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: current).isEmpty)
    second.isHidden = false
    #expect(registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: current) == [second.assetID!])
    second.removeFromSuperview()
    #expect(registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: current).isEmpty)
    #expect(second.hitTest(.zero) == nil)
    await nextMainQueueTurn()
  }

  @Test("현재 scope만 허용하고 collection·정확한 크기·폭·RTL 및 다른 창과 scroll을 분리한다")
  func sourceOrderAndLayoutScopesNeverLeakMembership() {
    let host = Host(); let other = Host()
    defer { host.close(); other.close() }
    let registry = OverviewNativeCellGeometryRegistry(); defer { registry.stop() }
    let current = scope()
    let view = cell(0, registry: registry, scope: current,
      frame: CGRect(x: 10, y: 10, width: 100, height: 60))
    host.document.addSubview(view)
    let variations = [scope(), scope(revision: current.collectionRevision, size: 150.25),
      scope(revision: current.collectionRevision, width: 201),
      scope(revision: current.collectionRevision, rtl: true)]
    for old in variations {
      #expect(registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: old).isEmpty)
    }
    #expect(registry.visibleAssetIDs(in: other.scroll, window: other.window, scope: current).isEmpty)
    #expect(registry.visibleAssetIDs(in: host.scroll, window: other.window, scope: current).isEmpty)
    let oldURL = view.assetID!
    let newURL = URL(fileURLWithPath: "/synthetic-native-geometry/replacement.jpg")
    let replacement = scope()
    view.configure(registry: registry, assetID: newURL, scope: replacement)
    #expect(registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: current).isEmpty)
    let visible = registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: replacement)
    #expect(visible == [newURL] && !visible.contains(oldURL))
  }

  @Test("한 native 변경 묶음은 main queue callback 한 번이며 다음 변경은 다시 한 번 전달한다")
  func changesCoalesceWithoutPerCellPublishers() async {
    let host = Host(); defer { host.close() }
    let registry = OverviewNativeCellGeometryRegistry(); defer { registry.stop() }
    let observer = Observer(); registry.observer = observer
    let current = scope()
    let first = cell(0, registry: registry, scope: current,
      frame: CGRect(x: 10, y: 10, width: 50, height: 40))
    let second = cell(1, registry: registry, scope: current,
      frame: CGRect(x: 70, y: 10, width: 50, height: 40))
    host.document.addSubview(first); host.document.addSubview(second)
    for offset in 0..<20 {
      first.setFrameOrigin(CGPoint(x: CGFloat(10 + offset), y: 10))
      second.bounds.origin.x = CGFloat(offset)
      first.layout(); second.layout()
    }
    #expect(observer.callbacks == 0)
    await nextMainQueueTurn()
    #expect(observer.callbacks == 1)
    first.setFrameSize(CGSize(width: 60, height: 45))
    first.setBoundsSize(CGSize(width: 60, height: 45))
    registry.invalidate(); registry.invalidate()
    await nextMainQueueTurn()
    #expect(observer.callbacks == 2)
  }

  @Test("ancestor만 이동해도 중앙 invalidation 뒤 snapshot은 동일한 child bounds의 실제 가시성을 읽는다")
  func ancestorMotionDoesNotReuseCachedRectangles() async {
    let host = Host(); defer { host.close() }
    let registry = OverviewNativeCellGeometryRegistry(); defer { registry.stop() }
    let observer = Observer(); registry.observer = observer
    let current = scope()
    let ancestor = FlippedDocument(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
    let child = cell(0, registry: registry, scope: current,
      frame: CGRect(x: 10, y: 10, width: 100, height: 60))
    host.document.addSubview(ancestor); ancestor.addSubview(child)
    await nextMainQueueTurn()
    let childFrame = child.frame, childBounds = child.bounds
    #expect(registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: current) == [child.assetID!])
    ancestor.setFrameOrigin(CGPoint(x: 0, y: 200))
    // The one scroll/document observer owns ancestor-only invalidation. A cell
    // is not claimed to observe arbitrary ancestor setters by itself.
    registry.invalidate()
    await nextMainQueueTurn()
    #expect(child.frame == childFrame && child.bounds == childBounds)
    #expect(registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: current).isEmpty)
    ancestor.setFrameOrigin(.zero)
    registry.invalidate()
    await nextMainQueueTurn()
    #expect(registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: current) == [child.assetID!])
  }

  @Test("약한 셀·observer는 해제를 막지 않고 snapshot이 죽은 slot을 정리한다")
  func registryAndQueuedCallbackDoNotRetainViewsOrObservers() async {
    let host = Host(); defer { host.close() }
    let registry = OverviewNativeCellGeometryRegistry(); defer { registry.stop() }
    let current = scope()
    weak var releasedView: OverviewNativeCellGeometryView?
    do {
      let view = cell(0, registry: registry, scope: current,
        frame: CGRect(x: 10, y: 10, width: 100, height: 60))
      releasedView = view
      #expect(registry.registeredSlotCount == 1)
    }
    #expect(releasedView == nil)
    #expect(registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: current).isEmpty)
    #expect(registry.registeredSlotCount == 0)
    weak var releasedObserver: Observer?
    do {
      let observer = Observer(); releasedObserver = observer
      registry.observer = observer
      registry.invalidate()
    }
    #expect(releasedObserver == nil)
    await nextMainQueueTurn()
    #expect(registry.observer == nil)
    weak var releasedRegistry: OverviewNativeCellGeometryRegistry?
    do {
      let transient = OverviewNativeCellGeometryRegistry()
      releasedRegistry = transient
      transient.invalidate()
    }
    #expect(releasedRegistry == nil)
    await nextMainQueueTurn()
  }

  @Test("stop은 이전 queued callback을 취소하고 동일 registry·scope의 생존 셀은 다시 등록된다")
  func stopAndSameConfigurationReattachmentAreGenerationSafe() async {
    let host = Host(); defer { host.close() }
    let registry = OverviewNativeCellGeometryRegistry(); defer { registry.stop() }
    let previous = Observer(); registry.observer = previous
    let current = scope()
    let view = cell(0, registry: registry, scope: current,
      frame: CGRect(x: 10, y: 10, width: 100, height: 60))
    host.document.addSubview(view)
    registry.stop()
    let replacement = Observer(); registry.observer = replacement
    view.configure(registry: registry, assetID: view.assetID!, scope: current)
    #expect(registry.registeredSlotCount == 1)
    await nextMainQueueTurn()
    #expect(previous.callbacks == 0)
    #expect(replacement.callbacks == 1)
    #expect(registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: current) == [view.assetID!])
    view.detachFromRegistry()
    #expect(registry.registeredSlotCount == 0)
    #expect(registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: current).isEmpty)
    await nextMainQueueTurn()
    #expect(replacement.callbacks == 2)
  }

  @Test("진단 모드 외에는 snapshot이 nil이고 진단 읽기는 추가 invalidation이나 시간측정을 만들지 않는다")
  func diagnosticSnapshotIsStrictlyOptInAndReadOnly() {
    let host = Host(); defer { host.close() }
    let registry = OverviewNativeCellGeometryRegistry(); defer { registry.stop() }
    let current = scope()
    let view = cell(0, registry: registry, scope: current,
      frame: CGRect(x: 10, y: 10, width: 100, height: 60))
    host.document.addSubview(view)
    _ = registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: current)
    if OverviewFocusRevealTrace.isEnabled {
      let first = registry.diagnosticSnapshot!
      let second = registry.diagnosticSnapshot!
      #expect(first["registeredCurrent"] as? UInt64 == 1)
      #expect(first["snapshotCount"] as? UInt64 == 1)
      #expect(first["snapshotCount"] as? UInt64 == second["snapshotCount"] as? UInt64)
      #expect(first["invalidationAttempts"] as? UInt64 == second["invalidationAttempts"] as? UInt64)
      #expect(first["snapshotAccumulatedNanoseconds"] as? UInt64
        == second["snapshotAccumulatedNanoseconds"] as? UInt64)
    } else {
      #expect(registry.diagnosticSnapshot == nil)
    }
  }

  @Test("단일 document frame observer가 같은 clip의 크기 변경들을 한 번의 정밀 membership 갱신으로 합친다")
  func centralDocumentFrameChangesForceOneCoalescedRefresh() async {
    let host = Host(); defer { host.close() }
    let anchor = OverviewScrollMotionView(frame: CGRect(x: 0, y: 0, width: 200, height: 0))
    var callbacks = 0
    anchor.onViewportChange = { _ in callbacks += 1 }
    host.document.addSubview(anchor)
    anchor.observe(host.scroll)
    defer { anchor.stopObserving() }
    await nextMainQueueTurn()
    let baseline = callbacks
    let clip = host.scroll.contentView.bounds
    for height in [1_100.0, 1_200.0, 1_300.0] {
      host.document.setFrameSize(CGSize(width: 200, height: height))
    }
    #expect(host.scroll.contentView.bounds == clip)
    #expect(callbacks == baseline)
    await nextMainQueueTurn()
    #expect(callbacks == baseline + 1,
      "Unchanged clip geometry still forces one membership snapshot after document layout")
  }

  @Test("clip을 교체하지 않고 document만 바꾸면 이전 문서 관찰을 해제하고 새 문서 변경만 갱신한다")
  func centralObserverFollowsDocumentReplacementOnSameClip() async {
    let host = Host(); defer { host.close() }
    let anchor = OverviewScrollMotionView(frame: CGRect(x: 0, y: 0, width: 200, height: 0))
    var callbacks = 0
    anchor.onViewportChange = { _ in callbacks += 1 }
    host.document.addSubview(anchor)
    anchor.observe(host.scroll)
    defer { anchor.stopObserving() }
    await nextMainQueueTurn()
    let clip = host.scroll.contentView
    let replacement = FlippedDocument(frame: CGRect(x: 0, y: 0, width: 200, height: 1_500))
    host.scroll.documentView = replacement
    replacement.addSubview(anchor)
    anchor.observe(host.scroll)
    await nextMainQueueTurn()
    #expect(host.scroll.contentView === clip)
    let baseline = callbacks
    host.document.setFrameSize(CGSize(width: 200, height: 1_700))
    await nextMainQueueTurn()
    #expect(callbacks == baseline, "The retired document must no longer schedule a refresh")
    replacement.setFrameSize(CGSize(width: 200, height: 1_800))
    await nextMainQueueTurn()
    #expect(callbacks == baseline + 1)
    #expect(anchor.currentViewportGeometry() != nil)
  }

  @Test("중앙 observer 중단은 queued refresh를 무효화하고 이전 객체의 해제가 새 registry observer를 지우지 않는다")
  func centralObserverStopDoesNotClearReplacementObserver() async {
    let host = Host(); defer { host.close() }
    let registry = OverviewNativeCellGeometryRegistry(); defer { registry.stop() }
    let old = OverviewScrollMotionView(frame: CGRect(x: 0, y: 0, width: 200, height: 0))
    old.cellGeometryRegistry = registry
    var oldCallbacks = 0
    old.onViewportChange = { _ in oldCallbacks += 1 }
    host.document.addSubview(old); old.observe(host.scroll)
    await nextMainQueueTurn(); await nextMainQueueTurn()
    let previous = oldCallbacks
    old.nativeCellGeometryDidChange()
    old.stopObserving()
    let replacement = OverviewScrollMotionView(frame: CGRect(x: 0, y: 0, width: 200, height: 0))
    replacement.cellGeometryRegistry = registry
    var replacementCallbacks = 0
    replacement.onViewportChange = { _ in replacementCallbacks += 1 }
    host.document.addSubview(replacement); replacement.observe(host.scroll)
    old.stopObserving(); old.removeFromSuperview()
    defer { replacement.stopObserving() }
    await nextMainQueueTurn(); await nextMainQueueTurn()
    #expect(oldCallbacks == previous)
    #expect(registry.observer === replacement)
    #expect(replacementCallbacks > 0)
  }

  @Test("native clip 경계에 닿기만 한 셀은 제외하고 양의 면적이 실제 겹치는 셀만 허용한다")
  func explicitClipIntersectionRequiresPositiveArea() {
    let host = Host(); defer { host.close() }
    let registry = OverviewNativeCellGeometryRegistry(); defer { registry.stop() }
    let current = scope()
    let view = cell(0, registry: registry, scope: current,
      frame: CGRect(x: 10, y: 10, width: 100, height: 60))
    host.document.addSubview(view)
    let clip = host.scroll.contentView.bounds
    view.frame = CGRect(x: clip.maxX, y: 10, width: 100, height: 60)
    #expect(registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: current).isEmpty)
    view.frame.origin.x = clip.maxX - 1
    #expect(registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: current) == [view.assetID!])
    view.frame = CGRect(x: 10, y: clip.maxY, width: 100, height: 60)
    #expect(registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: current).isEmpty)
    view.frame.origin.y = clip.maxY - 1
    #expect(registry.visibleAssetIDs(in: host.scroll, window: host.window, scope: current) == [view.assetID!])
  }

  @Test("공유 gate의 같은 clip에 새 observer가 붙은 뒤 이전 observer 중단은 새 live gesture를 끝내지 않는다")
  func retiredObserverCannotClearNewSharedGateOrEndItsLiveGesture() async throws {
    let host = Host(); defer { host.close() }
    let registry = OverviewNativeCellGeometryRegistry(); defer { registry.stop() }
    let gate = OverviewRefinementGate(quietInterval: .milliseconds(60), observesWindowVisibility: false)
    defer { gate.stop() }
    let old = OverviewScrollMotionView(frame: CGRect(x: 0, y: 0, width: 200, height: 0))
    old.gate = gate; old.cellGeometryRegistry = registry
    host.document.addSubview(old); old.observe(host.scroll)
    await nextMainQueueTurn(); await nextMainQueueTurn()
    let replacement = OverviewScrollMotionView(frame: CGRect(x: 0, y: 0, width: 200, height: 0))
    replacement.gate = gate; replacement.cellGeometryRegistry = registry
    host.document.addSubview(replacement); replacement.observe(host.scroll)
    defer { old.stopObserving(); replacement.stopObserving() }
    await nextMainQueueTurn(); await nextMainQueueTurn()
    #expect(gate.nativeScrollView === host.scroll)
    #expect(gate.nativeContentAnchor === replacement)
    #expect(registry.observer === replacement)
    gate.liveScrollBegan()
    old.stopObserving()
    #expect(gate.nativeScrollView === host.scroll)
    #expect(gate.nativeContentAnchor === replacement)
    #expect(registry.observer === replacement)
    // This exceeds the quiet interval. The retired observer must not schedule
    // liveScrollEnded on the shared gate while the replacement still gestures.
    try await Task.sleep(for: .milliseconds(150))
    #expect(gate.isDeferring)
    // Retired callbacks must not reclaim the registry or mutate new admission.
    old.refreshViewportGeometry(forceMembership: true)
    #expect(gate.nativeContentAnchor === replacement)
    #expect(registry.observer === replacement)
    old.stopObserving()
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification,
      object: host.scroll)
    let deadline = ContinuousClock.now + .seconds(1)
    while gate.isDeferring && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!gate.isDeferring)
  }

  @Test("실제 bitmap 진단 probe도 같은 native clip 교차를 사용해 viewport 밖 이미지를 제외한다")
  func bitmapDiagnosticProbeExcludesCellsOutsideNativeClip() {
    let host = Host(); defer { host.close() }
    let first = OverviewBitmapProbeView(frame: CGRect(x: 10, y: 10, width: 100, height: 60))
    let second = OverviewBitmapProbeView(frame: CGRect(x: 10, y: 210, width: 100, height: 60))
    let firstURL = URL(fileURLWithPath: "/synthetic-native-geometry/bitmap-first.jpg")
    let secondURL = URL(fileURLWithPath: "/synthetic-native-geometry/bitmap-second.jpg")
    first.value = OverviewBitmapProbeSample(instance: first.instance, assetURL: firstURL,
      byteCount: 1, modificationDate: nil, hasBitmap: true, pixelWidth: 256, pixelHeight: 192)
    second.value = OverviewBitmapProbeSample(instance: second.instance, assetURL: secondURL,
      byteCount: 1, modificationDate: nil, hasBitmap: true, pixelWidth: 256, pixelHeight: 192)
    OverviewBitmapProbeRegistry.register(first); OverviewBitmapProbeRegistry.register(second)
    defer { OverviewBitmapProbeRegistry.remove(first); OverviewBitmapProbeRegistry.remove(second) }
    host.document.addSubview(first); host.document.addSubview(second)
    #expect(Set(OverviewBitmapProbeRegistry.visible(in: host.scroll, window: host.window).map(\.assetURL)) == [firstURL])
    host.scroll.contentView.scroll(to: CGPoint(x: 0, y: 200))
    host.scroll.reflectScrolledClipView(host.scroll.contentView)
    #expect(Set(OverviewBitmapProbeRegistry.visible(in: host.scroll, window: host.window).map(\.assetURL)) == [secondURL])
  }

  @Test("이전 창의 별도 scroll에 남은 live 알림은 현재 창의 공유 gate를 시작하거나 끝내지 않는다")
  func retiredDifferentScrollNotificationsCannotMutateNewLiveGesture() async throws {
    let previousHost = Host(); let currentHost = Host()
    defer { previousHost.close(); currentHost.close() }
    let gate = OverviewRefinementGate(quietInterval: .milliseconds(60), observesWindowVisibility: false)
    defer { gate.stop() }
    let old = OverviewScrollMotionView(frame: CGRect(x: 0, y: 0, width: 200, height: 0))
    old.gate = gate
    previousHost.document.addSubview(old); old.observe(previousHost.scroll)
    let replacement = OverviewScrollMotionView(frame: CGRect(x: 0, y: 0, width: 200, height: 0))
    replacement.gate = gate
    currentHost.document.addSubview(replacement); replacement.observe(currentHost.scroll)
    defer { old.stopObserving(); replacement.stopObserving() }
    await nextMainQueueTurn(); await nextMainQueueTurn()
    #expect(old.window === previousHost.window)
    #expect(replacement.window === currentHost.window)
    #expect(gate.nativeScrollView === currentHost.scroll)
    #expect(gate.nativeContentAnchor === replacement)
    gate.liveScrollBegan()
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification,
      object: previousHost.scroll)
    try await Task.sleep(for: .milliseconds(150))
    #expect(gate.isDeferring,
      "A retired scroll's didEnd must not quiet the replacement's ongoing gesture")
    #expect(gate.nativeScrollView === currentHost.scroll)
    #expect(gate.nativeContentAnchor === replacement)
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification,
      object: currentHost.scroll)
    let deadline = ContinuousClock.now + .seconds(1)
    while gate.isDeferring && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!gate.isDeferring)
    let generation = gate.motionGeneration
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification,
      object: previousHost.scroll)
    await nextMainQueueTurn()
    #expect(gate.motionGeneration == generation,
      "A retired scroll's willStart must not change the replacement's motion generation")
    #expect(!gate.isDeferring)
    #expect(gate.nativeScrollView === currentHost.scroll)
    #expect(gate.nativeContentAnchor === replacement)
  }
}
