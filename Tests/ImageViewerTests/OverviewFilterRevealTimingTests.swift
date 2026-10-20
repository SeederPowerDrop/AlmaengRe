import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import ImageViewer

/// A real AppKit event loop owns every post-attachment layout transaction.
/// The fixture is synthetic; this never opens a user's library or shared cache.
final class OverviewFilterRevealTimingTests: XCTestCase {
  func testMeasuredAssetIdentitiesRemapAcrossFilterRestoreAndSort() {
    // Match the observed 717 -> 729 transition: twelve excluded entries precede
    // the retained focus, so unchanged on-screen URLs acquire different indices.
    let excluded: Set<Int> = [41, 195, 262, 263, 410, 411, 412, 494, 517, 518, 519, 520]
    let all = (0..<729).map { index in
      ImageAsset(url: URL(fileURLWithPath: "/synthetic-overview-assets/asset-\(index).jpg"),
        byteCount: excluded.contains(index) ? 0 : 1, modificationDate: nil)
    }
    let filtered = all.filter { $0.byteCount != 0 }
    let measuredIDs = Set(filtered[564...572].map(\.id))
    let capturedIndices = Set(564...572)
    let filteredRevision = UUID()
    var lookup = OverviewAssetIndexMap()

    XCTAssertEqual(filtered.count, 717)
    XCTAssertEqual(lookup.indices(for: measuredIDs, in: filtered,
      collectionRevision: filteredRevision), capturedIndices)
    XCTAssertEqual(lookup.index(for: all[580].id, in: filtered,
      collectionRevision: filteredRevision), 568)

    let restoredRevision = UUID()
    let restoredIndices = lookup.indices(for: measuredIDs, in: all,
      collectionRevision: restoredRevision)
    XCTAssertEqual(restoredIndices, Set(576...584))
    XCTAssertNotEqual(restoredIndices, capturedIndices)
    XCTAssertTrue(restoredIndices.contains(580))
    // Number badges use this same identity lookup in the already-observing cell.
    XCTAssertEqual(lookup.index(for: all[580].id, in: all,
      collectionRevision: restoredRevision), 580)

    var enriched = all
    for index in enriched.indices { enriched[index].hasReadLocation = true }
    XCTAssertEqual(lookup.indices(for: measuredIDs, in: enriched,
      collectionRevision: restoredRevision), restoredIndices)
    let reversed = Array(enriched.reversed())
    let sortedRevision = UUID()
    XCTAssertEqual(lookup.indices(for: measuredIDs, in: reversed,
      collectionRevision: sortedRevision), Set(144...152))
    XCTAssertEqual(lookup.index(for: all[580].id, in: reversed,
      collectionRevision: sortedRevision), 148)

    let unknown = URL(fileURLWithPath: "/synthetic-overview-assets/removed.jpg")
    XCTAssertEqual(lookup.indices(for: measuredIDs.union([unknown]), in: reversed,
      collectionRevision: sortedRevision), Set(144...152))
    XCTAssertNil(lookup.index(for: unknown, in: reversed, collectionRevision: sortedRevision))
    XCTAssertTrue(lookup.indices(for: [], in: reversed, collectionRevision: sortedRevision).isEmpty)
    let emptyRevision = UUID()
    XCTAssertTrue(lookup.indices(for: measuredIDs, in: [], collectionRevision: emptyRevision).isEmpty)
    XCTAssertNil(lookup.index(for: all[580].id, in: [], collectionRevision: emptyRevision))
  }

  func testNativeContentIntersectionHandlesOriginsFlippingRTLAndResize() {
    let first = URL(fileURLWithPath: "/synthetic-overview-assets/first.jpg")
    let second = URL(fileURLWithPath: "/synthetic-overview-assets/second.jpg")
    let edge = URL(fileURLWithPath: "/synthetic-overview-assets/edge.jpg")
    let invalid = URL(fileURLWithPath: "/synthetic-overview-assets/invalid.jpg")
    let frames = [first: CGRect(x: 18, y: 80, width: 100, height: 40),
      second: CGRect(x: 18, y: 180, width: 100, height: 40),
      edge: CGRect(x: 18, y: 200, width: 100, height: 0),
      invalid: CGRect(x: CGFloat.nan, y: 100, width: 100, height: 40)]
    let flipped = OverviewNativeViewportGeometry(
      viewportInDocument: CGRect(x: 7, y: 103, width: 200, height: 100),
      contentOriginInDocument: CGPoint(x: 7, y: 3), documentIsFlipped: true)
    XCTAssertEqual(flipped.documentFrame(for: frames[first]!), CGRect(x: 25, y: 83, width: 100, height: 40))
    XCTAssertEqual(flipped.visibleAssetIDs(in: frames), [first, second])
    let narrowHeight = OverviewNativeViewportGeometry(
      viewportInDocument: CGRect(x: 7, y: 103, width: 200, height: 20),
      contentOriginInDocument: flipped.contentOriginInDocument, documentIsFlipped: true)
    XCTAssertEqual(narrowHeight.visibleAssetIDs(in: frames), [first])
    let touchingEdge = OverviewNativeViewportGeometry(
      viewportInDocument: CGRect(x: 7, y: 123, width: 200, height: 60),
      contentOriginInDocument: flipped.contentOriginInDocument, documentIsFlipped: true)
    XCTAssertTrue(touchingEdge.visibleAssetIDs(in: frames).isEmpty)

    let unflipped = OverviewNativeViewportGeometry(
      viewportInDocument: CGRect(x: 7, y: 380, width: 200, height: 20),
      contentOriginInDocument: CGPoint(x: 7, y: 500), documentIsFlipped: false)
    XCTAssertEqual(unflipped.documentFrame(for: frames[first]!), CGRect(x: 25, y: 380, width: 100, height: 40))
    XCTAssertEqual(unflipped.visibleAssetIDs(in: frames), [first])
    // RTL layout has already produced physical content rectangles. Do not
    // mirror them again when intersecting the native clip's physical x axis.
    let rtlFrames = [first: CGRect(x: 600, y: 80, width: 100, height: 40),
      second: CGRect(x: 18, y: 80, width: 100, height: 40)]
    let rtl = OverviewNativeViewportGeometry(
      viewportInDocument: CGRect(x: 607, y: 83, width: 100, height: 40),
      contentOriginInDocument: CGPoint(x: 7, y: 3), documentIsFlipped: true)
    XCTAssertEqual(rtl.visibleAssetIDs(in: rtlFrames), [first])
    XCTAssertTrue(rtl.visibleAssetIDs(in: [:]).isEmpty)
    let empty = OverviewNativeViewportGeometry(viewportInDocument: .zero,
      contentOriginInDocument: .zero, documentIsFlipped: true)
    XCTAssertTrue(empty.visibleAssetIDs(in: frames).isEmpty)
  }

