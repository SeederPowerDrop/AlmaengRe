import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

@Suite("캐시 썸네일 복구의 공유 작업 예산")
struct CachedThumbnailWorkloadTests {
  private enum ProbeError: Error { case timeout }

  private actor Probe {
    private(set) var starts: [Int] = []
    private(set) var maximumRunning = 0
    private var running = 0
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]

    // Match a native operation that cannot release its worker until it returns.
    func run(_ label: Int) async -> Int {
      starts.append(label)
      running += 1
      maximumRunning = max(maximumRunning, running)
      await withCheckedContinuation { pending[label] = $0 }
      running -= 1
      return label
    }

    func release(_ label: Int) { pending.removeValue(forKey: label)?.resume() }

    func releaseAll() {
      let continuations = Array(pending.values)
      pending.removeAll()
      for continuation in continuations { continuation.resume() }
    }

    func waitForStarts(_ count: Int) async throws {
      let deadline = ContinuousClock.now + .seconds(3)
      while ContinuousClock.now < deadline {
        if starts.count >= count { return }
        try await Task.sleep(for: .milliseconds(1))
      }
      throw ProbeError.timeout
    }
  }

  @Test("복구·원본 작업은 같은 단일 슬롯과 우선순위를 지키고 대기 취소도 유지한다")
  func cacheRestorationSharesSourceBudgetAndCancellation() async throws {
    let snapshot = ImageResourceSnapshot(physicalMemory: 16 * 1_024 * 1_024 * 1_024,
      activeProcessorCount: 8, appleSilicon: true, isAppActive: false,
      memoryPressure: .critical, cpuBusyFraction: 0.8)
    let governor = ImageResourceGovernor(snapshot: snapshot, storageOverride: .internalSSD,
      maximumConcurrentLoadsOverride: 1, monitorsMemoryPressure: false)
    let url = URL(fileURLWithPath: "/private/cached-thumbnail-workload.png")
    let limits = await governor.limits(for: url)
    #expect(limits.totalConcurrentLoads == 1)
    #expect(limits.thumbnailCacheBytes == 0)
    #expect(limits.interLoadDelayMilliseconds >= 150)
    let namespace = UUID()
    let probe = Probe()
    let first = Task {
      try await governor.value(for: ImageResourceWorkKey(namespace: namespace, key: 1),
        url: url, priority: .interactivePreview, workload: .cachedThumbnail) { _ in
          await probe.run(1)
        }
    }
    defer {
      first.cancel()
      Task { await probe.releaseAll() }
    }
    try await probe.waitForStarts(1)
    // Omit workload to exercise the source default used by existing callers.
    let source = Task {
      try await governor.value(for: ImageResourceWorkKey(namespace: namespace, key: 2),
        url: url, priority: .visible) { _ in await probe.run(2) }
    }
    let cached = Task {
      try await governor.value(for: ImageResourceWorkKey(namespace: namespace, key: 3),
        url: url, priority: .interactivePreview, workload: .cachedThumbnail) { _ in
          await probe.run(3)
        }
    }
    let cancelled = Task {
      try await governor.value(for: ImageResourceWorkKey(namespace: namespace, key: 4),
        url: url, priority: .interactivePreview, workload: .cachedThumbnail) { _ in
          await probe.run(4)
        }
    }
    defer {
      source.cancel()
      cached.cancel()
      cancelled.cancel()
    }
    try await waitFor(governor, running: 1, queued: 3, waiters: 4)
    #expect(await probe.starts == [1])
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    try await waitFor(governor, running: 1, queued: 2, waiters: 3)
    #expect(await probe.starts == [1])

    await probe.release(1)
    #expect(try await first.value == 1)
    try await probe.waitForStarts(2)
    #expect(await probe.starts == [1, 3])
    #expect(await probe.maximumRunning == 1)
    await probe.release(3)
    #expect(try await cached.value == 3)
    try await probe.waitForStarts(3)
    #expect(await probe.starts == [1, 3, 2])
    #expect(await probe.maximumRunning == 1)
    await probe.release(2)
    #expect(try await source.value == 2)
    try await waitFor(governor, running: 0, queued: 0, waiters: 0)
    let finalLimits = await governor.limits(for: url)
    #expect(finalLimits == limits)
  }

  @Test("새 첫 픽셀은 대기 중인 폴더 선읽기보다 먼저 시작하고 단일 작업 예산을 지킨다")
  func visibleCachedBitmapPrecedesQueuedCompactWarmup() async throws {
    let snapshot = ImageResourceSnapshot(physicalMemory: 16 * 1_024 * 1_024 * 1_024,
      activeProcessorCount: 8, appleSilicon: true, isAppActive: false,
      cpuBusyFraction: 0.1)
    let governor = ImageResourceGovernor(snapshot: snapshot, storageOverride: .internalSSD,
      maximumConcurrentLoadsOverride: 1, monitorsMemoryPressure: false)
    let url = URL(fileURLWithPath: "/private/compact-warm-shared-budget.dng")
    #expect(await governor.overviewWarmDelay(for: url) != nil)
    let namespace = UUID()
    let probe = Probe()
    let currentWarmup = Task {
      try await governor.value(for: ImageResourceWorkKey(namespace: namespace, key: 1),
        url: url, priority: .idleThumbnail) { _ in await probe.run(1) }
    }
    defer {
      currentWarmup.cancel()
      Task { await probe.releaseAll() }
    }
    try await probe.waitForStarts(1)
    let nextWarmup = Task {
      try await governor.value(for: ImageResourceWorkKey(namespace: namespace, key: 2),
        url: url, priority: .idleThumbnail) { _ in await probe.run(2) }
    }
    defer { nextWarmup.cancel() }
    try await waitFor(governor, running: 1, queued: 1, waiters: 2)
    let visibleBitmap = Task {
      try await governor.value(for: ImageResourceWorkKey(namespace: namespace, key: 3),
        url: url, priority: .interactivePreview, workload: .cachedThumbnail) { _ in
          await probe.run(3)
        }
    }
    defer { visibleBitmap.cancel() }
    try await waitFor(governor, running: 1, queued: 2, waiters: 3)

    // Synchronous work retains its occupied slot. Once it returns, the new
    // viewport's bitmap wins over a warmup that was queued before it.
    #expect(await probe.starts == [1])
    await probe.release(1)
    #expect(try await currentWarmup.value == 1)
    try await probe.waitForStarts(2)
    #expect(await probe.starts == [1, 3])
    #expect(await probe.maximumRunning == 1)
    await probe.release(3)
    #expect(try await visibleBitmap.value == 3)
    try await probe.waitForStarts(3)
    #expect(await probe.starts == [1, 3, 2])
    #expect(await probe.maximumRunning == 1)
    await probe.release(2)
    #expect(try await nextWarmup.value == 2)
    try await waitFor(governor, running: 0, queued: 0, waiters: 0)
  }

  @Test("위급 압박의 150ms 원본 정책에서도 기존 PNG를 복구하고 RAM 예산 0을 지킨다")
  func existingPNGRestoresWithoutSourceOrMemoryRetention() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CachedThumbnailWorkloadTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = try #require(CGContext(data: nil, width: 64, height: 64,
      bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let bitmap = try #require(context.makeImage())
    let source = directory.appendingPathComponent("source.png")
    let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL,
      "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, bitmap, nil)
    #expect(CGImageDestinationFinalize(destination))
    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
    let asset = ImageAsset(url: source,
      byteCount: try #require((attributes[.size] as? NSNumber)?.int64Value),
      modificationDate: attributes[.modificationDate] as? Date)
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    await disk.store(bitmap, for: ThumbnailCacheKey(asset: asset,
      pixelSize: 256, isBrowsingPreview: true))
    #expect(await disk.snapshot().entryCount == 1)
    try FileManager.default.removeItem(at: source)

    let snapshot = ImageResourceSnapshot(physicalMemory: 16 * 1_024 * 1_024 * 1_024,
      activeProcessorCount: 8, appleSilicon: true, isAppActive: false,
      memoryPressure: .critical, cpuBusyFraction: 0.8)
    let governor = ImageResourceGovernor(snapshot: snapshot, storageOverride: .internalSSD,
      monitorsMemoryPressure: false)
    let pipeline = ThumbnailPipeline(governor: governor, diskCache: disk)
    await pipeline.setCachedPreviewDiagnosticPhase("critical_cache_only")
    let restored = try #require(await pipeline.cachedPreview(for: asset, maxPixelSize: 768))
    await pipeline.setCachedPreviewDiagnosticPhase(nil)
    #expect(restored.width == bitmap.width)
    #expect(restored.height == bitmap.height)
    #expect(await disk.snapshot().hits == 1)
    #expect(await pipeline.cacheSnapshot().entryCount == 0)
    #expect(await pipeline.cacheSnapshot().byteCount == 0)
    #expect(await pipeline.cacheSnapshot().byteLimit == 0)
    #expect(await governor.limits(for: source).interLoadDelayMilliseconds >= 150)
    let records = await pipeline.cachedPreviewDiagnosticsSnapshot()
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.phase == "critical_cache_only")
    #expect(record.cacheHit)
    #expect(!record.cancelled)
    #expect(!FileManager.default.fileExists(atPath: source.path))
  }

  private func waitFor(_ governor: ImageResourceGovernor, running: Int, queued: Int, waiters: Int)
    async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
      let state = await governor.stateSnapshot()
      if state.runningCount == running, state.queuedCount == queued, state.waiterCount == waiters {
        return
      }
      try await Task.sleep(for: .milliseconds(1))
    }
    throw ProbeError.timeout
  }
}
