import AppKit
import SwiftUI
import Testing

@testable import ImageViewer

/// Opt-in native UI workload. Each part starts with new application pipelines;
/// filesystem/Quick Look caches are not modified, so their state is unknown.
/// Prints aggregate timings only. Never exports image pixels or filenames.
@Suite("실제 RAW 몽땅보기 표시·스크롤·크기 조절", .serialized)
@MainActor
struct RealRAWOverviewInteractionTests {
  @Test("실제 전체 폴더 화면에서 넘기고 크기를 바꿔도 슬라이더와 마지막 크기를 유지한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_OVERVIEW_INTERACTION"] == "1"),
    .timeLimit(.minutes(3)))
  func actualOverviewControlsAndScrolling() async throws {
    let directory = try rawDirectory()
    let preparationAssets = try rawAssets(in: directory, limit: Int.max)
    let cachePreparation = try RAWFileCachePreparation.prepare(urls: preparationAssets.map(\.url),
      phase: "native_actual_overview")
    let suite = "RealRAWOverviewInteraction.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: temporary.appendingPathComponent("marks.sqlite"))
    defer {
      store.saveSessionNow()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: temporary)
    }
    store.presentationMode = .overview
    store.thumbnailSize = 150
    let heartbeat = MainActorHeartbeat()
    heartbeat.start()
    defer { heartbeat.stop() }
    #expect(await store.thumbnailPipeline.cacheSnapshot().entryCount == 0)
    let openedAt = ProcessInfo.processInfo.systemUptime
    store.openFolderFromTree(directory)
    try await wait("whole folder listing") { !store.isLoading && !store.isFiltering }
    let rawAssets = store.assets.filter {
      ImageFormatRegistry.cameraRAWExtensions.contains($0.fileExtension)
    }
    let rawCount = rawAssets.filter { ($0.byteCount ?? 0) > 0 }.count
    try #require(rawCount >= 100)
    // Leaving Home opens the file in the viewer, just as the real app does.
    // Enter the overview after the folder has finished opening.
    store.presentationMode = .overview
    try #require(store.presentationMode == .overview)
    let listedAt = ProcessInfo.processInfo.systemUptime

    _ = NSApplication.shared
    let host = NSHostingView(rootView: OverviewView(store: store))
    let window = makeWindow(host: host)
    defer { close(window) }
    try await wait("overview controls") {
      host.layoutSubtreeIfNeeded()
      return sliders(in: host).count == 1 && firstScrollView(in: host) != nil
    }
    try await wait("first observed thumbnail cache entry") {
      host.layoutSubtreeIfNeeded()
      return await store.thumbnailPipeline.cacheSnapshot().entryCount > 0
    }
    let firstBitmapAt = ProcessInfo.processInfo.systemUptime
    // Initial geometry publishes the available footer width on the next turn.
    // Do not mistake that first layout for a value-induced track resize.
    for _ in 0..<4 {
      try await Task.sleep(for: .milliseconds(25))
      host.layoutSubtreeIfNeeded()
    }
    let slider = try #require(sliders(in: host).first)
    let trackWidth = slider.bounds.width
    let scroll = try #require(firstScrollView(in: host))
    print(String(format:
      "RAW_OVERVIEW_INTERACTION phase=actual_overview_initial rawCount=%d emptyRAWCount=%d listingSeconds=%.6f cacheEntryObservedAfterListingSeconds=%.6f appCacheInitiallyEmpty=true osFilePagesVerifiedZero=%@ quickLookCache=unknown readOnly=true",
      rawCount, rawAssets.count - rawCount, listedAt - openedAt, firstBitmapAt - listedAt,
      String(cachePreparation.osFilePagesVerifiedZero)))

    heartbeat.reset()
    var maximumQueued = 0
    var forcedLayoutSeconds: [Double] = []
    func layoutForObservation() {
      let started = ProcessInfo.processInfo.systemUptime
      host.layoutSubtreeIfNeeded()
      forcedLayoutSeconds.append(ProcessInfo.processInfo.systemUptime - started)
    }
    for step in 0..<30 {
      let requested: CGFloat = [150, 220, 340, 480, 240][step % 5]
      setSlider(slider, size: requested)
      try await Task.sleep(for: .milliseconds(20))
      layoutForObservation()
      let current = try #require(sliders(in: host).first)
      #expect(current === slider)
      #expect(abs(current.bounds.width - trackWidth) < 0.1)
      #expect(abs(store.thumbnailSize - requested) < 0.01)
      if let document = scroll.documentView {
        let maximumY = max(0, document.bounds.height - scroll.contentView.bounds.height)
        let fraction = CGFloat(step) / 29
        scroll.contentView.scroll(to: NSPoint(x: 0,
          y: document.isFlipped ? maximumY * fraction : maximumY * (1 - fraction)))
        scroll.reflectScrolledClipView(scroll.contentView)
      }
      try await Task.sleep(for: .milliseconds(40))
      maximumQueued = max(maximumQueued, await store.loadingGovernor.stateSnapshot().queuedCount)
    }
    try await wait("final overview work") {
      layoutForObservation()
      let work = await store.loadingGovernor.stateSnapshot()
      return work.runningCount == 0 && work.queuedCount == 0
    }
    #expect(abs(store.thumbnailSize - 240) < 0.01)
    #expect(abs(defaults.double(forKey: "ImageViewer.OverviewThumbnailSize.v1") - 240) < 0.01)
    #expect(sliders(in: host).first === slider)
    heartbeat.report(phase: "actual_overview_scroll_and_resize", count: rawCount,
      extra: String(format:
        "nativeScrollSteps=30 nativeSliderChanges=30 maximumQueued=%d finalSize=240 forcedLayoutCalls=%d forcedLayoutTotalSeconds=%.6f forcedLayoutMaxSeconds=%.6f",
        maximumQueued, forcedLayoutSeconds.count, forcedLayoutSeconds.reduce(0, +),
        forcedLayoutSeconds.max() ?? 0))
    window.contentView = nil
    await store.thumbnailPipeline.purgeCache()
    await store.pipeline.purgeCaches()
  }

  @Test("캐시가 없는 실제 RAW 128개를 표시하고 크기 조절 중 요청을 멈췄다가 마지막 해상도로 재개한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_OVERVIEW_INTERACTION"] == "1"),
    .timeLimit(.minutes(3)))
  func uncachedProductionThumbnailGridDefersAndResumes() async throws {
    let assets = try rawAssets(in: rawDirectory(), limit: 128)
    try #require(assets.count >= 100)
    let cachePreparation = try RAWFileCachePreparation.prepare(urls: assets.map(\.url),
      phase: "native_production_thumbnail_grid")
    let governor = ImageResourceGovernor(mode: .comfortable, storageOverride: .internalSSD)
    let thumbnails = ThumbnailPipeline(governor: governor)
    let frames = ImagePipeline(governor: governor)
    let state = RAWGridState()
    let heartbeat = MainActorHeartbeat()
    heartbeat.start()
    defer { heartbeat.stop() }
    _ = NSApplication.shared
    let host = NSHostingView(rootView: RAWGridHarness(state: state, assets: assets,
      thumbnails: thumbnails, frames: frames).frame(width: 1_100, height: 740))
    let window = makeWindow(host: host)
    defer { close(window) }

    // This starts empty and explicitly exercises the production defersLoading
    // input. Native slider identity/edit binding is checked by the other test.
    for size: CGFloat in [160, 240, 320, 180, 280, 150] {
      state.size = size
      try await Task.sleep(for: .milliseconds(20))
      host.layoutSubtreeIfNeeded()
    }
    #expect(state.uniqueDisplayed.isEmpty)
    #expect(await thumbnails.cacheSnapshot().entryCount == 0)
    let deferredWork = await governor.stateSnapshot()
    #expect(deferredWork.runningCount == 0 && deferredWork.queuedCount == 0)

    heartbeat.reset()
    let releasedAt = ProcessInfo.processInfo.systemUptime
    state.defersLoading = false
    var maximumQueued = 0
    // Twelve cards fit within two rows at 150pt in this window. Wait for every
    // card in each page, so a fast scroll cannot claim unrendered files as tested.
    for first in stride(from: 0, to: assets.count, by: 12) {
      state.targetIndex = first
      let expected = Set(first..<min(first + 12, assets.count))
      try await wait("RAW display page \(first / 12 + 1)", diagnostics: {
        await gridDiagnostics(host: host, state: state, thumbnails: thumbnails, governor: governor,
          expected: expected)
      }) {
        host.layoutSubtreeIfNeeded()
        maximumQueued = max(maximumQueued, await governor.stateSnapshot().queuedCount)
        return expected.isSubset(of: state.uniqueDisplayed)
      }
    }
    try #require(state.uniqueDisplayed.count == assets.count)
    let firstDisplayAt = try #require(state.firstDisplayUptime)
    print(String(format:
      "RAW_OVERVIEW_INTERACTION phase=production_thumbnail_grid count=%d firstDisplayCallbackSeconds=%.6f allDisplayedSeconds=%.6f maximumQueued=%d appCacheInitiallyEmpty=true osFilePagesVerifiedZero=%@ quickLookCache=unknown readOnly=true",
      state.uniqueDisplayed.count, firstDisplayAt - releasedAt,
      ProcessInfo.processInfo.systemUptime - releasedAt, maximumQueued,
      String(cachePreparation.osFilePagesVerifiedZero)))
    heartbeat.report(phase: "production_thumbnail_grid_scroll", count: state.uniqueDisplayed.count)

    state.defersLoading = true
    try await wait("cancel in-flight grid thumbnails") {
      host.layoutSubtreeIfNeeded()
      let work = await governor.stateSnapshot()
      return work.runningCount == 0 && work.queuedCount == 0
    }
    heartbeat.reset()
    for step in 0..<30 {
      state.size = [180, 260, 340, 440, 240][step % 5]
      try await Task.sleep(for: .milliseconds(16))
      host.layoutSubtreeIfNeeded()
      let work = await governor.stateSnapshot()
      #expect(work.runningCount == 0 && work.queuedCount == 0,
        "Intermediate grid sizes must not start RAW work while interaction is deferred")
    }
    let finalIndex = max(0, assets.count - 8)
    // Finish the new row geometry before requesting a scroll. The target may
    // equal the last page's index, so a fresh request revision is also required.
    for _ in 0..<3 {
      try await Task.sleep(for: .milliseconds(20))
      host.layoutSubtreeIfNeeded()
    }
    state.targetIndex = finalIndex
    state.scrollRequestRevision += 1
    let finalReleaseAt = ProcessInfo.processInfo.systemUptime
    state.defersLoading = false
    let requiredPixels = OverviewThumbnailSizing.requestedPixelSize(for: state.size, displayScale: 2)
    try await wait("final displayed RAW resolution", diagnostics: {
      await gridDiagnostics(host: host, state: state, thumbnails: thumbnails, governor: governor,
        expected: [finalIndex])
    }) {
      host.layoutSubtreeIfNeeded()
      guard let size = state.displayedSizes[finalIndex] else { return false }
      return max(size.width, size.height) >= CGFloat(requiredPixels)
    }
    #expect(state.size == 240)
    heartbeat.report(phase: "production_thumbnail_grid_resize", count: state.uniqueDisplayed.count,
      extra: String(format: "deferredChanges=30 finalSize=240 finalDisplaySeconds=%.6f",
        ProcessInfo.processInfo.systemUptime - finalReleaseAt))
    let cache = await thumbnails.cacheSnapshot()
    #expect(cache.byteCount <= cache.byteLimit)
    window.contentView = nil
    await thumbnails.purgeCache()
    await frames.purgeCaches()
  }

  private func rawDirectory() throws -> URL {
    URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_DIRECTORY"]))
  }

  private func rawAssets(in directory: URL, limit: Int) throws -> [ImageAsset] {
    let urls = try FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
      .filter { ImageFormatRegistry.cameraRAWExtensions.contains($0.pathExtension.lowercased()) }
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    var assets: [ImageAsset] = []
    for url in urls {
      let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      guard let byteCount = values.fileSize, byteCount > 0 else { continue }
      assets.append(ImageAsset(url: url, byteCount: Int64(byteCount),
        modificationDate: values.contentModificationDate))
      if assets.count == limit { break }
    }
    return assets
  }

  private func makeWindow(host: NSView) -> NSWindow {
    _ = NSApplication.shared
    let frame = NSRect(x: 40, y: 40, width: 1_100, height: 740)
    host.frame = NSRect(origin: .zero, size: frame.size)
    let window = NSWindow(contentRect: frame,
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    // Lazy grids cull off-screen/fully occluded content. A real visible fixture
    // window is necessary when measuring production display callbacks.
    window.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    return window
  }

  private func close(_ window: NSWindow) {
    window.orderOut(nil)
    window.contentView = nil
    window.close()
  }

  private func setSlider(_ slider: NSSlider, size: CGFloat) {
    let range = OverviewThumbnailSizing.range
    let fraction = Double((size - range.lowerBound) / (range.upperBound - range.lowerBound))
    slider.doubleValue = slider.minValue + fraction * (slider.maxValue - slider.minValue)
    _ = slider.sendAction(slider.action, to: slider.target)
  }

  private func sliders(in view: NSView) -> [NSSlider] {
    if let slider = view as? NSSlider { return [slider] }
    return view.subviews.flatMap { sliders(in: $0) }
  }

  private func firstScrollView(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.lazy.compactMap { firstScrollView(in: $0) }.first
  }

  private func gridDiagnostics(host: NSView, state: RAWGridState, thumbnails: ThumbnailPipeline,
    governor: ImageResourceGovernor, expected: Set<Int>
  ) async -> String {
    let work = await governor.stateSnapshot()
    let cache = await thumbnails.cacheSnapshot()
    let scroll = firstScrollView(in: host)
    let clip = scroll?.contentView.bounds ?? .zero
    let document = scroll?.documentView?.bounds ?? .zero
    return "displayedUnique=\(state.uniqueDisplayed.count) displayedCurrent=\(state.displayedSizes.count) "
      + "expected=\(expected.count) expectedDisplayed=\(expected.intersection(state.uniqueDisplayed).count) "
      + "size=\(state.size) deferred=\(state.defersLoading) target=\(state.targetIndex) "
      + "host=\(host.bounds) clip=\(clip) document=\(document) "
      + "windowVisible=\(host.window?.isVisible ?? false) occlusion=\(host.window?.occlusionState.rawValue ?? 0) "
      + "running=\(work.runningCount) queued=\(work.queuedCount) cacheEntries=\(cache.entryCount) "
      + "cacheBytes=\(cache.byteCount) cacheLimit=\(cache.byteLimit)"
  }

  private func wait(_ phase: String, diagnostics: (() async -> String)? = nil,
    condition: () async -> Bool
  ) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 40
    while ProcessInfo.processInfo.systemUptime < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    if let diagnostics {
      print("RAW_OVERVIEW_INTERACTION_TIMEOUT phase=\(phase) \(await diagnostics())")
    }
    throw DeadlineExceeded(phase: phase)
  }

  private struct DeadlineExceeded: Error { let phase: String }
}

