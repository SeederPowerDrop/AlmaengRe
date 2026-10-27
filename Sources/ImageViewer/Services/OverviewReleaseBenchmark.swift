import AppKit
import CryptoKit
import Darwin
import Foundation
import SwiftUI

/// Explicit developer opt-in in the installed app, using its real RootView and
/// normal event loop. Cold preparation is the default; an explicit, verified
/// prepared-run resume measures native traversal separately from preparation.
@MainActor
final class OverviewReleaseBenchmark {
  private static let environment = ProcessInfo.processInfo.environment
  private static let defaultsSuiteName = "ImageViewer.ReleaseOverview.\(UUID().uuidString)"
  static let isolatedDefaults: UserDefaults? = {
    guard environment["IMAGEVIEWER_RELEASE_OVERVIEW_BENCHMARK"] == "1" else { return nil }
    return UserDefaults(suiteName: defaultsSuiteName)
  }()

  static func makeFromEnvironment() -> OverviewReleaseBenchmark? {
    guard environment["IMAGEVIEWER_RELEASE_OVERVIEW_BENCHMARK"] == "1" else { return nil }
    return OverviewReleaseBenchmark(environment: environment)
  }

  let defaults: UserDefaults
  let store: AppStore
  let preloader = OverviewThumbnailPreloader()
  private let source: URL
  private let output: URL
  private let runtime: URL
  private let cacheDirectory: URL
  private let timeout: Double
  private let thermalTarget: OverviewBenchmarkThermalTarget
  private let explicitConfiguration: Bool
  private let ownedOutputWasFresh: Bool
  private let preparedRun: URL?
  private let preparedFixture: URL?
  private let validatesFilters: Bool
  private let focusedResizeOnly: Bool
  private let originalInventory: URL?
  private var hasPreparedInput: Bool { preparedRun != nil || preparedFixture != nil }
  private let runID = UUID().uuidString
  private let disk: ThumbnailDiskCache
  private let sampler = ReleaseOverviewResourceSampler()
  private var nativeVisitLedger: OverviewBitmapVisitLedger?
  private weak var nativeVisitScroll: NSScrollView?
  private var task: Task<Void, Never>?
  private weak var window: NSWindow?
  private weak var root: NSView?
  private var report = ReleaseOverviewReport()
  private var activePhase: ReleaseOverviewResourceSampler.Phase?
  private var sourceURLs: [URL] = []
  private var sourceVersions: [ImageFileVersion] = []
  private var photos: [ImageAsset] = []
  private var indices: [URL: Int] = [:]
  private var phaseWindows: [(name: String, start: Double, end: Double?)] = []
  private var bitmapEvents: [ReleaseOverviewBitmapDisplayEvent] = []
  private var pendingBitmapEvents: [Int] = []
  private var windowUpdateObserver: NSObjectProtocol?
  private var started: Double = 0
  private var filterValidationIsRunning = false
  private var multipleValidator: MultipleViewerNativeValidation?

  private init(environment: [String: String]) {
    defaults = Self.isolatedDefaults!
    source = URL(fileURLWithPath: environment["IMAGEVIEWER_RELEASE_BENCHMARK_SOURCE"] ?? "", isDirectory: true)
    output = URL(fileURLWithPath: environment["IMAGEVIEWER_RELEASE_BENCHMARK_OUTPUT"]
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("release-overview-\(UUID())").path,
      isDirectory: true)
    runtime = output.appendingPathComponent("runtime", isDirectory: true)
    cacheDirectory = runtime.appendingPathComponent("thumbnails", isDirectory: true)
    preparedRun = environment["IMAGEVIEWER_RELEASE_BENCHMARK_PREPARED_RUN"].map {
      URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
    }
    preparedFixture = environment["IMAGEVIEWER_RELEASE_BENCHMARK_PREPARED_FIXTURE"].map {
      URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
    }
    validatesFilters = environment["IMAGEVIEWER_RELEASE_BENCHMARK_FILTERS"] == "1"
    focusedResizeOnly = environment["IMAGEVIEWER_RELEASE_BENCHMARK_FOCUSED_RESIZE"] == "1"
    originalInventory = environment["IMAGEVIEWER_RELEASE_BENCHMARK_ORIGINAL_INVENTORY"].map {
      URL(fileURLWithPath: $0)
    }
    let configuredThermalTarget = OverviewBenchmarkThermalTarget(
      environmentValue: environment["IMAGEVIEWER_RELEASE_BENCHMARK_THERMAL_TARGET"])
    thermalTarget = configuredThermalTarget ?? .nominal
    // LaunchServices may already have created stdout/stderr logs. Result files
    // must be absent. Only an explicit resume may start with a runtime, and it
    // may contain only the externally verified thumbnails directory, no DB.
    ownedOutputWasFresh = (preparedRun == nil && preparedFixture == nil
        ? !FileManager.default.fileExists(atPath: runtime.path)
        : Self.hasOnlyPreparedThumbnails(in: runtime))
      && !FileManager.default.fileExists(atPath: output.appendingPathComponent("release-overview-report.json").path)
      && !FileManager.default.fileExists(atPath: output.appendingPathComponent("exit-status.json").path)
      && !FileManager.default.fileExists(atPath: output.appendingPathComponent("run-identity.json").path)
    explicitConfiguration = environment["IMAGEVIEWER_RELEASE_BENCHMARK_SOURCE"]?.hasPrefix("/") == true
      && environment["IMAGEVIEWER_RELEASE_BENCHMARK_OUTPUT"]?.hasPrefix("/") == true
      && (environment["IMAGEVIEWER_RELEASE_BENCHMARK_PREPARED_RUN"]?.hasPrefix("/") ?? true)
      && (environment["IMAGEVIEWER_RELEASE_BENCHMARK_PREPARED_FIXTURE"]?.hasPrefix("/") ?? true)
      && (environment["IMAGEVIEWER_RELEASE_BENCHMARK_ORIGINAL_INVENTORY"]?.hasPrefix("/") ?? true)
      && !(preparedRun != nil && preparedFixture != nil)
      && configuredThermalTarget != nil
    timeout = min(7_200, max(180, Double(environment["IMAGEVIEWER_RELEASE_BENCHMARK_TIMEOUT_SECONDS"] ?? "") ?? 1_800))
    try? FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    disk = ThumbnailDiskCache(directory: cacheDirectory)
    store = AppStore(defaults: defaults, monitorsSystemResources: true,
      photoMarkDatabaseURL: runtime.appendingPathComponent("marks.sqlite"), thumbnailDiskCache: disk)
  }

