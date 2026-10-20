import AppKit
import CryptoKit
import Darwin
import Foundation

/// Explicit installed-release diagnostics. No production preference domain,
/// source pixels, source files, caches, worker budgets or loading policy change.
@MainActor
final class MultipleViewerNativeValidation {
  private struct FrameEvent {
    let request: ViewerFrameRequest
    let applied: Double
    let width: Int
    let height: Int
    let refinement: Bool
    let sourceMaximumDimension: Double?
    let imageIdentity: ObjectIdentifier

    var hasSourceDimensions: Bool { sourceMaximumDimension != nil }
  }
  private struct ValidationFailure: Error {
    let phase: String
  }

  private var events: [FrameEvent] = []
  private var sidebarEvents: [ThumbnailBitmapStateEvent] = []
  private var resourceSamples: [[String: Any]] = []
  private var scenarios: [[String: Any]] = []
  private var sameOrderQueryDiagnostics: [String: Any]?
  private var running = false
  private var ledgerTruncated = false
  private let maximumEvents = 2_048
  private var previousResource: (uptime: Double, cpu: Double)?

  func recordViewer(request: ViewerFrameRequest, frame: RenderedFrame, isRefinement: Bool) {
    guard running else { return }
    guard events.count < maximumEvents else { ledgerTruncated = true; return }
    events.append(FrameEvent(request: request, applied: ProcessInfo.processInfo.systemUptime,
      width: frame.image.width, height: frame.image.height, refinement: isRefinement,
      sourceMaximumDimension: frame.sourcePixelSize.map { Double(max($0.width, $0.height)) },
      imageIdentity: ObjectIdentifier(frame.image)))
  }

  /// Optional existing SidebarView callback; a missing hook is reported explicitly.
  func recordSidebar(_ event: ThumbnailBitmapStateEvent) {
    guard running else { return }
    guard sidebarEvents.count < maximumEvents else { ledgerTruncated = true; return }
    sidebarEvents.append(event)
  }

