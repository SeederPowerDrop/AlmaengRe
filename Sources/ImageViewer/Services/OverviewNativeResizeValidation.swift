import AppKit
import Darwin
import Foundation

struct OverviewNativeResizeReport: Codable {
  var schemaVersion = 1
  var status = "started"
  var failurePhase = ""
  var itemCount = 0
  var nonemptyCount = 0
  var preparedPreviewCount = 0
  var originalSize = 0.0
  var originalSizeRestored = false
  var fullNativeTrackingSucceeded = false
  var bitmapEventsReceived = 0
  var steps: [OverviewNativeResizeStep] = []
  var cacheBefore: OverviewResizeCacheSnapshot?
  var cacheAfter: OverviewResizeCacheSnapshot?
  let cpuScope = "getrusage_process_CPU_100_percent_equals_one_core"
  let heartbeatScope = "main_RunLoop_common_and_eventTracking_Timer_extra_gap_not_compositor_FPS"
  let bitmapScope = "accepted_ThumbnailImageView_State_assignment_metadata_only_no_pixels_exported_no_direct_inspection_of_retained_State_or_physical_paint"
  let qualityScope = "latest_accepted_bitmap_dimensions_cover_actual_final_pixel_bucket_for_current_nonempty_visible_assets_requires_same_unchanged_sources"
  let nativeScope = "actual_RootView_NSSlider_via_CUA_native_UI_events_and_binding_observed_drag_samples_separate_not_required_no_synthetic_AppKit_input"
}

struct OverviewNativeResizeStep: Codable {
  var requestedSize = 0.0
  var actualFinalSize = 0.0
  var nativeTrackingSucceeded = false
  var nativeDragEventsPosted = 0
  var observedPressedMouseSamples = 0
  var nativeMouseDownObserved = false
  var nativeMouseUpObserved = false
  var waitingForExternalInputSeconds = 0.0
  var observedBindingChanges = 0
  var gestureWallSeconds = 0.0
  var gestureCPUPercentOneCore = 0.0
  var quietWallSeconds = 0.0
  var quietCPUPercentOneCore = 0.0
  var mainTimerExtraGapP95Seconds = 0.0
  var mainTimerExtraGapMaximumSeconds = 0.0
  var sampledCPUPercentOneCoreMaximum = 0.0
  var sampledFootprintMaximumBytes: UInt64 = 0
  var firstBitmapApplicationsDuringTracking = 0
  var refinementApplicationsDuringTracking = 0
  var applicationsSmallerThanPreviousAcceptedBitmap = 0
  var cachedPreviewRequests = 0
  var uncancelledCachedPreviewMisses = 0
  var requiredPixelBucket = 0
  var visibleNonemptyCount = 0
  var sufficientAcceptedBitmapCount = 0
  var finalBitmapApplicationsAfterRelease = 0
  var sufficientBitmapMetadataPredatesReleaseCount = 0
  var finalVisibleGeometryStable = false
  var cacheWithinBudget = false
  var viewportDiagnostics: [OverviewResizeViewportDiagnostic] = []
}

/// At most three metadata snapshots per step. These inspect the existing native
/// probes and coordinate bridge without changing layout, membership or admission.
struct OverviewResizeViewportDiagnostic: Codable {
  var stage: String
  var uptime: Double
  var currentIndex: Int
  var thumbnailSize: Double
  var requiredPixelBucket: Int
  var preloaderVisibleCount: Int
  var preloaderVisibleOrdinals: [Int]
  var preloaderOrdinalsTruncated: Bool
  var nativeVisibleProbeCount: Int
  var nativeVisibleNonemptyProbeCount: Int
  var nativeVisibleHasBitmapCount: Int
  var nativeVisiblePixelCoverageCount: Int
  var nativeVisibleLatestAcceptedMetadataCount: Int
  var nativeVisibleLatestAcceptedPixelCoverageCount: Int
  var unmappedNativeProbeCount: Int
  var nativeRowsTruncated: Bool
  var nativeRows: [OverviewResizeNativeProbeDiagnostic]
  var matchingAnchorCount: Int
  var anchorFrame: OverviewResizeDiagnosticRect?
  var anchorBounds: OverviewResizeDiagnosticRect?
  var clipBounds: OverviewResizeDiagnosticRect?
  var documentBounds: OverviewResizeDiagnosticRect?
  var freshViewportInDocument: OverviewResizeDiagnosticRect?
  var freshContentOriginX: Double?
  var freshContentOriginY: Double?
  var freshDocumentIsFlipped: Bool?
  var gateIsDeferring: Bool?
  var gateIsWindowSuppressed: Bool?
  var gateMotionGeneration: UInt64?
  var gateQuietRevision: UInt64?
  let scope = "bounded_existing_native_probe_and_fresh_coordinate_metadata_only_no_layout_or_membership_mutation_no_paths_pixels_or_physical_paint_proof"
  let latestAcceptedScope = "URL_keyed_callback_dimensions_event_has_no_source_version; live_probe_source_tuple_match_is_recorded_separately"
}