  func testNativeBoundsRefreshesMembershipBeforeAnyNewCellPreference() throws {
    guard Thread.isMainThread else { throw FilterRevealTimingFailure("main_thread_required") }
    MainActor.assumeIsolated {
      _ = NSApplication.shared
      let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 120, height: 100))
      scroll.borderType = .noBorder
      scroll.hasVerticalScroller = false
      scroll.hasHorizontalScroller = false
      let document = FilterRevealFlippedDocument(frame: NSRect(x: 0, y: 0, width: 120, height: 1_000))
      scroll.documentView = document
      let gate = OverviewRefinementGate(quietInterval: .seconds(3_600), observesWindowVisibility: false)
      let observer = OverviewScrollMotionView(frame: NSRect(x: 0, y: 0, width: 120, height: 0))
      observer.gate = gate
      let first = URL(fileURLWithPath: "/synthetic-overview-assets/first.jpg")
      let second = URL(fileURLWithPath: "/synthetic-overview-assets/second.jpg")
      // This table never changes: only the native clip moves.
      let frames = [first: CGRect(x: 18, y: 18, width: 80, height: 50),
        second: CGRect(x: 18, y: 218, width: 80, height: 50)]
      var visible: Set<URL> = []
      var callbackCount = 0
      observer.onViewportChange = { geometry in
        callbackCount += 1
        visible = geometry?.visibleAssetIDs(in: frames) ?? []
        gate.updateVisibleAssets(visible)
      }
      document.addSubview(observer)
      observer.observe(scroll)
      observer.refreshViewportGeometry()
      defer { observer.stopObserving(); gate.stop() }
      XCTAssertEqual(visible, [first])
      let initialCallbacks = callbackCount
      let initialQuietRevision = gate.quietRevision
      scroll.contentView.scroll(to: CGPoint(x: 0, y: 200))
      scroll.reflectScrolledClipView(scroll.contentView)
      XCTAssertEqual(visible, [second])
      XCTAssertGreaterThan(callbackCount, initialCallbacks)
      XCTAssertTrue(gate.isDeferring)
      XCTAssertEqual(gate.quietRevision, initialQuietRevision,
        "Motion must defer before changed membership can publish a stationary quiet revision")
      scroll.contentView.scroll(to: .zero)
      scroll.reflectScrolledClipView(scroll.contentView)
      XCTAssertEqual(visible, [first])
      XCTAssertEqual(gate.quietRevision, initialQuietRevision)
    }
  }

  func testNaturalLayoutRevealsRetainedFocusAfterSmallMembershipChanges() throws {
    guard Thread.isMainThread else { throw FilterRevealTimingFailure("main_thread_required") }
    try MainActor.assumeIsolated {
      let application = NSApplication.shared
      guard !application.isRunning else { throw FilterRevealTimingFailure("application_already_running") }
      let previousDelegate = application.delegate
      let previousPolicy = application.activationPolicy()
      let delegate = FilterRevealTimingDelegate()
      application.delegate = delegate
      _ = application.setActivationPolicy(.regular)
      defer {
        delegate.cancelWatchdog()
        application.delegate = previousDelegate
        _ = application.setActivationPolicy(previousPolicy)
      }
      DispatchQueue.main.async { delegate.start() }
      application.run()
      guard let outcome = delegate.outcome else { throw FilterRevealTimingFailure("native_run_returned_without_result") }
      try outcome.get()
    }
  }

  func testNaturalDeepFilterResizeKeepsNativeImagesAdmitted() throws {
    guard Thread.isMainThread else { throw FilterRevealTimingFailure("main_thread_required") }
    try MainActor.assumeIsolated {
      let application = NSApplication.shared
      guard !application.isRunning else { throw FilterRevealTimingFailure("application_already_running") }
      let previousDelegate = application.delegate
      let previousPolicy = application.activationPolicy()
      let delegate = FilterResizeTimingDelegate()
      application.delegate = delegate
      _ = application.setActivationPolicy(.regular)
      defer {
        delegate.cancelWatchdog()
        application.delegate = previousDelegate
        _ = application.setActivationPolicy(previousPolicy)
      }
      // NSApplication may already have finished launching in another native
      // test. Start on the next real application turn in either case.
      DispatchQueue.main.async { delegate.start() }
      application.run()
      guard let outcome = delegate.outcome else { throw FilterRevealTimingFailure("native_resize_run_returned_without_result") }
      try outcome.get()
    }
  }
}

private final class FilterRevealFlippedDocument: NSView {
  override var isFlipped: Bool { true }
}

private struct FilterRevealTimingFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

@MainActor
private final class FilterRevealTimingDelegate: NSObject, NSApplicationDelegate {
  private(set) var outcome: Result<Void, any Error>?
  private var task: Task<Void, Never>?
  private var watchdog: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) { start() }

  func start() {
    guard task == nil, outcome == nil else { return }
    let timer = Timer(timeInterval: 120, target: self,
      selector: #selector(watchdogExpired(_:)), userInfo: nil, repeats: false)
    watchdog = timer
    RunLoop.main.add(timer, forMode: .common)
    task = Task { @MainActor in
      do {
        try await FilterRevealTimingRun().perform()
        try await FilterRevealTimingRun().perform(metadataScenario: true)
        finish(.success(()))
      }
      catch { finish(.failure(error)) }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateCancel }

  func cancelWatchdog() { watchdog?.invalidate(); watchdog = nil }

  @objc private func watchdogExpired(_ timer: Timer) {
    task?.cancel()
    finish(.failure(FilterRevealTimingFailure("native_watchdog_120_seconds")))
  }

  private func finish(_ result: Result<Void, any Error>) {
    guard outcome == nil else { return }
    outcome = result
    cancelWatchdog()
    NSApp.stop(nil)
    if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
      NSApp.postEvent(wake, atStart: false)
    }
  }
}

@MainActor
private final class FilterResizeTimingDelegate: NSObject, NSApplicationDelegate {
  private(set) var outcome: Result<Void, any Error>?
  private var task: Task<Void, Never>?
  private var watchdog: Timer?

