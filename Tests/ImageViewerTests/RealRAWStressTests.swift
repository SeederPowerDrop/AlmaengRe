import Combine
import Darwin
import Foundation
import Testing

@testable import ImageViewer

/// Opt-in, read-only integration test against an existing folder of distinct DNGs:
/// IMAGEVIEWER_RAW_DIRECTORY=/path/to/photos swift test --filter RealRAWStressTests
/// IMAGEVIEWER_RAW_LIMIT limits nonempty inputs for a quick smoke run. Nothing is
/// written to the corpus; logs contain counts, dimensions and indices, never paths
/// or private descriptive/GPS metadata.
/// Timing includes the current filesystem/Quick Look cache state, not a cold disk.
@Suite("실제 DNG 읽기 전용 부하 시험", .serialized)
struct RealRAWStressTests {
  private enum Failure: Error {
    case scan, invalidLimit, invalidResult, deadline(String)
  }

  private struct ItemResult: Sendable {
    let index: Int
    let valid: Bool
    let bitmapBytes: Int
  }

  private actor MetadataSummary {
    private var dimensions: [String: Int] = [:]
    private var bitDepths: [String: Int] = [:]

    func add(_ metadata: ImageMetadata) {
      dimensions["\(metadata.pixelWidth)x\(metadata.pixelHeight)", default: 0] += 1
      bitDepths[metadata.bitDepth.map(String.init) ?? "unknown", default: 0] += 1
    }

    func snapshot() -> [String: [String: Int]] {
      ["resolutionCounts": dimensions, "bitDepthCounts": bitDepths]
    }
  }

  @MainActor
  private final class Observations {
    var firstVisibleAt: TimeInterval?
    var shownSlots: Set<Int> = []
    var displayed: [Set<URL>]
    var phase = 0
    var displayedByPhase: [Int: [Set<URL>]] = [:]
    var emptyAfterFirst = 0
    var errors = 0
    var maximumRunning = 0
    var maximumQueued = 0
    var maximumRSS: UInt64 = 0

    init(slots: Int) { displayed = Array(repeating: [], count: slots) }

    func record(_ presentation: ViewerFrameLoader.Presentation?, slot: Int) {
      guard let presentation else {
        if shownSlots.contains(slot) { emptyAfterFirst += 1 }
        return
      }
      if firstVisibleAt == nil { firstVisibleAt = ProcessInfo.processInfo.systemUptime }
      shownSlots.insert(slot)
      displayed[slot].insert(presentation.request.asset.url)
      if phase > 0 {
        var samples = displayedByPhase[phase] ?? Array(repeating: [], count: displayed.count)
        samples[slot].insert(presentation.request.asset.url)
        displayedByPhase[phase] = samples
      }
    }

    func sample(_ state: ImageWorkSchedulerState) {
      maximumRunning = max(maximumRunning, state.runningCount)
      maximumQueued = max(maximumQueued, state.queuedCount)
      maximumRSS = max(maximumRSS, RealRAWStressTests.residentBytes())
    }
  }