struct OverviewResizeNativeProbeDiagnostic: Codable {
  var instance: UUID
  var currentOrdinal: Int?
  var sourceVersionMatchesCurrent: Bool
  var isNonempty: Bool
  var hasBitmap: Bool
  var pixelWidth: Int
  var pixelHeight: Int
  var pixelsCoverRequiredBucket: Bool
  var latestAcceptedPixelWidth: Int?
  var latestAcceptedPixelHeight: Int?
  var latestAcceptedPixelsCoverRequiredBucket: Bool
  var productionGateAllowsRefinement: Bool?
}

struct OverviewResizeDiagnosticRect: Codable {
  var x: Double
  var y: Double
  var width: Double
  var height: Double

  init?(_ value: CGRect) {
    guard value.minX.isFinite, value.minY.isFinite,
      value.width.isFinite, value.height.isFinite else { return nil }
    x = Double(value.minX); y = Double(value.minY)
    width = Double(value.width); height = Double(value.height)
  }
}

struct OverviewResizeCacheSnapshot: Codable {
  var memoryBytes: Int
  var memoryLimit: Int
  var diskBytes: Int
  var diskLimit: Int
  var withinBudget: Bool { memoryBytes <= memoryLimit && diskBytes <= diskLimit }
}

@MainActor
enum OverviewNativeResizeValidation {
  private static var latest: [URL: ThumbnailBitmapStateEvent] = [:]
  private static var activeEvents: [ThumbnailBitmapStateEvent]?

  /// Call before the benchmark's phase guard, including before resize begins.
  /// Stores only dimensions/times; neither bitmap pixels nor source paths leave
  /// this process through the resize report.
  static func record(_ event: ThumbnailBitmapStateEvent) {
    latest[event.assetURL] = event
    if activeEvents != nil, activeEvents!.count < 20_000 { activeEvents!.append(event) }
  }