  /// Uses the product keyboard router with real NSEvents and the already hosted
  /// RootView. It does not inject OS key events or create an XCTest hosting view.
  func run(store: AppStore, shortcuts: ShortcutStore, root: NSView, window: NSWindow,
    output: URL) async throws {
    let began = ProcessInfo.processInfo.systemUptime
    let deadline = began + 120
    let originalAssets = store.assets
    let originalURLs = originalAssets.map(\.id)
    let originalMode = store.presentationMode
    let originalCount = store.imagesPerPage
    let originalIndex = store.currentIndex
    let originalPlacement = store.thumbnailPanelPlacement
    let originalWraps = store.wrapsNavigation
    let originalFocus = store.isFocusMode
    let originalMarking = store.isPhotoMarking
    let originalScale = store.baseScaleMode
    let originalZoom = store.zoom
    let originalPan = store.panOffset
    let originalQuery = store.libraryQuery
    let originalComparison = store.comparisonLayout
    let previousObserver = ViewerFrameLoader.diagnosticPresentationObserver
    let sidebarDiagnosticPrefix = "multiple_viewer_sidebar_\(UUID())_"
    var report: [String: Any] = [
      "status": "running", "processID": getpid(), "startedUptime": began,
      "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
      "scope": "actual_installed_RootView; product_handleViewerKeyDown_with_constructed_NSEvent; no_OS_event_injection_or_XCTest_host",
      "bitmapScope": "ViewerFrameLoader accepted preview/refinement publication plus native CGImage backing layer observation; not physical compositor paint",
      "latencyScope": "page input to accepted target asset publication includes admission, decode, cache and actor waits; never isolated decode time",
      "qualityScope": "existing requested display resolution, HDR flag and actual-visible-count loading policy are checked at precise publication; no source/export quality changes",
      "sidebarScope": "actual mounted vertical/horizontal native scroll view; optional bitmap callback counts explicitly reported",
      "cacheScope": "existing bounded caches retained, not purged or enlarged; caller determines prepared/cold state",
      "sourcePathsExported": false, "sourcePixelsExported": false,
      "scenarioTimeLimitSeconds": 120,
    ]
    running = true
    events.removeAll(); sidebarEvents.removeAll(); resourceSamples.removeAll(); scenarios.removeAll()
    sameOrderQueryDiagnostics = nil
    ledgerTruncated = false; previousResource = nil
    ViewerFrameLoader.diagnosticPresentationObserver = { [weak self] request, frame, refinement in
      previousObserver?(request, frame, refinement)
      self?.recordViewer(request: request, frame: frame, isRefinement: refinement)
    }
    let sampler = Task { @MainActor [weak self, weak window] in
      while !Task.isCancelled {
        if let window { self?.sampleResources(window: window) }
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
      }
    }
    defer {
      sampler.cancel()
      running = false
      ViewerFrameLoader.diagnosticPresentationObserver = previousObserver
      store.libraryQuery = originalQuery
      store.wrapsNavigation = originalWraps
      store.isPhotoMarking = originalMarking
      store.thumbnailPanelPlacement = originalPlacement
      store.setImagesPerPage(originalCount)
      if store.assets.indices.contains(originalIndex) { store.select(index: originalIndex) }
      store.presentationMode = originalMode
      store.isFocusMode = originalFocus
      store.setComparisonLayout(originalComparison)
      store.baseScaleMode = originalScale
      store.zoom = originalZoom
      store.panOffset = originalPan
    }
    do {
      try require(root.window === window && window.isVisible, "multiple_viewer_actual_root_window_required")
      try require(originalAssets.count >= 40
        && originalAssets.prefix(40).allSatisfy { ($0.byteCount ?? 0) > 0 && !$0.isPlaybackMedia },
        "multiple_viewer_nonempty_first_40_photos_required")
      try require(!store.isLoading && !store.isFiltering, "multiple_viewer_library_must_be_ready")
      try requireForeground(window)
      store.pauseSlideshow()
      store.isPhotoMarking = false
      store.isFocusMode = false
      store.wrapsNavigation = false
      store.setComparisonLayout(.off)
      store.presentationMode = .viewer
      store.setFitToWindow()
      for count in [2, 4, 6, 9] {
        try requireForeground(window)
        let scenarioStart = ProcessInfo.processInfo.systemUptime
        let cpuStart = OverviewWarmCPUCost.processCPUSeconds()
        let eventStart = events.count
        let sidebarStart = sidebarEvents.count
        let resourceStart = resourceSamples.count
        let sidebarPhase = sidebarDiagnosticPrefix + String(count)
        await store.thumbnailPipeline.setCachedPreviewDiagnosticPhase(sidebarPhase)
        store.thumbnailPanelPlacement = count <= 4 ? .left : .bottom
        store.select(index: 0)
        store.setImagesPerPage(count)
        let initial = store.visibleAssets
        try require(Self.isExactPage(actual: initial, all: originalAssets, start: 0, count: count),
          "multiple_viewer_initial_page_identity")
        let initialInput = ProcessInfo.processInfo.systemUptime
        let initialReady = try await waitForPage(store: store, root: root, window: window,
          assets: initial, since: initialInput, eventFloor: eventStart,
          until: min(deadline, initialInput + 16))
        try require(nativeSidebarScrollViews(root: root, horizontal: count > 4).count > 0,
          "multiple_viewer_sidebar_native_scroll_missing")

        let inputBegan = ProcessInfo.processInfo.systemUptime
        var inputs: [[String: Any]] = []
        var expectedStart = 0
        // Reach three pages, then return to a different final page. Every step
        // validates order/duplicates/selection before asynchronous decode settles.
        for direction in [1, 1, 1, -1, -1, 1, -1] {
          try requireForeground(window)
          let previousStart = expectedStart
          expectedStart = max(0, min(originalAssets.count - count, expectedStart + direction * count))
          let inputTime = ProcessInfo.processInfo.systemUptime
          let event = try keyEvent(direction: direction, window: window)
          try require(store.handleViewerKeyDown(event, shortcuts: shortcuts),
            "multiple_viewer_product_keyboard_route_rejected")
          let expected = Array(originalAssets[expectedStart..<expectedStart + count])
          try require(store.pageStartIndex == expectedStart && store.currentIndex == expectedStart
            && store.selectedURLs == [expected[0].url]
            && Self.isExactPage(actual: store.visibleAssets, all: originalAssets,
              start: expectedStart, count: count), "multiple_viewer_page_gap_order_selection")
          inputs.append(["direction": direction, "previousPageStart": previousStart,
            "pageStart": expectedStart, "inputUptime": inputTime,
            "visibleCount": store.visibleAssets.count,
            "sidebarScrollOrigins": nativeSidebarScrollViews(root: root, horizontal: count > 4)
              .map { ["x": $0.contentView.bounds.origin.x, "y": $0.contentView.bounds.origin.y] }])
          try await Task.sleep(for: .milliseconds(90))
        }
        let lastInput = try requiredNumber(inputs.last?["inputUptime"])
        let inputEnded = ProcessInfo.processInfo.systemUptime
        let finalAssets = store.visibleAssets
        let finalReady = try await waitForPage(store: store, root: root, window: window,
          assets: finalAssets, since: lastInput, eventFloor: eventStart,
          until: min(deadline, lastInput + 18))
        try require(store.assets.map(\.id) == originalURLs, "multiple_viewer_collection_order_changed")
        sampleResources(window: window)
        let cpuEnd = OverviewWarmCPUCost.processCPUSeconds()
        let elapsed = ProcessInfo.processInfo.systemUptime - scenarioStart
        let phaseEvents = Array(events.dropFirst(eventStart))
        let phaseResources = Array(resourceSamples.dropFirst(resourceStart))
        let sidebarCache = await store.thumbnailPipeline.cachedPreviewDiagnosticsSnapshot()
          .filter { $0.phase == sidebarPhase && !$0.cancelled }
        scenarios.append([
          "visibleCount": count, "loadingPolicy": count <= 4 ? "quality" : "responsive",
          "sidebarPlacement": store.thumbnailPanelPlacement.rawValue,
          "wallSeconds": elapsed,
          "processCPUSeconds": cpuDelta(cpuStart, cpuEnd).map { $0 as Any } ?? NSNull(),
          "averageCPUPercentOneCore": cpuDelta(cpuStart, cpuEnd).map { $0 / elapsed * 100 as Any } ?? NSNull(),
          "sampledCPUPercentOneCore": Self.distribution(phaseResources.filter {
            ($0["intervalSeconds"] as? Double ?? 0) >= 0.25
          }.compactMap { $0["cpuPercentOneCore"] as? Double }, unit: "PercentOneCore"),
          "maximumFootprintBytes": phaseResources.compactMap { $0["footprintBytes"] as? UInt64 }.max() ?? 0,
          "inputCount": inputs.count, "inputBurstWallSeconds": inputEnded - inputBegan,
          "inputSpacingMilliseconds": 90, "inputs": inputs,
          "initialPage": initialReady, "finalPageStart": expectedStart, "finalPage": finalReady,
          "previewPublications": phaseEvents.filter { !$0.refinement }.count,
          "precisePublications": phaseEvents.filter(\.refinement).count,
          "sidebarBitmapPublications": sidebarEvents.count - sidebarStart,
          "sidebarCacheOnlyRequests": sidebarCache.count,
          "sidebarCacheOnlyHits": sidebarCache.filter(\.cacheHit).count,
          "sidebarCacheOnlyMisses": sidebarCache.filter { !$0.cacheHit }.count,
          "sidebarCacheOnlyReturnSeconds": Self.distribution(sidebarCache.map(\.elapsedSeconds)),
          "nativeBackingAtFinal": nativeBackings(root: root),
        ])
      }
      report["sameOrderQueryValidation"] = try await validateSameOrderRepublish(
        store: store, root: root, window: window, deadline: deadline)
      try require(!ledgerTruncated, "multiple_viewer_diagnostic_ledger_capacity")
      try require(!sidebarEvents.isEmpty && sidebarEvents.allSatisfy {
        originalURLs.contains($0.assetURL) && $0.pixelWidth > 0 && $0.pixelHeight > 0
      }, "multiple_viewer_actual_sidebar_bitmap_callbacks_required")
      let sidebarCache = await store.thumbnailPipeline.cachedPreviewDiagnosticsSnapshot()
        .filter { $0.phase.hasPrefix(sidebarDiagnosticPrefix) && !$0.cancelled }
      try require(!sidebarCache.isEmpty && sidebarCache.allSatisfy(\.cacheHit),
        "multiple_viewer_prepared_sidebar_cache_miss_or_missing_requests")
      try require(resourceSamples.allSatisfy { ($0["foregroundIsOwnProcess"] as? Bool) == true },
        "multiple_viewer_requires_actual_app_foreground")
      await store.thumbnailPipeline.setCachedPreviewDiagnosticPhase(nil)
      report["status"] = "completed"
    } catch {
      await store.thumbnailPipeline.setCachedPreviewDiagnosticPhase(nil)
      if let sameOrderQueryDiagnostics { report["sameOrderQueryValidation"] = sameOrderQueryDiagnostics }
      report["status"] = "failed"
      report["failurePhase"] = (error as? ValidationFailure)?.phase ?? "unexpected_multiple_viewer_validation_error"
      try? finishReport(&report, began: began, output: output)
      throw error
    }
    try finishReport(&report, began: began, output: output)
  }

