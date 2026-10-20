import AppKit
import SwiftUI

/// Layout/source-order identity only. Never reset a card's bitmap State when
/// membership is measured for a different layout of the same image URL.
struct OverviewNativeCellGeometryScope: Hashable {
  let collectionRevision: UUID
  let pointSize: CGFloat
  let paneWidth: CGFloat
  let isRightToLeft: Bool
}

@MainActor
protocol OverviewNativeCellGeometryObserver: AnyObject {
  func nativeCellGeometryDidChange()
}

/// One registry belongs to one overview. Slots own neither cells nor asset URLs;
/// even views that miss dismantling are released and pruned by the next snapshot.
@MainActor
final class OverviewNativeCellGeometryRegistry {
  private final class WeakSlot {
    weak var view: OverviewNativeCellGeometryView?
    init(_ view: OverviewNativeCellGeometryView) { self.view = view }
  }

  weak var observer: (any OverviewNativeCellGeometryObserver)? {
    didSet {
      if let observer, oldValue.map({ ObjectIdentifier($0) }) != ObjectIdentifier(observer) {
        invalidate()
      }
    }
  }
  private var slots: [ObjectIdentifier: WeakSlot] = [:]
  private var notificationPending = false
  private var generation: UInt64 = 0
  private struct Diagnostics {
    // Keep integer JSON counters exactly representable by common consumers.
    static let cap: UInt64 = (1 << 53) - 1
    var registeredMaximum: UInt64 = 0
    var liveMaximum: UInt64 = 0
    var deadMaximum: UInt64 = 0
    var matchingScopeLastSnapshot: UInt64 = 0
    var matchingScopeMaximum: UInt64 = 0
    var visibleLastSnapshot: UInt64 = 0
    var visibleMaximum: UInt64 = 0
    var invalidationAttempts: UInt64 = 0
    var invalidationDeliveries: UInt64 = 0
    var snapshotCount: UInt64 = 0
    var snapshotAccumulatedNanoseconds: UInt64 = 0
    var snapshotMaximumNanoseconds: UInt64 = 0
  }
  private var diagnostics = Diagnostics()
  var registeredSlotCount: Int { slots.count }

  /// Read-only, opt-in metadata. Reading this property does not schedule work,
  /// prune slots, increment snapshotCount or read a clock. No URLs are exported.
  var diagnosticSnapshot: [String: Any]? {
    guard OverviewFocusRevealTrace.isEnabled else { return nil }
    let live = slots.values.reduce(0) { $0 + ($1.view == nil ? 0 : 1) }
    let dead = slots.count - live
    return ["registeredCurrent": Self.capped(slots.count),
      "registeredMaximum": diagnostics.registeredMaximum,
      "liveCurrent": Self.capped(live), "liveMaximum": diagnostics.liveMaximum,
      "deadCurrent": Self.capped(dead), "deadMaximum": diagnostics.deadMaximum,
      "matchingScopeLastSnapshot": diagnostics.matchingScopeLastSnapshot,
      "matchingScopeMaximum": diagnostics.matchingScopeMaximum,
      "visibleLastSnapshot": diagnostics.visibleLastSnapshot,
      "visibleMaximum": diagnostics.visibleMaximum,
      "invalidationAttempts": diagnostics.invalidationAttempts,
      "invalidationDeliveries": diagnostics.invalidationDeliveries,
      "snapshotCount": diagnostics.snapshotCount,
      "snapshotAccumulatedNanoseconds": diagnostics.snapshotAccumulatedNanoseconds,
      "snapshotMaximumNanoseconds": diagnostics.snapshotMaximumNanoseconds,
      "counterCap": Diagnostics.cap,
      "scope": "registered_maximum_is_registry_lifetime; live_dead_matching_visible_maxima_are_observed_in_visibleAssetIDs; matching_and_visible_are_last_snapshot; cost_is_visibleAssetIDs_only_excludes_registration_SwiftUI_native_layout_and_scroll_observer_hops"]
  }