  @discardableResult
  static func run(store: AppStore, preloader: OverviewThumbnailPreloader, root: NSView,
    window: NSWindow, output: URL) async throws -> OverviewNativeResizeReport {
    var report = OverviewNativeResizeReport()
    report.itemCount = store.assets.count
    report.nonemptyCount = store.assets.filter { ($0.byteCount ?? 0) > 0 }.count
    report.originalSize = Double(store.thumbnailSize)
    activeEvents = []
    let probe = OverviewResizeResourceProbe()
    probe.start()
    defer { probe.stop(); activeEvents = nil }
    do {
      try ownForeground()
      try require(store.presentationMode == .overview && store.assets.count == 729, "expected_actual_overview_729")
      let sliders = descendants(in: root).filter { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 20 }
      try require(sliders.count == 1, "expected_unique_actual_overview_slider")
      let slider = sliders[0]
      guard let scroll = OverviewBenchmarkScrollTarget.find(in: root) else {
        throw OverviewResizeValidationError(phase: "actual_overview_scroll_marker_missing")
      }
      let assets = store.assets
      let revision = store.assetOrderRevision
      let prepared = await store.thumbnailPipeline.overviewCachedAssetCounts(
        assets: assets.filter { ($0.byteCount ?? 0) > 0 }, maxPixelSize: 256)
      report.preparedPreviewCount = prepared.preview
      try require(prepared.preview == report.nonemptyCount, "prepared_compact_cache_incomplete")
      report.cacheBefore = await cacheSnapshot(store)
      for (index, size) in [80.0, 150.0, 480.0, report.originalSize].enumerated() {
        try ownForeground()
        try require(store.assetOrderRevision == revision, "collection_changed_during_resize")
        let phase = "native_resize_\(index)"
        await store.thumbnailPipeline.setCachedPreviewDiagnosticPhase(phase)
        let eventStart = activeEvents?.count ?? 0
        let previous = latest
        let sampleStart = probe.observations.count
        let readyAt = ProcessInfo.processInfo.systemUptime
        let trackingSession = OverviewResizeTrackingSession(slider: slider, window: window,
          store: store, targetSize: CGFloat(size))
        let native = try await trackingSession.perform(output: output, step: index)
        withExtendedLifetime(trackingSession) {}
        let started = native.startedUptime
        let released = native.endedUptime
        let cpuStarted = native.startedCPU
        let cpuReleased = native.endedCPU
        var step = OverviewNativeResizeStep()
        step.requestedSize = size
        step.actualFinalSize = Double(store.thumbnailSize)
        step.nativeTrackingSucceeded = native.succeeded
        step.nativeDragEventsPosted = 0
        step.observedPressedMouseSamples = native.dragCount
        step.nativeMouseDownObserved = native.mouseDown
        step.nativeMouseUpObserved = native.mouseUp
        step.waitingForExternalInputSeconds = max(0, started - readyAt)
        step.observedBindingChanges = native.bindingChanges
        step.gestureWallSeconds = released - started
        step.gestureCPUPercentOneCore = max(0, cpuReleased - cpuStarted) / max(0.000_001, released - started) * 100
        if !native.succeeded {
          step.viewportDiagnostics.append(viewportDiagnostic(stage: "tracking_failed_stage_end",
            store: store, preloader: preloader, root: root, scroll: scroll,
            window: window, requiredPixelBucket: step.requiredPixelBucket))
          report.steps.append(step)
        }
        try require(native.succeeded, "native_slider_tracking_did_not_change_binding")
        try require(descendants(in: root).contains(where: { $0 === slider }), "native_slider_identity_replaced")
        let scale = window.backingScaleFactor
        let viewportWidth = scroll.bounds.width
        let pointSize = min(store.thumbnailSize, max(1, viewportWidth - 50))
        let pixels = OverviewThumbnailSizing.requestedPixelSize(for: pointSize, displayScale: scale)
        step.requiredPixelBucket = ((pixels + 127) / 128) * 128
        let quietDeadline = ProcessInfo.processInfo.systemUptime + 65
        var previousVisible: Set<Int> = []
        var stableSince = ProcessInfo.processInfo.systemUptime
        var capturedEmptyMembership = false
        while ProcessInfo.processInfo.systemUptime < quietDeadline {
          try ownForeground()
          try Task.checkCancellation()
          let visible = preloader.visibleIndices
          if visible.isEmpty, !capturedEmptyMembership {
            capturedEmptyMembership = true
            step.viewportDiagnostics.append(viewportDiagnostic(stage: "first_empty_membership",
              store: store, preloader: preloader, root: root, scroll: scroll,
              window: window, requiredPixelBucket: step.requiredPixelBucket))
          }
          if visible != previousVisible { stableSince = ProcessInfo.processInfo.systemUptime; previousVisible = visible }
          let valid = visible.compactMap { assets.indices.contains($0) ? assets[$0] : nil }
            .filter { ($0.byteCount ?? 0) > 0 }
          step.visibleNonemptyCount = valid.count
          step.sufficientAcceptedBitmapCount = valid.filter {
            guard let bitmap = latest[$0.url] else { return false }
            return max(bitmap.pixelWidth, bitmap.pixelHeight) >= step.requiredPixelBucket
          }.count
          let work = await store.loadingGovernor.stateSnapshot()
          if !valid.isEmpty, step.sufficientAcceptedBitmapCount == valid.count,
            ProcessInfo.processInfo.systemUptime - stableSince >= 0.4,
            work.runningCount == 0 && work.queuedCount == 0 {
            step.finalVisibleGeometryStable = true
            step.sufficientBitmapMetadataPredatesReleaseCount = valid.filter {
              (latest[$0.url]?.appliedUptime ?? .greatestFiniteMagnitude) < released
            }.count
            break
          }
          try await Task.sleep(for: .milliseconds(40))
        }
        let ended = ProcessInfo.processInfo.systemUptime
        step.quietWallSeconds = ended - released
        step.quietCPUPercentOneCore = max(0, OverviewResizeResourceProbe.cpuSeconds() - cpuReleased)
          / max(0.000_001, ended - released) * 100
        if !step.finalVisibleGeometryStable {
          step.viewportDiagnostics.append(viewportDiagnostic(stage: "quiet_timeout",
            store: store, preloader: preloader, root: root, scroll: scroll,
            window: window, requiredPixelBucket: step.requiredPixelBucket))
        }
        step.viewportDiagnostics.append(viewportDiagnostic(stage: "stage_end",
          store: store, preloader: preloader, root: root, scroll: scroll,
          window: window, requiredPixelBucket: step.requiredPixelBucket))
        let events = Array((activeEvents ?? []).dropFirst(eventStart))
        let during = events.filter { $0.appliedUptime >= started && $0.appliedUptime <= released }
        step.firstBitmapApplicationsDuringTracking = during.filter { !$0.isRefinement }.count
        step.refinementApplicationsDuringTracking = during.filter(\.isRefinement).count
        step.finalBitmapApplicationsAfterRelease = events.filter { $0.appliedUptime > released && $0.isRefinement }.count
        var observed = previous
        for event in events {
          if let old = observed[event.assetURL], max(event.pixelWidth, event.pixelHeight) < max(old.pixelWidth, old.pixelHeight) {
            step.applicationsSmallerThanPreviousAcceptedBitmap += 1
          }
          observed[event.assetURL] = event
        }
        let requests = await store.thumbnailPipeline.cachedPreviewDiagnosticsSnapshot()
          .filter { $0.phase == phase }
        step.cachedPreviewRequests = requests.count
        step.uncancelledCachedPreviewMisses = requests.filter { !$0.cancelled && !$0.cacheHit }.count
        let samples = Array(probe.observations.dropFirst(sampleStart))
        let gaps = samples.map(\.extraGap).sorted()
        step.mainTimerExtraGapP95Seconds = releaseOverviewPercentile(gaps, fraction: 0.95)
        step.mainTimerExtraGapMaximumSeconds = gaps.last ?? 0
        step.sampledCPUPercentOneCoreMaximum = samples.map(\.cpuPercent).max() ?? 0
        step.sampledFootprintMaximumBytes = samples.map(\.footprint).max() ?? 0
        step.cacheWithinBudget = await cacheSnapshot(store).withinBudget
        report.steps.append(step)
        try require(step.finalVisibleGeometryStable, "final_display_size_bitmap_metadata_did_not_complete")
        try require(step.cacheWithinBudget, "resize_cache_exceeded_existing_limit")
        try require(step.uncancelledCachedPreviewMisses == 0, "prepared_resize_cache_miss")
      }
      await store.thumbnailPipeline.setCachedPreviewDiagnosticPhase(nil)
      report.fullNativeTrackingSucceeded = report.steps.count == 4 && report.steps.allSatisfy(\.nativeTrackingSucceeded)
      report.bitmapEventsReceived = activeEvents?.count ?? 0
      report.cacheAfter = await cacheSnapshot(store)
      // Exact restoration is outside the measured native gesture. Native
      // pointer coordinates can quantize a value to the slider's pixel grid.
      store.thumbnailSize = CGFloat(report.originalSize)
      report.originalSizeRestored = Double(store.thumbnailSize) == report.originalSize
      report.status = "completed"
      try write(report, output: output)
      return report
    } catch {
      await store.thumbnailPipeline.setCachedPreviewDiagnosticPhase(nil)
      store.thumbnailSize = CGFloat(report.originalSize)
      report.originalSizeRestored = Double(store.thumbnailSize) == report.originalSize
      report.bitmapEventsReceived = activeEvents?.count ?? 0
      report.status = "failed"
      report.failurePhase = (error as? OverviewResizeValidationError)?.phase ?? "unexpected_resize_error"
      report.cacheAfter = await cacheSnapshot(store)
      try write(report, output: output)
      throw error
    }
  }