  private func waitForPage(store: AppStore, root: NSView, window: NSWindow, assets: [ImageAsset],
    since: Double, eventFloor: Int, until deadline: Double) async throws -> [String: Any] {
    let expected = Set(assets.map(\.url))
    while ProcessInfo.processInfo.systemUptime < deadline {
      try Task.checkCancellation()
      try requireForeground(window)
      let relevant = events.dropFirst(eventFloor).filter { $0.applied >= since && expected.contains($0.request.asset.url) }
      let presented = assets.enumerated().allSatisfy {
        store.viewerPresentedAssets[$0.offset] == AppStore.PresentedAssetVersion($0.element)
      }
      let precise = Set(relevant.filter(\.refinement).map { $0.request.asset.url })
      if presented && precise == expected {
        let finalEvents = assets.compactMap { asset in
          relevant.last { $0.refinement && $0.request.asset.url == asset.url }
        }
        try require(finalEvents.count == assets.count
          && finalEvents.allSatisfy { Self.finalFrameIsValid(request: $0.request,
            width: $0.width, height: $0.height, isRefinement: $0.refinement,
            sourceMaximumDimension: $0.sourceMaximumDimension, visibleCount: assets.count,
            prefersHDR: store.prefersHDR) }, "multiple_viewer_final_quality_or_policy_mismatch")
        let first = assets.compactMap { asset in relevant.first { $0.request.asset.url == asset.url } }
        let backings = nativeBackings(root: root)
        if backings.count == assets.count,
          nativeImageIdentities(root: root) == Set(finalEvents.map(\.imageIdentity)) {
          return ["uniqueExpectedAssets": expected.count, "acceptedTargetSlots": assets.count,
            "firstAcceptedTargetSeconds": Self.distribution(first.map { $0.applied - since }),
            "preciseTargetSeconds": Self.distribution(finalEvents.map { $0.applied - since }),
            "allTargetFirstAcceptedSeconds": first.map { $0.applied - since }.max() ?? 0,
            "allTargetPreciseSeconds": finalEvents.map { $0.applied - since }.max() ?? 0,
            "nativeBackingCount": backings.count, "nativeLayersContainAcceptedPreciseCGImages": true,
            "preciseMaximumDimensions": finalEvents.map { max($0.width, $0.height) },
            "requestedMaximumDimensions": finalEvents.map { $0.request.maxPixelSize },
            "allHaveDefinitiveSourceDimensions": finalEvents.allSatisfy(\.hasSourceDimensions)]
        }
      }
      try await Task.sleep(for: .milliseconds(40))
    }
    throw ValidationFailure(phase: "multiple_viewer_page_presentation_or_precise_timeout")
  }

