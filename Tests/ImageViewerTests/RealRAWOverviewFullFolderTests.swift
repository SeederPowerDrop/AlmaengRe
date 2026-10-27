import AppKit
import CoreGraphics
import Darwin
import SwiftUI
import Testing

@testable import ImageViewer

/// Explicitly enabled native workload with the production overview, preloader,
/// governor and live resource monitor. Only aggregate diagnostics are exported.
/// The operator changes foreground applications through the two signal files;
/// only its own test window is activated for native foreground interaction.
/// The optional seeded mode prepares through real visible-cell demand while
/// preserving the original background run's cache and resource evidence.
@MainActor
struct RealRAWOverviewFullFolderTests {
  func fullFolderPreparationAndNativeRevisit() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["IMAGEVIEWER_FULL_APPKIT_HOST"] == "1" else {
      throw FullOverviewDeadlineExceeded(phase: "requires_RealRAWOverviewNativeHostTests_synchronous_AppKit_host")
    }
    _ = NSApplication.shared
    let previousActivationPolicy = NSApp.activationPolicy()
    _ = NSApp.setActivationPolicy(.regular)
    defer { _ = NSApp.setActivationPolicy(previousActivationPolicy) }
    let foregroundSeeded = environment["IMAGEVIEWER_RAW_OVERVIEW_FULL_MODE"] == "foreground_seeded"
    let source = URL(fileURLWithPath: environment["IMAGEVIEWER_RAW_DIRECTORY"]
      ?? "/Users/hyunjinkim/Pictures/iPhoneRAW", isDirectory: true)
    let output = URL(fileURLWithPath: environment["IMAGEVIEWER_FULL_OVERVIEW_OUTPUT"]
      ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("ImageViewer-full-overview-\(UUID())").path,
      isDirectory: true)
    try #require(output.path.hasPrefix("/"))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let suite = "RealRAWOverviewFullFolder.\(UUID())"
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let defaults = try #require(UserDefaults(suiteName: suite))
    let diskDirectory = temporary.appendingPathComponent("thumbnails", isDirectory: true)
    if foregroundSeeded {
      let seedPath = try #require(environment["IMAGEVIEWER_RAW_OVERVIEW_SEED_DIRECTORY"],
        "The seeded visible-demand mode requires an owned thumbnail cache seed")
      try FileManager.default.copyItem(at: URL(fileURLWithPath: seedPath, isDirectory: true), to: diskDirectory)
    }
    let disk = ThumbnailDiskCache(directory: diskDirectory)
    let store = AppStore(defaults: defaults, monitorsSystemResources: true,
      photoMarkDatabaseURL: temporary.appendingPathComponent("marks.sqlite"), thumbnailDiskCache: disk)
    let preloader = OverviewThumbnailPreloader()
    let sampler = FullOverviewResourceSampler()
    var window: NSWindow?
    defer {
      preloader.stop(pipeline: store.thumbnailPipeline)
      sampler.stop()
      if let window {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
      }
      store.saveSessionNow()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: temporary)
    }

    let originalURLs = try FileManager.default.contentsOfDirectory(at: source,
      includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
      .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    let originalVersions = originalURLs.map { ImageFileVersion(url: $0) }
    let started = uptime
    let deadline = started + 19 * 60
    store.thumbnailSize = 226.4
    store.showsOverviewNumbers = false
    store.openFolderFromTree(source)
    try await wait(until: min(deadline, uptime + 90), name: "folder_listing") {
      !store.isLoading && !store.isFiltering
    }
    store.presentationMode = .overview
    let photos = store.assets
    try #require(photos.count >= 700, "The full-folder workload needs at least 700 listed items")
    let nonempty = photos.filter { ($0.byteCount ?? 0) > 0 }
    let empty = photos.filter { ($0.byteCount ?? 0) == 0 }
    var report = FullOverviewReport()
    report.mode = foregroundSeeded ? "foreground_seeded_visible_demand" : "automatic_background_preparation"
    if foregroundSeeded {
      report.storageCacheScope = "copied_partial_app_disk_cache_OS_file_cache_and_QuickLook_cache_uncontrolled"
    }
    report.sources = FullOverviewSourceCounts(total: photos.count, nonempty: nonempty.count,
      nonemptyRAW: nonempty.filter { ImageFormatRegistry.cameraRAWExtensions.contains($0.fileExtension) }.count,
      empty: empty.count)
    report.initialCache = await cacheReport(store: store, photos: photos, pixels: 768)
    report.seedPreviewAssets = foregroundSeeded ? report.initialCache?.previewCoveredAssets ?? 0 : 0
    sampler.start()

    do {
      if foregroundSeeded {
        // The seeded follow-up already has the original background evidence.
        // Start its short no-overview baseline without another file handshake.
        if NSApp.isActive { NSApp.hide(nil) }
        try await waitForIdle(store: store, deadline: min(deadline, uptime + 90), name: "seeded_baseline_queue_idle")
        try await writeProgress(output: output, stage: "seeded_baseline_other_app", started: started,
          store: store, photos: photos, preloader: preloader, pixels: 768, sampler: sampler)
        let baseline = sampler.beginPhase("seeded_partial_cache_baseline_without_overview")
        try await Task.sleep(for: .seconds(30))
        report.phases.append(sampler.endPhase(baseline))
      } else {
      try await writeProgress(output: output, stage: "ready_baseline_other_app", started: started,
        store: store, photos: photos, preloader: preloader, pixels: 768, sampler: sampler)
      try await awaitSignal(output.appendingPathComponent("baseline-start.signal"),
        deadline: min(deadline, uptime + 150), name: "baseline_foreground_signal")
      try await waitForIdle(store: store, deadline: min(deadline, uptime + 90), name: "baseline_queue_idle")
      let baseline = sampler.beginPhase("baseline_other_app_without_overview_or_warming")
      try await Task.sleep(for: .seconds(30))
      let baselineReport = sampler.endPhase(baseline)
      report.phases.append(baselineReport)
      #expect(baselineReport.inactiveSampleFraction >= 0.95,
        "At least 95% of baseline samples must have another app in the foreground")
      #expect(baselineReport.otherForegroundSampleFraction >= 0.95)

      try await writeProgress(output: output, stage: "ready_warm_other_app", started: started,
        store: store, photos: photos, preloader: preloader, pixels: 768, sampler: sampler)
      try await awaitSignal(output.appendingPathComponent("warm-start.signal"),
        deadline: min(deadline, uptime + 150), name: "warm_foreground_signal")
      }
      let preparation = sampler.beginPhase(foregroundSeeded
        ? "production_visible_demand_preparation_measured_actual_focus"
        : "production_full_folder_preparation_other_app")
      let host = NSHostingView(rootView: OverviewView(store: store, thumbnailPreloader: preloader))
      let nativeWindow = makeWindow(host: host)
      window = nativeWindow
      sampler.observedWindow = nativeWindow
      let pixels = OverviewThumbnailSizing.requestedPixelSize(for: store.thumbnailSize,
        displayScale: nativeWindow.backingScaleFactor)
      report.requestedPixelSize = ((pixels + 127) / 128) * 128
      report.displayScale = Double(nativeWindow.backingScaleFactor)
      try await wait(until: min(deadline, uptime + 90), name: "actual_overview_viewport") {
        host.layoutSubtreeIfNeeded()
        return !preloader.visibleIndices.isEmpty && self.firstScrollView(in: host) != nil
          && (foregroundSeeded || preloader.isPreparing)
      }
      report.initialVisibleCount = preloader.visibleIndices.count
      report.initialVisibleMinimum = preloader.visibleIndices.min() ?? -1
      if foregroundSeeded {
        report.preparationActivationSucceeded = await activateOwnWindow(nativeWindow, timeout: 5)
        let nativeScroll = try #require(firstScrollView(in: host))
        report.visibleDemandPreparation = try await prepareThroughVisibleCells(scroll: nativeScroll,
          host: host, preloader: preloader, store: store, photos: photos, pixels: pixels,
          output: output, sampler: sampler, started: started, deadline: deadline)
      } else {
        // Put only this test's window behind the already active other app. The
        // production preloader must continue even if its grid becomes occluded.
        nativeWindow.orderBack(nil)
        var nextProgress = uptime
        while preloader.isPreparing {
          try Task.checkCancellation()
          if uptime >= deadline { throw FullOverviewDeadlineExceeded(phase: "full_folder_preparation") }
          host.layoutSubtreeIfNeeded()
          if uptime >= nextProgress {
            try await writeProgress(output: output, stage: "warming_other_app", started: started,
              store: store, photos: photos, preloader: preloader, pixels: pixels, sampler: sampler)
            nextProgress = uptime + 10
          }
          try await Task.sleep(for: .milliseconds(100))
        }
      }
      let preparationReport = sampler.endPhase(preparation)
      report.phases.append(preparationReport)
      if !foregroundSeeded {
        #expect(preparationReport.inactiveSampleFraction >= 0.95,
          "At least 95% of preparation samples must have another app in the foreground")
        #expect(preparationReport.otherForegroundSampleFraction >= 0.95)
      }
      report.afterPreparation = await cacheReport(store: store, photos: photos, pixels: pixels)
      let preparedCounts = await store.thumbnailPipeline.overviewCachedAssetCounts(
        assets: nonempty, maxPixelSize: pixels)
      try #require(preparedCounts.preview == nonempty.count,
        "Every nonempty supported photo must have reusable first pixels after preparation")
      if foregroundSeeded {
        #expect(report.visibleDemandPreparation?.uniqueNonemptyVisibleAssets == nonempty.count)
      }
      #expect((report.afterPreparation?.memoryBytes ?? 0) <= (report.afterPreparation?.memoryLimit ?? 0))
      report.newlyPreparedPreviewAssets = max(0, preparedCounts.preview - report.seedPreviewAssets)

      if foregroundSeeded {
        nativeWindow.orderOut(nil)
        NSApp.hide(nil)
      }
      try await waitForIdle(store: store, deadline: min(deadline, uptime + 90), name: "post_preparation_queue_idle")
      try await writeProgress(output: output, stage: "post_preparation_other_app_idle", started: started,
        store: store, photos: photos, preloader: preloader, pixels: pixels, sampler: sampler)
      let idle = sampler.beginPhase("production_after_preparation_other_app_idle")
      try await Task.sleep(for: .seconds(30))
      let idleReport = sampler.endPhase(idle)
      report.phases.append(idleReport)
      #expect(idleReport.inactiveSampleFraction >= 0.95)
      #expect(idleReport.otherForegroundSampleFraction >= 0.95)

      if foregroundSeeded {
        report.nativeScrollActivationSucceeded = await activateOwnWindow(nativeWindow, timeout: 5)
      } else {
        nativeWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await wait(until: min(deadline, uptime + 15), name: "native_test_foreground_activation") {
          NSApp.isActive
        }
        report.nativeScrollActivationSucceeded = true
      }
      try await Task.sleep(for: .seconds(1))
      report.nativeScrollAppWasActive = NSApp.isActive

      try await writeProgress(output: output, stage: "native_scroll_to_end", started: started,
        store: store, photos: photos, preloader: preloader, pixels: pixels, sampler: sampler)
      let scroll = try #require(firstScrollView(in: host))
      _ = await store.thumbnailPipeline.cachedPreviewDiagnosticsSnapshot(clear: true)
      await store.thumbnailPipeline.setCachedPreviewDiagnosticPhase("outbound")
      let toEnd = sampler.beginPhase("native_scroll_to_end_after_full_preparation")
      var endPass = try await scrollPass(name: "to_end", towardEnd: true, scroll: scroll,
        host: host, preloader: preloader, store: store, photos: photos, pixels: pixels,
        deadline: deadline)
      report.phases.append(sampler.endPhase(toEnd))
      report.atEndCache = await cacheReport(store: store, photos: photos, pixels: pixels)
      try await writeProgress(output: output, stage: "native_scroll_back", started: started,
        store: store, photos: photos, preloader: preloader, pixels: pixels, sampler: sampler)
      await store.thumbnailPipeline.setCachedPreviewDiagnosticPhase("back")
      let back = sampler.beginPhase("native_scroll_back_after_full_preparation")
      var backPass = try await scrollPass(name: "back_to_start", towardEnd: false, scroll: scroll,
        host: host, preloader: preloader, store: store, photos: photos, pixels: pixels,
        deadline: deadline)
      report.phases.append(sampler.endPhase(back))
      await store.thumbnailPipeline.setCachedPreviewDiagnosticPhase(nil)
      // Late completions retain their entry phase. Finish genuine UI work
      // before taking the ledger, without issuing bitmap availability probes.
      try await Task.sleep(for: .milliseconds(250))
      try await waitForIdle(store: store, deadline: min(deadline, uptime + 90), name: "native_diagnostic_queue_idle")
      let actualUIRequests = await store.thumbnailPipeline.cachedPreviewDiagnosticsSnapshot(clear: true)
      endPass.report.actualUICachedPreview = actualUICacheReport(records: actualUIRequests,
        phase: "outbound", seenIndices: endPass.seenIndices, photos: photos)
      backPass.report.actualUICachedPreview = actualUICacheReport(records: actualUIRequests,
        phase: "back", seenIndices: backPass.seenIndices, photos: photos)
      // Availability probes populate RAM, so run them only after BOTH measured
      // native passes. The return journey must use the cache left by the real UI.
      let endProbe = sampler.beginPhase("diagnostic_cache_availability_after_both_scrolls_outbound_assets")
      await cacheProbes(indices: endPass.seenIndices, photos: photos, pipeline: store.thumbnailPipeline,
        pixels: pixels, result: &endPass.report)
      report.phases.append(sampler.endPhase(endProbe))
      report.scrolls.append(endPass.report)
      let backProbe = sampler.beginPhase("diagnostic_cache_availability_after_scroll_back")
      await cacheProbes(indices: backPass.seenIndices, photos: photos, pipeline: store.thumbnailPipeline,
        pixels: pixels, result: &backPass.report)
      report.phases.append(sampler.endPhase(backProbe))
      report.scrolls.append(backPass.report)
      report.afterScrolls = await cacheReport(store: store, photos: photos, pixels: pixels)
      report.sourceMetadataUnchanged = originalURLs.map { ImageFileVersion(url: $0) } == originalVersions
      #expect(report.sourceMetadataUnchanged, "Read-only overview work changed source metadata")
      for pass in report.scrolls {
        #expect(pass.uniqueVisibleCount == photos.count,
          "Each native pass must visit every listed photo")
        #expect(pass.cacheFirstPixelMisses == 0,
          "All newly visible nonempty photos must reuse prepared first pixels")
        #expect((pass.actualUICachedPreview?.uncancelledMisses ?? 0) == 0,
          "Actual UI requests for prepared nonempty photos must reuse cached first pixels")
      }
      let nativePhases = report.phases.filter { $0.name.hasPrefix("native_scroll_") }
      report.foregroundValidationComplete = report.nativeScrollActivationSucceeded
        && !nativePhases.isEmpty && nativePhases.allSatisfy { $0.inactiveSampleFraction <= 0.05 }
      report.status = foregroundSeeded && !report.foregroundValidationComplete
        ? "attention_needed_for_foreground_validation" : "completed"
      report.totalWallSeconds = uptime - started
      report.samples = sampler.samples
      try writeJSON(report, to: output.appendingPathComponent("full-folder-report.json"))
      try await writeProgress(output: output, stage: "completed", started: started,
        store: store, photos: photos, preloader: preloader, pixels: pixels, sampler: sampler)
      log("RAW_OVERVIEW_FULL completed total=\(photos.count) nonempty=\(nonempty.count) empty=\(empty.count) sourceMetadataUnchanged=\(report.sourceMetadataUnchanged)")
    } catch {
      await store.thumbnailPipeline.setCachedPreviewDiagnosticPhase(nil)
      report.status = "failed"
      report.failurePhase = (error as? FullOverviewDeadlineExceeded)?.phase ?? "execution_or_cancellation"
      report.totalWallSeconds = uptime - started
      report.samples = sampler.samples
      report.afterScrolls = await cacheReport(store: store, photos: photos, pixels: report.requestedPixelSize)
      report.sourceMetadataUnchanged = originalURLs.map { ImageFileVersion(url: $0) } == originalVersions
      try? writeJSON(report, to: output.appendingPathComponent("full-folder-report.json"))
      throw error
    }
  }

  /// Visits the real viewport and lets its production cells request missing
  /// images. The only diagnostic request here reads disk metadata; it neither
  /// decodes a photo nor restores a bitmap into RAM.
  private func prepareThroughVisibleCells(scroll: NSScrollView, host: NSView,
    preloader: OverviewThumbnailPreloader, store: AppStore, photos: [ImageAsset], pixels: Int,
    output: URL, sampler: FullOverviewResourceSampler, started: Double, deadline: Double)
    async throws -> FullOverviewVisiblePreparationReport {
    let began = uptime
    let document = try #require(scroll.documentView)
    let step = max(1, scroll.contentView.bounds.height * 0.6)
    var position: CGFloat = 0
    var seen = Set<Int>()
    var viewportCount = 0
    var nextProgress = uptime
    while true {
      try Task.checkCancellation()
      if uptime >= deadline { throw FullOverviewDeadlineExceeded(phase: "visible_demand_preparation") }
      let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
      scroll.contentView.scroll(to: CGPoint(x: 0, y: document.isFlipped ? position : maximum - position))
      scroll.reflectScrolledClipView(scroll.contentView)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      let viewportDeadline = min(deadline, uptime + 90)
      while true {
        try Task.checkCancellation()
        if uptime >= viewportDeadline {
          throw FullOverviewDeadlineExceeded(phase: "visible_demand_viewport_cache")
        }
        host.layoutSubtreeIfNeeded()
        let visible = preloader.visibleIndices
        let eligibleIndices = visible.filter { photos.indices.contains($0) && (photos[$0].byteCount ?? 0) > 0 }
        seen.formUnion(eligibleIndices)
        let coverage = await store.thumbnailPipeline.overviewCachedAssetCounts(
          assets: eligibleIndices.sorted().map { photos[$0] }, maxPixelSize: pixels)
        if uptime >= nextProgress {
          try await writeProgress(output: output, stage: "visible_demand_preparation", started: started,
            store: store, photos: photos, preloader: preloader, pixels: pixels, sampler: sampler)
          nextProgress = uptime + 10
        }
        if !visible.isEmpty && coverage.preview == eligibleIndices.count { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      viewportCount += 1
      position = logicalScrollPosition(scroll: scroll, document: document)
      let currentMaximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
      if position >= currentMaximum - 1 { break }
      let next = min(currentMaximum, position + step)
      if next <= position { throw FullOverviewDeadlineExceeded(phase: "visible_demand_scroll_progress") }
      position = next
    }
    // Return through the native scroll view without a cache restoration probe.
    let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
    scroll.contentView.scroll(to: CGPoint(x: 0, y: document.isFlipped ? 0 : maximum))
    scroll.reflectScrolledClipView(scroll.contentView)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    return FullOverviewVisiblePreparationReport(nativeViewports: viewportCount,
      uniqueNonemptyVisibleAssets: seen.count, wallSeconds: uptime - began)
  }

  private func activateOwnWindow(_ window: NSWindow, timeout: Double) async -> Bool {
    NSApp.unhide(nil)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
    let deadline = uptime + timeout
    while uptime < deadline {
      if NSApp.isActive { return true }
      do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
    }
    return NSApp.isActive
  }

  private func scrollPass(name: String, towardEnd: Bool, scroll: NSScrollView,
    host: NSView, preloader: OverviewThumbnailPreloader, store: AppStore,
    photos: [ImageAsset], pixels: Int, deadline: Double) async throws
    -> (report: FullOverviewScrollReport, seenIndices: [Int]) {
    let started = uptime
    var result = FullOverviewScrollReport(name: name)
    var seen = preloader.visibleIndices
    let document = try #require(scroll.documentView)
    host.layoutSubtreeIfNeeded()
    var position = logicalScrollPosition(scroll: scroll, document: document)
    result.startPosition = Double(position)
    let step = max(1, scroll.contentView.bounds.height * 0.6)
    while true {
      try Task.checkCancellation()
      if uptime >= deadline { throw FullOverviewDeadlineExceeded(phase: name) }
      let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
      let next = towardEnd ? min(maximum, position + step) : max(0, position - step)
      let y = document.isFlipped ? next : maximum - next
      scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
      scroll.reflectScrolledClipView(scroll.contentView)
      host.layoutSubtreeIfNeeded()
      await Task.yield()
      try await Task.sleep(for: .milliseconds(20))
      host.layoutSubtreeIfNeeded()
      result.nativeScrollSteps += 1
      let visible = preloader.visibleIndices
      result.maximumVisibleCount = max(result.maximumVisibleCount, visible.count)
      seen.formUnion(visible)
      result.finalVisibleMinimum = visible.min() ?? -1
      result.finalVisibleMaximum = visible.max() ?? -1
      position = logicalScrollPosition(scroll: scroll, document: document)
      if (towardEnd && position >= maximum - 1) || (!towardEnd && position <= 1) { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    result.endPosition = Double(position)
    result.uniqueVisibleCount = seen.count
    result.wallSeconds = uptime - started
    if towardEnd { #expect(result.finalVisibleMaximum >= photos.count - 3) }
    else { #expect(result.finalVisibleMinimum <= 2) }
    return (result, seen.sorted())
  }

  /// Diagnostic probes run after the native pass's phase has ended, so they do
  /// not promote work or warm RAM during its measured scrolling workload.
  private func cacheProbes(indices: [Int], photos: [ImageAsset], pipeline: ThumbnailPipeline,
    pixels: Int, result: inout FullOverviewScrollReport) async {
    var latencies: [Double] = []
    for index in indices where photos.indices.contains(index) && (photos[index].byteCount ?? 0) > 0 {
      let requested = uptime
      if let image = await pipeline.cachedPreview(for: photos[index], maxPixelSize: pixels) {
        do {
          try materialize(image)
          latencies.append(uptime - requested)
        } catch { result.cacheFirstPixelMisses += 1 }
      } else { result.cacheFirstPixelMisses += 1 }
    }
    result.cacheFirstPixels = FullOverviewLatencyReport(values: latencies)
  }

  private func actualUICacheReport(records: [CachedPreviewDiagnosticRecord], phase: String,
    seenIndices: [Int], photos: [ImageAsset]) -> FullOverviewUICachedPreviewReport {
    let nonemptyURLs = Set(photos.filter { ($0.byteCount ?? 0) > 0 }.map { $0.url.standardizedFileURL })
    let visibleURLs = Set(seenIndices.filter {
      photos.indices.contains($0) && (photos[$0].byteCount ?? 0) > 0
    }.map { photos[$0].url.standardizedFileURL })
    let phaseRecords = records.filter { $0.phase == phase }
    let eligible = phaseRecords.filter { nonemptyURLs.contains($0.assetURL.standardizedFileURL) }
    let completed = eligible.filter { !$0.cancelled }
    let hits = completed.filter(\.cacheHit)
    let misses = completed.filter { !$0.cacheHit }
    let cancelled = eligible.filter(\.cancelled)
    let hitURLs = Set(hits.map { $0.assetURL.standardizedFileURL })
    return FullOverviewUICachedPreviewReport(recordedRequests: phaseRecords.count,
      totalNonemptyAssets: nonemptyURLs.count, passEligibleVisibleAssets: visibleURLs.count,
      eligibleRecordedRequests: eligible.count,
      excludedEmptyOrOtherAssetRequests: phaseRecords.count - eligible.count,
      uncancelledHits: hits.count, uncancelledMisses: misses.count, cancelledRequests: cancelled.count,
      uniqueNonemptyAttemptedAssets: Set(eligible.map { $0.assetURL.standardizedFileURL }).count,
      uniqueNonemptyHitAssets: hitURLs.count,
      uniqueNonemptyMissAssets: Set(misses.map { $0.assetURL.standardizedFileURL }).count,
      uniqueNonemptyCancelledAssets: Set(cancelled.map { $0.assetURL.standardizedFileURL }).count,
      uniqueVisibleNonemptyHitAssets: hitURLs.intersection(visibleURLs).count,
      hitLatencies: FullOverviewLatencyReport(values: hits.map(\.elapsedSeconds)),
      completedRequestLatencies: FullOverviewLatencyReport(values: completed.map(\.elapsedSeconds)),
      ledgerMayHaveReachedLimit: records.count >= 4_096)
  }

  private func materialize(_ image: CGImage) throws {
    let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
      bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
  }

  private func logicalScrollPosition(scroll: NSScrollView, document: NSView) -> CGFloat {
    let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
    return document.isFlipped ? scroll.contentView.bounds.minY : maximum - scroll.contentView.bounds.minY
  }

  private func cacheReport(store: AppStore, photos: [ImageAsset], pixels: Int) async -> FullOverviewCacheReport {
    let memory = await store.thumbnailPipeline.cacheSnapshot()
    let disk = await store.thumbnailPipeline.diskCacheSnapshot()
    let coverage = await store.thumbnailPipeline.overviewCachedAssetCounts(assets: photos, maxPixelSize: pixels)
    let work = await store.loadingGovernor.stateSnapshot()
    return FullOverviewCacheReport(memoryEntries: memory.entryCount, memoryBytes: memory.byteCount,
      memoryLimit: memory.byteLimit, diskEntries: disk?.entryCount ?? 0, diskBytes: disk?.byteCount ?? 0,
      diskLimit: disk?.byteLimit ?? 0, diskPreviewBytes: disk?.previewBytes ?? 0,
      diskExactBytes: disk?.exactBytes ?? 0, diskHits: disk?.hits ?? 0, diskMisses: disk?.misses ?? 0,
      previewCoveredAssets: coverage.preview, exactCoveredAssets: coverage.exact,
      runningLoads: work.runningCount, queuedLoads: work.queuedCount)
  }

  private func writeProgress(output: URL, stage: String, started: Double, store: AppStore,
    photos: [ImageAsset], preloader: OverviewThumbnailPreloader, pixels: Int,
    sampler: FullOverviewResourceSampler) async throws {
    let progress = FullOverviewProgress(stage: stage, elapsedSeconds: uptime - started,
      totalAssets: photos.count, isPreparing: preloader.isPreparing,
      visibleCount: preloader.visibleIndices.count, appIsActive: NSApp.isActive,
      windowVisible: sampler.observedWindow?.isVisible ?? false,
      windowOcclusionVisible: sampler.observedWindow?.occlusionState.contains(.visible) ?? false,
      cache: await cacheReport(store: store, photos: photos, pixels: pixels),
      latestSample: sampler.samples.last)
    try writeJSON(progress, to: output.appendingPathComponent("progress.json"))
    log("RAW_OVERVIEW_FULL stage=\(stage) elapsedSeconds=\(Int(progress.elapsedSeconds)) previewCovered=\(progress.cache.previewCoveredAssets) exactCovered=\(progress.cache.exactCoveredAssets) visible=\(progress.visibleCount) appIsActive=\(progress.appIsActive)")
  }

  private func awaitSignal(_ url: URL, deadline: Double, name: String) async throws {
    try await wait(until: deadline, name: name) { FileManager.default.fileExists(atPath: url.path) }
  }

  private func waitForIdle(store: AppStore, deadline: Double, name: String) async throws {
    try await wait(until: deadline, name: name) {
      let work = await store.loadingGovernor.stateSnapshot()
      return work.runningCount == 0 && work.queuedCount == 0
    }
  }

  private func wait(until deadline: Double, name: String, condition: () async -> Bool) async throws {
    while uptime < deadline {
      try Task.checkCancellation()
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw FullOverviewDeadlineExceeded(phase: name)
  }

  private func makeWindow(host: NSView) -> NSWindow {
    let frame = NSRect(x: 40, y: 40, width: 1_500, height: 900)
    host.frame = NSRect(origin: .zero, size: frame.size)
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    return window
  }

  private func firstScrollView(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.lazy.compactMap { firstScrollView(in: $0) }.first
  }

  private func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
  }

  private func log(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
  }

  private var uptime: Double { ProcessInfo.processInfo.systemUptime }
}

private struct FullOverviewDeadlineExceeded: Error { let phase: String }

private struct FullOverviewReport: Encodable {
  var status = "started"
  var mode = "automatic_background_preparation"
  var failurePhase = ""
  var sources = FullOverviewSourceCounts(total: 0, nonempty: 0, nonemptyRAW: 0, empty: 0)
  var requestedPixelSize = 768
  var displayScale = 0.0
  var initialVisibleCount = 0
  var initialVisibleMinimum = -1
  var initialCache: FullOverviewCacheReport?
  var afterPreparation: FullOverviewCacheReport?
  var atEndCache: FullOverviewCacheReport?
  var afterScrolls: FullOverviewCacheReport?
  var phases: [FullOverviewPhaseReport] = []
  var scrolls: [FullOverviewScrollReport] = []
  var samples: [FullOverviewResourceSample] = []
  var sourceMetadataUnchanged = false
  var seedPreviewAssets = 0
  var newlyPreparedPreviewAssets = 0
  var preparationActivationSucceeded = false
  var nativeScrollActivationSucceeded = false
  var foregroundValidationComplete = false
  var visibleDemandPreparation: FullOverviewVisiblePreparationReport?
  var nativeScrollAppWasActive = false
  var totalWallSeconds = 0.0
  let sourcePixelsExported = false
  let sourcePathsExported = false
  let cpuScope = "test_process_getrusage_100_percent_equals_one_core"
  let systemCPUScope = "live_policy_filtered_whole_machine_fraction_not_app_GPU_usage"
  let firstPixelsScope = "separate_post_pass_cache_only_availability_for_unique_visible_assets_not_screen_paint_latency"
  let nativeScrollScope = "production_NSScrollView_60_percent_viewport_steps_100ms_minimum_spacing"
  let resourcePolicyScope = "production_live_monitor_no_pressure_CPU_focus_or_power_overrides"
  let eventLoopScope = "synchronous_XCTest_owned_NSApplication_run_real_AppKit_dispatch_without_async_finishLaunching_or_manual_event_pump"
  let testProcessID = getpid()
  var storageCacheScope = "fresh_app_disk_cache_OS_file_cache_and_QuickLook_cache_uncontrolled"
}

private struct FullOverviewVisiblePreparationReport: Encodable {
  let nativeViewports: Int
  let uniqueNonemptyVisibleAssets: Int
  let wallSeconds: Double
  let sourceDemandScope = "test_only_moves_production_viewports_no_explicit_pipeline_decode_prefetch_or_bitmap_probe_requests"
  let focusScope = "actual_active_fraction_and_foreground_bundle_counts_in_preparation_phase"
}

private struct FullOverviewSourceCounts: Encodable {
  let total: Int
  let nonempty: Int
  let nonemptyRAW: Int
  let empty: Int
}

private struct FullOverviewCacheReport: Encodable {
  let memoryEntries: Int
  let memoryBytes: Int
  let memoryLimit: Int
  let diskEntries: Int
  let diskBytes: Int
  let diskLimit: Int
  let diskPreviewBytes: Int
  let diskExactBytes: Int
  let diskHits: UInt64
  let diskMisses: UInt64
  let previewCoveredAssets: Int
  let exactCoveredAssets: Int
  let runningLoads: Int
  let queuedLoads: Int
}

private struct FullOverviewProgress: Encodable {
  let stage: String
  let elapsedSeconds: Double
  let totalAssets: Int
  let isPreparing: Bool
  let visibleCount: Int
  let appIsActive: Bool
  let windowVisible: Bool
  let windowOcclusionVisible: Bool
  let cache: FullOverviewCacheReport
  let latestSample: FullOverviewResourceSample?
}

private struct FullOverviewScrollReport: Encodable {
  let name: String
  var nativeScrollSteps = 0
  var uniqueVisibleCount = 0
  var maximumVisibleCount = 0
  var finalVisibleMinimum = -1
  var finalVisibleMaximum = -1
  var cacheFirstPixelMisses = 0
  var cacheFirstPixels = FullOverviewLatencyReport(values: [])
  var actualUICachedPreview: FullOverviewUICachedPreviewReport?
  var startPosition = 0.0
  var endPosition = 0.0
  var wallSeconds = 0.0
}

private struct FullOverviewUICachedPreviewReport: Encodable {
  let recordedRequests: Int
  let totalNonemptyAssets: Int
  let passEligibleVisibleAssets: Int
  let eligibleRecordedRequests: Int
  let excludedEmptyOrOtherAssetRequests: Int
  let uncancelledHits: Int
  let uncancelledMisses: Int
  let cancelledRequests: Int
  let uniqueNonemptyAttemptedAssets: Int
  let uniqueNonemptyHitAssets: Int
  let uniqueNonemptyMissAssets: Int
  let uniqueNonemptyCancelledAssets: Int
  let uniqueVisibleNonemptyHitAssets: Int
  let hitLatencies: FullOverviewLatencyReport
  let completedRequestLatencies: FullOverviewLatencyReport
  let ledgerMayHaveReachedLimit: Bool
  let measurementScope = "actual_ThumbnailImageView_cachedPreview_entry_to_CGImage_return_including_pipeline_queue_not_screen_paint"
  let coverageScope = "already_displayed_or_retained_cells_may_show_without_a_new_pipeline_call"
}

private struct FullOverviewLatencyReport: Encodable {
  let count: Int
  let p50Seconds: Double
  let p95Seconds: Double
  let maximumSeconds: Double

  init(values: [Double]) {
    let sorted = values.sorted()
    count = sorted.count
    p50Seconds = fullOverviewPercentile(sorted, fraction: 0.5)
    p95Seconds = fullOverviewPercentile(sorted, fraction: 0.95)
    maximumSeconds = sorted.last ?? 0
  }
}

private struct FullOverviewResourceSample: Encodable {
  let uptime: Double
  let intervalSeconds: Double
  let cpuPercentOneCore: Double
  let footprintBytes: UInt64
  let residentBytes: UInt64
  let lifetimePeakFootprintBytes: UInt64
  let lifetimePeakResidentBytes: Int64
  let appIsActive: Bool
  let windowVisible: Bool
  let windowOcclusionVisible: Bool
  let foregroundBundleID: String
  let foregroundProcessID: Int32
  let foregroundIsOtherProcess: Bool
  let systemCPUAvailable: Bool
  let systemCPUBusyFraction: Double
  let memoryPressure: Int
  let thermalLevel: Int
  let lowPowerMode: Bool
}

private struct FullOverviewPhaseReport: Encodable {
  let name: String
  let wallSeconds: Double
  let processCPUSeconds: Double
  let averageCPUPercentOneCore: Double
  let sampledCPUPercentOneCoreP95: Double
  let sampleCount: Int
  let inactiveSampleFraction: Double
  let otherForegroundSampleFraction: Double
  let foregroundBundleIDCounts: [String: Int]
  let footprintMinimumBytes: UInt64
  let footprintMaximumBytes: UInt64
  let footprintEndBytes: UInt64
  let heartbeatSamples: Int
  let heartbeatGapP95Seconds: Double
  let heartbeatGapMaximumSeconds: Double
  let warningMemorySamples: Int
  let criticalMemorySamples: Int
}

@MainActor
private final class FullOverviewResourceSampler {
  struct Phase {
    let name: String
    let started: Double
    let cpuStarted: Double
    let firstSample: Int
    let firstHeartbeat: Int
  }

  private(set) var samples: [FullOverviewResourceSample] = []
  weak var observedWindow: NSWindow?
  private var heartbeatGaps: [Double] = []
  private var task: Task<Void, Never>?
  private var heartbeat: Task<Void, Never>?
  private var monitor: ImageSystemResourceMonitor?
  private var resources = ImageResourceSnapshot.currentHardware
  private var previousUsage: (uptime: Double, cpuSeconds: Double)?

  func start() {
    monitor = ImageSystemResourceMonitor(isAppActive: NSApp.isActive) { [weak self] snapshot in
      Task { @MainActor in self?.resources = snapshot }
    }
    sample()
    task = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        self?.sample()
      }
    }
    heartbeat = Task { @MainActor [weak self] in
      var previous = ProcessInfo.processInfo.systemUptime
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
        let now = ProcessInfo.processInfo.systemUptime
        self?.heartbeatGaps.append(max(0, now - previous - 0.016))
        previous = now
      }
    }
  }

  func stop() {
    task?.cancel()
    heartbeat?.cancel()
    task = nil
    heartbeat = nil
    monitor = nil
  }

  func beginPhase(_ name: String) -> Phase {
    sample()
    return Phase(name: name, started: ProcessInfo.processInfo.systemUptime,
      cpuStarted: processUsage().cpuSeconds, firstSample: samples.count,
      firstHeartbeat: heartbeatGaps.count)
  }

  func endPhase(_ phase: Phase) -> FullOverviewPhaseReport {
    sample()
    let wall = max(0.000_001, ProcessInfo.processInfo.systemUptime - phase.started)
    let cpu = max(0, processUsage().cpuSeconds - phase.cpuStarted)
    let observations = Array(samples.dropFirst(phase.firstSample))
    let gaps = Array(heartbeatGaps.dropFirst(phase.firstHeartbeat)).sorted()
    let cpuValues = observations.filter { $0.intervalSeconds >= 0.5 }.map(\.cpuPercentOneCore).sorted()
    var bundles: [String: Int] = [:]
    for observation in observations { bundles[observation.foregroundBundleID, default: 0] += 1 }
    let denominator = Double(max(1, observations.count))
    return FullOverviewPhaseReport(name: phase.name, wallSeconds: wall, processCPUSeconds: cpu,
      averageCPUPercentOneCore: cpu / wall * 100,
      sampledCPUPercentOneCoreP95: fullOverviewPercentile(cpuValues, fraction: 0.95),
      sampleCount: observations.count,
      inactiveSampleFraction: Double(observations.filter { !$0.appIsActive }.count) / denominator,
      otherForegroundSampleFraction: Double(observations.filter(\.foregroundIsOtherProcess).count) / denominator,
      foregroundBundleIDCounts: bundles,
      footprintMinimumBytes: observations.map(\.footprintBytes).min() ?? 0,
      footprintMaximumBytes: observations.map(\.footprintBytes).max() ?? 0,
      footprintEndBytes: observations.last?.footprintBytes ?? 0,
      heartbeatSamples: gaps.count, heartbeatGapP95Seconds: fullOverviewPercentile(gaps, fraction: 0.95),
      heartbeatGapMaximumSeconds: gaps.last ?? 0,
      warningMemorySamples: observations.filter { $0.memoryPressure == ImageResourcePressure.warning.rawValue }.count,
      criticalMemorySamples: observations.filter { $0.memoryPressure == ImageResourcePressure.critical.rawValue }.count)
  }

  private func sample() {
    let now = ProcessInfo.processInfo.systemUptime
    let process = processUsage()
    let footprint = footprintUsage()
    let cpu: Double
    let interval: Double
    if let previousUsage, now > previousUsage.uptime + 0.000_001 {
      interval = now - previousUsage.uptime
      cpu = max(0, process.cpuSeconds - previousUsage.cpuSeconds) / interval * 100
    } else {
      cpu = 0
      interval = 0
    }
    previousUsage = (now, process.cpuSeconds)
    let frontmost = NSWorkspace.shared.frontmostApplication
    samples.append(FullOverviewResourceSample(uptime: now, intervalSeconds: interval, cpuPercentOneCore: cpu,
      footprintBytes: footprint.current, residentBytes: footprint.resident,
      lifetimePeakFootprintBytes: footprint.peak, lifetimePeakResidentBytes: process.peakResidentBytes,
      appIsActive: NSApp.isActive, windowVisible: observedWindow?.isVisible ?? false,
      windowOcclusionVisible: observedWindow?.occlusionState.contains(.visible) ?? false,
      foregroundBundleID: frontmost?.bundleIdentifier ?? "unavailable",
      foregroundProcessID: frontmost?.processIdentifier ?? -1,
      foregroundIsOtherProcess: frontmost.map { $0.processIdentifier != getpid() } ?? false,
      systemCPUAvailable: resources.cpuBusyFraction != nil,
      systemCPUBusyFraction: resources.cpuBusyFraction ?? 0,
      memoryPressure: resources.memoryPressure.rawValue, thermalLevel: resources.thermal.rawValue,
      lowPowerMode: resources.lowPowerMode))
  }

  private func processUsage() -> (cpuSeconds: Double, peakResidentBytes: Int64) {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return (0, 0) }
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    return (user + system, Int64(usage.ru_maxrss))
  }

  private func footprintUsage() -> (current: UInt64, resident: UInt64, peak: UInt64) {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
      }
    }
    guard result == 0 else { return (0, 0, 0) }
    return (usage.ri_phys_footprint, usage.ri_resident_size, usage.ri_lifetime_max_phys_footprint)
  }
}

private func fullOverviewPercentile(_ sorted: [Double], fraction: Double) -> Double {
  guard !sorted.isEmpty else { return 0 }
  return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))]
}