  private static func descendants(in view: NSView) -> [NSSlider] {
    if let slider = view as? NSSlider { return [slider] }
    return view.subviews.flatMap { descendants(in: $0) }
  }
  private static func viewportAnchors(in view: NSView) -> [OverviewScrollMotionView] {
    if let anchor = view as? OverviewScrollMotionView { return [anchor] }
    return view.subviews.flatMap { viewportAnchors(in: $0) }
  }
  private static func viewportDiagnostic(stage: String, store: AppStore,
    preloader: OverviewThumbnailPreloader, root: NSView, scroll: NSScrollView,
    window: NSWindow, requiredPixelBucket: Int) -> OverviewResizeViewportDiagnostic {
    let anchors = viewportAnchors(in: root).filter {
      $0.window === window && $0.enclosingScrollView === scroll
    }
    let anchor = anchors.count == 1 ? anchors.first : nil
    // This only reads geometry. Do not call refreshViewportGeometry: its callback
    // would update the production membership that this snapshot must diagnose.
    let fresh = anchor?.currentViewportGeometry()
    var ordinals: [URL: Int] = [:]
    for (index, asset) in store.assets.enumerated() { ordinals[asset.url] = index }
    let visible = OverviewBitmapProbeRegistry.visible(in: scroll, window: window)
    let rows = visible.map { sample -> OverviewResizeNativeProbeDiagnostic in
      let index = ordinals[sample.assetURL]
      let current = index.flatMap { store.assets.indices.contains($0) ? store.assets[$0] : nil }
      let accepted = latest[sample.assetURL]
      return OverviewResizeNativeProbeDiagnostic(instance: sample.instance,
        currentOrdinal: index,
        sourceVersionMatchesCurrent: current.map {
          $0.byteCount == sample.byteCount && $0.modificationDate == sample.modificationDate
        } ?? false,
        isNonempty: (sample.byteCount ?? 0) > 0,
        hasBitmap: sample.hasBitmap, pixelWidth: sample.pixelWidth, pixelHeight: sample.pixelHeight,
        pixelsCoverRequiredBucket: sample.hasBitmap && requiredPixelBucket > 0
          && max(sample.pixelWidth, sample.pixelHeight) >= requiredPixelBucket,
        latestAcceptedPixelWidth: accepted?.pixelWidth,
        latestAcceptedPixelHeight: accepted?.pixelHeight,
        latestAcceptedPixelsCoverRequiredBucket: accepted.map {
          requiredPixelBucket > 0 && max($0.pixelWidth, $0.pixelHeight) >= requiredPixelBucket
        } ?? false,
        productionGateAllowsRefinement: anchor?.gate?.allowsRefinement(for: sample.assetURL))
    }.sorted { lhs, rhs in
      if lhs.currentOrdinal != rhs.currentOrdinal {
        return (lhs.currentOrdinal ?? Int.max) < (rhs.currentOrdinal ?? Int.max)
      }
      return lhs.instance.uuidString < rhs.instance.uuidString
    }
    let preloaded = preloader.visibleIndices.sorted()
    let originX = fresh.map { Double($0.contentOriginInDocument.x) }
    let originY = fresh.map { Double($0.contentOriginInDocument.y) }
    return OverviewResizeViewportDiagnostic(stage: stage,
      uptime: ProcessInfo.processInfo.systemUptime, currentIndex: store.currentIndex,
      thumbnailSize: Double(store.thumbnailSize), requiredPixelBucket: requiredPixelBucket,
      preloaderVisibleCount: preloaded.count,
      preloaderVisibleOrdinals: Array(preloaded.prefix(512)),
      preloaderOrdinalsTruncated: preloaded.count > 512,
      nativeVisibleProbeCount: rows.count,
      nativeVisibleNonemptyProbeCount: rows.filter(\.isNonempty).count,
      nativeVisibleHasBitmapCount: rows.filter(\.hasBitmap).count,
      nativeVisiblePixelCoverageCount: rows.filter(\.pixelsCoverRequiredBucket).count,
      nativeVisibleLatestAcceptedMetadataCount: rows.filter { $0.latestAcceptedPixelWidth != nil }.count,
      nativeVisibleLatestAcceptedPixelCoverageCount: rows.filter(\.latestAcceptedPixelsCoverRequiredBucket).count,
      unmappedNativeProbeCount: rows.filter { $0.currentOrdinal == nil }.count,
      nativeRowsTruncated: rows.count > 256, nativeRows: Array(rows.prefix(256)),
      matchingAnchorCount: anchors.count,
      anchorFrame: anchor.flatMap { OverviewResizeDiagnosticRect($0.frame) },
      anchorBounds: anchor.flatMap { OverviewResizeDiagnosticRect($0.bounds) },
      clipBounds: OverviewResizeDiagnosticRect(scroll.contentView.bounds),
      documentBounds: scroll.documentView.flatMap { OverviewResizeDiagnosticRect($0.bounds) },
      freshViewportInDocument: fresh.flatMap { OverviewResizeDiagnosticRect($0.viewportInDocument) },
      freshContentOriginX: originX.flatMap { $0.isFinite ? $0 : nil },
      freshContentOriginY: originY.flatMap { $0.isFinite ? $0 : nil },
      freshDocumentIsFlipped: fresh?.documentIsFlipped,
      gateIsDeferring: anchor?.gate?.isDeferring,
      gateIsWindowSuppressed: anchor?.gate?.isWindowSuppressed,
      gateMotionGeneration: anchor?.gate?.motionGeneration,
      gateQuietRevision: anchor?.gate?.quietRevision)
  }
  private static func ownForeground() throws {
    try require(NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
      "resize_actual_own_process_foreground_lost")
  }
  private static func require(_ condition: Bool, _ phase: String) throws {
    if !condition { throw OverviewResizeValidationError(phase: phase) }
  }
  private static func cacheSnapshot(_ store: AppStore) async -> OverviewResizeCacheSnapshot {
    let memory = await store.thumbnailPipeline.cacheSnapshot()
    let disk = await store.thumbnailPipeline.diskCacheSnapshot()
    return OverviewResizeCacheSnapshot(memoryBytes: memory.byteCount, memoryLimit: memory.byteLimit,
      diskBytes: disk?.byteCount ?? 0, diskLimit: disk?.byteLimit ?? 0)
  }
  private static func write(_ report: OverviewNativeResizeReport, output: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: output.appendingPathComponent("overview-resize-report.json"), options: .atomic)
  }
}