  private func validateSameOrderRepublish(store: AppStore, root: NSView, window: NSWindow,
    deadline: Double) async throws -> [String: Any] {
    let beforeAssets = store.assets
    let beforeOrder = store.assetOrderRevision
    let beforeLibrary = store.libraryRevision
    let beforeEvents = events.count
    let beforeBackings = nativeImageIdentities(root: root)
    let beforeVisible = store.visibleAssets.map(AppStore.PresentedAssetVersion.init)
    let beforePageStart = store.pageStartIndex
    let beforeCurrentIndex = store.currentIndex
    let beforeCount = store.imagesPerPage
    let beforeSelectedURLs = store.selectedURLs
    let query = store.libraryQuery
    var target = query
    // Change the query even when the caller already uses '*'. Adjacent stars
    // have the same all-matching filename semantics in LibraryTextMatcher.
    target.searchText = query.searchText == "*" ? "**" : "*"
    let started = ProcessInfo.processInfo.systemUptime
    var diagnostic: [String: Any] = ["schemaVersion": 2, "status": "running",
      "queryChanged": target != query, "queryStartedFiltering": false,
      "queryCompleted": false, "originalQueryRestored": false,
      "scope": "changed equivalent all-matching filename query and restoration on the settled page; identical results must retain collection revisions and native frames; no EXIF read or source edit forced"]
    defer {
      diagnostic["wallSeconds"] = ProcessInfo.processInfo.systemUptime - started
      sameOrderQueryDiagnostics = diagnostic
    }

    @MainActor func snapshot() -> [String: Any] {
      let extra = Array(events.dropFirst(beforeEvents))
      let backings = nativeImageIdentities(root: root)
      return ["isLoading": store.isLoading, "isFiltering": store.isFiltering, "hasAlert": store.alert != nil,
        "queryMatchesTarget": store.libraryQuery == target, "queryMatchesOriginal": store.libraryQuery == query,
        "foregroundIsOwnProcess": NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
        "windowVisible": window.isVisible, "windowOcclusionVisible": window.occlusionState.contains(.visible),
        "remainingDeadlineSeconds": max(0, deadline - ProcessInfo.processInfo.systemUptime),
        "orderedSourceIDsUnchanged": store.assets.map(\.id) == beforeAssets.map(\.id),
        "assetOrderRevisionUnchanged": store.assetOrderRevision == beforeOrder,
        "libraryRevisionChanged": store.libraryRevision != beforeLibrary,
        "fullAssetMetadataUnchanged": store.assets == beforeAssets,
        "visibleSourceVersionsUnchanged": store.visibleAssets.map(AppStore.PresentedAssetVersion.init) == beforeVisible,
        "pageStartIndexUnchanged": store.pageStartIndex == beforePageStart,
        "currentIndexUnchanged": store.currentIndex == beforeCurrentIndex,
        "visibleCountUnchanged": store.imagesPerPage == beforeCount,
        "selectedURLsUnchanged": store.selectedURLs == beforeSelectedURLs,
        "nativeCGImageIdentitiesRetained": backings == beforeBackings,
        "nativeCGImageCount": backings.count,
        "newPreviewPublications": extra.filter { !$0.refinement }.count,
        "newPrecisePublications": extra.filter(\.refinement).count]
    }
    @MainActor func requireRetainedState(_ state: [String: Any], phase: String) throws {
      try require(state["orderedSourceIDsUnchanged"] as? Bool == true
        && state["assetOrderRevisionUnchanged"] as? Bool == true
        && state["pageStartIndexUnchanged"] as? Bool == true
        && state["currentIndexUnchanged"] as? Bool == true
        && state["visibleCountUnchanged"] as? Bool == true
        && state["selectedURLsUnchanged"] as? Bool == true,
        "multiple_viewer_\(phase)_query_order_or_interaction_changed")
      if state["fullAssetMetadataUnchanged"] as? Bool == true {
        try require(state["libraryRevisionChanged"] as? Bool == false
          && state["visibleSourceVersionsUnchanged"] as? Bool == true
          && state["nativeCGImageIdentitiesRetained"] as? Bool == true
          && state["newPreviewPublications"] as? Int == 0
          && state["newPrecisePublications"] as? Int == 0,
          "multiple_viewer_\(phase)_identical_query_restarted_visible_frames")
      }
    }
    @MainActor func waitForQuery(_ expected: LibraryQuery, phase: String) async throws {
      let limit = min(deadline, ProcessInfo.processInfo.systemUptime + 12)
      while ProcessInfo.processInfo.systemUptime < limit {
        try requireForeground(window)
        if !store.isFiltering && store.libraryQuery == expected { break }
        try await Task.sleep(for: .milliseconds(40))
      }
      try require(!store.isFiltering && store.libraryQuery == expected,
        "multiple_viewer_\(phase)_query_completion_timeout")
      try require(store.alert == nil, "multiple_viewer_\(phase)_query_alert")
    }

    var validationError: (any Error)?
    do {
      try require(!store.isLoading && !store.isFiltering && store.alert == nil
        && !beforeVisible.isEmpty && beforeBackings.count == beforeVisible.count,
        "multiple_viewer_equivalent_query_settled_page_required")
      let originalMatcher = LibraryTextMatcher(pattern: query.searchText)
      let allNamesMatch = store.allAssets.allSatisfy { originalMatcher.matches($0.filename) }
      diagnostic["originalFilenameQueryMatchesAllSourceNames"] = allNamesMatch
      try require(target != query && allNamesMatch,
        "multiple_viewer_equivalent_query_must_change_all_matching_search")
      store.libraryQuery = target
      diagnostic["queryStartedFiltering"] = store.isFiltering
      try require(store.isFiltering, "multiple_viewer_equivalent_query_did_not_start")
      try await waitForQuery(target, phase: "equivalent")
      diagnostic["queryCompleted"] = true
      try await Task.sleep(for: .milliseconds(250))
      try requireForeground(window)
      try require(!store.isLoading && !store.isFiltering && store.libraryQuery == target && store.alert == nil,
        "multiple_viewer_equivalent_query_changed_during_settle")
      let state = snapshot()
      diagnostic["afterQuery"] = state
      // Retain the existing summary fields, now populated from observations.
      for (key, value) in state { diagnostic[key] = value }
      try requireRetainedState(state, phase: "equivalent")
    } catch {
      validationError = error
      diagnostic["status"] = "failed"
      diagnostic["failurePhase"] = (error as? ValidationFailure)?.phase ?? "equivalent_query_interrupted"
      diagnostic["failureState"] = snapshot()
    }

    // Restore and observe completion on success and failure. A failed phase is
    // never promoted to a pass merely because its isolated query was restored.
    var restorationError: (any Error)?
    do {
      let needsRestore = store.libraryQuery != query
      diagnostic["restoreRequired"] = needsRestore
      if needsRestore {
        store.libraryQuery = query
        diagnostic["restoreStartedFiltering"] = store.isFiltering
        try require(store.isFiltering, "multiple_viewer_original_query_restore_did_not_start")
      }
      try await waitForQuery(query, phase: "original_restore")
      diagnostic["originalQueryRestored"] = true
      try await Task.sleep(for: .milliseconds(250))
      try requireForeground(window)
      try require(!store.isLoading && !store.isFiltering && store.libraryQuery == query && store.alert == nil,
        "multiple_viewer_original_query_changed_during_restore_settle")
      let state = snapshot()
      diagnostic["afterRestore"] = state
      try requireRetainedState(state, phase: "original_restore")
    } catch {
      restorationError = error
      diagnostic["status"] = "failed"
      diagnostic["restoreFailurePhase"] = (error as? ValidationFailure)?.phase ?? "original_query_restore_interrupted"
      diagnostic["restoreFailureState"] = snapshot()
      diagnostic["originalQueryRestored"] = !store.isLoading && !store.isFiltering && store.libraryQuery == query && store.alert == nil
    }
    if let validationError { throw validationError }
    if let restorationError { throw restorationError }
    diagnostic["status"] = "completed"
    diagnostic["wallSeconds"] = ProcessInfo.processInfo.systemUptime - started
    return diagnostic
  }

