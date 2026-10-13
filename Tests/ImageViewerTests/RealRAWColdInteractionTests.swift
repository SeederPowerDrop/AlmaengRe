import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

/// Explicit read-only decoder workload, not a GUI frame-rate measurement. The
/// Each phase starts with new application caches. Explicit test-only preparation
/// can additionally invalidate the selected files' OS pages and verify zero
/// residency before the phase. Image decoder and Quick Look caches are separate
/// and are never represented as cleared.
@Suite("실제 RAW 새 캐시와 빠른 탐색 부하", .serialized)
struct RealRAWColdInteractionTests {
  private enum Failure: Error { case scan, tooFewFiles, drainTimeout }
  private enum Status: String, Sendable { case ready, cancelled, failed }
  private struct Record: Sendable {
    let index: Int
    let status: Status
    let seconds: TimeInterval
    let finishedAt: TimeInterval
    let valid: Bool
    let longestEdge: Int
  }
  private struct Context: Sendable {
    let governor: ImageResourceGovernor
    let thumbnails: ThumbnailPipeline
    let monitor: ImageSystemResourceMonitor

    init() {
      let governor = ImageResourceGovernor(mode: .comfortable)
      self.governor = governor
      thumbnails = ThumbnailPipeline(governor: governor)
      monitor = ImageSystemResourceMonitor(isAppActive: true) { snapshot in
        Task { await governor.update(snapshot) }
      }
    }
  }
  private struct Window {
    let started: TimeInterval
    let tasks: [Task<Record, Never>]
  }
  private struct IOUsage {
    let diskBytesRead: UInt64
    let footprintBytes: UInt64
    let lifetimePeakFootprintBytes: UInt64
  }