private struct OverviewResizeValidationError: Error { let phase: String }

@MainActor
private final class OverviewResizeTrackingSession {
  struct Outcome {
    let succeeded: Bool
    let dragCount: Int
    let bindingChanges: Int
    let mouseDown: Bool
    let mouseUp: Bool
    let startedUptime: Double
    let endedUptime: Double
    let startedCPU: Double
    let endedCPU: Double
  }
  private let slider: NSSlider
  private let window: NSWindow
  private let store: AppStore
  private let targetSize: CGFloat
  private var mouseDown = false
  private var mouseUp = false
  private var sawPressed = false
  private var pressedSamples = 0
  private var bindingChanges = 0
  private var previousValue = 0.0
  private var lastChange = 0.0
  private var started = 0.0
  private var startedCPU = 0.0
  private var lostForeground = false

  init(slider: NSSlider, window: NSWindow, store: AppStore, targetSize: CGFloat) {
    self.slider = slider; self.window = window; self.store = store; self.targetSize = targetSize
  }

  func perform(output: URL, step: Int) async throws -> Outcome {
    guard slider.isEnabled, slider.window === window, NSApp.isRunning else {
      throw OverviewResizeValidationError(phase: "native_slider_tracking_host_unavailable")
    }
    previousValue = Double(store.thumbnailSize)
    let ready = ProcessInfo.processInfo.systemUptime
    let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self, event.windowNumber == self.window.windowNumber else { return }
        if event.type == .leftMouseDown {
          let point = self.slider.convert(event.locationInWindow, from: nil)
          if self.slider.bounds.insetBy(dx: -12, dy: -12).contains(point) {
            self.observeStart()
          }
        } else if self.mouseDown { self.mouseUp = true }
      }
      return event
    }
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.observe() }
    }
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .eventTracking)
    defer { timer.invalidate(); if let monitor { NSEvent.removeMonitor(monitor) } }
    let input: [String: Any] = ["stage": "waiting_for_native_CUA_drag", "step": step,
      "targetSize": Double(targetSize), "startingSize": Double(store.thumbnailSize),
      "processID": getpid(), "windowTitle": window.title,
      "scope": "external_CUA_drag_only_app_observes_local_events_and_pressed_mouse_state"]
    try JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("overview-resize-input.json"), options: .atomic)
    let range = OverviewThumbnailSizing.range
    let tolerance = max(2, Double(range.upperBound - range.lowerBound) / max(1, slider.bounds.width) * 2)
    while ProcessInfo.processInfo.systemUptime - ready < 90 {
      try Task.checkCancellation()
      if lostForeground { throw OverviewResizeValidationError(phase: "resize_actual_own_process_foreground_lost") }
      let now = ProcessInfo.processInfo.systemUptime
      if mouseDown, mouseUp, bindingChanges >= 2,
        abs(Double(store.thumbnailSize - targetSize)) <= tolerance,
        now - lastChange >= 0.1 {
        let result = Outcome(succeeded: true, dragCount: pressedSamples,
          bindingChanges: bindingChanges, mouseDown: true, mouseUp: true,
          startedUptime: started, endedUptime: now, startedCPU: startedCPU,
          endedCPU: OverviewResizeResourceProbe.cpuSeconds())
        try JSONSerialization.data(withJSONObject: ["stage": "native_drag_completed", "step": step,
          "actualSize": Double(store.thumbnailSize)], options: [.sortedKeys])
          .write(to: output.appendingPathComponent("overview-resize-input.json"), options: .atomic)
        return result
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw OverviewResizeValidationError(phase: "external_native_slider_drag_timeout")
  }
  private func observeStart() {
    guard !mouseDown else { return }
    mouseDown = true; started = ProcessInfo.processInfo.systemUptime
    startedCPU = OverviewResizeResourceProbe.cpuSeconds()
  }
  private func observe() {
    if !NSApp.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() {
      lostForeground = true
    }
    let now = ProcessInfo.processInfo.systemUptime
    let pressed = NSEvent.pressedMouseButtons & 1 != 0
    if pressed { observeStart(); sawPressed = true; pressedSamples += 1 }
    if Double(store.thumbnailSize) != previousValue {
      bindingChanges += 1; previousValue = Double(store.thumbnailSize); lastChange = now
    }
    // Tracking may consume mouse-up before a local monitor sees it. A real
    // pressed-to-released transition is independently observed on the run loop.
    if mouseDown && sawPressed && !pressed && bindingChanges > 0 { mouseUp = true }
  }
}

