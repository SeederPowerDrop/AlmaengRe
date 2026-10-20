import AppKit
import SwiftUI

/// Benchmark metadata only: native clipping and the bitmap accepted by this
/// live cell are observed together. No image pixels are retained or exported.
struct OverviewBitmapProbeSample: Equatable {
  let instance: UUID
  let assetURL: URL
  let byteCount: Int64?
  let modificationDate: Date?
  let hasBitmap: Bool
  let pixelWidth: Int
  let pixelHeight: Int
}

struct OverviewBitmapVisitReport: Encodable {
  let observedVisits: Int
  let uniqueAssets: Int
  let readyBeforeEntry: Int
  let readyAfterEntry: Int
  let leftWithoutBitmap: Int
  let unresolvedAtEnd: Int
  let samples: Int
  let readyLatency: ReleaseOverviewLatencyReport
  let scope = "live_native_thumbnail_probe_intersection_and_SwiftUI_accepted_bitmap_presence_per_cell_instance_and_source_version_not_physical_paint_or_FPS"
}

/// Availability may precede viewport entry. A past cell cannot prove that a new
/// instance has a bitmap. Source changes and cleared State start a fresh visit.
struct OverviewBitmapVisitLedger {
  private struct Key: Hashable {
    let instance: UUID
    let url: URL
    let bytes: Int64?
    let date: Date?
  }
  private struct Visit {
    let key: Key
    let entered: Double
    var ready: Double?
    let wasReadyAtEntry: Bool
    var left = false
  }
  private var visits: [Visit] = []
  private var active: [Key: Int] = [:]
  private(set) var samples = 0

  mutating func observe(_ visible: [OverviewBitmapProbeSample], at time: Double) {
    samples += 1
    let eligible = visible.filter { ($0.byteCount ?? 1) > 0 }
    let keys = Set(eligible.map { Key(instance: $0.instance, url: $0.assetURL,
      bytes: $0.byteCount, date: $0.modificationDate) })
    for key in Array(active.keys) where !keys.contains(key) {
      if let index = active.removeValue(forKey: key) { visits[index].left = true }
    }
    for sample in eligible {
      let key = Key(instance: sample.instance, url: sample.assetURL,
        bytes: sample.byteCount, date: sample.modificationDate)
      let ready = sample.hasBitmap && sample.pixelWidth > 0 && sample.pixelHeight > 0
      if let index = active[key] {
        if ready, visits[index].ready == nil { visits[index].ready = time }
        if !ready, visits[index].ready != nil {
          visits[index].left = true
          active.removeValue(forKey: key)
        } else { continue }
      }
      guard visits.count < 20_000 else { continue }
      active[key] = visits.count
      visits.append(Visit(key: key, entered: time, ready: ready ? time : nil,
        wasReadyAtEntry: ready))
    }
  }

  func report() -> OverviewBitmapVisitReport {
    OverviewBitmapVisitReport(observedVisits: visits.count,
      uniqueAssets: Set(visits.map { $0.key.url }).count,
      readyBeforeEntry: visits.filter(\.wasReadyAtEntry).count,
      readyAfterEntry: visits.filter { !$0.wasReadyAtEntry && $0.ready != nil }.count,
      leftWithoutBitmap: visits.filter { $0.left && $0.ready == nil }.count,
      unresolvedAtEnd: visits.filter { !$0.left && $0.ready == nil }.count,
      samples: samples,
      readyLatency: ReleaseOverviewLatencyReport(values: visits.compactMap { visit in
        visit.ready.map { max(0, $0 - visit.entered) }
      }))
  }
}

@MainActor
enum OverviewBitmapProbeRegistry {
  private final class WeakView {
    weak var view: OverviewBitmapProbeView?
    init(_ view: OverviewBitmapProbeView) { self.view = view }
  }
  private static var views: [UUID: WeakView] = [:]
  static var onChange: (() -> Void)?
  private static var notificationPending = false

  static func register(_ view: OverviewBitmapProbeView) {
    views = views.filter { $0.value.view != nil }
    views[view.instance] = WeakView(view)
    changed()
  }
  static func remove(_ view: OverviewBitmapProbeView) {
    views.removeValue(forKey: view.instance)
    changed()
  }
  static func changed() {
    guard onChange != nil, !notificationPending else { return }
    notificationPending = true
    DispatchQueue.main.async {
      notificationPending = false
      onChange?()
    }
  }
  static func visible(in scroll: NSScrollView, window: NSWindow) -> [OverviewBitmapProbeSample] {
    views.values.compactMap { weakView in
      guard let view = weakView.view, view.window === window,
        view.enclosingScrollView === scroll, !view.isHiddenOrHasHiddenAncestor,
        view.visibleRect.width > 0.5, view.visibleRect.height > 0.5,
        let value = view.value else { return nil }
      // Some native hosts do not include the clip view's bounds in visibleRect.
      // Receipt membership must still be the physical scroll viewport, even
      // when that host allows drawing beyond its own bounds.
      let clipped = view.convert(view.bounds, to: scroll.contentView)
        .intersection(scroll.contentView.bounds)
      guard clipped.width > 0.5, clipped.height > 0.5,
        clipped.minX.isFinite, clipped.minY.isFinite,
        clipped.maxX.isFinite, clipped.maxY.isFinite else { return nil }
      return OverviewBitmapProbeSample(instance: view.instance, assetURL: value.assetURL,
        byteCount: value.byteCount, modificationDate: value.modificationDate,
        hasBitmap: value.hasBitmap, pixelWidth: value.pixelWidth, pixelHeight: value.pixelHeight)
    }
  }
}

@MainActor
final class OverviewBitmapProbeView: NSView {
  let instance = UUID()
  var value: OverviewBitmapProbeSample?
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct OverviewBitmapPresentationProbe: NSViewRepresentable {
  let asset: ImageAsset
  let size: CGSize?
  func makeNSView(context: Context) -> OverviewBitmapProbeView {
    let view = OverviewBitmapProbeView()
    view.setAccessibilityElement(false)
    OverviewBitmapProbeRegistry.register(view)
    return view
  }
  func updateNSView(_ view: OverviewBitmapProbeView, context: Context) {
    let value = OverviewBitmapProbeSample(instance: view.instance, assetURL: asset.url,
      byteCount: asset.byteCount, modificationDate: asset.modificationDate,
      hasBitmap: size != nil, pixelWidth: Int(size?.width ?? 0), pixelHeight: Int(size?.height ?? 0))
    if view.value != value { view.value = value; OverviewBitmapProbeRegistry.changed() }
  }
  static func dismantleNSView(_ view: OverviewBitmapProbeView, coordinator: ()) {
    OverviewBitmapProbeRegistry.remove(view)
  }
}