  func attach(to view: NSView) {
    guard task == nil, let window = view.window, let content = window.contentView else { return }
    self.window = window
    root = content
    windowUpdateObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.observeNativeWindowUpdate() }
      }
    task = Task { @MainActor [self] in await run() }
  }

  func sidebarBitmapStateApplied(_ event: ThumbnailBitmapStateEvent) {
    multipleValidator?.recordSidebar(event)
  }

  func bitmapStateApplied(_ event: ThumbnailBitmapStateEvent) {
    OverviewNativeResizeValidation.record(event)
    guard bitmapEvents.count < 20_000, let index = indices[event.assetURL],
      let phase = phaseWindows.last(where: { event.requestStartedUptime >= $0.start
        && event.requestStartedUptime <= ($0.end ?? Double.greatestFiniteMagnitude) })?.name else { return }
    let visible = bitmapAssetIsVisible(originalIndex: index)
    bitmapEvents.append(ReleaseOverviewBitmapDisplayEvent(phase: phase, assetIndex: index,
      requestStartedUptime: event.requestStartedUptime, stateAppliedUptime: event.appliedUptime,
      nextNativeWindowUpdateObservedUptime: nil, pixelWidth: event.pixelWidth, pixelHeight: event.pixelHeight,
      isRefinement: event.isRefinement, visibleAtStateApplication: visible,
      visibleAtWindowUpdate: false, appActiveAtWindowUpdate: false,
      windowOcclusionVisibleAtWindowUpdate: false))
    pendingBitmapEvents.append(bitmapEvents.count - 1)
  }

  /// Observe the app's own natural update notification. Never force drawing,
  /// flush a transaction, pump events, or add a layout pass for instrumentation.
  private func observeNativeWindowUpdate() {
    observeNativeBitmapVisits()
    let pending = pendingBitmapEvents
    pendingBitmapEvents.removeAll(keepingCapacity: true)
    let observed = uptime
    for index in pending where bitmapEvents.indices.contains(index) {
      bitmapEvents[index].nextNativeWindowUpdateObservedUptime = observed
      bitmapEvents[index].visibleAtWindowUpdate = bitmapAssetIsVisible(originalIndex: bitmapEvents[index].assetIndex)
      bitmapEvents[index].appActiveAtWindowUpdate = NSApp.isActive
      bitmapEvents[index].windowOcclusionVisibleAtWindowUpdate = window?.occlusionState.contains(.visible) ?? false
    }
  }

  private func run() async {
    started = uptime
    report.runID = runID
    report.requiredStartThermalLevel = thermalTarget.rawValue
    let deadline = started + timeout
    do {
      try require(explicitConfiguration, "explicit_absolute_source_and_output_required")
      try require(ownedOutputWasFresh, "fresh_owned_output_runtime_and_result_files_required")
      if focusedResizeOnly {
        try require(preparedFixture != nil
          && Self.environment["IMAGEVIEWER_RELEASE_BENCHMARK_INTERACTIONS"] == "1",
          "focused_resize_requires_verified_fixture_and_interactions")
      }
      #if DEBUG
        throw ReleaseOverviewRunError(phase: "installed_release_configuration_required")
      #endif
      guard let window, let root else { throw ReleaseOverviewRunError(phase: "actual_root_window_missing") }
      window.setFrameAutosaveName("")
      fitWindow(window)
      report.runtimeCacheDirectory = cacheDirectory.path
      report.existingInstanceProcessIDs = NSWorkspace.shared.runningApplications
        .filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != getpid() }
        .map(\.processIdentifier)
      report.binaryIdentity = try binaryIdentity()
      try writeJSON(ReleaseOverviewRunIdentity(runID: runID, binary: report.binaryIdentity!),
        to: output.appendingPathComponent("run-identity.json"))
      try require(report.binaryIdentity?.executablePath.hasPrefix("/Applications/") == true,
        "installed_Applications_binary_required")
      try require(Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/알맹Re.app",
        "canonical_installed_bundle_required")
      let initialDisk = await disk.snapshot()
      report.coldDiskCacheVerified = initialDisk.entryCount == 0 && initialDisk.byteCount == 0
      if preparedFixture != nil {
        try await validatePreparedFixture(initialDisk: initialDisk)
      } else if preparedRun != nil {
        try validatePreparedResume(initialDisk: initialDisk)
      } else {
        try require(report.coldDiskCacheVerified, "cold_owned_disk_cache_required_no_seed_allowed")
      }
      if focusedResizeOnly {
        report.mode = "focused_prepared_deep_resize"
        try writeJSON(ReleaseOverviewFocusedResizeScope(),
          to: output.appendingPathComponent("focused-resize-scope.json"))
      }
      report.initialCache = await cacheReport(pixels: 768)
      sourceURLs = try FileManager.default.contentsOfDirectory(at: source,
        includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
      var sourceSelection: OverviewBenchmarkSourceSelection.Selection?
      if let originalInventory {
        do {
          let selected = try OverviewBenchmarkSourceSelection.select(sourceURLs: sourceURLs,
            inventoryData: Data(contentsOf: originalInventory))
          sourceSelection = selected
          sourceURLs = selected.sourceURLs
          report.sourceSelection = selected.report
        } catch let error as OverviewBenchmarkSourceSelection.Failure {
          throw ReleaseOverviewRunError(phase: "original_inventory_\(error.rawValue)")
        }
      }
      sourceVersions = sourceURLs.map { ImageFileVersion(url: $0) }
      sampler.observedWindow = window
      sampler.start()
      // The user can continue in another app during preparation. Initial Home
      // observation records actual focus, without requiring a foreground stay.
      window.orderBack(nil)
      report.initialVisibleRootWindowCount = visibleRootWindowCount
      report.applePersistenceIgnoreStateArgumentPresent = ProcessInfo.processInfo.arguments.contains("-ApplePersistenceIgnoreState")
      try require(report.initialVisibleRootWindowCount == 1, "exactly_one_benchmark_RootView_window_required")
      if !hasPreparedInput {
        try await progress("initial_home_observation", pixels: 768)
        begin("installed_release_initial_home_observation")
        try await Task.sleep(for: .seconds(5))
        _ = end()

        try await progress("ready_background_switch", pixels: 768)
        try await wait(until: min(deadline, uptime + 180), phase: "background_start_signal") {
          FileManager.default.fileExists(atPath: self.output.appendingPathComponent("background-start.signal").path)
        }
        try await wait(until: min(deadline, uptime + 30), phase: "actual_other_app_foreground") { self.otherAppIsForeground }
        try await progress("other_app_cold_baseline", pixels: 768)
        begin("installed_release_other_app_empty_home_baseline")
        try await Task.sleep(for: .seconds(30))
        let otherBaseline = end()
        try require(otherBaseline.inactiveSampleFraction >= 0.95 && otherBaseline.otherForegroundSampleFraction >= 0.95,
          "other_app_baseline_activity_validation")
        begin("installed_release_cold_automatic_background_preparation")
        phaseWindows.append(("background", uptime, nil))
      }
      store.presentationMode = .overview
      store.thumbnailSize = 226.4
      store.showsOverviewNumbers = false
      store.showsFolderTree = false
      if let sourceSelection {
        let selectedImages = sourceSelection.sourceURLs.filter {
          !MediaFormatRegistry.isPlaybackMedia($0) && ImageFormatRegistry.canAttemptToDecode($0)
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        try require(selectedImages.count == 729, "expected_729_original_inventory_still_images")
        report.sourceSelection?.selectedImageCount = selectedImages.count
        store.open(urls: selectedImages)
      } else {
        store.openFolderFromTree(source)
      }
      try await wait(until: min(deadline, uptime + 90), phase: "folder_listing") {
        !self.store.isLoading && !self.store.isFiltering && self.store.assets.count > 0
      }
      // Opening from Home deliberately selects the viewer. Follow the normal
      // open-then-overview route after that asynchronous commit has completed.
      // A multiple-file open focuses its first supplied URL. Normalize the
      // diagnostic starting page to the same first sorted photo as a folder open.
      store.select(index: 0)
      store.returnToOverview()
      photos = store.assets
      indices = Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($0.element.url, $0.offset) })
      let nonempty = photos.filter { ($0.byteCount ?? 0) > 0 }
      report.sources = ReleaseOverviewSourceCounts(total: photos.count, nonempty: nonempty.count,
        nonemptyRAW: nonempty.filter { ImageFormatRegistry.cameraRAWExtensions.contains($0.fileExtension) }.count,
        empty: photos.filter { ($0.byteCount ?? 0) == 0 }.count)
      try require(photos.count == 729 && nonempty.count == 717 && report.sources.empty == 12
        && report.sources.nonemptyRAW == 716,
        "expected_729_listed_717_nonempty_12_empty")
      try await wait(until: min(deadline, uptime + 90), phase: "actual_RootView_overview_viewport") {
        root.layoutSubtreeIfNeeded()
        return !self.preloader.visibleIndices.isEmpty && self.overviewScrollView(in: root) != nil
      }
      let scroll = try required(overviewScrollView(in: root), phase: "actual_overview_scroll_missing")
      let pixels = OverviewThumbnailSizing.requestedPixelSize(for: store.thumbnailSize,
        displayScale: window.backingScaleFactor)
      report.requestedPixelSize = ((pixels + 127) / 128) * 128
      report.displayScale = Double(window.backingScaleFactor)
      report.initialVisibleCount = preloader.visibleIndices.count
      report.initialVisibleMinimum = preloader.visibleIndices.min() ?? -1
      report.rootContentWidth = Double(root.bounds.width)
      report.rootContentHeight = Double(root.bounds.height)
      report.initialViewportWidth = Double(scroll.contentView.bounds.width)
      report.initialViewportHeight = Double(scroll.contentView.bounds.height)
      try require(OverviewBenchmarkScrollTarget.hasOverviewViewportDimensions(scroll, in: root),
        "marked_overview_viewport_must_exceed_half_root_width")
      window.orderBack(nil)
      if hasPreparedInput {
        let coverage = await store.thumbnailPipeline.overviewCachedAssetCounts(assets: nonempty, maxPixelSize: pixels)
        try require(coverage.preview == 717, "resumed_cache_must_match_all_current_source_URL_versions")
        report.initialCache = await cacheReport(pixels: pixels)
        report.afterPreparation = report.initialCache
        let stage = preparedFixture == nil ? "ready_native_resume" : "ready_native_fixture"
        try await progress(stage, pixels: pixels)
        try await wait(until: deadline, phase: "native_resume_start_signal") {
          FileManager.default.fileExists(atPath: self.output.appendingPathComponent("\(stage).signal").path)
        }
      } else {
        var nextProgress = uptime
        let preparationDeadline = max(uptime, deadline - 180)
        while true {
          try Task.checkCancellation()
          if uptime >= preparationDeadline { throw ReleaseOverviewRunError(phase: "automatic_background_preparation_deadline") }
          if uptime >= nextProgress {
            try await progress("automatic_background_preparing", pixels: pixels)
            let coverage = await store.thumbnailPipeline.overviewCachedAssetCounts(assets: nonempty, maxPixelSize: pixels)
            if coverage.preview == nonempty.count && !preloader.isPreparing { break }
            nextProgress = uptime + 10
          }
          try await Task.sleep(for: .milliseconds(200))
        }
        if let last = phaseWindows.indices.last { phaseWindows[last].end = uptime }
        let preparation = end()
        try require(preparation.inactiveSampleFraction >= 0.95 && preparation.otherForegroundSampleFraction >= 0.95,
          "automatic_preparation_requires_actual_other_app_foreground")
        try require(!sampler.samples.contains { $0.foregroundBundleID == "com.apple.loginwindow" },
          "loginwindow_is_not_other_app_use")
        report.afterPreparation = await cacheReport(pixels: pixels)
        try require(report.afterPreparation?.previewCoveredAssets == 717, "all_valid_assets_automatically_prepared")
        report.newlyPreparedPreviewAssets = nonempty.count
        try await waitForIdle(until: min(deadline, uptime + 60))
        try await progress("post_preparation_other_app_idle", pixels: pixels)
        begin("installed_release_prepared_other_app_idle")
        try await Task.sleep(for: .seconds(30))
        let idle = end()
        try require(idle.inactiveSampleFraction >= 0.95 && idle.otherForegroundSampleFraction >= 0.95,
          "post_preparation_actual_other_app_idle")
      }

      try await activateOwnWindow(until: min(deadline, uptime + 20))
      let focusedSampleStart = focusedResizeOnly ? sampler.samples.count : nil
      if focusedResizeOnly { try requireFocusedResizeForeground(window) }
      // Restored focus/geometry may have moved while the app was inactive.
      // Begin both directional coverage measurements at the actual top edge.
      store.select(index: 0)
      if let document = scroll.documentView {
        let top = document.isFlipped ? 0 : max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
      }
      try await wait(until: min(deadline, uptime + 10), phase: "native_initial_top_range") {
        self.preloader.visibleIndices.contains(0)
      }
      try await waitForComparableNativeStart(pixels: pixels, deadline: deadline)
      if focusedResizeOnly {
        begin("installed_release_focused_deep_resize_preflight")
        try await prepareFocusedResize(root: root, window: window, pixels: pixels, deadline: deadline)
        _ = end()
        report.nativeStartCache = await cacheReport(pixels: pixels)
      } else {
        report.nativeScrollActivationSucceeded = true
        report.nativeScrollAppWasActive = NSApp.isActive
        report.nativeStartCache = await cacheReport(pixels: pixels)
        _ = await store.thumbnailPipeline.cachedPreviewDiagnosticsSnapshot(clear: true)
        await store.thumbnailPipeline.setCachedPreviewDiagnosticPhase("outbound")
        try await progress("native_scroll_to_end", pixels: pixels)
        begin("installed_release_native_scroll_to_end")
        phaseWindows.append(("outbound", uptime, nil))
        var outbound = try await scrollPass(name: "to_end", towardEnd: true, scroll: scroll, root: root, deadline: deadline)
        phaseWindows[phaseWindows.count - 1].end = uptime
        _ = end()
        report.atEndCache = await cacheReport(pixels: pixels)
        await store.thumbnailPipeline.setCachedPreviewDiagnosticPhase("back")
        try await progress("native_scroll_back", pixels: pixels)
        begin("installed_release_native_scroll_back")
        phaseWindows.append(("back", uptime, nil))
        var back = try await scrollPass(name: "back_to_start", towardEnd: false, scroll: scroll, root: root, deadline: deadline)
        phaseWindows[phaseWindows.count - 1].end = uptime
        _ = end()
        await store.thumbnailPipeline.setCachedPreviewDiagnosticPhase(nil)
        try await waitForIdle(until: min(deadline, uptime + 60))
        let ledger = await store.thumbnailPipeline.cachedPreviewDiagnosticsSnapshot(clear: true)
        outbound.actualUICachedPreview = uiCacheReport(records: ledger, phase: "outbound", seen: outbound.uniqueVisibleCount)
        back.actualUICachedPreview = uiCacheReport(records: ledger, phase: "back", seen: back.uniqueVisibleCount)
        // Diagnostic PNG reads happen only after BOTH genuine UI passes.
        begin("post_roundtrip_diagnostic_cache_probes")
        outbound.cacheFirstPixels = await cacheProbes(pixels: pixels, misses: &outbound.cacheFirstPixelMisses)
        back.cacheFirstPixels = await cacheProbes(pixels: pixels, misses: &back.cacheFirstPixelMisses)
        _ = end()
        report.scrolls = [outbound, back]
        report.afterScrolls = await cacheReport(pixels: pixels)
        report.foregroundValidationComplete = report.phases.filter { $0.name.hasPrefix("installed_release_native_scroll_") }
          .allSatisfy { $0.inactiveSampleFraction <= 0.05 && $0.otherForegroundSampleFraction <= 0.05 }
        try require(report.foregroundValidationComplete, "native_scroll_foreground_validation")
        for pass in report.scrolls {
          try require(pass.uniqueVisibleCount == 729, "native_scroll_must_visit_all_729")
          try require(pass.cacheFirstPixelMisses == 0, "prepared_cache_probe_miss")
          try require(pass.actualUICachedPreview?.uncancelledMisses == 0, "actual_UI_uncancelled_cache_miss")
          try require((pass.actualUICachedPreview?.eligibleRecordedRequests ?? 0) > 0
            && (pass.actualUICachedPreview?.uncancelledHits ?? 0) > 0,
            "actual_UI_ledger_must_record_real_requests_and_hits")
          try require(pass.actualUICachedPreview?.ledgerMayHaveReachedLimit == false,
            "actual_UI_diagnostic_ledger_capacity_reached")
        }
        for pass in report.scrolls {
          // Ready-before-entry is valid retained State. A new callback while the
          // lagging SwiftUI visibility preference says visible is not required.
          try require((pass.nativeBitmapVisits?.observedVisits ?? 0) > 0
            && (pass.nativeBitmapVisits?.samples ?? 0) > 0,
            "native_cell_bitmap_presence_measurement_required")
        }
        if validatesFilters {
          try await validateLibraryFilters(root: root, pixels: pixels, deadline: deadline)
        }
      }
      if Self.environment["IMAGEVIEWER_RELEASE_BENCHMARK_INTERACTIONS"] == "1" {
        try await progress("overview_native_resize", pixels: pixels)
        _ = try await OverviewNativeResizeValidation.run(store: store, preloader: preloader,
          root: root, window: window, output: output)
        if !focusedResizeOnly {
          try await progress("multiple_viewer_navigation", pixels: pixels)
          let validator = MultipleViewerNativeValidation()
          multipleValidator = validator
          defer { multipleValidator = nil }
          try await validator.run(store: store, shortcuts: ShortcutStore(defaults: defaults),
            root: root, window: window, output: output)
        }
      }
      if let focusedSampleStart {
        try requireFocusedResizeForeground(window)
        let samples = sampler.samples.dropFirst(focusedSampleStart)
        try require(!samples.isEmpty && samples.allSatisfy {
          $0.appIsActive && !$0.foregroundIsOtherProcess && $0.foregroundProcessID == getpid()
            && $0.windowVisible && $0.windowOcclusionVisible
        }, "focused_resize_sampled_foreground_or_visibility_lost")
        // Keep the full-scroll fields false/empty: this is a separate scenario.
        var scope = ReleaseOverviewFocusedResizeScope()
        scope.focusedForegroundAndVisibilityAccepted = true
        try writeJSON(scope, to: output.appendingPathComponent("focused-resize-scope.json"))
      }
      report.sourceMetadataUnchanged = sourceURLs.map { ImageFileVersion(url: $0) } == sourceVersions
      try require(report.sourceMetadataUnchanged, "source_metadata_changed")
      report.executableUnchangedAtEnd = try binaryIdentity().executableSHA256 == report.binaryIdentity?.executableSHA256
      try require(report.executableUnchangedAtEnd, "installed_executable_changed_during_run")
      report.status = "completed"
      finish(exitCode: 0)
    } catch {
      if activePhase != nil { _ = end() }
      report.status = "failed"
      report.failurePhase = (error as? ReleaseOverviewRunError)?.phase ?? "unexpected_execution_error"
      report.sourceMetadataUnchanged = sourceURLs.map { ImageFileVersion(url: $0) } == sourceVersions
      // An optional later filter failure must not replace the already measured
      // native roundtrip's cache snapshot with filter/refinement work.
      if report.filterValidation == nil {
        report.afterScrolls = await cacheReport(pixels: report.requestedPixelSize)
      }
      finish(exitCode: 2)
    }
  }

  private func bitmapAssetIsVisible(originalIndex: Int) -> Bool {
    guard filterValidationIsRunning else { return preloader.visibleIndices.contains(originalIndex) }
    guard photos.indices.contains(originalIndex),
      let currentIndex = store.assets.firstIndex(where: { $0.url == photos[originalIndex].url }) else { return false }
    return preloader.visibleIndices.contains(currentIndex)
  }

  private func observeNativeBitmapVisits() {
    guard nativeVisitLedger != nil, let nativeVisitScroll, let window else { return }
    nativeVisitLedger?.observe(OverviewBitmapProbeRegistry.visible(in: nativeVisitScroll,
      window: window), at: uptime)
  }

  private func waitForComparableNativeStart(pixels: Int, deadline: Double) async throws {
    let readyDeadline = min(deadline, uptime + 180)
    var stableSince: Double?
    while uptime < readyDeadline {
      try Task.checkCancellation()
      if focusedResizeOnly, let window { try requireFocusedResizeForeground(window) }
      let cache = await cacheReport(pixels: pixels)
      let visible = preloader.visibleIndices.filter { photos.indices.contains($0)
        && (photos[$0].byteCount ?? 0) > 0 }.count
      let ready = cache.queuedLoads == 0 && cache.runningLoads == 0
        && cache.exactCoveredAssets >= visible && visible > 0
        && thermalTarget.accepts(level: ProcessInfo.processInfo.thermalState.rawValue)
      if ready {
        if stableSince == nil { stableSince = uptime }
        if uptime - (stableSince ?? uptime) >= 2 { return }
      } else { stableSince = nil }
      try await progress(thermalTarget.progressStage, pixels: pixels)
      try await Task.sleep(for: .milliseconds(250))
    }
    throw ReleaseOverviewRunError(phase: thermalTarget.timeoutFailurePhase)
  }

  private func requireFocusedResizeForeground(_ window: NSWindow) throws {
    try require(NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
      "focused_resize_actual_own_process_foreground_lost")
    try require(window.isVisible && window.occlusionState.contains(.visible),
      "focused_resize_actual_window_visibility_lost")
  }

  private func prepareFocusedResize(root: NSView, window: NSWindow, pixels: Int,
    deadline: Double) async throws {
    let index = 580
    try require(store.assets.indices.contains(index) && (store.assets[index].byteCount ?? 0) > 0,
      "focused_resize_nonempty_index580_required")
    let selected = store.assets[index].url
    let revision = store.assetOrderRevision
    store.select(index: index)
    let revealDeadline = min(deadline, uptime + 30)
    while true {
      try Task.checkCancellation()
      try requireFocusedResizeForeground(window)
      try require(store.assetOrderRevision == revision, "focused_resize_collection_changed")
      if store.currentIndex == index, store.currentAsset?.url == selected,
        preloader.visibleIndices.contains(index),
        let scroll = overviewScrollView(in: root),
        OverviewBenchmarkScrollTarget.hasOverviewViewportDimensions(scroll, in: root),
        OverviewBitmapProbeRegistry.visible(in: scroll, window: window).contains(where: { $0.assetURL == selected }) {
        break
      }
      try require(uptime < revealDeadline, "focused_resize_index580_native_reveal_timeout")
      try await Task.sleep(for: .milliseconds(100))
    }
    try await waitForComparableNativeStart(pixels: pixels, deadline: deadline)
    try requireFocusedResizeForeground(window)
    try require(store.assetOrderRevision == revision && store.currentIndex == index
      && store.currentAsset?.url == selected && preloader.visibleIndices.contains(index),
      "focused_resize_index580_membership_changed_before_input")
    try await progress("focused_deep_resize_ready", pixels: pixels)
  }

  /// Keep filtering outside the established cold/prepared/native phases. The
  /// normal query owns metadata reads; its independent result oracle runs only
  /// after the measured UI observation, so it cannot prewarm that first query.
  private func validateLibraryFilters(root: NSView, pixels: Int, deadline: Double) async throws {
    let originalQuery = store.libraryQuery
    let originalURLs = store.assets.map(\.url)
    let originalFolder = store.currentFolderURL
    report.filterValidation = ReleaseOverviewFilterValidationReport(
      originalQuery: originalQuery, originalAssetCount: originalURLs.count)
    filterValidationIsRunning = true
    defer { filterValidationIsRunning = false }
    do {
      try require(originalURLs.count == 729 && store.allAssets.count == 729
        && store.presentationMode == .overview, "filter_validation_original_729_overview_required")
      let nameQuery = LibraryQuery(searchText: "IMG_7*")
      let nameExpected = try await filterExpectedResults(store.allAssets, query: nameQuery)
      try require(!nameExpected.isEmpty && nameExpected.count < originalURLs.count,
        "filename_filter_must_select_nonempty_proper_subset")
      // Establish one real selection that survives this filename filter and
      // its sort. This normal selection warm-up is outside every filter phase.
      let selected = try required(nameExpected.first(where: { ($0.byteCount ?? 0) > 0 }),
        phase: "filename_filter_nonempty_selection_missing")
      let selectedIndex = try required(store.assets.firstIndex(where: { $0.url == selected.url }),
        phase: "filename_filter_selection_not_in_original_collection")
      store.select(index: selectedIndex)
      try await wait(until: min(deadline, uptime + 30), phase: "filter_selection_native_viewport") {
        self.store.currentAsset?.url == selected.url && self.preloader.visibleIndices.contains(self.store.currentIndex)
          && self.overviewScrollView(in: root) != nil
      }
      try await Task.sleep(for: .milliseconds(500))
      try await waitForIdle(until: min(deadline, uptime + 60))

      try await filterStep(name: "filename_search", query: nameQuery,
        metadataReadExpectation: "no_metadata_required", root: root, pixels: pixels, deadline: deadline)
      var descending = nameQuery
      descending.sort = .nameDescending
      try await filterStep(name: "filename_search_name_descending", query: descending,
        metadataReadExpectation: "no_metadata_required", root: root, pixels: pixels, deadline: deadline)
      try await filterStep(name: "filename_restore_729", query: originalQuery,
        metadataReadExpectation: "no_metadata_required", root: root, pixels: pixels, deadline: deadline)

      let metadataBefore = store.allAssets.filter { $0.sortMetadata != nil }.count
      report.filterValidation?.metadataAssetFieldsBeforeFirstQuery = metadataBefore
      report.filterValidation?.firstMetadataQueryHadNoPreparedAssetFields = metadataBefore == 0
      try require(metadataBefore == 0, "first_metadata_filter_requires_unprepared_asset_fields")
      let metadataQuery = LibraryQuery(searchFilters: LibrarySearchFilters(metadataText: "Apple"))
      try await filterStep(name: "metadata_Apple_first_read", query: metadataQuery,
        metadataReadExpectation: "first_normal_query_unprepared_asset_fields_no_oracle_pre_read",
        root: root, pixels: pixels, deadline: deadline)
      let firstVersions = Dictionary(uniqueKeysWithValues: store.allAssets.compactMap { asset in
        asset.sortMetadataVersion.map { (asset.url, $0) }
      })
      try await filterStep(name: "metadata_first_restore_729", query: originalQuery,
        metadataReadExpectation: "already_prepared_fields_retained_no_metadata_required",
        root: root, pixels: pixels, deadline: deadline)
      let repeatFields = store.allAssets.filter { $0.sortMetadata != nil }.count
      let repeatVersions = Dictionary(uniqueKeysWithValues: store.allAssets.compactMap { asset in
        asset.sortMetadataVersion.map { (asset.url, $0) }
      })
      report.filterValidation?.metadataAssetFieldsBeforeRepeat = repeatFields
      report.filterValidation?.metadataVersionsRetainedBeforeRepeat = firstVersions.count == 729
        && firstVersions == repeatVersions
      try require(repeatFields == 729 && report.filterValidation?.metadataVersionsRetainedBeforeRepeat == true,
        "metadata_repeat_requires_all_positive_and_negative_versioned_fields_retained")
      try await filterStep(name: "metadata_Apple_cached_repeat", query: metadataQuery,
        metadataReadExpectation: "second_identical_normal_query_all_versioned_asset_fields_already_present",
        root: root, pixels: pixels, deadline: deadline)
      try await filterStep(name: "metadata_repeat_restore_729", query: originalQuery,
        metadataReadExpectation: "already_prepared_fields_retained_no_metadata_required",
        root: root, pixels: pixels, deadline: deadline)

      report.filterValidation?.queryRestored = store.libraryQuery == originalQuery
      report.filterValidation?.folderRestored = store.currentFolderURL == originalFolder
      report.filterValidation?.originalOrderedCollectionRestored = store.assets.map(\.url) == originalURLs
      let filtersStayedForeground = report.filterValidation?.steps.allSatisfy {
        guard let resources = $0.resources else { return false }
        return resources.inactiveSampleFraction <= 0.05 && resources.otherForegroundSampleFraction <= 0.05
      } ?? false
      report.filterValidation?.foregroundValidationComplete = filtersStayedForeground
      try require(report.filterValidation?.queryRestored == true && report.filterValidation?.folderRestored == true
        && report.filterValidation?.originalOrderedCollectionRestored == true,
        "filters_must_restore_original_query_folder_and_ordered_729_collection")
      try require(report.filterValidation?.foregroundValidationComplete == true,
        "filter_validation_requires_actual_app_foreground")
      report.filterValidation?.afterFilters = await cacheReport(pixels: pixels)
      report.filterValidation?.status = "completed"
      try writeJSON(report.filterValidation!, to: output.appendingPathComponent("filter-validation-report.json"))
    } catch {
      await store.thumbnailPipeline.setCachedPreviewDiagnosticPhase(nil)
      // Restore through the same normal route even when a diagnostic assertion
      // fails. Only this process's isolated store/preferences are affected.
      if store.libraryQuery != originalQuery { store.libraryQuery = originalQuery }
      try? await wait(until: uptime + 30, phase: "failed_filter_query_restore") {
        !self.store.isFiltering && self.store.libraryQuery == originalQuery
      }
      report.filterValidation?.queryRestored = store.libraryQuery == originalQuery && !store.isFiltering
      report.filterValidation?.folderRestored = store.currentFolderURL == originalFolder
      report.filterValidation?.originalOrderedCollectionRestored = store.assets.map(\.url) == originalURLs
      report.filterValidation?.afterFilters = await cacheReport(pixels: pixels)
      report.filterValidation?.status = "failed"
      report.filterValidation?.failurePhase = (error as? ReleaseOverviewRunError)?.phase ?? "unexpected_filter_execution_error"
      try? writeJSON(report.filterValidation!, to: output.appendingPathComponent("filter-validation-report.json"))
      throw error
    }
  }

  private func filterStep(name: String, query: LibraryQuery, metadataReadExpectation: String,
    root: NSView, pixels: Int, deadline: Double) async throws {
    var result = ReleaseOverviewFilterStepReport(name: name, query: query,
      metadataReadExpectation: metadataReadExpectation)
    result.metadataAssetFieldsBefore = store.allAssets.filter { $0.sortMetadata != nil }.count
    let selectionBefore = store.selectedURLs
    let focusBefore = store.currentAsset?.url
    result.selectedCountBefore = selectionBefore.count
    try require(store.libraryQuery != query, "filter_\(name)_must_change_query_to_exercise_normal_path")
    try await progress("filter_\(name)", pixels: pixels)
    _ = await store.thumbnailPipeline.cachedPreviewDiagnosticsSnapshot(clear: true)
    await store.thumbnailPipeline.setCachedPreviewDiagnosticPhase(name)
    begin("installed_release_filter_\(name)")
    phaseWindows.append((name, uptime, nil))
    do {
      let beforeRevision = store.libraryRevision
      QueryPerformanceTrace.reset()
      let queryStarted = uptime
      store.libraryQuery = query
      try await wait(until: min(deadline, uptime + 300), phase: "filter_\(name)_normal_query_completion") {
        !self.store.isLoading && !self.store.isFiltering && self.store.libraryQuery == query
          && self.store.libraryRevision != beforeRevision
      }
      result.queryCompletionWallSeconds = uptime - queryStarted
      let queryCompleted = uptime
      try require(store.alert == nil && !store.assets.isEmpty, "filter_\(name)_nonempty_result_without_alert_required")
      try await wait(until: min(deadline, uptime + 30), phase: "filter_\(name)_actual_overview_viewport") {
        guard let scroll = self.overviewScrollView(in: root) else { return false }
        let visible = self.preloader.visibleIndices
        return !visible.isEmpty && visible.allSatisfy(self.store.assets.indices.contains)
          && visible.contains(self.store.currentIndex)
          && OverviewBenchmarkScrollTarget.hasOverviewViewportDimensions(scroll, in: root)
          && self.window?.isVisible == true
      }
      result.postQueryViewportSettleSeconds = uptime - queryCompleted
      // Observe natural callbacks and at least one regular resource sample. Do
      // not issue image probes, force layout, or draw to obtain this observation.
      try await Task.sleep(for: .seconds(1))
      phaseWindows[phaseWindows.count - 1].end = uptime
      result.resources = end()
      result.queryPerformanceEvents = QueryPerformanceTrace.snapshot(since: queryStarted)
      await store.thumbnailPipeline.setCachedPreviewDiagnosticPhase(nil)
      let ledger = await store.thumbnailPipeline.cachedPreviewDiagnosticsSnapshot(clear: true)
      result.actualUICachedPreview = uiCacheReport(records: ledger, phase: name,
        seen: preloader.visibleIndices.count)
      let firstStates = bitmapEvents.filter {
        $0.phase == name && !$0.isRefinement && $0.visibleAtStateApplication
      }
      result.firstBitmapStateCallbacks = firstStates.count
      result.firstBitmapStateLatencies = ReleaseOverviewLatencyReport(values: firstStates.map {
        max(0, $0.stateAppliedUptime - $0.requestStartedUptime)
      })
      let actual = store.assets
      let inputs = store.allAssets
      let expected = try await filterExpectedResults(inputs, query: query)
      let expectedURLs = expected.map(\.url)
      let actualURLs = actual.map(\.url)
      result.expectedCount = expected.count
      result.actualCount = actual.count
      result.allAssetCount = inputs.count
      result.expectedOriginalOrderSHA256 = try filterOrderDigest(expectedURLs)
      result.actualOriginalOrderSHA256 = try filterOrderDigest(actualURLs)
      result.orderedResultMatchesOracle = actualURLs == expectedURLs
      let actualSet = Set(actualURLs)
      let retainedSelection = selectionBefore.intersection(actualSet)
      result.selectedCountAfter = store.selectedURLs.count
      result.expectedRetainedSelectedCount = retainedSelection.count
      result.selectedURLsMatchExpectedIntersection = store.selectedURLs == retainedSelection
      result.focusRetainedWhenPresent = focusBefore.map { !actualSet.contains($0) || store.currentAsset?.url == $0 } ?? true
      result.currentIndexIsValid = actual.indices.contains(store.currentIndex)
      result.metadataAssetFieldsAfter = inputs.filter { $0.sortMetadata != nil }.count
      result.metadataSearchValuePresentCount = inputs.filter {
        !($0.sortMetadata?.searchableText ?? "").isEmpty
      }.count
      if query.requiresMetadata {
        result.metadataQueryMatchCount = inputs.filter { query.searchFilters.matches($0) }.count
      }
      result.visibleCount = preloader.visibleIndices.count
      result.visibleMinimum = preloader.visibleIndices.min() ?? -1
      result.visibleMaximum = preloader.visibleIndices.max() ?? -1
      result.viewportWiderThanHalfRoot = overviewScrollView(in: root).map {
        OverviewBenchmarkScrollTarget.hasOverviewViewportDimensions($0, in: root)
      } ?? false
      result.visibleRootWindowCount = visibleRootWindowCount
      try require(result.orderedResultMatchesOracle && !expected.isEmpty && inputs.count == 729,
        "filter_\(name)_ordered_result_must_match_same_input_Rust_oracle")
      try require(result.selectedURLsMatchExpectedIntersection && result.focusRetainedWhenPresent
        && result.currentIndexIsValid, "filter_\(name)_selection_and_focus_safety")
      try require(result.visibleCount > 0 && result.viewportWiderThanHalfRoot && result.visibleRootWindowCount == 1,
        "filter_\(name)_actual_single_RootView_marked_viewport_required")
      try require(result.actualUICachedPreview?.uncancelledMisses == 0,
        "filter_\(name)_uncancelled_prepared_cache_miss")
      result.status = "completed"
      report.filterValidation?.steps.append(result)
    } catch {
      if phaseWindows.last?.name == name, phaseWindows.last?.end == nil {
        phaseWindows[phaseWindows.count - 1].end = uptime
      }
      if activePhase != nil { result.resources = end() }
      await store.thumbnailPipeline.setCachedPreviewDiagnosticPhase(nil)
      result.status = "failed"
      result.failurePhase = (error as? ReleaseOverviewRunError)?.phase ?? "unexpected_filter_step_error"
      report.filterValidation?.steps.append(result)
      throw error
    }
  }

  private func filterExpectedResults(_ assets: [ImageAsset], query: LibraryQuery) async throws -> [ImageAsset] {
    let worker = Task.detached(priority: .utility) { try RustImageEngine.query(assets, options: query) }
    return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
  }

  private func filterOrderDigest(_ urls: [URL]) throws -> String {
    let order = try urls.map { try required(indices[$0], phase: "filter_oracle_contains_unknown_original_asset") }
    return SHA256.hash(data: try JSONEncoder().encode(order)).map { String(format: "%02x", $0) }.joined()
  }

  private func finish(exitCode: Int32) {
    preloader.stop(pipeline: store.thumbnailPipeline)
    sampler.stop()
    if let windowUpdateObserver { NotificationCenter.default.removeObserver(windowUpdateObserver) }
    windowUpdateObserver = nil
    report.totalWallSeconds = uptime - started
    report.samples = sampler.samples
    report.bitmapDisplayEvents = bitmapEvents
    report.finalVisibleRootWindowCount = visibleRootWindowCount
    report.existingInstancesStillRunning = report.existingInstanceProcessIDs.filter {
      NSRunningApplication(processIdentifier: $0).map { !$0.isTerminated } ?? false
    }
    var actualExitCode = exitCode
    if ownedOutputWasFresh {
      do {
        try writeJSON(report, to: output.appendingPathComponent("release-overview-report.json"))
        try writeJSON(ReleaseOverviewExitStatus(runID: runID, exitCode: exitCode, finalReportWritten: true),
          to: output.appendingPathComponent("exit-status.json"))
      } catch {
        actualExitCode = 2
        log("RELEASE_OVERVIEW report_write_failed runID=\(runID) processExitCode=2")
      }
    } else {
      actualExitCode = 2
      log("RELEASE_OVERVIEW rejected_nonfresh_output runID=\(runID) processExitCode=2")
    }
    log("RELEASE_OVERVIEW finished runID=\(runID) status=\(report.status) phase=\(report.failurePhase) elapsed=\(Int(report.totalWallSeconds)) processExitCode=\(actualExitCode)")
    defaults.removePersistentDomain(forName: Self.defaultsSuiteName)
    // Only this explicitly launched benchmark process exits. User instances and
    // their in-memory edits are never sent termination or open-file messages.
    Darwin.exit(actualExitCode)
  }

  private func scrollPass(name: String, towardEnd: Bool, scroll: NSScrollView,
    root: NSView, deadline: Double) async throws -> ReleaseOverviewScrollReport {
    let document = try required(scroll.documentView, phase: "scroll_document_missing")
    root.layoutSubtreeIfNeeded()
    let started = uptime
    var result = ReleaseOverviewScrollReport(name: name)
    nativeVisitLedger = OverviewBitmapVisitLedger()
    nativeVisitScroll = scroll
    OverviewBitmapProbeRegistry.onChange = { [weak self] in self?.observeNativeBitmapVisits() }
    let boundsObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.observeNativeBitmapVisits() }
      }
    defer {
      NotificationCenter.default.removeObserver(boundsObserver)
      OverviewBitmapProbeRegistry.onChange = nil
      nativeVisitLedger = nil
      nativeVisitScroll = nil
    }
    observeNativeBitmapVisits()
    var seen = preloader.visibleIndices
    let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
    let steps = max(79, Int(ceil(maximum / max(1, scroll.contentView.bounds.height * 0.9))))
    result.startPosition = logicalPosition(scroll, document)
    for index in 1...steps {
      try Task.checkCancellation()
      if uptime >= deadline { throw ReleaseOverviewRunError(phase: "native_\(name)_deadline") }
      let previousVisible = preloader.visibleIndices
      seen.formUnion(previousVisible)
      let previousPosition = logicalPosition(scroll, document)
      let currentMaximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
      let logical = currentMaximum * CGFloat(towardEnd ? index : steps - index) / CGFloat(steps)
      scroll.contentView.scroll(to: CGPoint(x: 0, y: document.isFlipped ? logical : currentMaximum - logical))
      scroll.reflectScrolledClipView(scroll.contentView)
      await Task.yield()
      try await Task.sleep(for: .milliseconds(20))
      try require(abs(logicalPosition(scroll, document) - previousPosition) > 0.5,
        "native_\(name)_clip_position_did_not_advance")
      // Observe the normal AppKit/SwiftUI update, without forcing every view
      // through another layout pass at every scroll step. A changed native
      // clip alone is insufficient: the actual overview range must advance.
      let settleDeadline = min(deadline, uptime + 2)
      while preloader.visibleIndices.isEmpty || preloader.visibleIndices == previousVisible {
        if uptime >= settleDeadline { throw ReleaseOverviewRunError(phase: "native_\(name)_overview_range_did_not_advance") }
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(20))
      }
      result.nativeScrollSteps += 1
      seen.formUnion(preloader.visibleIndices)
      result.maximumVisibleCount = max(result.maximumVisibleCount, preloader.visibleIndices.count)
      result.finalVisibleMinimum = preloader.visibleIndices.min() ?? -1
      result.finalVisibleMaximum = preloader.visibleIndices.max() ?? -1
      try await Task.sleep(for: .milliseconds(100))
      observeNativeBitmapVisits()
    }
    result.endPosition = logicalPosition(scroll, document)
    try require(preloader.visibleIndices.contains(towardEnd ? photos.count - 1 : 0),
      "native_\(name)_overview_endpoint_not_visible")
    result.uniqueVisibleCount = seen.count
    result.nativeBitmapVisits = nativeVisitLedger?.report()
    result.wallSeconds = uptime - started
    return result
  }

  private func uiCacheReport(records: [CachedPreviewDiagnosticRecord], phase: String,
    seen: Int) -> ReleaseOverviewUICachedPreviewReport {
    let phaseRecords = records.filter { $0.phase == phase }
    let eligible = phaseRecords.filter { record in photos.contains { $0.url == record.assetURL && ($0.byteCount ?? 0) > 0 } }
    let completed = eligible.filter { !$0.cancelled }
    let hits = completed.filter(\.cacheHit)
    let misses = completed.filter { !$0.cacheHit }
    let cancelled = eligible.filter(\.cancelled)
    return ReleaseOverviewUICachedPreviewReport(recordedRequests: phaseRecords.count,
      totalNonemptyAssets: photos.filter { ($0.byteCount ?? 0) > 0 }.count,
      passEligibleVisibleAssets: min(717, seen), eligibleRecordedRequests: eligible.count,
      excludedEmptyOrOtherAssetRequests: phaseRecords.count - eligible.count,
      uncancelledHits: hits.count, uncancelledMisses: misses.count, cancelledRequests: cancelled.count,
      uniqueNonemptyAttemptedAssets: Set(eligible.map(\.assetURL)).count,
      uniqueNonemptyHitAssets: Set(hits.map(\.assetURL)).count,
      uniqueNonemptyMissAssets: Set(misses.map(\.assetURL)).count,
      uniqueNonemptyCancelledAssets: Set(cancelled.map(\.assetURL)).count,
      uniqueVisibleNonemptyHitAssets: Set(hits.map(\.assetURL)).count,
      hitLatencies: ReleaseOverviewLatencyReport(values: hits.map(\.elapsedSeconds)),
      completedRequestLatencies: ReleaseOverviewLatencyReport(values: completed.map(\.elapsedSeconds)),
      ledgerMayHaveReachedLimit: records.count >= 4_096)
  }

  private func cacheProbes(pixels: Int, misses: inout Int) async -> ReleaseOverviewLatencyReport {
    var seconds: [Double] = []
    for asset in photos where (asset.byteCount ?? 0) > 0 {
      let start = uptime
      if let image = await store.thumbnailPipeline.cachedPreview(for: asset, maxPixelSize: pixels),
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        seconds.append(uptime - start)
      } else { misses += 1 }
    }
    return ReleaseOverviewLatencyReport(values: seconds)
  }

  private func cacheReport(pixels: Int) async -> ReleaseOverviewCacheReport {
    let memory = await store.thumbnailPipeline.cacheSnapshot()
    let disk = await disk.snapshot()
    let coverage = await store.thumbnailPipeline.overviewCachedAssetCounts(assets: photos, maxPixelSize: pixels)
    let work = await store.loadingGovernor.stateSnapshot()
    return ReleaseOverviewCacheReport(memoryEntries: memory.entryCount, memoryBytes: memory.byteCount,
      memoryLimit: memory.byteLimit, diskEntries: disk.entryCount, diskBytes: disk.byteCount,
      diskLimit: disk.byteLimit, diskPreviewBytes: disk.previewBytes, diskExactBytes: disk.exactBytes,
      diskHits: disk.hits, diskMisses: disk.misses, previewCoveredAssets: coverage.preview,
      exactCoveredAssets: coverage.exact, runningLoads: work.runningCount, queuedLoads: work.queuedCount)
  }

  private func progress(_ stage: String, pixels: Int) async throws {
    let progress = ReleaseOverviewProgress(stage: stage, elapsedSeconds: uptime - started,
      totalAssets: photos.count, isPreparing: preloader.isPreparing,
      visibleCount: preloader.visibleIndices.count, appIsActive: NSApp.isActive,
      windowVisible: window?.isVisible ?? false,
      windowOcclusionVisible: window?.occlusionState.contains(.visible) ?? false,
      cache: await cacheReport(pixels: pixels), latestSample: sampler.samples.last)
    try writeJSON(progress, to: output.appendingPathComponent("progress.json"))
    log("RELEASE_OVERVIEW stage=\(stage) elapsedSeconds=\(Int(progress.elapsedSeconds)) covered=\(progress.cache.previewCoveredAssets) visible=\(progress.visibleCount) appIsActive=\(progress.appIsActive)")
  }

  private func begin(_ name: String) { activePhase = sampler.beginPhase(name) }
  @discardableResult private func end() -> ReleaseOverviewPhaseReport {
    let phase = sampler.endPhase(activePhase!)
    activePhase = nil
    report.phases.append(phase)
    return phase
  }
  private func waitForIdle(until deadline: Double) async throws {
    try await wait(until: deadline, phase: "governed_work_idle") {
      let state = await self.store.loadingGovernor.stateSnapshot()
      return state.runningCount == 0 && state.queuedCount == 0
    }
  }
  private func wait(until deadline: Double, phase: String, condition: () async -> Bool) async throws {
    while uptime < deadline {
      try Task.checkCancellation()
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ReleaseOverviewRunError(phase: phase)
  }
  private func activateOwnWindow(until deadline: Double) async throws {
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    try await wait(until: deadline, phase: "actual_release_foreground_activation") {
      NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
    }
  }
  private var otherAppIsForeground: Bool {
    guard !NSApp.isActive, let front = NSWorkspace.shared.frontmostApplication else { return false }
    return front.processIdentifier != getpid() && front.bundleIdentifier != "com.apple.loginwindow"
  }

  private static func hasOnlyPreparedThumbnails(in runtime: URL) -> Bool {
    guard runtime.resolvingSymlinksInPath() == runtime.standardizedFileURL,
      let children = try? FileManager.default.contentsOfDirectory(at: runtime,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
      children.count == 1, let thumbnails = children.first,
      thumbnails.lastPathComponent == "thumbnails",
      let values = try? thumbnails.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      else { return false }
    return values.isDirectory == true && values.isSymbolicLink != true
  }

  /// This path deliberately makes no claim that two products have identical
  /// sources. Both products independently verify one immutable prepared fixture
  /// before the common native measurement starts. The strict resume path below
  /// continues to require identical product sources and a previous cold run.
  private func validatePreparedFixture(initialDisk: ThumbnailDiskCacheSnapshot) async throws {
    guard let preparedFixture else { return }
    func sha(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func canonicalSHA(_ object: Any) throws -> String {
      sha(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
    }
    let decoder = JSONDecoder()
    let certificateData = try Data(contentsOf: output.appendingPathComponent("prepared-fixture-proof.json"))
    let certificate = try decoder.decode(PreparedOverviewFixtureCertificate.self, from: certificateData)
    if let failure = certificate.initialFailure(initialDisk: initialDisk,
      executableSHA256: report.binaryIdentity?.executableSHA256 ?? "") {
      throw ReleaseOverviewRunError(phase: failure)
    }
    try require(URL(fileURLWithPath: certificate.sourceDirectory, isDirectory: true).standardizedFileURL == source.standardizedFileURL
      && URL(fileURLWithPath: certificate.destinationCacheDirectory, isDirectory: true).standardizedFileURL == cacheDirectory.standardizedFileURL,
      "prepared_fixture_source_or_owned_destination_path_mismatch")
    let manifestData = try Data(contentsOf: preparedFixture.appendingPathComponent("fixture-manifest.json"))
    try require(sha(manifestData) == certificate.fixtureManifestSHA256, "prepared_fixture_manifest_SHA256_mismatch")
    let manifest = try decoder.decode(PreparedOverviewFixtureManifest.self, from: manifestData)
    let json = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
    try require(manifest.schemaVersion == 1 && manifest.cacheAlgorithmVersion == 1
      && manifest.previews.count == 717 && Set(manifest.previews.map(\.relativePath)).count == 717
      && manifest.compactPreviewBytes == certificate.compactPreviewBytes
      && manifest.previews.reduce(0, { $0 + $1.bytes }) == certificate.compactPreviewBytes,
      "prepared_fixture_manifest_inventory_mismatch")
    let previewDigest = try canonicalSHA(json?["previews"] ?? [])
    try require(previewDigest == manifest.previewManifestSHA256,
      "prepared_fixture_preview_manifest_digest_mismatch")
    for entry in manifest.previews {
      let components = entry.relativePath.split(separator: "/")
      try require(components.count == 2 && components[0].utf8.count == 64
        && components[0].utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        && components[1] == "preview-256.png" && entry.bytes > 0
        && entry.width > 0 && entry.width <= 256 && entry.height > 0 && entry.height <= 256,
        "prepared_fixture_invalid_preview_entry")
      let matches = try autoreleasepool { () throws -> Bool in
        let data = try Data(contentsOf: cacheDirectory.appendingPathComponent(entry.relativePath))
        guard data.count == entry.bytes, sha(data) == entry.sha256, data.count >= 24,
          Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10] else { return false }
        func uint32(_ offset: Int) -> Int {
          data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        return Array(data[12..<16]) == [73, 72, 68, 82]
          && uint32(16) == entry.width && uint32(20) == entry.height
      }
      try require(matches, "prepared_fixture_copied_PNG_SHA256_or_dimensions_mismatch")
    }
    let metadata = manifest.sourceMetadata
    try require(metadata.algorithm == "sha256_compact_sorted_json_pathHash_size_mtimeNs_v1"
      && metadata.fileCount == 734 && metadata.files.count == 734
      && metadata.sha256 == certificate.sourceFileMetadataSHA256,
      "prepared_fixture_source_metadata_inventory_mismatch")
    var urls = try FileManager.default.contentsOfDirectory(at: source,
      includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
      .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    if let originalInventory {
      // Preserve the fixture's exact original inventory when unrelated files
      // were subsequently added to the same real folder. Selection rejects
      // missing/duplicate hashes; the stat/digest check below remains exact.
      urls = try OverviewBenchmarkSourceSelection.select(sourceURLs: urls,
        inventoryData: Data(contentsOf: originalInventory)).sourceURLs
    }
    var current: [[String: Any]] = []
    for url in urls {
      var info = stat()
      try require(url.withUnsafeFileSystemRepresentation { pointer in
        guard let pointer else { return false }
        return Darwin.lstat(pointer, &info) == 0
      }, "prepared_fixture_source_stat_failed")
      current.append(["pathSHA256": sha(Data(url.standardizedFileURL.path.utf8)),
        "sizeBytes": Int64(info.st_size), "mtimeNanoseconds": Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)])
    }
    current.sort { ($0["pathSHA256"] as? String ?? "") < ($1["pathSHA256"] as? String ?? "") }
    let currentMetadataDigest = try canonicalSHA(current)
    try require(current.count == 734 && currentMetadataDigest == metadata.sha256,
      "prepared_fixture_current_source_metadata_changed")
    let memory = await store.thumbnailPipeline.cacheSnapshot()
    try require(memory.entryCount == 0 && memory.byteCount == 0, "prepared_fixture_initial_RAM_must_be_empty")
    report.mode = "prepared_fixture_native_only"
    report.preparationMode = report.mode
    report.fixtureManifestSHA256 = certificate.fixtureManifestSHA256
    report.fixturePreviewManifestSHA256 = manifest.previewManifestSHA256
    report.fixtureSourceMetadataSHA256 = metadata.sha256
    report.fixtureCertificateSHA256 = sha(certificateData)
    report.fixtureProductSourceDigestSHA256 = certificate.productSourceDigestSHA256
    report.fixtureMeasurementSourceDigestSHA256 = certificate.measurementSourceDigestSHA256
    report.fixtureInitialDiskOnlyCompactVerified = true
    report.fixtureInitialMemoryEmptyVerified = true
    report.coldDiskCacheVerified = false
    report.seedPreviewAssets = 717
    report.newlyPreparedPreviewAssets = 0
    report.storageCacheScope = "common_frozen_717_compact_PNG_fixture_new_private_RAM_and_disk_no_claim_of_cold_RAW_preparation_OS_caches_uncontrolled"
  }

  /// The operator creates this certificate after comparing source metadata,
  /// product-source manifests and all copied PNG CRCs/hashes. The app binds it
  /// to this executable, the exact previous report and the current URL/version
  /// cache keys. It never copies a cache or writes an original image itself.
  private func validatePreparedResume(initialDisk: ThumbnailDiskCacheSnapshot) throws {
    guard let preparedRun else { return }
    try require(preparedRun != output.standardizedFileURL, "prepared_resume_must_use_a_new_owned_output")
    let decoder = JSONDecoder()
    let previousData = try Data(contentsOf: preparedRun.appendingPathComponent("release-overview-report.json"))
    let previous = try decoder.decode(PreparedOverviewSourceReport.self, from: previousData)
    let previousExit = try decoder.decode(ReleaseOverviewExitStatus.self,
      from: Data(contentsOf: preparedRun.appendingPathComponent("exit-status.json")))
    let certificateData = try Data(contentsOf: output.appendingPathComponent("resume-prepared-proof.json"))
    let certificate = try decoder.decode(PreparedOverviewCertificate.self, from: certificateData)
    func sha(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func isDigest(_ value: String) -> Bool {
      value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
    try require(previous.status == "failed" && previous.failurePhase == "actual_release_foreground_activation",
      "prepared_resume_source_must_have_failed_only_native_activation")
    try require(previousExit.runID == previous.runID && previousExit.exitCode == 2 && previousExit.finalReportWritten,
      "prepared_resume_source_exit_identity_required")
    try require(certificate.sourceRunID == previous.runID && certificate.sourceReportSHA256 == sha(previousData),
      "prepared_resume_source_report_digest_mismatch")
    try require(previous.binaryIdentity.compiledWithDebugConfiguration == false
      && previous.binaryIdentity.appVersion == report.binaryIdentity?.appVersion
      && certificate.sourceExecutableSHA256 == previous.binaryIdentity.executableSHA256
      && certificate.currentExecutableSHA256 == report.binaryIdentity?.executableSHA256,
      "prepared_resume_executable_lineage_mismatch")
    try require(certificate.productSourceInputsIdentical
      && isDigest(certificate.previousProductSourceDigestSHA256)
      && certificate.previousProductSourceDigestSHA256 == certificate.currentProductSourceDigestSHA256,
      "prepared_resume_product_sources_must_match")
    try require(certificate.sourceMetadataUnchangedSincePreparation && isDigest(certificate.sourceFileMetadataSHA256)
      && URL(fileURLWithPath: certificate.sourceDirectory, isDirectory: true).standardizedFileURL == source.standardizedFileURL
      && previous.sourceMetadataUnchanged,
      "prepared_resume_source_metadata_proof_required")
    try require(previous.sources.total == 729 && previous.sources.nonempty == 717
      && previous.sources.nonemptyRAW == 716 && previous.sources.empty == 12,
      "prepared_resume_source_inventory_mismatch")
    try require(previous.coldDiskCacheVerified && previous.seedPreviewAssets == 0
      && previous.newlyPreparedPreviewAssets == 717
      && previous.initialCache.diskEntries == 0 && previous.initialCache.diskBytes == 0
      && previous.afterPreparation.previewCoveredAssets == 717,
      "prepared_resume_source_must_have_completed_cold_717_preparation")
    for name in ["installed_release_other_app_empty_home_baseline",
      "installed_release_cold_automatic_background_preparation", "installed_release_prepared_other_app_idle"] {
      let matches = previous.phases.filter { $0.name == name }
      try require(matches.count == 1 && matches[0].inactiveSampleFraction >= 0.95
        && matches[0].otherForegroundSampleFraction >= 0.95,
        "prepared_resume_source_requires_actual_other_app_phases")
      if name != "installed_release_cold_automatic_background_preparation" {
        try require(matches[0].wallSeconds >= 29.5, "prepared_resume_source_30_second_baseline_required")
      }
    }
    try require(!previous.samples.isEmpty && !previous.samples.contains { $0.foregroundBundleID == "com.apple.loginwindow" },
      "prepared_resume_source_must_not_include_loginwindow")
    try require(previous.initialViewportWidth > previous.rootContentWidth * 0.5
      && previous.overviewScrollTargetScope == report.overviewScrollTargetScope,
      "prepared_resume_source_must_identify_actual_overview_grid")
    try require(certificate.verifiedPNGCount == 717 && certificate.uniqueSourceHashes == 717
      && certificate.pngCRCAndDimensionsVerified && certificate.compactPreviewBytes > 0
      && certificate.compactPreviewBytes <= 128 * 1_024 * 1_024
      && URL(fileURLWithPath: certificate.destinationCacheDirectory, isDirectory: true).standardizedFileURL == cacheDirectory.standardizedFileURL,
      "prepared_resume_verified_seed_certificate_required")
    try require(initialDisk.entryCount == 717 && initialDisk.previewBytes == certificate.compactPreviewBytes
      && initialDisk.byteCount == certificate.compactPreviewBytes && initialDisk.exactBytes == 0,
      "prepared_resume_seed_must_contain_only_717_verified_compact_previews")
    report.mode = "resume_prepared_native_only"
    report.preparationMode = "resume_prepared_native_only"
    report.resumeSourceRunID = previous.runID
    report.resumeSourceReportSHA256 = certificate.sourceReportSHA256
    report.resumeCertificateSHA256 = sha(certificateData)
    report.coldDiskCacheVerified = false
    report.seedPreviewAssets = 717
    report.newlyPreparedPreviewAssets = 0
    report.storageCacheScope = "externally_verified_717_compact_preview_seed_OS_file_cache_and_QuickLook_cache_uncontrolled"
  }

  private var visibleRootWindowCount: Int {
    NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }.count
  }
  private func overviewScrollView(in view: NSView) -> NSScrollView? {
    OverviewBenchmarkScrollTarget.find(in: view)
  }
  private func logicalPosition(_ scroll: NSScrollView, _ document: NSView) -> Double {
    Double(document.isFlipped ? scroll.contentView.bounds.minY
      : max(0, document.bounds.height - scroll.contentView.bounds.height) - scroll.contentView.bounds.minY)
  }
  private func fitWindow(_ window: NSWindow) {
    guard let screen = window.screen ?? NSScreen.main else { return }
    let available = screen.visibleFrame.insetBy(dx: 10, dy: 10)
    let chrome = max(0, window.frame.height - (window.contentView?.bounds.height ?? 0))
    window.setContentSize(NSSize(width: min(1_728, available.width), height: min(930, available.height - chrome)))
    window.setFrameOrigin(NSPoint(x: available.minX, y: max(available.minY, available.maxY - window.frame.height)))
    report.windowFrameWidth = Double(window.frame.width)
    report.windowFrameHeight = Double(window.frame.height)
    report.screenVisibleFrameWidth = Double(screen.visibleFrame.width)
    report.screenVisibleFrameHeight = Double(screen.visibleFrame.height)
  }
  private func binaryIdentity() throws -> ReleaseOverviewBinaryIdentity {
    let executable = try required(Bundle.main.executableURL, phase: "bundle_executable_missing")
    let handle = try FileHandle(forReadingFrom: executable)
    defer { try? handle.close() }
    var hash = SHA256()
    while let block = try handle.read(upToCount: 1_024 * 1_024), !block.isEmpty { hash.update(data: block) }
    return ReleaseOverviewBinaryIdentity(processID: getpid(), executablePath: executable.path,
      executableSHA256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
      bundleIdentifier: Bundle.main.bundleIdentifier ?? "unavailable",
      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unavailable",
      appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unavailable",
      compiledWithDebugConfiguration: Self.compiledWithDebugConfiguration,
      executionScope: "actual_installed_application_RootView_WindowGroup_process_no_XCTest_host")
  }
  private func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
  }
  private func require(_ condition: Bool, _ phase: String) throws {
    guard condition else { throw ReleaseOverviewRunError(phase: phase) }
  }
  private func required<T>(_ value: T?, phase: String) throws -> T {
    guard let value else { throw ReleaseOverviewRunError(phase: phase) }
    return value
  }
  private func log(_ value: String) { FileHandle.standardOutput.write(Data((value + "\n").utf8)) }
  private static var compiledWithDebugConfiguration: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }
  private var uptime: Double { ProcessInfo.processInfo.systemUptime }
}

/// This anchor is installed only when the overview's diagnostic bitmap callback
/// is supplied. Document height cannot identify a grid: a narrow 729-row sidebar
/// is taller than the overview's multi-column document.
@MainActor
enum OverviewBenchmarkScrollTarget {
  static let markerIdentifier = NSUserInterfaceItemIdentifier(
    "org.openimageviewer.diagnostics.overview-grid-scroll-anchor")

  static func find(in root: NSView) -> NSScrollView? {
    var markers: [NSView] = []
    func collect(_ view: NSView) {
      if view.identifier == markerIdentifier { markers.append(view) }
      view.subviews.forEach(collect)
    }
    collect(root)
    guard markers.count == 1, let marker = markers.first,
      !marker.isHiddenOrHasHiddenAncestor,
      let scroll = marker.enclosingScrollView, !scroll.isHiddenOrHasHiddenAncestor,
      let document = scroll.documentView,
      document.bounds.height > scroll.contentView.bounds.height,
      scroll.contentView.bounds.height > 0 else { return nil }
    return scroll
  }

  static func hasOverviewViewportDimensions(_ scroll: NSScrollView, in root: NSView) -> Bool {
    root.bounds.width > 0 && scroll.contentView.bounds.width > root.bounds.width * 0.5
      && scroll.contentView.bounds.height > 0
  }
}

struct OverviewBenchmarkScrollMarker: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    view.identifier = OverviewBenchmarkScrollTarget.markerIdentifier
    return view
  }
  func updateNSView(_ nsView: NSView, context: Context) {}
}