  @Test("폴더 전체·썸네일·정밀 표시·빠른 탐색·취소 복구",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_DIRECTORY"] != nil),
    .timeLimit(.minutes(30)))
  @MainActor
  func readOnlyRealCorpus() async throws {
    let environment = ProcessInfo.processInfo.environment
    let directory = URL(fileURLWithPath: try #require(environment["IMAGEVIEWER_RAW_DIRECTORY"]),
      isDirectory: true)
    let totalStart = ProcessInfo.processInfo.systemUptime
    let library = ImageLibrary()
    let opened: OpenedImageLibrary
    do { opened = try await library.open(urls: [directory]) }
    catch { throw Failure.scan } // Native errors may include a private filename.
    let dngs = opened.assets.filter { $0.fileExtension == "dng" }
    let empty = dngs.filter { $0.byteCount == 0 }
    let nonempty = dngs.filter { $0.byteCount != 0 }
    let limit: Int
    if let value = environment["IMAGEVIEWER_RAW_LIMIT"] {
      guard let parsed = Int(value), parsed > 0 else { throw Failure.invalidLimit }
      limit = parsed
    } else { limit = nonempty.count }
    let assets = Array(nonempty.prefix(limit))
    #expect(!assets.isEmpty)
    guard !assets.isEmpty else { return }
    Self.log("scan", started: totalStart, count: dngs.count, extra: [
      "nonemptyCount": nonempty.count, "zeroByteCount": empty.count,
      "testedNonemptyCount": assets.count, "limited": assets.count < nonempty.count,
      "corpusBytes": dngs.reduce(Int64(0)) { $0 + ($1.byteCount ?? 0) },
      "indexBasis": "nonempty library order", "readOnly": true,
    ])

    let governor = ImageResourceGovernor(mode: .comfortable)
    let monitor = ImageSystemResourceMonitor(isAppActive: true) { snapshot in
      Task { await governor.update(snapshot) }
    }
    defer { withExtendedLifetime((opened.access, monitor)) {} }
    let pipeline = ImagePipeline(governor: governor)
    let thumbnails = ThumbnailPipeline(governor: governor)
    Self.log("configuration", started: totalStart, count: assets.count, extra: [
      "mode": "comfortable", "systemMonitor": true,
      "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
      "processorCount": ProcessInfo.processInfo.activeProcessorCount,
    ])

    let metadataSummary = MetadataSummary()
    let metadataStarted = ProcessInfo.processInfo.systemUptime
    _ = try await Self.measureWindows("metadata", assets: assets, window: 20) { asset in
      let metadata = try await pipeline.metadata(for: asset.url)
      guard metadata.pixelWidth > 0, metadata.pixelHeight > 0 else { throw Failure.invalidResult }
      await metadataSummary.add(metadata)
      return 0
    }
    let metadataDistributions = await metadataSummary.snapshot()
    Self.log("metadata_distribution", started: metadataStarted, count: assets.count,
      extra: ["resolutionCounts": metadataDistributions["resolutionCounts"] ?? [:],
        "bitDepthCounts": metadataDistributions["bitDepthCounts"] ?? [:]])

    for phase in ["thumbnails_first", "thumbnails_repeat"] {
      _ = try await Self.measureWindows(phase, assets: assets, window: 20) { asset in
        let image = try await thumbnails.thumbnail(for: asset, maxPixelSize: 256)
        guard image.width > 0, image.height > 0,
          max(image.width, image.height) <= 256 else { throw Failure.invalidResult }
        return image.bytesPerRow * image.height
      }
    }

    let page = Array(assets.prefix(10))
    for phase in ["page10_first", "page10_cached"] {
      _ = try await Self.measureWindows(phase, assets: page, window: 10) { asset in
        try await Self.render(asset, pixels: 1_280, pipeline: pipeline)
      }
    }
    await pipeline.purgeCaches()
    _ = try await Self.measureWindows("refined_all", assets: assets, window: 10) { asset in
      try await Self.render(asset, pixels: 1_280, pipeline: pipeline)
    }

    // The full-size path is intentionally serial and never retains or exports pixels.
    await pipeline.purgeCaches()
    let largest = Array(assets.sorted { ($0.byteCount ?? 0) > ($1.byteCount ?? 0) }.prefix(3))
    _ = try await Self.measureWindows("full_resolution_largest", assets: largest, window: 1) { asset in
      try await Self.render(asset, pixels: nil, pipeline: pipeline)
    }
    await pipeline.purgeCaches()

    let negativeStart = ProcessInfo.processInfo.systemUptime
    var rejectedEmpty = 0
    for asset in empty {
      do {
        // Only a native pipeline error counts as rejection, never our result validator.
        _ = try await pipeline.renderFrame(url: asset.url, maxPixelSize: 1_280,
          adjustments: .identity, prefersHDR: true)
      }
      catch is CancellationError { throw CancellationError() }
      catch { rejectedEmpty += 1 }
    }
    #expect(rejectedEmpty == empty.count)
    Self.log("zero_byte_negative_cases", started: negativeStart, count: empty.count,
      extra: ["rejectedCount": rejectedEmpty])
    _ = try await Self.measureWindows("recovery_after_empty", assets: Array(assets.prefix(1)),
      window: 1) { asset in try await Self.render(asset, pixels: 1_280, pipeline: pipeline) }

    try await cancellationRecovery(assets: assets, pipeline: pipeline,
      thumbnails: thumbnails, governor: governor)
    for slots in [1, 2, 10] {
      await pipeline.purgeCaches()
      await thumbnails.purgeCache()
      try await rapidBrowsing(assets: assets, slots: slots, pipeline: pipeline,
        thumbnails: thumbnails, governor: governor)
    }
    await pipeline.purgeCaches()
    await thumbnails.purgeCache()
    try await Self.drain(governor, phase: "final_drain")
    Self.log("complete", started: totalStart, count: assets.count,
      extra: ["zeroByteCount": empty.count, "scannedDNGCount": dngs.count])
  }