@MainActor
private final class OverviewResizeResourceProbe {
  struct Observation { let extraGap: Double; let cpuPercent: Double; let footprint: UInt64 }
  private(set) var observations: [Observation] = []
  private var timer: Timer?
  private var previousTick = 0.0
  private var previousSample = 0.0
  private var previousCPU = 0.0
  private var currentCPU = 0.0
  private var currentFootprint: UInt64 = 0
  func start() {
    previousTick = ProcessInfo.processInfo.systemUptime
    previousSample = previousTick; previousCPU = Self.cpuSeconds()
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.sample() }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .eventTracking)
  }
  func stop() { timer?.invalidate(); timer = nil }
  private func sample() {
    let now = ProcessInfo.processInfo.systemUptime
    if now - previousSample >= 0.25 {
      let cpu = Self.cpuSeconds()
      currentCPU = max(0, cpu - previousCPU) / (now - previousSample) * 100
      previousCPU = cpu; previousSample = now
      var usage = rusage_info_v4()
      let result = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
      }
      if result == 0 { currentFootprint = usage.ri_phys_footprint }
    }
    observations.append(Observation(extraGap: max(0, now - previousTick - 1.0 / 60),
      cpuPercent: currentCPU, footprint: currentFootprint))
    previousTick = now
  }
  static func cpuSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }
}