@MainActor
private final class RAWGridState: ObservableObject {
  @Published var size: CGFloat = 150
  @Published var defersLoading = true
  @Published var targetIndex = 0
  @Published var scrollRequestRevision = 0
  var uniqueDisplayed: Set<Int> = []
  var displayedSizes: [Int: CGSize] = [:]
  var firstDisplayUptime: Double?

  func record(_ size: CGSize?, at index: Int) {
    displayedSizes[index] = size
    guard size != nil else { return }
    uniqueDisplayed.insert(index)
    if firstDisplayUptime == nil { firstDisplayUptime = ProcessInfo.processInfo.systemUptime }
  }
}

/// Uses the production lazy-grid cell loading/rendering path and its real size
/// callback, with explicit interaction state that is private in OverviewView.
@MainActor
private struct RAWGridHarness: View {
  @ObservedObject var state: RAWGridState
  let assets: [ImageAsset]
  let thumbnails: ThumbnailPipeline
  let frames: ImagePipeline

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: state.size + 14,
          maximum: (state.size + 14) * 1.35), spacing: 12)], spacing: 16) {
          ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
            ThumbnailImageView(asset: asset, thumbnailPipeline: thumbnails, pipeline: frames,
              maxPixelSize: OverviewThumbnailSizing.requestedPixelSize(for: state.size, displayScale: 2),
              prefersPreciseImage: true, defersLoading: state.defersLoading,
              onDisplayedImageSizeChange: { state.record($0, at: index) })
              .frame(height: state.size).padding(7).id(index)
          }
        }
        .padding(18)
      }
      .onChange(of: state.targetIndex) { _, index in proxy.scrollTo(index, anchor: .top) }
      .onChange(of: state.scrollRequestRevision) { _, _ in
        proxy.scrollTo(state.targetIndex, anchor: .top)
      }
    }
  }
}

/// Measures main-actor scheduling gaps, not display refresh rate or GPU frames.
@MainActor
private final class MainActorHeartbeat {
  private var task: Task<Void, Never>?
  private var gaps: [Double] = []

  func start() {
    task = Task { @MainActor [weak self] in
      var previous = ProcessInfo.processInfo.systemUptime
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
        let now = ProcessInfo.processInfo.systemUptime
        self?.gaps.append(max(0, now - previous - 0.016))
        previous = now
      }
    }
  }

  func reset() { gaps.removeAll(keepingCapacity: true) }
  func stop() { task?.cancel(); task = nil }

  func report(phase: String, count: Int, extra: String = "") {
    let sorted = gaps.sorted()
    let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
    print(String(format:
      "RAW_OVERVIEW_RESPONSIVENESS phase=%@ count=%d heartbeatSamples=%d schedulingGapP95Seconds=%.6f schedulingGapMaxSeconds=%.6f %@",
      phase, count, sorted.count, p95, sorted.last ?? 0, extra))
  }
}