struct OverviewReleaseBenchmarkAttachment: NSViewRepresentable {
  let benchmark: OverviewReleaseBenchmark
  func makeNSView(context: Context) -> NSView { OverviewReleaseBenchmarkAttachView(benchmark: benchmark) }
  func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
private final class OverviewReleaseBenchmarkAttachView: NSView {
  let benchmark: OverviewReleaseBenchmark
  init(benchmark: OverviewReleaseBenchmark) { self.benchmark = benchmark; super.init(frame: .zero) }
  required init?(coder: NSCoder) { return nil }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { benchmark.attach(to: self) }
  }
}

private struct ReleaseOverviewRunError: Error { let phase: String }
private struct ReleaseOverviewFocusedResizeScope: Encodable {
  let mode = "focused_prepared_deep_resize"
  let focusIndex = 580
  let fullCollectionRoundtripExecuted = false
  let filterSequenceExecuted = false
  let multipleViewerNavigationExecuted = false
  let nativeResizeInputTimerAndQualityGatesUnchanged = true
  let comparisonScope = "same_focused_scenario_only_not_full_scroll_and_seven_filter_history"
  var focusedForegroundAndVisibilityAccepted = false
}
private struct ReleaseOverviewExitStatus: Codable {
  let runID: String
  let exitCode: Int32
  let finalReportWritten: Bool
}