  static func isExactPage(actual: [ImageAsset], all: [ImageAsset], start: Int, count: Int) -> Bool {
    guard start >= 0, count > 0, start + count <= all.count, actual.count == count,
      Set(actual.map(\.id)).count == count else { return false }
    return actual.map(AppStore.PresentedAssetVersion.init)
      == Array(all[start..<start + count]).map(AppStore.PresentedAssetVersion.init)
  }

  static func finalFrameIsValid(request: ViewerFrameRequest, width: Int, height: Int,
    isRefinement: Bool, sourceMaximumDimension: Double?, visibleCount: Int, prefersHDR: Bool) -> Bool {
    guard isRefinement, let sourceMaximumDimension, sourceMaximumDimension.isFinite,
      sourceMaximumDimension > 0, width > 0, height > 0, request.maxPixelSize > 0,
      request.prefersHDR == prefersHDR,
      request.loadingPolicy == .forVisibleItemCount(visibleCount) else { return false }
    let bucket = ImageLoadingPolicy.pixelBucket(request.maxPixelSize)
    let expected = min(Double(bucket), sourceMaximumDimension)
    return Double(max(width, height)) >= expected - 1 && max(width, height) <= bucket + 1
  }

  private func requireForeground(_ window: NSWindow) throws {
    try require(NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
      && window.isVisible && window.occlusionState.contains(.visible),
      "multiple_viewer_requires_actual_app_foreground")
  }
  private func require(_ value: Bool, _ phase: String) throws {
    if !value { throw ValidationFailure(phase: phase) }
  }
  private func requiredNumber(_ value: Any?) throws -> Double {
    guard let value = value as? Double else { throw ValidationFailure(phase: "multiple_viewer_missing_input_time") }
    return value
  }
  private func keyEvent(direction: Int, window: NSWindow) throws -> NSEvent {
    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: direction > 0 ? "\u{f703}" : "\u{f702}",
      charactersIgnoringModifiers: direction > 0 ? "\u{f703}" : "\u{f702}",
      isARepeat: true, keyCode: direction > 0 ? 124 : 123) else {
      throw ValidationFailure(phase: "multiple_viewer_key_event_creation")
    }
    return event
  }
  private func descendants<T: NSView>(_ type: T.Type, root: NSView) -> [T] {
    (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants(type, root: $0) }
  }
  private func backingViews(root: NSView) -> [ExtendedRangeBackingView] {
    descendants(ExtendedRangeBackingView.self, root: root).filter {
      !$0.isHiddenOrHasHiddenAncestor && $0.window != nil && !$0.visibleRect.isEmpty && $0.layer?.contents != nil
    }
  }
  private func nativeImageIdentities(root: NSView) -> Set<ObjectIdentifier> {
    Set(backingViews(root: root).compactMap { view in
      view.layer?.contents.map { ObjectIdentifier($0 as AnyObject) }
    })
  }
  private func nativeBackings(root: NSView) -> [[String: Any]] {
    backingViews(root: root).compactMap { view in
      guard let contents = view.layer?.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
      let image = unsafeBitCast(contents as AnyObject, to: CGImage.self)
      return ["pixelWidth": image.width, "pixelHeight": image.height,
        "bitsPerComponent": image.bitsPerComponent, "bitsPerPixel": image.bitsPerPixel]
    }
  }
  private func nativeSidebarScrollViews(root: NSView, horizontal: Bool) -> [NSScrollView] {
    descendants(NSScrollView.self, root: root).filter {
      !$0.isHiddenOrHasHiddenAncestor && $0.documentView != nil
        && (horizontal ? $0.bounds.width > root.bounds.width / 2 && $0.bounds.height < 160
          : $0.bounds.width < root.bounds.width / 2 && $0.bounds.height > 200)
    }
  }
  private func sampleResources(window: NSWindow) {
    let now = ProcessInfo.processInfo.systemUptime
    let cpu = OverviewWarmCPUCost.processCPUSeconds()
    var sample: [String: Any] = ["uptime": now,
      "foregroundIsOwnProcess": NSApp.isActive
        && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
      "windowVisible": window.isVisible, "windowOcclusionVisible": window.occlusionState.contains(.visible)]
    if let cpu {
      sample["processCPUSeconds"] = cpu
      if let previousResource, now > previousResource.uptime {
        sample["intervalSeconds"] = now - previousResource.uptime
        sample["cpuPercentOneCore"] = max(0, cpu - previousResource.cpu) / (now - previousResource.uptime) * 100
      }
      previousResource = (now, cpu)
    }
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
      }
    }
    sample["footprintAvailable"] = result == 0
    if result == 0 { sample["footprintBytes"] = usage.ri_phys_footprint }
    resourceSamples.append(sample)
  }
  private func cpuDelta(_ start: Double?, _ end: Double?) -> Double? {
    guard let start, let end, end >= start else { return nil }
    return end - start
  }
  private static func distribution(_ values: [Double], unit: String = "Seconds") -> [String: Any] {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return ["count": 0] }
    return ["count": sorted.count, "p50" + unit: releaseOverviewPercentile(sorted, fraction: 0.5),
      "p95" + unit: releaseOverviewPercentile(sorted, fraction: 0.95), "maximum" + unit: sorted.last!]
  }
  private func finishReport(_ report: inout [String: Any], began: Double, output: URL) throws {
    report["wallSeconds"] = ProcessInfo.processInfo.systemUptime - began
    report["scenarios"] = scenarios
    report["resourceSamples"] = resourceSamples
    report["viewerFramePublicationCount"] = events.count
    report["sidebarBitmapPublicationCount"] = sidebarEvents.count
    report["sidebarBitmapCallbackConnected"] = !sidebarEvents.isEmpty
    report["ledgerTruncated"] = ledgerTruncated
    report["CPUResourceScope"] = "getrusage_SELF_user_plus_system;100percent_equals_one_core;phys_footprint_sampled_500ms;GPU_not_measured"
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: output.appendingPathComponent("multi-viewer-navigation-report.json"), options: .atomic)
  }
}