  func start() {
    guard task == nil, outcome == nil else { return }
    let timer = Timer(timeInterval: 180, target: self,
      selector: #selector(watchdogExpired(_:)), userInfo: nil, repeats: false)
    watchdog = timer
    RunLoop.main.add(timer, forMode: .common)
    task = Task { @MainActor in
      do {
        try await FilterRevealTimingRun().perform(metadataScenario: true, deepResizeScenario: true)
        finish(.success(()))
      } catch { finish(.failure(error)) }
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) { start() }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateCancel }
  func cancelWatchdog() { watchdog?.invalidate(); watchdog = nil }

  @objc private func watchdogExpired(_ timer: Timer) {
    task?.cancel()
    finish(.failure(FilterRevealTimingFailure("native_resize_watchdog_180_seconds")))
  }

  private func finish(_ result: Result<Void, any Error>) {
    guard outcome == nil else { return }
    outcome = result
    cancelWatchdog()
    NSApp.stop(nil)
    if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
      NSApp.postEvent(wake, atStart: false)
    }
  }
}

@MainActor
private final class FilterRevealTimingRun {
  private struct ScrollObservation {
    let request: OverviewFocusScrollRequest
    let index: Int
    let animated: Bool
    let wasCurrent: Bool
  }

  private var requests: [ScrollObservation] = []
  private var failures: [String] = []
  private var store: AppStore?
  private var preloader: OverviewThumbnailPreloader?
  private var scroll: NSScrollView?
  private var window: NSWindow?
  private var scenario = "qoi_membership"