private struct PreparedOverviewCertificate: Decodable {
  let sourceRunID: String
  let sourceReportSHA256: String
  let sourceExecutableSHA256: String
  let currentExecutableSHA256: String
  let sourceDirectory: String
  let destinationCacheDirectory: String
  let sourceFileMetadataSHA256: String
  let sourceMetadataUnchangedSincePreparation: Bool
  let previousProductSourceDigestSHA256: String
  let currentProductSourceDigestSHA256: String
  let productSourceInputsIdentical: Bool
  let verifiedPNGCount: Int
  let uniqueSourceHashes: Int
  let pngCRCAndDimensionsVerified: Bool
  let compactPreviewBytes: Int
}

private struct PreparedOverviewSourceReport: Decodable {
  struct Binary: Decodable {
    let appVersion: String
    let executableSHA256: String
    let compiledWithDebugConfiguration: Bool
  }
  struct Sources: Decodable {
    let total: Int
    let nonempty: Int
    let nonemptyRAW: Int
    let empty: Int
  }
  struct Cache: Decodable {
    let diskEntries: Int
    let diskBytes: Int
    let previewCoveredAssets: Int
  }
  struct Phase: Decodable {
    let name: String
    let wallSeconds: Double
    let inactiveSampleFraction: Double
    let otherForegroundSampleFraction: Double
  }
  struct Sample: Decodable { let foregroundBundleID: String }
  let runID: String
  let status: String
  let failurePhase: String
  let binaryIdentity: Binary
  let sourceMetadataUnchanged: Bool
  let sources: Sources
  let coldDiskCacheVerified: Bool
  let seedPreviewAssets: Int
  let newlyPreparedPreviewAssets: Int
  let initialCache: Cache
  let afterPreparation: Cache
  let phases: [Phase]
  let samples: [Sample]
  let initialViewportWidth: Double
  let rootContentWidth: Double
  let overviewScrollTargetScope: String
}
private struct ReleaseOverviewRunIdentity: Encodable {
  let runID: String
  let binary: ReleaseOverviewBinaryIdentity
}