  private static func capped(_ value: Int) -> UInt64 {
    min(Diagnostics.cap, UInt64(max(0, value)))
  }
  private static func adding(_ value: UInt64, to previous: UInt64) -> UInt64 {
    previous + min(value, Diagnostics.cap - previous)
  }

  /// O(1); do not scan/prune all realized cells for every register/update.
  func register(_ view: OverviewNativeCellGeometryView) {
    let key = ObjectIdentifier(view)
    guard slots[key]?.view !== view else { return }
    slots[key] = WeakSlot(view)
    if OverviewFocusRevealTrace.isEnabled {
      diagnostics.registeredMaximum = max(diagnostics.registeredMaximum, Self.capped(slots.count))
    }
    invalidate()
  }

  /// A stale view can never unregister a newer object with a reused address.
  func remove(_ view: OverviewNativeCellGeometryView) {
    let key = ObjectIdentifier(view)
    guard slots[key]?.view === view else { return }
    slots.removeValue(forKey: key)
    invalidate()
  }

  /// Every native cell change joins one main-queue callback. The queue captures
  /// neither the registry nor its observer strongly; no per-cell timers/publishers.
  func invalidate() {
    if OverviewFocusRevealTrace.isEnabled {
      diagnostics.invalidationAttempts = Self.adding(1, to: diagnostics.invalidationAttempts)
    }
    guard !notificationPending else { return }
    notificationPending = true
    let scheduledGeneration = generation
    DispatchQueue.main.async { [weak self] in
      guard let self, self.generation == scheduledGeneration else { return }
      self.notificationPending = false
      if let observer = self.observer {
        if OverviewFocusRevealTrace.isEnabled {
          self.diagnostics.invalidationDeliveries = Self.adding(1, to: self.diagnostics.invalidationDeliveries)
        }
        observer.nativeCellGeometryDidChange()
      }
    }
  }

  /// Read final native clipping rather than cached SwiftUI content rectangles.
  /// Scrolling and ancestor/document changes are invalidated by the overview's
  /// single scroll observer. No native coordinate result is retained here.
  func visibleAssetIDs(in scroll: NSScrollView, window: NSWindow,
    scope: OverviewNativeCellGeometryScope) -> Set<URL> {
    let started = OverviewFocusRevealTrace.isEnabled ? DispatchTime.now().uptimeNanoseconds : nil
    var dead: [ObjectIdentifier] = []
    var visible: Set<URL> = []
    var diagnosticLive = 0
    var diagnosticMatching = 0
    let document = scroll.documentView
    for (key, slot) in slots {
      guard let view = slot.view else { dead.append(key); continue }
      if started != nil {
        diagnosticLive += 1
        if view.scope == scope { diagnosticMatching += 1 }
      }
      guard view.scope == scope, let assetID = view.assetID,
        view.window === window, scroll.window === window,
        view.enclosingScrollView === scroll, let document,
        view.isDescendant(of: document), !view.isHiddenOrHasHiddenAncestor else { continue }
      let rectangle = view.visibleRect
      guard rectangle.width > 0, rectangle.height > 0,
        rectangle.minX.isFinite, rectangle.minY.isFinite,
        rectangle.maxX.isFinite, rectangle.maxY.isFinite else { continue }
      // visibleRect may include off-viewport cells when an NSClipView/ancestor
      // does not clip its bounds. Keep its ancestor-visibility check, but always
      // require a positive native intersection with this exact scroll viewport.
      let frameInClip = view.convert(view.bounds, to: scroll.contentView)
      guard OverviewThumbnailPreloadPlan.isVisible(frameInClip, in: scroll.contentView.bounds) else { continue }
      visible.insert(assetID)
    }
    for key in dead { slots.removeValue(forKey: key) }
    if let started {
      let ended = DispatchTime.now().uptimeNanoseconds
      let elapsed = min(Diagnostics.cap, ended >= started ? ended - started : 0)
      diagnostics.snapshotCount = Self.adding(1, to: diagnostics.snapshotCount)
      diagnostics.liveMaximum = max(diagnostics.liveMaximum, Self.capped(diagnosticLive))
      diagnostics.deadMaximum = max(diagnostics.deadMaximum, Self.capped(dead.count))
      diagnostics.matchingScopeLastSnapshot = Self.capped(diagnosticMatching)
      diagnostics.matchingScopeMaximum = max(diagnostics.matchingScopeMaximum, Self.capped(diagnosticMatching))
      diagnostics.visibleLastSnapshot = Self.capped(visible.count)
      diagnostics.visibleMaximum = max(diagnostics.visibleMaximum, Self.capped(visible.count))
      diagnostics.snapshotAccumulatedNanoseconds = Self.adding(elapsed, to: diagnostics.snapshotAccumulatedNanoseconds)
      diagnostics.snapshotMaximumNanoseconds = max(diagnostics.snapshotMaximumNanoseconds, elapsed)
    }
    return visible
  }