  @Test("전체 RAW 첫 읽기와 화면 건너뛰기·크기 변경 취소 후 최종 해상도를 검사한다",
    .enabled(if: ProcessInfo.processInfo.environment["RAW_COLD_INTERACTIONS"] == "1"),
    .timeLimit(.minutes(15)))
  func coldCacheAndInteractionWorkload() async throws {
    let environment = ProcessInfo.processInfo.environment
    let directory = URL(fileURLWithPath: try #require(environment["IMAGEVIEWER_RAW_DIRECTORY"]))
    let listingStarted = ProcessInfo.processInfo.systemUptime
    let listingIO = Self.ioUsage()
    let assets: [ImageAsset]
    var emptyCount = 0, candidateCount = 0
    do {
      let urls = try FileManager.default.contentsOfDirectory(at: directory,
        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles])
        .filter { ImageFormatRegistry.cameraRAWExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
      candidateCount = urls.count
      assets = try urls.compactMap { url in
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true else { return nil }
        guard let size = values.fileSize, size > 0 else { emptyCount += 1; return nil }
        return ImageAsset(url: url, byteCount: Int64(size), modificationDate: values.contentModificationDate)
      }
    } catch { throw Failure.scan }
    // At least six distinct 36-file windows, rather than repeating a tiny sample.
    guard assets.count >= 216 else { throw Failure.tooFewFiles }
    Self.log("listing", fields: ["candidates": candidateCount, "nonempty": assets.count,
      "skippedEmpty": emptyCount, "seconds": Self.now - listingStarted], ioStart: listingIO)

    let bufferPurged = environment["IMAGEVIEWER_OS_BUFFER_PURGED"] == "1"
    try await firstSweep(assets, diskBufferPurged: bufferPurged)
    try await fastScroll(assets)
    try await resizeBursts(assets)
  }

  private func firstSweep(_ assets: [ImageAsset], diskBufferPurged: Bool) async throws {
    let preparation = try RAWFileCachePreparation.prepare(urls: assets.map(\.url), phase: "full_sweep")
    let context = Context()
    defer { withExtendedLifetime(context.monitor) {} }
    await context.thumbnails.purgeCache()
    #expect(await context.thumbnails.cacheSnapshot().entryCount == 0)
    let started = Self.now
    let ioStart = Self.ioUsage()
    Self.log("full_sweep_start", fields: ["count": assets.count, "pixelSize": 512,
      "appCacheCold": true, "diskBufferPurged": diskBufferPurged,
      "osFilePagesVerifiedZeroAtPhaseStart": preparation.osFilePagesVerifiedZero,
      "diskCacheCold": false, "quicklookCacheCleared": false, "maxOutstandingRequests": 4])
    var records: [Record] = []
    var firstScreen: [Record] = []
    try await withThrowingTaskGroup(of: Record.self) { group in
      var next = 0
      for index in 0..<min(4, assets.count) {
        let asset = assets[index]
        group.addTask { await Self.decode(asset, index: index, pixelSize: 512, context: context) }
        next += 1
      }
      while let result = try await group.next() {
        try Task.checkCancellation()
        records.append(result)
        if result.index < 36 {
          firstScreen.append(result)
          if firstScreen.count == 36 {
            Self.report("first_36_within_full_sweep", records: firstScreen, started: started,
              fields: ["appCacheCold": true, "diskBufferPurgedBeforeSweep": diskBufferPurged,
                "osFilePagesVerifiedZeroAtPhaseStart": preparation.osFilePagesVerifiedZero])
          }
        }
        let snapshot = await context.thumbnails.cacheSnapshot()
        #expect(snapshot.byteCount <= snapshot.byteLimit)
        if records.count.isMultiple(of: 100) || records.count == assets.count {
          Self.log("full_sweep_progress", fields: ["completed": records.count, "total": assets.count,
            "seconds": Self.now - started, "cacheEntries": snapshot.entryCount,
            "cacheBytes": snapshot.byteCount, "cacheLimit": snapshot.byteLimit], ioStart: ioStart)
        }
        if next < assets.count {
          let index = next, asset = assets[index]
          group.addTask { await Self.decode(asset, index: index, pixelSize: 512, context: context) }
          next += 1
        }
      }
    }
    Self.report("full_sweep", records: records, started: started, ioStart: ioStart)
    #expect(records.count == assets.count)
    #expect(records.allSatisfy { $0.status == .ready && $0.valid })
    try await finish(context, phase: "full_sweep")
  }

  private func fastScroll(_ assets: [ImageAsset]) async throws {
    let size = 36, windowCount = 6
    let step = (assets.count - size) / (windowCount - 1)
    let selected = (0..<windowCount).flatMap { number in
      Array(assets[(number * step)..<(number * step + size)])
    }
    let preparation = try RAWFileCachePreparation.prepare(urls: selected.map(\.url), phase: "scroll")
    let context = Context()
    defer { withExtendedLifetime(context.monitor) {} }
    await context.thumbnails.purgeCache()
    #expect(await context.thumbnails.cacheSnapshot().entryCount == 0)
    let started = Self.now, ioStart = Self.ioUsage()
    Self.log("scroll_start", fields: ["windows": windowCount, "filesPerWindow": size,
      "distinctFiles": windowCount * size, "intervalMilliseconds": 80,
      "appCacheCold": true, "diskBufferPurged": false, "diskCacheCold": false,
      "osFilePagesVerifiedZeroAtPhaseStart": preparation.osFilePagesVerifiedZero,
      "quicklookCacheCleared": false])
    var windows: [Window] = []
    defer { for window in windows { window.tasks.forEach { $0.cancel() } } }
    for number in 0..<windowCount {
      if let previous = windows.last { previous.tasks.forEach { $0.cancel() } }
      let firstIndex = number * step
      let windowStarted = Self.now
      let tasks = (firstIndex..<(firstIndex + size)).map { index in
        let asset = assets[index]
        return Task { await Self.decode(asset, index: index, pixelSize: 512, context: context) }
      }
      windows.append(Window(started: windowStarted, tasks: tasks))
      if number + 1 < windowCount { try await Task.sleep(for: .milliseconds(80)) }
    }
    var all: [Record] = []
    for (number, window) in windows.enumerated() {
      var records: [Record] = []
      for task in window.tasks { records.append(await task.value) }
      Self.report("scroll_window", records: records, started: window.started,
        fields: ["window": number + 1, "finalWindow": number + 1 == windows.count])
      #expect(records.allSatisfy { $0.status != .failed && ($0.status != .ready || $0.valid) })
      if number + 1 == windows.count { #expect(records.allSatisfy { $0.status == .ready }) }
      all += records
    }
    Self.report("scroll", records: all, started: started, ioStart: ioStart)
    try await finish(context, phase: "scroll")
  }

  private func resizeBursts(_ assets: [ImageAsset]) async throws {
    let selected = Array(assets.dropFirst(assets.count / 2).prefix(24))
    let preparation = try RAWFileCachePreparation.prepare(urls: selected.map(\.url), phase: "resize")
    let context = Context()
    defer { withExtendedLifetime(context.monitor) {} }
    await context.thumbnails.purgeCache()
    #expect(await context.thumbnails.cacheSnapshot().entryCount == 0)
    let started = Self.now, ioStart = Self.ioUsage()
    let sizes = [512, 768, 1_280, 1_920, 2_048]
    Self.log("resize_start", fields: ["files": selected.count, "requestedPixelSizes": sizes,
      "intervalMilliseconds": 40, "appCacheCold": true, "diskBufferPurged": false,
      "diskCacheCold": false, "quicklookCacheCleared": false,
      "osFilePagesVerifiedZeroAtPhaseStart": preparation.osFilePagesVerifiedZero,
      "scope": "pipeline_cancellation_stress_not_UI_deferred_drag"])
    var windows: [Window] = []
    defer { for window in windows { window.tasks.forEach { $0.cancel() } } }
    for (step, pixels) in sizes.enumerated() {
      if let previous = windows.last { previous.tasks.forEach { $0.cancel() } }
      let windowStarted = Self.now
      let final = step + 1 == sizes.count
      let tasks = selected.enumerated().map { index, asset in
        Task { await Self.decode(asset, index: index, pixelSize: pixels, context: context) }
      }
      windows.append(Window(started: windowStarted, tasks: tasks))
      if !final { try await Task.sleep(for: .milliseconds(40)) }
    }
    var all: [Record] = []
    var finalRecords: [Record] = []
    for (step, window) in windows.enumerated() {
      var records: [Record] = []
      for task in window.tasks { records.append(await task.value) }
      let final = step + 1 == windows.count
      Self.report("resize_window", records: records, started: window.started,
        fields: ["pixelSize": sizes[step], "finalResolution": final])
      #expect(records.allSatisfy { $0.status != .failed && ($0.status != .ready || $0.valid) })
      if final {
        #expect(records.allSatisfy { $0.status == .ready && $0.valid })
        finalRecords = records
      }
      all += records
    }
    Self.report("resize", records: all, started: started, ioStart: ioStart)
    // Read source dimensions only AFTER measured decoding. Pre-reading Image I/O
    // properties would warm the exact file headers whose residency was cleared.
    for (asset, record) in zip(selected, finalRecords) {
      let source = try #require(CGImageSourceCreateWithURL(asset.url as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary))
      let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
      let required = min(2_048, max(width, height))
      #expect(required > 0 && record.longestEdge >= required)
    }
    #expect(finalRecords.count == selected.count)
    try await finish(context, phase: "resize")
  }

  private static func decode(_ asset: ImageAsset, index: Int, pixelSize: Int, context: Context) async -> Record {
    let started = now
    do {
      let image = try await context.thumbnails.thumbnail(for: asset, maxPixelSize: pixelSize)
      try Task.checkCancellation()
      let valid = image.width > 0 && image.height > 0 && image.bitsPerComponent == 8
        && max(image.width, image.height) <= pixelSize
      return Record(index: index, status: .ready, seconds: now - started, finishedAt: now,
        valid: valid, longestEdge: max(image.width, image.height))
    } catch is CancellationError {
      return Record(index: index, status: .cancelled, seconds: now - started, finishedAt: now,
        valid: true, longestEdge: 0)
    } catch {
      return Record(index: index, status: .failed, seconds: now - started, finishedAt: now,
        valid: false, longestEdge: 0)
    }
  }

  private func finish(_ context: Context, phase: String) async throws {
    let drainStarted = Self.now
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
      let state = await context.governor.stateSnapshot()
      if state.runningCount == 0 && state.queuedCount == 0 && state.waiterCount == 0 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let state = await context.governor.stateSnapshot()
    Self.log("drained", fields: ["workload": phase, "seconds": Self.now - drainStarted,
      "running": state.runningCount, "queued": state.queuedCount, "waiters": state.waiterCount])
    guard state.runningCount == 0 && state.queuedCount == 0 && state.waiterCount == 0 else {
      throw Failure.drainTimeout
    }
    let cache = await context.thumbnails.cacheSnapshot()
    #expect(cache.byteCount <= cache.byteLimit)
    Self.log("cache", fields: ["workload": phase, "entries": cache.entryCount,
      "bytes": cache.byteCount, "byteLimit": cache.byteLimit])
    await context.thumbnails.purgeCache()
    #expect(await context.thumbnails.cacheSnapshot().byteCount == 0)
  }

  private static func report(_ phase: String, records: [Record], started: TimeInterval,
    fields: [String: Any] = [:], ioStart: IOUsage? = nil
  ) {
    let ready = records.filter { $0.status == .ready }
    let durations = ready.map(\.seconds).sorted()
    var result = fields
    result["requested"] = records.count
    result["ready"] = ready.count
    result["cancelled"] = records.filter { $0.status == .cancelled }.count
    result["failed"] = records.filter { $0.status == .failed }.count
    result["invalid"] = ready.filter { !$0.valid }.count
    if let first = ready.map(\.finishedAt).min() {
      result["firstReadySeconds"] = first - started
    } else { result["firstReadySeconds"] = NSNull() }
    if ready.count == records.count, let last = ready.map(\.finishedAt).max() {
      result["completeSeconds"] = last - started
    } else { result["completeSeconds"] = NSNull() }
    result["settledSeconds"] = records.map(\.finishedAt).max().map { $0 - started } ?? 0
    result["p50Seconds"] = percentile(durations, fraction: 0.5)
    result["p95Seconds"] = percentile(durations, fraction: 0.95)
    result["maxSeconds"] = durations.last ?? 0
    result["perFileIncludesQueueWait"] = true
    log(phase, fields: result, ioStart: ioStart)
  }

  private static func percentile(_ sorted: [Double], fraction: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))]
  }

  private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

  private static func ioUsage() -> IOUsage? {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
      }
    }
    guard result == 0 else { return nil }
    return IOUsage(diskBytesRead: usage.ri_diskio_bytesread,
      footprintBytes: usage.ri_phys_footprint,
      lifetimePeakFootprintBytes: usage.ri_lifetime_max_phys_footprint)
  }

  private static func log(_ phase: String, fields: [String: Any], ioStart: IOUsage? = nil) {
    var data = fields
    data["phase"] = phase
    data["readOnly"] = true
    if let current = ioUsage() {
      data["physicalFootprintBytes"] = current.footprintBytes
      data["processLifetimePeakFootprintBytes"] = current.lifetimePeakFootprintBytes
      if let before = ioStart, current.diskBytesRead >= before.diskBytesRead {
        data["processDiskBytesRead"] = current.diskBytesRead - before.diskBytesRead
        data["diskCounterScope"] = "calling_process_only_excludes_QuickLook_services"
      }
    }
    guard let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) else { return }
    var line = Data("RAW_COLD_INTERACTION ".utf8)
    line.append(encoded)
    line.append(0x0a)
    FileHandle.standardOutput.write(line)
  }
}
