import AppKit
import SwiftUI
import Testing

@testable import ImageViewer

@Suite("몽땅보기 실제 끝·처음 반복 탐색", .serialized)
@MainActor
struct OverviewScrollIdentityTests {
  private struct Deadline: Error, CustomStringConvertible {
    let phase: String
    let snapshot: String
    var description: String { "Overview scroll wait exceeded [\(phase)]: \(snapshot)" }
  }

  @Test("729항목의 마지막·처음 재방문을 반복해도 가시 범위와 현재 선택이 따라간다")
  func fixedRowStructureKeepsScrollProxyRevisits() async throws {
    let suite = "OverviewScrollIdentity.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
    let folder = temporary.appendingPathComponent("photos", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: temporary)
    }
    // A valid one-pixel synthetic QOI keeps this a navigation regression, not a
    // decoding benchmark. The real production grid still contains 729 assets.
    let qoi = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
      0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    for index in 0..<729 {
      let picked = index.isMultiple(of: 10) || index >= 727
      let url = folder.appendingPathComponent(String(format: "photo-%04d", index)
        + (picked ? "-picked.qoi" : ".qoi"))
      try qoi.write(to: url)
      // Both sorts keep photo zero first but reverse every following row.
      try FileManager.default.setAttributes([.modificationDate:
        Date(timeIntervalSince1970: 1_800_000_000 + Double(index == 0 ? 0 : 729 - index))],
        ofItemAtPath: url.path)
    }
    let disk = ThumbnailDiskCache(directory: temporary.appendingPathComponent("cache", isDirectory: true))
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: temporary.appendingPathComponent("marks.sqlite"), thumbnailDiskCache: disk)
    store.thumbnailSize = 226.4
    store.showsOverviewNumbers = false
    store.openFolderFromTree(folder)
    try await wait("listing_729", diagnostics: { snapshot(store: store) }) {
      !store.isLoading && !store.isFiltering && store.assets.count == 729
    }
    store.returnToOverview()

    _ = NSApplication.shared
    let preloader = OverviewThumbnailPreloader(quietInterval: .seconds(30))
    var scrollRequests: [(request: OverviewFocusScrollRequest, animated: Bool,
      wasCurrent: Bool, index: Int, uptime: TimeInterval)] = []
    func scrollRequestSnapshot() -> String {
      " appliedRequests=" + scrollRequests.suffix(8).map {
        "[collectionRevision=\($0.request.collectionRevision) target=\($0.request.assetID?.lastPathComponent ?? "nil") "
          + "index=\($0.index) animated=\($0.animated) wasCurrent=\($0.wasCurrent) uptime=\($0.uptime)]"
      }.joined(separator: ";")
    }
    let host = NSHostingView(rootView: OverviewView(store: store, thumbnailPreloader: preloader,
      onScrollRequestApplied: { request, animated in
        scrollRequests.append((request, animated,
          request.collectionRevision == store.assetOrderRevision && request.assetID == store.currentAsset?.id,
          store.currentIndex, ProcessInfo.processInfo.systemUptime))
      })
      .environment(\.displayScale, 2))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 1_500, height: 800),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer {
      window.orderOut(nil); window.contentView = nil; window.close()
      preloader.stop(pipeline: store.thumbnailPipeline)
    }
    try await wait("initial_overview", diagnostics: {
      snapshot(store: store, preloader: preloader, host: host, scroll: self.scrollView(in: host))
    }) {
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
      return preloader.visibleIndices.contains(0) && self.scrollView(in: host) != nil
    }
    let scroll = try #require(scrollView(in: host))
    let initialOrigin = scroll.contentView.bounds.origin.y
    try await settle(host)
    for index in [1, 2, 0] {
      store.select(index: index)
      try await wait("nearby_focus_\(index)", diagnostics: {
        snapshot(store: store, preloader: preloader, host: host, scroll: scroll)
          + scrollRequestSnapshot()
      }) {
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        return preloader.visibleIndices.contains(index) && scrollRequests.last?.index == index
      }
      try await settle(host)
      #expect(scrollRequests.last?.animated == true)
    }
    for iteration in 0..<2 {
      store.select(index: 728)
      try await wait("last_728_iteration_\(iteration)", diagnostics: {
        snapshot(store: store, preloader: preloader, host: host, scroll: scroll)
      }) {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return store.currentIndex == 728 && preloader.visibleIndices.contains(728)
          && (preloader.visibleIndices.min() ?? 0) > 600
      }
      try await settle(host)
      #expect(preloader.visibleIndices.contains(728))
      #expect(scrollRequests.last?.index == 728 && scrollRequests.last?.animated == false)
      #expect(abs(scroll.contentView.bounds.origin.y - initialOrigin) > scroll.contentView.bounds.height)
      #expect(store.presentationMode == .overview)
      store.select(index: 0)
      try await wait("first_0_iteration_\(iteration)", diagnostics: {
        snapshot(store: store, preloader: preloader, host: host, scroll: scroll)
      }) {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return store.currentIndex == 0 && preloader.visibleIndices.contains(0)
          && (preloader.visibleIndices.max() ?? 729) < 30
      }
      try await settle(host)
      #expect(preloader.visibleIndices.contains(0))
      #expect(scrollRequests.last?.index == 0 && scrollRequests.last?.animated == false)
      #expect(abs(scroll.contentView.bounds.origin.y - initialOrigin) < 1)
    }
    let firstURL = store.assets[0].url
    let orderedIDs = store.assets.map(\.id)
    let unchangedOrderRevision = store.assetOrderRevision
    let document = try #require(scroll.documentView)
    let maximumOrigin = max(0, document.bounds.height - scroll.contentView.bounds.height)
    let endOrigin = initialOrigin < maximumOrigin * 0.5 ? maximumOrigin : 0
    let manualScrollRequestCount = scrollRequests.count
    // Keep focus/selection at photo zero while the user independently scrolls
    // to the end. A query returning the identical ordered collection must not
    // pull this viewport back to the still-focused first photo.
    scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.origin.x, y: endOrigin))
    scroll.reflectScrolledClipView(scroll.contentView)
    try await wait("manual_end_preserves_focus_0", diagnostics: {
      snapshot(store: store, preloader: preloader, host: host, scroll: scroll)
        + scrollRequestSnapshot()
    }) {
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
      return preloader.visibleIndices.contains(728) && (preloader.visibleIndices.min() ?? 0) > 600
    }
    try await settle(host)
    let settledEndOrigin = scroll.contentView.bounds.origin.y
    for search in ["photo*", ""] {
      let previousFullRevision = store.libraryRevision
      store.libraryQuery.searchText = search
      // The query setter synchronously enters filtering before its async work.
      // Observe that edge, then wait for completion; an identical result keeps
      // collection revisions stable instead of publishing the same assets.
      try #require(store.isFiltering, "The changed query must actually start before awaiting its completion")
      try await wait("same_order_query_\(search.isEmpty ? "clear" : "apply")", diagnostics: {
        snapshot(store: store, preloader: preloader, host: host, scroll: scroll)
          + scrollRequestSnapshot()
      }) {
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        return !store.isFiltering && store.libraryQuery.searchText == search
          && store.assets.count == 729 && preloader.visibleIndices.contains(728)
      }
      try await settle(host)
      #expect(store.assets.map(\.id) == orderedIDs)
      #expect(store.assetOrderRevision == unchangedOrderRevision)
      #expect(store.libraryRevision == previousFullRevision)
      #expect(store.alert == nil, "The query must finish successfully, not merely stop filtering after an error")
      #expect(store.currentIndex == 0 && store.currentAsset?.url == firstURL)
      #expect(store.selectedURLs == [firstURL])
      #expect(abs(scroll.contentView.bounds.origin.y - settledEndOrigin) < 1)
      #expect(scrollRequests.count == manualScrollRequestCount)
    }
    scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.origin.x, y: initialOrigin))
    scroll.reflectScrolledClipView(scroll.contentView)
    try await wait("manual_return_before_filter", diagnostics: {
      snapshot(store: store, preloader: preloader, host: host, scroll: scroll)
        + scrollRequestSnapshot()
    }) {
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
      return preloader.visibleIndices.contains(0) && (preloader.visibleIndices.max() ?? 729) < 30
    }
    try await settle(host)
    #expect(scrollRequests.count == manualScrollRequestCount)

    // Keep the first identity unchanged while filtering so the grid must update
    // its indices/preload membership even without replacing card bitmap State.
    store.libraryQuery.searchText = "photo-00"
    try await wait("filter_100_same_first", diagnostics: {
      snapshot(store: store, preloader: preloader, host: host, scroll: scroll)
    }) {
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
      return !store.isFiltering && store.assets.count == 100
        && store.assets.first?.url == firstURL && preloader.visibleIndices.contains(0)
    }
    #expect(store.selectedURLs == [firstURL])
    store.select(index: 99)
    try await wait("filter_last_99", diagnostics: {
      snapshot(store: store, preloader: preloader, host: host, scroll: scroll)
    }) {
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
      return preloader.visibleIndices.contains(99) && (preloader.visibleIndices.min() ?? 0) > 60
    }
    try await settle(host)
    let selectedFilteredURL = try #require(store.currentAsset?.url)
    store.libraryQuery.searchText = ""
    try await wait("filter_removed_729", diagnostics: {
      snapshot(store: store, preloader: preloader, host: host, scroll: scroll)
    }) {
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
      return !store.isFiltering && store.assets.count == 729
        && store.currentAsset?.url == selectedFilteredURL && preloader.visibleIndices.contains(99)
    }
    #expect(store.currentIndex == 99)
    #expect(store.selectedURLs == [selectedFilteredURL])
    store.select(index: 728)
    try await wait("unfiltered_last_728", diagnostics: {
      snapshot(store: store, preloader: preloader, host: host, scroll: scroll)
    }) {
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
      return preloader.visibleIndices.contains(728)
    }
    try await settle(host)
    store.select(index: 0)
    try await wait("unfiltered_first_0", diagnostics: {
      snapshot(store: store, preloader: preloader, host: host, scroll: scroll)
    }) {
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
      return preloader.visibleIndices.contains(0) && (preloader.visibleIndices.max() ?? 729) < 30
    }
    // Membership can reach row zero before its 200ms animation completes.
    // Finish this roundtrip before starting the independent filter scenario.
    try await settle(host)
    #expect(store.selectedURLs == [firstURL])

    // A distributed 75-photo filter moves the same focused photo to index 70.
    // Its removal must reveal that same photo at index 700 with one nonanimated
    // request, even though the collection's first identity never changed.
    store.select(index: 700)
    try await wait("focus_700_before_filter", diagnostics: {
      snapshot(store: store, preloader: preloader, host: host, scroll: scroll)
        + scrollRequestSnapshot()
    }) {
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
      return preloader.visibleIndices.contains(700)
    }
    try await settle(host)
    let retainedURL = try #require(store.currentAsset?.url)
    var requestStart = scrollRequests.count
    store.libraryQuery.searchText = "*picked*"
    try await wait("distributed_filter_75", diagnostics: {
      snapshot(store: store, preloader: preloader, host: host, scroll: scroll)
        + scrollRequestSnapshot()
    }) {
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
      return !store.isFiltering && store.assets.count == 75 && store.currentIndex == 70
        && preloader.visibleIndices.contains(70)
    }
    try await settle(host)
    #expect(store.assets.first?.url == firstURL)
    #expect(store.currentAsset?.url == retainedURL)
    #expect(store.selectedURLs == [retainedURL])
    #expect(scrollRequests.count - requestStart == 1)
    #expect(scrollRequests.last?.animated == false)
    requestStart = scrollRequests.count
    store.libraryQuery.searchText = ""
    try await wait("distributed_filter_restore_729", diagnostics: {
      snapshot(store: store, preloader: preloader, host: host, scroll: scroll)
        + scrollRequestSnapshot()
    }) {
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
      return !store.isFiltering && store.assets.count == 729 && store.currentIndex == 700
        && preloader.visibleIndices.contains(700)
    }
    try await settle(host)
    #expect(store.currentAsset?.url == retainedURL)
    #expect(store.selectedURLs == [retainedURL])
    #expect(scrollRequests.count - requestStart == 1)
    #expect(scrollRequests.last?.animated == false)

    requestStart = scrollRequests.count
    store.libraryQuery.sort = .modifiedOldest
    try await wait("same_first_reordered_focus", diagnostics: {
      snapshot(store: store, preloader: preloader, host: host, scroll: scroll)
        + scrollRequestSnapshot()
    }) {
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
      return !store.isFiltering && store.assets.first?.url == firstURL
        && store.currentAsset?.url == retainedURL && store.currentIndex == 29
        && preloader.visibleIndices.contains(29)
    }
    try await settle(host)
    #expect(scrollRequests.count - requestStart == 1)
    #expect(scrollRequests.last?.animated == false)
    #expect(store.selectedURLs == [retainedURL])

    // Repeated same-turn focus/layout requests and a burst of normal queries
    // replace pending tasks before their post-yield application point.
    requestStart = scrollRequests.count
    store.select(index: 728)
    host.layoutSubtreeIfNeeded()
    store.select(index: 0)
    host.layoutSubtreeIfNeeded()
    store.libraryQuery.searchText = "photo-00"
    store.libraryQuery.searchText = "photo-01"
    store.libraryQuery.searchText = "*picked*"
    try await wait("rapid_filter_latest_75", diagnostics: {
      snapshot(store: store, preloader: preloader, host: host, scroll: scroll)
        + scrollRequestSnapshot()
    }) {
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
      return !store.isFiltering && store.assets.count == 75
        && store.libraryQuery.searchText == "*picked*"
        && store.currentAsset?.url == firstURL && preloader.visibleIndices.contains(0)
    }
    try await settle(host)
    let finalRevision = store.assetOrderRevision
    let rapidRequests = Array(scrollRequests.dropFirst(requestStart))
    #expect(rapidRequests.filter { $0.request.collectionRevision == finalRevision }.count == 1)
    #expect(rapidRequests.allSatisfy { $0.wasCurrent })
    #expect(rapidRequests.allSatisfy { !$0.animated })
    #expect(!rapidRequests.contains { $0.request.assetID == retainedURL })
    #expect(scrollRequests.last?.animated == false)
  }

  @Test("컬렉션 전환은 이전 보완을 무효화하고 quiet 뒤 새 viewport만 허용한다")
  func collectionTransitionKeepsOcclusionAndCurrentViewportProtection() async throws {
    let gate = OverviewRefinementGate(quietInterval: .milliseconds(60),
      requiresVisibleMembership: true)
    defer { gate.stop() }
    let old = URL(fileURLWithPath: "/tmp/overview-old-collection.qoi")
    let current = URL(fileURLWithPath: "/tmp/overview-current-collection.qoi")
    gate.updateVisibleAssets([old])
    let previousGeneration = gate.motionGeneration
    #expect(gate.allowsRefinement(for: old))
    gate.collectionChanged()
    #expect(gate.motionGeneration == previousGeneration + 1)
    #expect(gate.isDeferring)
    #expect(!gate.allowsRefinement(for: old, since: previousGeneration))
    gate.updateVisibleAssets([current])
    try await wait("collection_quiet", diagnostics: { "deferring=\(gate.isDeferring)" }) {
      !gate.isDeferring
    }
    #expect(gate.allowsRefinement(for: current))
    #expect(!gate.allowsRefinement(for: old))
    gate.windowVisibilityChanged(isApplicationActive: false, isWindowVisible: false)
    gate.collectionChanged()
    gate.updateVisibleAssets([current])
    try await Task.sleep(for: .milliseconds(100))
    #expect(gate.isWindowSuppressed)
    #expect(!gate.allowsRefinement(for: current))
    gate.windowVisibilityChanged(isApplicationActive: true, isWindowVisible: true)
    try await wait("exposed_collection_quiet", diagnostics: { "deferring=\(gate.isDeferring)" }) {
      gate.allowsRefinement(for: current)
    }
  }

  // NSHostingView tests have no running NSApplication event loop. Process the
  // display transactions across the normal 200ms scroll animation before
  // issuing its reverse, rather than treating an early target model as settled.
  private func settle(_ host: NSView) async throws {
    for _ in 0..<6 {
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  private func scrollView(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
  }

  private func snapshot(store: AppStore, preloader: OverviewThumbnailPreloader? = nil,
    host: NSView? = nil, scroll: NSScrollView? = nil) -> String {
    let visible = preloader?.visibleIndices ?? []
    let document = scroll?.documentView
    let convertedViewport = document.flatMap { document in
      scroll.map { document.convert($0.contentView.bounds, from: $0.contentView) }
    }
    return "currentIndex=\(store.currentIndex) visibleCount=\(visible.count) visibleMin=\(visible.min() ?? -1) visibleMax=\(visible.max() ?? -1) visible=\(visible.sorted()) "
      + "clipOrigin=\(String(describing: scroll?.contentView.bounds.origin)) clipSize=\(String(describing: scroll?.contentView.bounds.size)) "
      + "documentBounds=\(String(describing: document?.bounds)) documentFrame=\(String(describing: document?.frame)) convertedViewport=\(String(describing: convertedViewport)) "
      + "clipPresentationBounds=\(String(describing: scroll?.contentView.layer?.presentation()?.bounds)) documentPresentationFrame=\(String(describing: document?.layer?.presentation()?.frame)) "
      + "hostBounds=\(String(describing: host?.bounds)) "
      + "assetsCount=\(store.assets.count) collectionRevision=\(store.assetOrderRevision) libraryRevision=\(store.libraryRevision) "
      + "loading=\(store.isLoading) filtering=\(store.isFiltering) mode=\(store.presentationMode)"
  }

  private func wait(_ phase: String, diagnostics: () -> String, until condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while ContinuousClock.now < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    let state = diagnostics()
    print("OVERVIEW_SCROLL_IDENTITY_WAIT_FAILED phase=\(phase) \(state)")
    // Preserve the original failure. This separately probes whether a missing
    // AppKit event loop in the offscreen test host left geometry work queued.
    pumpAppKitAfterFailure()
    let recovered = condition()
    print("OVERVIEW_SCROLL_IDENTITY_AFTER_FAILURE_APPKIT_PUMP phase=\(phase) recovered=\(recovered) \(diagnostics())")
    throw Deadline(phase: phase, snapshot: state)
  }

  private func pumpAppKitAfterFailure() {
    for _ in 0..<4 {
      NSApp.updateWindows()
      _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.025))
    }
  }
}
