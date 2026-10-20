import Foundation
import Testing

@testable import ImageViewer

@Suite("사진 헤더 메타데이터의 공유 작업 예산")
struct MetadataHeaderWorkloadTests {
  private enum ProbeError: Error { case timeout }

  private actor Probe {
    private(set) var starts: [Int] = []
    private(set) var maximumRunning = 0
    private var running = 0
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]

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
      let deadline = ContinuousClock.now + .seconds(5)
      while ContinuousClock.now < deadline {
        if starts.count >= count { return }
        try await Task.sleep(for: .milliseconds(1))
      }
      throw ProbeError.timeout
    }
  }

  @Test("사진 헤더만 원본 디코딩 지연을 생략하고 원본·영상·오디오는 유지한다")
  func headerPolicyAndPlaybackRoutingStayDistinct() {
    for delay in [0, 25, 60, 100, 150, 1_000] {
      #expect(ImageResourceWorkload.source.pacingDelayMilliseconds(delay) == delay)
      #expect(ImageResourceWorkload.metadataHeader.pacingDelayMilliseconds(delay) == 0)
      #expect(ImageResourceWorkload.cachedThumbnail.pacingDelayMilliseconds(delay) == 0)
      #expect(ImageResourceWorkload.overviewPreview.pacingDelayMilliseconds(delay) == 0)
    }
    for name in ["image.dng", "image.jpg", "image.heic", "image.qoi"] {
      #expect(LibrarySortMetadataReader.workload(for: URL(fileURLWithPath: "/private/\(name)"),
        isVideo: false) == .metadataHeader)
    }
    #expect(LibrarySortMetadataReader.workload(for: URL(fileURLWithPath: "/private/movie.mp4"),
      isVideo: true) == .source)
    #expect(LibrarySortMetadataReader.workload(for: URL(fileURLWithPath: "/private/audio.wav"),
      isVideo: false) == .source)
    #expect(LibrarySortMetadataReader.workload(for: URL(fileURLWithPath: "/private/hinted.jpg"),
      isVideo: true) == .source)
  }

  @Test("경고 상태의 실제 메타데이터 요청도 원본과 한 슬롯을 공유하고 취소를 지킨다")
  func metadataReaderSharesPressureLimitedSlotAndCancellation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MetadataHeaderWorkload-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstURL = directory.appendingPathComponent("first.dng")
    let cancelledURL = directory.appendingPathComponent("cancelled.dng")
    try Data([1]).write(to: firstURL)
    try Data([2]).write(to: cancelledURL)
    let snapshot = ImageResourceSnapshot(physicalMemory: 16 * 1_024 * 1_024 * 1_024,
      activeProcessorCount: 8, appleSilicon: true, isAppActive: true,
      memoryPressure: .warning, cpuBusyFraction: 0.1)
    let governor = ImageResourceGovernor(snapshot: snapshot, storageOverride: .internalSSD,
      monitorsMemoryPressure: false)
    let limits = await governor.limits(for: firstURL)
    #expect(limits.totalConcurrentLoads == 1)
    #expect(limits.interLoadDelayMilliseconds == 60)
    let probe = Probe()
    let cache = LibrarySortMetadataCache(reader: { url, _ in
      let label = url == firstURL ? 2 : 3
      _ = await probe.run(label)
      return LibrarySortMetadata(cameraMake: "Synthetic")
    })
    let namespace = UUID()
    let source = Task {
      try await governor.value(for: ImageResourceWorkKey(namespace: namespace, key: 1),
        url: firstURL) { _ in await probe.run(1) }
    }
    defer {
      source.cancel()
      Task { await probe.releaseAll() }
    }
    try await probe.waitForStarts(1)
    let first = Task {
      try await cache.metadata(for: LibrarySortFileVersion(url: firstURL),
        isVideo: false, governor: governor)
    }
    defer { first.cancel() }
    try await waitFor(governor, running: 1, queued: 1, waiters: 2)
    let cancelled = Task {
      try await cache.metadata(for: LibrarySortFileVersion(url: cancelledURL),
        isVideo: false, governor: governor)
    }
    defer { cancelled.cancel() }
    try await waitFor(governor, running: 1, queued: 2, waiters: 3)
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    try await waitFor(governor, running: 1, queued: 1, waiters: 2)
    #expect(await probe.starts == [1])

    await probe.release(1)
    #expect(try await source.value == 1)
    try await probe.waitForStarts(2)
    #expect(await probe.starts == [1, 2])
    #expect(await probe.maximumRunning == 1)
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    // A native reader may ignore cancellation. Its occupied slot cannot be
    // recycled merely because the metadata caller stopped waiting.
    try await waitFor(governor, running: 1, queued: 0, waiters: 0)
    await probe.release(2)
    try await waitFor(governor, running: 0, queued: 0, waiters: 0)
    #expect(await probe.starts == [1, 2])
    #expect(await governor.limits(for: firstURL) == limits)
  }

  private func waitFor(_ governor: ImageResourceGovernor,
    running: Int, queued: Int, waiters: Int
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      let state = await governor.stateSnapshot()
      if state.runningCount == running && state.queuedCount == queued
        && state.waiterCount == waiters { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    throw ProbeError.timeout
  }
}