  /// Invalidate pending callbacks when the overview disappears. A surviving
  /// representable update must register again, even if URL/scope did not change.
  func stop() {
    generation &+= 1
    notificationPending = false
    observer = nil
    slots.removeAll(keepingCapacity: false)
  }
}

@MainActor
final class OverviewNativeCellGeometryView: NSView {
  private(set) weak var registry: OverviewNativeCellGeometryRegistry?
  private(set) var assetID: URL?
  private(set) var scope: OverviewNativeCellGeometryScope?

  func configure(registry: OverviewNativeCellGeometryRegistry, assetID: URL,
    scope: OverviewNativeCellGeometryScope) {
    let changed = self.registry !== registry || self.assetID != assetID || self.scope != scope
    if self.registry !== registry { self.registry?.remove(self) }
    self.registry = registry
    self.assetID = assetID
    self.scope = scope
    // register must run on every update: stop() can have emptied the same registry.
    registry.register(self)
    if changed { registry.invalidate() }
  }

  func detachFromRegistry() {
    registry?.remove(self)
    registry = nil
    assetID = nil
    scope = nil
  }

  override var frame: NSRect {
    didSet { if frame != oldValue { registry?.invalidate() } }
  }
  override var bounds: NSRect {
    didSet { if bounds != oldValue { registry?.invalidate() } }
  }
  override var isHidden: Bool {
    didSet { if isHidden != oldValue { registry?.invalidate() } }
  }
  override func setFrameOrigin(_ newOrigin: NSPoint) {
    let previous = frame
    super.setFrameOrigin(newOrigin)
    if frame != previous { registry?.invalidate() }
  }
  override func setFrameSize(_ newSize: NSSize) {
    let previous = frame
    super.setFrameSize(newSize)
    if frame != previous { registry?.invalidate() }
  }
  override func setBoundsOrigin(_ newOrigin: NSPoint) {
    let previous = bounds
    super.setBoundsOrigin(newOrigin)
    if bounds != previous { registry?.invalidate() }
  }
  override func setBoundsSize(_ newSize: NSSize) {
    let previous = bounds
    super.setBoundsSize(newSize)
    if bounds != previous { registry?.invalidate() }
  }
  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    registry?.invalidate()
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    registry?.invalidate()
  }
  override func layout() {
    super.layout()
    registry?.invalidate()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Put this transparent view in the complete card's background, not its image
/// subrectangle. It has no drawing, accessibility element, file reads or pixels.
struct OverviewNativeCellGeometry: NSViewRepresentable {
  let registry: OverviewNativeCellGeometryRegistry
  let assetID: URL
  let scope: OverviewNativeCellGeometryScope

  func makeNSView(context: Context) -> OverviewNativeCellGeometryView {
    let view = OverviewNativeCellGeometryView(frame: .zero)
    view.setAccessibilityElement(false)
    view.configure(registry: registry, assetID: assetID, scope: scope)
    return view
  }

  func updateNSView(_ view: OverviewNativeCellGeometryView, context: Context) {
    view.configure(registry: registry, assetID: assetID, scope: scope)
  }

  static func dismantleNSView(_ view: OverviewNativeCellGeometryView, coordinator: ()) {
    view.detachFromRegistry()
  }
}