  private static func render(_ asset: ImageAsset, pixels: Int?, pipeline: ImagePipeline)
    async throws -> Int
  {
    let frame = try await pipeline.renderFrame(url: asset.url, maxPixelSize: pixels,
      adjustments: .identity, prefersHDR: true)
    guard hasExpectedDimensions(frame, pixels: pixels) else { throw Failure.invalidResult }
    return frame.image.bytesPerRow * frame.image.height
  }

  private static func hasExpectedDimensions(_ frame: RenderedFrame, pixels: Int?) -> Bool {
    guard frame.image.width > 0, frame.image.height > 0,
      let sourceSize = frame.sourcePixelSize else { return false }
    // sourcePixelSize already includes EXIF orientation. Check both axes so an
    // undersized preview or an incorrect aspect ratio cannot pass as refinement.
    let width = Double(sourceSize.width), height = Double(sourceSize.height)
    guard width.isFinite, height.isFinite, width > 0, height > 0 else { return false }
    let sourceLongEdge = max(width, height)
    let scale = pixels.map { min(1, Double($0) / sourceLongEdge) } ?? 1
    let expectedLongEdge = pixels.map { min(Double($0), sourceLongEdge) } ?? sourceLongEdge
    return abs(Double(max(frame.image.width, frame.image.height)) - expectedLongEdge) <= 1
      && abs(Double(frame.image.width) - width * scale) <= 1
      && abs(Double(frame.image.height) - height * scale) <= 1
  }

  /// Bounded windows mirror visible grid/page requests; failures do not skip later files.
  private static func measureWindows(_ phase: String, assets: [ImageAsset], window: Int,
    operation: @escaping @Sendable (ImageAsset) async throws -> Int
  ) async throws -> [ItemResult] {
    let started = ProcessInfo.processInfo.systemUptime
    let results = try await withDeadline(phase, seconds: 600) {
      var results: [ItemResult] = []
      for offset in stride(from: 0, to: assets.count, by: window) {
        try Task.checkCancellation()
        let batch = await withTaskGroup(of: ItemResult.self) { group in
          for index in offset..<min(offset + window, assets.count) {
            group.addTask {
              do {
                return ItemResult(index: index, valid: true,
                  bitmapBytes: try await operation(assets[index]))
              } catch {
                return ItemResult(index: index, valid: false, bitmapBytes: 0)
              }
            }
          }
          var batch: [ItemResult] = []
          for await item in group { batch.append(item) }
          return batch
        }
        results.append(contentsOf: batch)
        if results.count.isMultiple(of: 100), results.count < assets.count {
          log(phase + "_progress", started: started, count: results.count,
            extra: ["total": assets.count])
        }
      }
      return results
    }
    let failures = results.filter { !$0.valid }.map(\.index).sorted()
    log(phase, started: started, count: assets.count, extra: [
      "successCount": results.count - failures.count, "failedIndices": failures,
      "bitmapBytesProcessed": results.reduce(0) { $0 + $1.bitmapBytes }, "window": window,
    ])
    #expect(failures.isEmpty)
    return results
  }