  func perform(metadataScenario: Bool = false, deepResizeScenario: Bool = false) async throws {
    scenario = deepResizeScenario ? "jpeg_Apple_metadata_RootView_deep_resize"
      : metadataScenario ? "jpeg_Apple_metadata_RootView_wide_to_narrow" : "qoi_membership"
    let suite = "OverviewFilterRevealTiming.\(UUID())"
    guard let defaults = UserDefaults(suiteName: suite) else { throw FilterRevealTimingFailure("private_defaults") }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
    let folder = temporary.appendingPathComponent("photos", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      if let store, let preloader { preloader.stop(pipeline: store.thumbnailPipeline) }
      window?.orderOut(nil); window?.contentView = nil; window?.close()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: temporary)
    }
    let qoi = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
      0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    let emptyIndices: Set<Int> = metadataScenario
      ? [41, 195, 262, 263, 410, 411, 412, 494, 517, 518, 519, 520]
      : Set(0..<12)
    let sourceData = metadataScenario ? try appleJPEG() : qoi
    for index in 0..<729 {
      let number = metadataScenario && index >= 580
        ? (index <= 654 ? 7_000 + index - 580 : 8_000 + index - 655) : index
      let filename = String(format: "photo-%04d", number) + (metadataScenario ? ".jpg" : ".qoi")
      try (emptyIndices.contains(index) ? Data() : sourceData).write(to: folder.appendingPathComponent(filename))
    }
    let disk = ThumbnailDiskCache(directory: temporary.appendingPathComponent("cache", isDirectory: true))
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: temporary.appendingPathComponent("marks.sqlite"), thumbnailDiskCache: disk)
    self.store = store
    store.thumbnailSize = 226.4
    store.showsOverviewNumbers = false
    store.showsFolderTree = false
    store.thumbnailPanelPlacement = .left
    store.openFolderFromTree(folder)
    try await wait("listing") { !store.isLoading && !store.isFiltering && store.assets.count == 729 }
    store.returnToOverview()
    let selectedURL = store.assets[580].url
    let orderedURLs = store.assets.map(\.url)
    try require(Set(store.assets.indices.filter { store.assets[$0].byteCount == 0 }) == emptyIndices,
      "empty_ordinals_must_match_fixture")

    let preloader = OverviewThumbnailPreloader(quietInterval: .seconds(3_600))
    self.preloader = preloader
    let bitmapObserver: (@MainActor @Sendable (ThumbnailBitmapStateEvent) -> Void)? = metadataScenario
      ? { @MainActor @Sendable _ in } : nil
    let overview = OverviewView(store: store, thumbnailPreloader: preloader,
      onBitmapStateApplied: bitmapObserver,
      onScrollRequestApplied: { [weak self] request, animated in
        self?.requests.append(ScrollObservation(request: request, index: store.currentIndex, animated: animated,
          wasCurrent: request.collectionRevision == store.assetOrderRevision && request.assetID == store.currentAsset?.id))
      })
    // The actual failure prepared the grid at six columns before a native
    // resize to three. Starting at the final narrow width omits that anchor
    // history. RootView also retains its real header and adjacent filmstrip.
    let hostWidth: CGFloat = metadataScenario ? 1_728 : 953
    let root: AnyView = metadataScenario
      ? AnyView(RootView(store: store, shortcuts: ShortcutStore(defaults: defaults),
        overviewPreloader: preloader, onOverviewBitmapStateApplied: bitmapObserver))
      : AnyView(overview.frame(width: 953))
    let host = NSHostingView(rootView: root.environment(\.displayScale, 2)
      .environment(\.layoutDirection, metadataScenario ? .leftToRight : .rightToLeft))
    let window = NSWindow(contentRect: NSRect(x: 20, y: 80, width: hostWidth,
      height: deepResizeScenario ? 930 : 570),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    self.window = window
    window.isReleasedWhenClosed = false
    window.title = "Synthetic overview filter timing regression"
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    // Initial attachment is the only phase allowed to force host layout/display.
    try await wait("initial_attachment") {
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
      return self.findScrollView(in: host, markedOverview: metadataScenario) != nil && preloader.visibleIndices.contains(0)
    }
    guard let scroll = findScrollView(in: host, markedOverview: metadataScenario) else {
      throw FilterRevealTimingFailure("overview_scroll_missing")
    }
    self.scroll = scroll
    let finalRootWidth: CGFloat = deepResizeScenario ? 1_728 : metadataScenario ? 1_194 : 953
    let finalViewportWidth: CGFloat = deepResizeScenario ? 1_507 : metadataScenario ? 973 : 953
    let finalViewportHeight: CGFloat = deepResizeScenario ? 737 : metadataScenario ? 563.5 : 509.5
    if metadataScenario && !deepResizeScenario {
      try require(abs(scroll.contentView.bounds.width - 1_507) < 1,
        "initial_RootView_wide_overview_viewport")
      log("before_narrow_resize", fields: ["overviewWidth": scroll.contentView.bounds.width,
        "overviewHeight": scroll.contentView.bounds.height, "rootWidth": host.bounds.width])
      window.setContentSize(CGSize(width: finalRootWidth, height: 760))
      try await wait("natural_narrow_resize") {
        abs(scroll.contentView.bounds.width - finalViewportWidth) < 1 && scroll.contentView.bounds.height > 0
          && self.preloader?.visibleIndices.contains(0) == true
      }
    }
    // Calibrate once at attachment to the actual app's overview clip. A manually
    // hosted RootView does not consume the app window's native toolbar height,
    // so its observed root height can differ from the requested 930pt window.
    // Every later transaction comes from the native application loop.
    let attachmentViewportHeight = scroll.contentView.bounds.height
    let attachmentHeightCorrection = finalViewportHeight - attachmentViewportHeight
    let calibratedRootHeight = host.bounds.height + attachmentHeightCorrection
    window.setContentSize(CGSize(width: finalRootWidth, height: calibratedRootHeight))
    try await wait("initial_viewport_dimensions") {
      if !metadataScenario { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
      return abs(scroll.contentView.bounds.width - finalViewportWidth) < 1
        && abs(scroll.contentView.bounds.height - finalViewportHeight) < 1
        && preloader.visibleIndices.contains(0)
    }
    if deepResizeScenario {
      try require(abs(host.bounds.width - 1_728) < 1 && abs(host.bounds.height - calibratedRootHeight) < 1,
        "deep_resize_wide_RootView_attachment_dimensions")
    }
    try await wait("native_application_active") { NSApp.isActive && window.isVisible }
    try await Task.sleep(for: .milliseconds(300))
    log("natural_layout_begin", fields: ["targetViewportWidth": finalViewportWidth,
      "targetViewportHeight": finalViewportHeight,
      "displayScale": 2, "thumbnailSize": 226.4, "forcedLayoutAfterAttachment": false,
      "sidebarWidth": metadataScenario ? 220 : 0, "emptyOrdinals": emptyIndices.sorted(),
      "actualRootView": metadataScenario, "naturallyResizedFromWideGrid": metadataScenario && !deepResizeScenario,
      "scrollRequestCallbackTracked": !metadataScenario,
      "deepResizeScenario": deepResizeScenario,
      "initialRequestedRootHeight": deepResizeScenario ? 930 : 570,
      "attachmentViewportHeightBeforeCorrection": attachmentViewportHeight,
      "attachmentHeightCorrection": attachmentHeightCorrection,
      "actualRootWidth": host.bounds.width, "actualRootHeight": host.bounds.height])

    // No layoutSubtreeIfNeeded, displayIfNeeded, updateWindows or manual run-loop
    // pumping occurs below. NSApplication.run supplies the native transactions.
    if metadataScenario {
      // Seed lazy anchor history using the same native overview clip, then run
      // the first EXIF query without the old minimum-byte warm-up repetitions.
      try await nativeScrollRoundtrip()
    }
    store.select(index: 580)
    await observeReveal("initial_focus_580", index: 580, url: selectedURL)
    if !metadataScenario {
      for iteration in 0..<3 {
        var filtered = LibraryQuery()
        filtered.searchFilters.minimumBytes = 1
        try await commit(filtered, count: 717, focus: 568, url: selectedURL,
          phase: "filter_717_\(iteration)")
        try await commit(LibraryQuery(), count: 729, focus: 580, url: selectedURL,
          phase: "restore_729_\(iteration)")
        try require(store.assets.map(\.url) == orderedURLs, "ordered_collection_not_restored")
      }
    }
    if metadataScenario {
      try await metadataSequence(store: store, selectedURL: selectedURL, orderedURLs: orderedURLs)
    }

    if deepResizeScenario {
      try require(store.assets.map(\.url) == orderedURLs && store.currentIndex == 580,
        "deep_resize_must_start_after_seven_filters_at_580")
      try await resizeMembershipSequence(root: host, focus: 580, phase: "deep_after_filters")
      // The earlier installed build91 run resized at the head without filters.
      // Keep that location as a separate control, not evidence for the deep case.
      store.select(index: 0)
      await observeReveal("resize_head_control_focus", index: 0, url: orderedURLs[0])
      try await resizeMembershipSequence(root: host, focus: 0, phase: "head_control")
      try await observeNativeGeometryIdle(root: host)
      log("complete", fields: ["failureCount": failures.count, "syntheticFiles": 729,
        "emptyFiles": 12, "metadataFilterSteps": 7, "resizeCases": 10,
        "sourcePixelsReadOnly": true, "displaySizeQualityClaimed": false])
      guard failures.isEmpty else { throw FilterRevealTimingFailure(failures.joined(separator: "\n")) }
      return
    }

    // Intermediate focus/query tasks may start, but a superseded request must
    // never be applied after the latest collection and focus have been committed.
    let requestStart = requests.count
    store.select(index: 728)
    await Task.yield()
    store.select(index: 580)
    store.libraryQuery.searchFilters.minimumBytes = 1
    await Task.yield()
    store.libraryQuery.searchFilters.minimumBytes = nil
    try require(store.isFiltering, "latest_burst_query_must_start")
    try await wait("latest_burst_query_completion") {
      !store.isFiltering && store.assets.count == 729 && store.libraryQuery == LibraryQuery()
    }
    try require(store.currentIndex == 580 && store.currentAsset?.url == selectedURL, "latest_burst_focus_identity")
    await observeReveal("latest_burst_reveal", index: 580, url: selectedURL)
    let staleRequests = requests.dropFirst(requestStart).filter { !$0.wasCurrent }
    if !staleRequests.isEmpty { recordFailure("superseded_scroll_request_applied") }

    // An equivalent ordered result must preserve a separately scrolled viewport,
    // even while a different card remains the focused/selected photo.
    guard let document = scroll.documentView else { throw FilterRevealTimingFailure("scroll_document_missing") }
    let endOrigin = max(0, document.bounds.height - scroll.contentView.bounds.height)
    let manualRequestStart = requests.count
    scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.origin.x, y: endOrigin))
    scroll.reflectScrolledClipView(scroll.contentView)
    try await wait("manual_tail_viewport") { preloader.visibleIndices.contains(728) }
    try await Task.sleep(for: .milliseconds(300))
    let settledOrigin = scroll.contentView.bounds.origin.y
    let revision = store.assetOrderRevision
    let fullRevision = store.libraryRevision
    for search in ["photo*", ""] {
      store.libraryQuery.searchText = search
      try require(store.isFiltering, "equivalent_query_must_start")
      try await wait("equivalent_query_completion") { !store.isFiltering && store.libraryQuery.searchText == search }
      try await Task.sleep(for: .milliseconds(300))
      try require(store.alert == nil && store.assets.map(\.url) == orderedURLs, "equivalent_query_result")
      try require(store.assetOrderRevision == revision && store.libraryRevision == fullRevision,
        "equivalent_query_changed_collection_revision")
      try require(store.currentIndex == 580 && store.currentAsset?.url == selectedURL
        && store.selectedURLs == [selectedURL], "equivalent_query_changed_focus_or_selection")
      if !preloader.visibleIndices.contains(728) || abs(scroll.contentView.bounds.origin.y - settledOrigin) >= 1
        || requests.count != manualRequestStart { recordFailure("equivalent_query_moved_manual_viewport") }
      log("equivalent_query_preserved", fields: ["searchIsEmpty": search.isEmpty])
    }
    log("complete", fields: ["failureCount": failures.count,
      "minimumByteFilterRestoreIterations": metadataScenario ? 0 : 3,
      "syntheticFiles": 729, "emptyFiles": 12, "sourcePixelsReadOnly": true])
    guard failures.isEmpty else { throw FilterRevealTimingFailure(failures.joined(separator: "\n")) }
  }

  private func nativeScrollRoundtrip() async throws {
    guard let scroll, let document = scroll.documentView else {
      throw FilterRevealTimingFailure("native_scroll_document_missing")
    }
    for forward in [true, false] {
      for step in 1...79 {
        let last = max(0, document.bounds.height - scroll.contentView.bounds.height)
        let fraction = CGFloat(step) / 79
        let y = forward ? last * fraction : last * (1 - fraction)
        scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        // Programmed input interval, not a product workaround or forced layout.
        try await Task.sleep(for: .milliseconds(20))
      }
      try await wait(forward ? "native_tail_membership" : "native_head_membership") {
        self.preloader?.visibleIndices.contains(forward ? 728 : 0) == true
      }
    }
    log("native_scroll_roundtrip", fields: ["stepsPerDirection": 79,
      "forcedLayout": false, "sourcePixelTimingClaimed": false])
  }

  private func resizeMembershipSequence(root: NSView, focus: Int, phase: String) async throws {
    guard let store, let scroll, let window, let preloader else {
      throw FilterRevealTimingFailure("resize_harness_not_attached")
    }
    let sliders = nativeSliders(in: root).filter { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 20 }
    try require(sliders.count == 1, "\(phase)_unique_native_slider")
    let slider = sliders[0]
    let revision = store.assetOrderRevision
    for (step, size) in [226.4, 77.34193548387097, 149.93548387096774, 480.3612903225807, 226.4].enumerated() {
      let name = "\(phase)_resize_\(step)"
      try require(store.assetOrderRevision == revision && store.currentIndex == focus,
        "\(name)_unchanged_collection_and_focus")
      // Match the two distinct value transactions observed in native clicks.
      // This invokes the real slider binding; it does not synthesize OS input
      // or claim mouse-drag coverage. NSApplication.run supplies all layouts.
      for value in [355.2, size] {
        let range = OverviewThumbnailSizing.range
        let fraction = (value - Double(range.lowerBound)) / Double(range.upperBound - range.lowerBound)
        slider.doubleValue = slider.minValue + fraction * (slider.maxValue - slider.minValue)
        try require(slider.sendAction(slider.action, to: slider.target), "\(name)_native_slider_binding_action")
        try await wait("\(name)_binding") { abs(Double(store.thumbnailSize) - value) < 0.001 }
        try await Task.sleep(for: .milliseconds(500))
      }
      try require(nativeSliders(in: root).contains { $0 === slider }, "\(name)_slider_identity_preserved")
      var previousNative: Set<URL> = []
      var stableSince: Double?
      do {
        try await wait("\(name)_native_membership_and_quiet_admission") {
          let native = Set(OverviewBitmapProbeRegistry.visible(in: scroll, window: window)
            .filter { ($0.byteCount ?? 0) > 0 }.map(\.assetURL))
          let admitted = Set(preloader.visibleIndices.compactMap {
            store.assets.indices.contains($0) ? store.assets[$0].url : nil
          })
          let gate = self.motionObserver(in: root, for: scroll)?.gate
          let ready = !native.isEmpty && native.isSubset(of: admitted)
            && gate?.isDeferring == false && native.allSatisfy { gate?.allowsRefinement(for: $0) == true }
          if !ready || native != previousNative { stableSince = nil }
          previousNative = native
          if ready && stableSince == nil { stableSince = ProcessInfo.processInfo.systemUptime }
          return stableSince.map { ProcessInfo.processInfo.systemUptime - $0 >= 0.4 } ?? false
        }
      } catch { recordFailure("\(name): \(error)") }
      let native = Set(OverviewBitmapProbeRegistry.visible(in: scroll, window: window)
        .filter { ($0.byteCount ?? 0) > 0 }.map(\.assetURL))
      let admitted = Set(preloader.visibleIndices.compactMap {
        store.assets.indices.contains($0) ? store.assets[$0].url : nil
      })
      let gate = motionObserver(in: root, for: scroll)?.gate
      let ordinals = Dictionary(uniqueKeysWithValues: store.assets.enumerated().map { ($0.element.url, $0.offset) })
      log(name, fields: ["requestedSize": size, "actualSize": Double(store.thumbnailSize),
        "nativeNonemptyIndices": native.compactMap { ordinals[$0] }.sorted(),
        "preloaderIndices": preloader.visibleIndices.sorted(),
        "nativeOnlyIndices": native.subtracting(admitted).compactMap { ordinals[$0] }.sorted(),
        "preloaderOnlyIndices": admitted.subtracting(native).compactMap { ordinals[$0] }.sorted(),
        "exactMembershipMatches": native == admitted,
        "nativeMembershipIsAdmitted": !native.isEmpty && native.isSubset(of: admitted),
        "quietGateAdmitsNative": !native.isEmpty && native.allSatisfy { gate?.allowsRefinement(for: $0) == true },
        "gateIsDeferring": gate?.isDeferring ?? true,
        "nativeSliderIdentityPreserved": nativeSliders(in: root).contains { $0 === slider },
        "forcedLayout": false, "displaySizeQualityClaimed": false,
        "naturalIntervalBetweenBindingActionsMilliseconds": 500,
        "inputScope": "two_real_slider_binding_actions_not_synthetic_mouse_events"])
    }
  }

  private func nativeSliders(in view: NSView) -> [NSSlider] {
    if let slider = view as? NSSlider { return [slider] }
    return view.subviews.flatMap { nativeSliders(in: $0) }
  }

  private func motionObserver(in view: NSView, for scroll: NSScrollView) -> OverviewScrollMotionView? {
    if let observer = view as? OverviewScrollMotionView, observer.enclosingScrollView === scroll { return observer }
    return view.subviews.lazy.compactMap { self.motionObserver(in: $0, for: scroll) }.first
  }

  private func observeNativeGeometryIdle(root: NSView) async throws {
    guard let scroll else { throw FilterRevealTimingFailure("idle_native_scroll_missing") }
    try await Task.sleep(for: .seconds(2))
    let nativeBefore = try checkedNativeIdleAdmission(root: root, phase: "idle_before")
    let registry = motionObserver(in: root, for: scroll)?.cellGeometryRegistry
    let rawBefore = registry?.diagnosticSnapshot
    let before = numericNativeGeometryDiagnostics(rawBefore)
    let activeBefore = NSApp.isActive
    let began = ProcessInfo.processInfo.systemUptime
    // No input, forced layout/display, polling or extra timer in this interval.
    try await Task.sleep(for: .seconds(5))
    let idleWall = ProcessInfo.processInfo.systemUptime - began
    let rawAfter = registry?.diagnosticSnapshot
    let after = numericNativeGeometryDiagnostics(rawAfter)
    let nativeAfter = try checkedNativeIdleAdmission(root: root, phase: "idle_after")
    var deltas: [String: Double] = [:]
    for (key, value) in before {
      if let final = after[key] { deltas[key] = final - value }
    }
    log("native_geometry_idle_observation", fields: [
      "settleSeconds": 2, "requestedIdleSeconds": 5, "observedIdleWallSeconds": idleWall,
      "registryPresent": registry != nil,
      "sameRegistryAfterIdle": registry === motionObserver(in: root, for: scroll)?.cellGeometryRegistry,
      "diagnosticsEnabledBefore": rawBefore != nil, "diagnosticsEnabledAfter": rawAfter != nil,
      "diagnosticsFlagOff": registry != nil && rawBefore == nil && rawAfter == nil,
      "numericBefore": before, "numericAfter": after, "numericDeltas": deltas,
      "nativeNonemptyBefore": nativeBefore.count, "nativeNonemptyAfter": nativeAfter.count,
      "nativeMembershipStable": nativeBefore == nativeAfter,
      "nativeMembershipAdmittedBeforeAndAfter": true,
      "applicationActiveBefore": activeBefore, "applicationActiveAfter": NSApp.isActive,
      "measurementScope": "registry_visibleAssetIDs_only_excludes_registration_SwiftUI_native_layout_and_observer_queue_hops",
      "maximumCounterScope": "registry_lifetime_maxima_not_idle_interval_peaks",
      "costThresholdApplied": false, "physicalPaintOrDisplaySizeQualityClaimed": false,
      "forcedLayout": false, "inputDuringObservation": false])
  }

  private func checkedNativeIdleAdmission(root: NSView, phase: String) throws -> Set<URL> {
    guard let store, let scroll, let window, let preloader else {
      throw FilterRevealTimingFailure("\(phase)_native_harness_missing")
    }
    let native = Set(OverviewBitmapProbeRegistry.visible(in: scroll, window: window)
      .filter { ($0.byteCount ?? 0) > 0 }.map(\.assetURL))
    let admitted = Set(preloader.visibleIndices.compactMap {
      store.assets.indices.contains($0) ? store.assets[$0].url : nil
    })
    let gate = motionObserver(in: root, for: scroll)?.gate
    try require(!native.isEmpty && native.isSubset(of: admitted), "\(phase)_native_membership_must_remain_admitted")
    try require(gate?.isDeferring == false && native.allSatisfy { gate?.allowsRefinement(for: $0) == true },
      "\(phase)_quiet_gate_must_remain_open")
    return native
  }

  private func numericNativeGeometryDiagnostics(_ raw: [String: Any]?) -> [String: Double] {
    guard let raw else { return [:] }
    // The opt-in API caps UInt64 counters at 2^53-1 for exact JSON numbers.
    // A fixed whitelist excludes strings/URLs and bounds the output size.
    let keys = ["registeredCurrent", "registeredMaximum", "liveCurrent", "liveMaximum",
      "deadCurrent", "deadMaximum", "matchingScopeLastSnapshot", "matchingScopeMaximum",
      "visibleLastSnapshot", "visibleMaximum", "invalidationAttempts", "invalidationDeliveries",
      "snapshotCount", "snapshotAccumulatedNanoseconds", "snapshotMaximumNanoseconds", "counterCap"]
    var result: [String: Double] = [:]
    for key in keys {
      if let value = raw[key] as? UInt64 { result[key] = Double(value) }
    }
    return result
  }

  private func metadataSequence(store: AppStore, selectedURL: URL, orderedURLs: [URL]) async throws {
    try require(store.allAssets.filter { $0.sortMetadata != nil }.isEmpty,
      "minimum_byte_queries_must_not_prepare_metadata")
    var filename = LibraryQuery(searchText: "photo-7*")
    try await commit(filename, count: 75, focus: 0, url: selectedURL, phase: "filename_75")
    filename.sort = .nameDescending
    try await commit(filename, count: 75, focus: 74, url: selectedURL, phase: "filename_descending_75")
    try await commit(LibraryQuery(), count: 729, focus: 580, url: selectedURL, phase: "filename_restore_729")
    try require(store.allAssets.filter { $0.sortMetadata != nil }.isEmpty,
      "filename_queries_must_leave_first_metadata_query_unprepared")
    log("first_metadata_unprepared", fields: ["preparedMetadataFields": 0])

    let apple = LibraryQuery(searchFilters: LibrarySearchFilters(metadataText: "Apple"))
    try await commit(apple, count: 717, focus: 568, url: selectedURL, phase: "metadata_Apple_first_717")
    try require(store.allAssets.filter { $0.sortMetadata != nil }.count == 729,
      "first_metadata_query_must_prepare_positive_and_negative_fields")
    try require(store.allAssets.filter { $0.sortMetadata?.cameraMake == "Apple" }.count == 717,
      "actual_metadata_reader_must_read_717_Apple_TIFF_Make_values")
    let versions = Dictionary(uniqueKeysWithValues: store.allAssets.compactMap { asset in
      asset.sortMetadataVersion.map { (asset.url, $0) }
    })
    try require(versions.count == 729, "all_metadata_versions_required")
    log("first_metadata_prepared", fields: ["preparedMetadataFields": 729, "AppleCameraMakeFields": 717])
    try await commit(LibraryQuery(), count: 729, focus: 580, url: selectedURL, phase: "metadata_first_restore_729")
    let retained = Dictionary(uniqueKeysWithValues: store.allAssets.compactMap { asset in
      asset.sortMetadataVersion.map { (asset.url, $0) }
    })
    try require(retained == versions && store.allAssets.filter { $0.sortMetadata != nil }.count == 729,
      "restore_must_retain_all_metadata_versions")
    try await commit(apple, count: 717, focus: 568, url: selectedURL, phase: "metadata_Apple_repeat_717")
    try await commit(LibraryQuery(), count: 729, focus: 580, url: selectedURL, phase: "metadata_repeat_restore_729")
    try require(store.assets.map(\.url) == orderedURLs, "metadata_sequence_must_restore_order")
  }

  private func appleJPEG() throws -> Data {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
      throw FilterRevealTimingFailure("synthetic_JPEG_context")
    }
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    let data = NSMutableData()
    guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw FilterRevealTimingFailure("synthetic_JPEG_destination")
    }
    CGImageDestinationAddImage(destination, image,
      [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple"]] as CFDictionary)
    guard CGImageDestinationFinalize(destination),
      let source = CGImageSourceCreateWithData(data, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
      tiff[kCGImagePropertyTIFFMake] as? String == "Apple" else {
      throw FilterRevealTimingFailure("synthetic_JPEG_must_contain_real_TIFF_Make_Apple")
    }
    return data as Data
  }

  private func commit(_ query: LibraryQuery, count: Int, focus: Int, url: URL, phase: String) async throws {
    guard let store else { throw FilterRevealTimingFailure("store_missing") }
    let beforeRevision = store.assetOrderRevision
    store.libraryQuery = query
    try require(store.isFiltering, "\(phase)_query_must_start")
    try await wait("\(phase)_query_completion") {
      !store.isFiltering && store.libraryQuery == query && store.assets.count == count
    }
    try require(store.alert == nil && store.assetOrderRevision != beforeRevision, "\(phase)_collection_commit")
    try require(store.currentIndex == focus && store.currentAsset?.url == url
      && store.selectedURLs == [url], "\(phase)_focus_and_selection_identity")
    await observeReveal(phase, index: focus, url: url)
  }

  private func observeReveal(_ phase: String, index: Int, url: URL) async {
    do {
      try await wait("\(phase)_viewport") {
        self.store?.currentIndex == index && self.store?.currentAsset?.url == url
          && self.preloader?.visibleIndices.contains(index) == true
      }
      try await Task.sleep(for: .milliseconds(300))
      if preloader?.visibleIndices.contains(index) != true { recordFailure("\(phase)_reveal_did_not_remain_visible") }
      if scenario.hasPrefix("jpeg_"), let scroll, let window, let store, let preloader {
        let nativeIDs = Set(OverviewBitmapProbeRegistry.visible(in: scroll, window: window).map(\.assetURL))
        let preloadedIDs = Set(preloader.visibleIndices.compactMap {
          store.assets.indices.contains($0) ? store.assets[$0].url : nil
        })
        if !nativeIDs.contains(url) { recordFailure("\(phase)_focused_native_image_not_intersecting") }
        if !nativeIDs.isSubset(of: preloadedIDs) {
          logRevealMembershipMismatch(phase: phase, nativeIDs: nativeIDs, preloadedIDs: preloadedIDs)
          recordFailure("\(phase)_native_image_membership_not_admitted")
        }
      }
      log(phase, fields: ["expectedIndex": index, "revealSucceeded": preloader?.visibleIndices.contains(index) == true])
    } catch { recordFailure("\(phase): \(error)") }
  }

  private func logRevealMembershipMismatch(phase: String, nativeIDs: Set<URL>, preloadedIDs: Set<URL>) {
    guard let store, let scroll, let window, let root = window.contentView else { return }
    let motion = motionObserver(in: root, for: scroll)
    let registry = motion?.cellGeometryRegistry
    let paneWidth = scroll.contentView.bounds.width
    let scope = OverviewNativeCellGeometryScope(collectionRevision: store.assetOrderRevision,
      pointSize: min(store.thumbnailSize, max(1, paneWidth - 50)), paneWidth: paneWidth,
      isRightToLeft: store.overviewIsRightToLeft)
    // A fresh registry read is diagnostic only: do not replace the preloader's
    // cached membership or retry/weaken the assertion above.
    let freshCards = registry?.visibleAssetIDs(in: scroll, window: window, scope: scope) ?? []
    let ordinals = Dictionary(uniqueKeysWithValues: store.assets.enumerated().map { ($0.element.url, $0.offset) })
    func indices(_ ids: Set<URL>) -> [Int] { ids.compactMap { ordinals[$0] }.sorted() }
    let anchors = nativeGeometryAnchors(in: root)
    let owned = anchors.filter { $0.window === window && $0.enclosingScrollView === scroll }
    let missing = nativeIDs.subtracting(freshCards)
    let differing = missing.union(freshCards.subtracting(nativeIDs))
    let candidates = anchors.filter { $0.assetID.map { differing.contains($0) } == true }.sorted {
      let firstMissing = $0.assetID.map { missing.contains($0) } ?? false
      let secondMissing = $1.assetID.map { missing.contains($0) } ?? false
      if firstMissing != secondMissing { return firstMissing }
      return ($0.assetID.flatMap { ordinals[$0] } ?? Int.max) < ($1.assetID.flatMap { ordinals[$0] } ?? Int.max)
    }
    let rows: [[String: Any]] = candidates.prefix(24).map { view in
      ["ordinal": view.assetID.flatMap { ordinals[$0] }.map { $0 as Any } ?? NSNull(),
        "scopeMatches": view.scope == scope,
        "collectionMatches": view.scope?.collectionRevision == scope.collectionRevision,
        "pointSize": view.scope.map { $0.pointSize as Any } ?? NSNull(),
        "paneWidth": view.scope.map { $0.paneWidth as Any } ?? NSNull(),
        "isRightToLeft": view.scope.map { $0.isRightToLeft as Any } ?? NSNull(),
        "bounds": diagnosticRectangle(view.bounds), "frame": diagnosticRectangle(view.frame),
        "frameInClip": diagnosticRectangle(view.convert(view.bounds, to: scroll.contentView)),
        "frameInWindow": diagnosticRectangle(view.convert(view.bounds, to: nil)),
        "visibleRect": diagnosticRectangle(view.visibleRect),
        "sameWindow": view.window === window, "sameScroll": view.enclosingScrollView === scroll,
        "hiddenBySelfOrAncestor": view.isHiddenOrHasHiddenAncestor]
    }
    let anchorIDs = Set(anchors.compactMap(\.assetID))
    var fields: [String: Any] = ["revealPhase": phase,
      "nativeProbeCount": nativeIDs.count, "nativeProbeOrdinals": Array(indices(nativeIDs).prefix(24)),
      "cachedPreloaderCount": preloadedIDs.count, "cachedPreloaderOrdinals": Array(indices(preloadedIDs).prefix(24)),
      "freshCardCount": freshCards.count, "freshCardOrdinals": Array(indices(freshCards).prefix(24)),
      "nativeMissingFromCachedOrdinals": Array(indices(nativeIDs.subtracting(preloadedIDs)).prefix(24)),
      "nativeMissingFromFreshOrdinals": Array(indices(missing).prefix(24)),
      "nativeMissingAnchorOrdinals": Array(indices(missing.subtracting(anchorIDs)).prefix(24)),
      "descendantAnchorCount": anchors.count, "sameWindowAndScrollAnchorCount": owned.count,
      "currentCollectionAnchorCount": owned.filter { $0.scope?.collectionRevision == scope.collectionRevision }.count,
      "exactScopeAnchorCount": owned.filter { $0.scope == scope }.count,
      "expectedPointSize": scope.pointSize, "expectedPaneWidth": scope.paneWidth,
      "expectedRTL": scope.isRightToLeft, "registryPresent": registry != nil,
      "registryDiagnostics": registry?.diagnosticSnapshot ?? [:],
      "anchorRows": rows, "anchorRowLimit": 24,
      "nativeScrollBounds": diagnosticRectangle(scroll.bounds),
      "clipBounds": diagnosticRectangle(scroll.contentView.bounds),
      "membershipWasReplaced": false, "retryOrForcedLayoutApplied": false]
    fields["documentBounds"] = scroll.documentView.map { diagnosticRectangle($0.bounds) } ?? [:]
    fields["documentFrame"] = scroll.documentView.map { diagnosticRectangle($0.frame) } ?? [:]
    fields["motionAnchorBounds"] = motion.map { diagnosticRectangle($0.bounds) } ?? [:]
    fields["motionAnchorFrame"] = motion.map { diagnosticRectangle($0.frame) } ?? [:]
    if let geometry = motion?.currentViewportGeometry() {
      fields["freshViewportInDocument"] = diagnosticRectangle(geometry.viewportInDocument)
      fields["freshContentOriginX"] = geometry.contentOriginInDocument.x
      fields["freshContentOriginY"] = geometry.contentOriginInDocument.y
      fields["documentIsFlipped"] = geometry.documentIsFlipped
    }
    log("reveal_membership_mismatch_diagnostics", fields: fields)
  }

  private func nativeGeometryAnchors(in view: NSView) -> [OverviewNativeCellGeometryView] {
    let own = (view as? OverviewNativeCellGeometryView).map { [$0] } ?? []
    return own + view.subviews.flatMap { nativeGeometryAnchors(in: $0) }
  }

  private func diagnosticRectangle(_ value: CGRect) -> [String: Any] {
    ["x": value.minX.isFinite ? value.minX as Any : NSNull(),
      "y": value.minY.isFinite ? value.minY as Any : NSNull(),
      "width": value.width.isFinite ? value.width as Any : NSNull(),
      "height": value.height.isFinite ? value.height as Any : NSNull()]
  }

  private func wait(_ phase: String, seconds: Double = 8, until condition: @MainActor () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !condition() {
      try Task.checkCancellation()
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        log("deadline", fields: ["waitingPhase": phase])
        throw FilterRevealTimingFailure("\(phase) \(snapshot())")
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func require(_ condition: Bool, _ phase: String) throws {
    guard condition else { log("assertion", fields: ["assertionPhase": phase]); throw FilterRevealTimingFailure("\(phase) \(snapshot())") }
  }

  private func recordFailure(_ phase: String) {
    let failure = "\(phase) \(snapshot())"
    failures.append(failure)
    log("failure", fields: ["failurePhase": phase])
  }

  private func snapshot() -> String {
    let visible = preloader?.visibleIndices.sorted() ?? []
    let last = requests.suffix(4).map {
      "index=\($0.index),current=\($0.wasCurrent),animated=\($0.animated),revision=\($0.request.collectionRevision)"
    }.joined(separator: ";")
    return "currentIndex=\(store?.currentIndex ?? -1) count=\(store?.assets.count ?? 0) visible=\(visible) "
      + "clip=\(String(describing: scroll?.contentView.bounds)) document=\(String(describing: scroll?.documentView?.bounds)) "
      + "filtering=\(store?.isFiltering ?? false) collectionRevision=\(String(describing: store?.assetOrderRevision)) "
      + "appActive=\(NSApp.isActive) windowVisible=\(window?.isVisible ?? false) requests=[\(last)]"
  }

  private func log(_ phase: String, fields: [String: Any] = [:]) {
    var value = fields
    value["phase"] = phase
    value["scenario"] = scenario
    value["snapshot"] = snapshot()
    value["uptime"] = ProcessInfo.processInfo.systemUptime
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
      FileHandle.standardOutput.write(Data("FILTER_REVEAL_TIMING ".utf8) + data + Data("\n".utf8))
    }
  }

  private func findScrollView(in view: NSView, markedOverview: Bool = false) -> NSScrollView? {
    if markedOverview { return OverviewBenchmarkScrollTarget.find(in: view) }
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
  }
}