  @MainActor
  private func cancellationRecovery(assets: [ImageAsset], pipeline: ImagePipeline,
    thumbnails: ThumbnailPipeline, governor: ImageResourceGovernor
  ) async throws {
    let started = ProcessInfo.processInfo.systemUptime
    let requests = Array(assets.prefix(100))
    let cancelled = requests.enumerated().map { index, asset in
      Task {
        if index.isMultiple(of: 2) {
          _ = try await pipeline.renderFrame(url: asset.url, maxPixelSize: 1_536,
            adjustments: .identity, prefersHDR: true)
        } else {
          _ = try await thumbnails.thumbnail(for: asset, maxPixelSize: 768)
        }
      }
    }
    try await Task.sleep(for: .milliseconds(10))
    cancelled.forEach { $0.cancel() }
    for task in cancelled { _ = try? await task.value }
    try await Self.drain(governor, phase: "cancel_drain")
    _ = try await Self.measureWindows("cancellation_recovery", assets: Array(assets.suffix(10)),
      window: 10) { asset in try await Self.render(asset, pixels: 1_280, pipeline: pipeline) }
    Self.log("cancelled_requests", started: started, count: requests.count)
  }

  @MainActor
  private func rapidBrowsing(assets: [ImageAsset], slots: Int, pipeline: ImagePipeline,
    thumbnails: ThumbnailPipeline, governor: ImageResourceGovernor
  ) async throws {
    let started = ProcessInfo.processInfo.systemUptime
    let observations = Observations(slots: slots)
    let loaders = (0..<slots).map { _ in ViewerFrameLoader() }
    var subscriptions: Set<AnyCancellable> = []
    for (slot, loader) in loaders.enumerated() {
      loader.$presentation.sink { observations.record($0, slot: slot) }.store(in: &subscriptions)
      loader.$errorMessage.compactMap { $0 }.sink { _ in observations.errors += 1 }
        .store(in: &subscriptions)
    }
    let sampler = Task { @MainActor in
      while !Task.isCancelled {
        observations.sample(await governor.stateSnapshot())
        do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
      }
    }
    defer {
      sampler.cancel()
      subscriptions.removeAll()
      loaders.forEach { $0.stop() }
    }
    let preview: ViewerFrameLoader.Preview = { request in
      if request.adjustments.isIdentity {
        do {
          let image = try await thumbnails.browsingThumbnail(for: request.asset, maxPixelSize: 512)
          return RenderedFrame(image: image, frameIndex: 0, frameCount: 1, duration: nil)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          // Match ViewerImageTile's fallback when the system preview fails.
        }
      }
      return try await pipeline.renderFrame(url: request.asset.url, maxPixelSize: 512,
        adjustments: request.adjustments, prefersHDR: false, priority: .interactivePreview)
    }
    let render: ViewerFrameLoader.Render = { request, index in
      try await pipeline.renderFrame(url: request.asset.url, frameIndex: index,
        maxPixelSize: request.maxPixelSize, adjustments: request.adjustments,
        prefersHDR: request.prefersHDR)
    }
    func request(_ step: Int, _ slot: Int) -> ViewerFrameRequest {
      let position = step <= 100 ? step : 200 - step
      return ViewerFrameRequest(asset: assets[(position + slot * 17) % assets.count], maxPixelSize: 1_280,
        adjustments: .identity, prefersHDR: true,
        loadingPolicy: .forVisibleItemCount(slots))
    }
    // First establish a visible frame in each tile, so continuity checks cannot pass
    // vacuously when a slow RAW preview completes only after input stops.
    for (slot, loader) in loaders.enumerated() {
      loader.load(request(0, slot), preview: preview, render: render)
    }
    try await waitUntil(phase: "rapid_initial", seconds: 120) {
      loaders.allSatisfy { $0.presentation != nil }
    }
    let inputStarted = ProcessInfo.processInfo.systemUptime
    for step in 1...200 {
      observations.phase = step <= 100 ? 1 : 2
      for (slot, loader) in loaders.enumerated() {
        loader.load(request(step, slot), preview: preview, render: render)
      }
      try await Task.sleep(for: .milliseconds(12))
    }
    let inputStopped = ProcessInfo.processInfo.systemUptime
    observations.phase = 0
    try await waitUntil(phase: "rapid_final", seconds: 180) {
      loaders.enumerated().allSatisfy { slot, loader in
        guard let shown = loader.presentation else { return false }
        return shown.request == request(200, slot)
          && Self.hasExpectedDimensions(shown.frame, pixels: 1_280)
      }
    }
    let refined = ProcessInfo.processInfo.systemUptime
    #expect(observations.errors == 0)
    #expect(observations.emptyAfterFirst == 0)
    #expect(observations.maximumRunning <= 2)
    #expect(observations.maximumRunning > 0)
    #expect(observations.maximumQueued <= slots * 2)
    let displayedCounts = observations.displayed.map(\.count)
    if assets.count > 1 { #expect(displayedCounts.allSatisfy { $0 > 1 }) }
    let forwardCounts = observations.displayedByPhase[1]?.map(\.count) ?? []
    let reverseCounts = observations.displayedByPhase[2]?.map(\.count) ?? []
    if assets.count > 1 {
      #expect(forwardCounts.count == slots && forwardCounts.allSatisfy { $0 > 1 })
      #expect(reverseCounts.count == slots && reverseCounts.allSatisfy { $0 > 1 })
    }
    subscriptions.removeAll() // stop() intentionally clears the presentation.
    loaders.forEach { $0.stop() }
    try await Self.drain(governor, phase: "rapid_drain")
    Self.log("rapid_browsing", started: started, count: 200, extra: [
      "slots": slots, "requestsPerSlot": 200, "direction": "forward_then_reverse",
      "firstVisibleSeconds": (observations.firstVisibleAt ?? refined) - started,
      "inputSeconds": inputStopped - inputStarted,
      "finalRefinementSeconds": refined - inputStopped,
      "displayedPerSlot": displayedCounts,
      "displayedForwardPerSlot": forwardCounts,
      "displayedReversePerSlot": reverseCounts,
      "blankAfterFirst": observations.emptyAfterFirst, "errorCount": observations.errors,
      "sampledMaximumRunning": observations.maximumRunning,
      "sampledMaximumQueued": observations.maximumQueued,
      "sampledMaximumRSSBytes": observations.maximumRSS, "drained": true,
    ])
  }

  @MainActor
  private func waitUntil(phase: String, seconds: Int,
    condition: @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !condition() {
      guard ContinuousClock.now < deadline else { throw Failure.deadline(phase) }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private static func drain(_ governor: ImageResourceGovernor, phase: String) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(120))
    while true {
      let state = await governor.stateSnapshot()
      if state.runningCount == 0, state.queuedCount == 0, state.waiterCount == 0 { return }
      guard ContinuousClock.now < deadline else { throw Failure.deadline(phase) }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private static func withDeadline<Value: Sendable>(_ phase: String, seconds: Int,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
      group.addTask(operation: operation)
      group.addTask {
        try await Task.sleep(for: .seconds(seconds))
        throw Failure.deadline(phase)
      }
      defer { group.cancelAll() }
      return try #require(try await group.next())
    }
  }

  private static func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
  }

  private static func log(_ phase: String, started: TimeInterval, count: Int,
    extra: [String: Any] = [:]
  ) {
    var fields = extra
    fields["phase"] = phase
    fields["count"] = count
    fields["seconds"] = ProcessInfo.processInfo.systemUptime - started
    fields["rssBytes"] = residentBytes()
    var usage = rusage()
    if getrusage(RUSAGE_SELF, &usage) == 0 { fields["processPeakRSSBytes"] = usage.ru_maxrss }
    guard let encoded = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    else { return }
    var line = Data("RAW_STRESS ".utf8)
    line.append(encoded)
    line.append(0x0a)
    FileHandle.standardOutput.write(line)
  }
}
