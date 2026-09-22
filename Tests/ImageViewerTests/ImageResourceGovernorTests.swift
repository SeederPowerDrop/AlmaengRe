import Foundation
import Testing

@testable import ImageViewer

@Suite("썸네일·정밀 이미지·메타데이터의 공유 자원 예산")
struct ImageResourceGovernorTests {
  private let url = URL(fileURLWithPath: "/tmp/imageviewer-governor-test.jpg")

  private var machine: ImageResourceSnapshot {
    ImageResourceSnapshot(
      physicalMemory: 16 * 1_024 * 1_024 * 1_024, activeProcessorCount: 8, appleSilicon: true)
  }

  @Test("서로 다른 파이프라인의 작업이 하나의 2개 슬롯을 공유한다")
  func metadataRenderAndQuickLookShareOneBudget() async throws {
    let governor = ImageResourceGovernor(snapshot: machine, storageOverride: .internalSSD)
    let probe = GovernorWorkProbe()
    let metadata = request(1, key: workKey(namespace: UUID(), key: 1), governor: governor, probe: probe)
    let render = request(2, key: workKey(namespace: UUID(), key: 1), governor: governor, probe: probe)
    try await probe.waitForStarts(2)
    let thumbnail = request(3, key: workKey(namespace: UUID(), key: 1), governor: governor, probe: probe)
    try await waitFor(governor, running: 2, queued: 1, waiters: 3)
    #expect(await probe.maximumRunning == 2)
    await probe.release(1)
    #expect(try await metadata.value == 1)
    try await probe.waitForStarts(3)
    #expect(await probe.maximumRunning == 2)
    await probe.release(2)
    await probe.release(3)
    #expect(try await render.value == 2)
    #expect(try await thumbnail.value == 3)
    try await waitFor(governor, running: 0, queued: 0, waiters: 0)
  }

  @Test("같은 이름공간·키는 합치고 다른 이름공간은 별도로 실행한다")
  func coalescingDoesNotCrossResultNamespaces() async throws {
    let governor = ImageResourceGovernor(snapshot: machine, storageOverride: .internalSSD)
    let probe = GovernorWorkProbe()
    let sharedKey = workKey(namespace: UUID(), key: 1)
    let first = request(10, key: sharedKey, governor: governor, probe: probe)
    try await probe.waitForStarts(1)
    let shared = request(11, key: sharedKey, governor: governor, probe: probe)
    try await waitFor(governor, running: 1, queued: 0, waiters: 2)
    let independent = request(12, key: workKey(namespace: UUID(), key: 1), governor: governor, probe: probe)
    try await probe.waitForStarts(2)
    #expect(await probe.starts.map(\.label) == [10, 12])
    await probe.release(10)
    await probe.release(12)
    #expect(try await first.value == 10)
    #expect(try await shared.value == 10)
    #expect(try await independent.value == 12)
  }

  @Test("SD 카드에서는 모든 이름공간을 합쳐 한 작업만 진행하고 선읽기를 시작하지 않는다")
  func removableStorageSerializesAllSourcesAndRejectsSpeculation() async throws {
    let governor = ImageResourceGovernor(mode: .priority, snapshot: machine, storageOverride: .removable)
    let probe = GovernorWorkProbe()
    let first = request(1, key: workKey(namespace: UUID(), key: 1), governor: governor, probe: probe)
    try await probe.waitForStarts(1)
    let second = request(2, key: workKey(namespace: UUID(), key: 1), governor: governor, probe: probe)
    try await waitFor(governor, running: 1, queued: 1, waiters: 2)
    let prefetch = request(3, key: workKey(namespace: UUID(), key: 1), priority: .prefetch,
      governor: governor, probe: probe)
    await expectCancellation(prefetch)
    #expect(await governor.limits(for: url).permitsSpeculation == false)
    #expect(await probe.starts.map(\.label) == [1])
    await probe.release(1)
    #expect(try await first.value == 1)
    try await probe.waitForStarts(2)
    #expect(await probe.maximumRunning == 1)
    await probe.release(2)
    #expect(try await second.value == 2)
  }

  @Test("표시 요청이 공유한 선읽기는 압박에서도 살아남고 순수 선읽기는 취소된다")
  func promotedVisibleWaiterSurvivesSpeculationShutdown() async throws {
    let governor = ImageResourceGovernor(mode: .priority, snapshot: machine,
      storageOverride: .internalSSD, maximumConcurrentLoadsOverride: 1)
    let probe = GovernorWorkProbe()
    let namespace = UUID()
    let blocker = request(0, key: workKey(namespace: namespace, key: 0), governor: governor, probe: probe)
    try await probe.waitForStarts(1)
    let sharedKey = workKey(namespace: namespace, key: 1)
    let prefetch = request(1, key: sharedKey, priority: .prefetch, governor: governor, probe: probe)
    try await waitFor(governor, running: 1, queued: 1, waiters: 2)
    let visible = request(11, key: sharedKey, governor: governor, probe: probe)
    try await waitFor(governor, running: 1, queued: 1, waiters: 3)
    let orphan = request(2, key: workKey(namespace: namespace, key: 2), priority: .prefetch,
      governor: governor, probe: probe)
    try await waitFor(governor, running: 1, queued: 2, waiters: 4)
    var warning = machine
    warning.memoryPressure = .warning
    await governor.update(warning)
    await expectCancellation(orphan)
    try await waitFor(governor, running: 1, queued: 1, waiters: 3)
    await probe.release(0)
    #expect(try await blocker.value == 0)
    try await probe.waitForStarts(2)
    #expect(await probe.starts.map(\.label) == [0, 1])
    #expect(await probe.starts.last?.priority == .utility)
    await probe.release(1)
    #expect(try await prefetch.value == 1)
    #expect(try await visible.value == 1)
  }

  @Test("공유 표시 요청이 취소되면 남은 선읽기는 압박 상태에서 취소할 수 있다")
  func cancelledVisibleWaiterDoesNotLeaveSpeculationPromoted() async throws {
    let governor = ImageResourceGovernor(mode: .priority, snapshot: machine,
      storageOverride: .internalSSD, maximumConcurrentLoadsOverride: 1)
    let probe = GovernorWorkProbe()
    let namespace = UUID()
    let blocker = request(0, key: workKey(namespace: namespace, key: 0), governor: governor, probe: probe)
    try await probe.waitForStarts(1)
    let sharedKey = workKey(namespace: namespace, key: 1)
    let prefetch = request(1, key: sharedKey, priority: .prefetch, governor: governor, probe: probe)
    try await waitFor(governor, running: 1, queued: 1, waiters: 2)
    let visible = request(11, key: sharedKey, governor: governor, probe: probe)
    try await waitFor(governor, running: 1, queued: 1, waiters: 3)
    visible.cancel()
    await expectCancellation(visible)
    try await waitFor(governor, running: 1, queued: 1, waiters: 2)
    var warning = machine
    warning.memoryPressure = .warning
    await governor.update(warning)
    let state = await governor.stateSnapshot()
    #expect(state.queuedCount == 0)
    #expect(state.waiterCount == 1)
    // Always clean up so a regression produces an assertion, not a hanging test.
    prefetch.cancel()
    await expectCancellation(prefetch)
    await probe.release(0)
    #expect(try await blocker.value == 0)
    #expect(await probe.starts.map(\.label) == [0])
  }

  @Test("다른 앱으로 이동하면 기존 작업 종료를 기다리고 대기 작업을 낮은 우선순위로 시작한다")
  func backgroundTransitionReducesOnlyFutureWork() async throws {
    let governor = ImageResourceGovernor(mode: .priority, snapshot: machine,
      storageOverride: .internalSSD, maximumConcurrentLoadsOverride: 2)
    let probe = GovernorWorkProbe()
    let namespace = UUID()
    let first = request(1, key: workKey(namespace: namespace, key: 1), governor: governor, probe: probe)
    let second = request(2, key: workKey(namespace: namespace, key: 2), governor: governor, probe: probe)
    try await probe.waitForStarts(2)
    let third = request(3, key: workKey(namespace: namespace, key: 3), governor: governor, probe: probe)
    try await waitFor(governor, running: 2, queued: 1, waiters: 3)
    #expect(await probe.starts.allSatisfy { $0.priority == .userInitiated })
    var inactive = machine
    inactive.isAppActive = false
    await governor.update(inactive)
    await probe.release(1)
    #expect(try await first.value == 1)
    try await waitFor(governor, running: 1, queued: 1, waiters: 2)
    #expect(await probe.starts.count == 2)
    await probe.release(2)
    #expect(try await second.value == 2)
    try await probe.waitForStarts(3)
    #expect(await probe.starts.last?.priority == .background)
    await probe.release(3)
    #expect(try await third.value == 3)
  }

  @Test("요청 취소는 비협조적인 네이티브 작업의 슬롯을 일찍 반환하지 않는다")
  func cancelledNativeOperationRetainsSharedSlot() async throws {
    let governor = ImageResourceGovernor(snapshot: machine, storageOverride: .internalSSD,
      maximumConcurrentLoadsOverride: 1)
    let probe = GovernorWorkProbe()
    let first = request(1, key: workKey(namespace: UUID(), key: 1), governor: governor, probe: probe)
    try await probe.waitForStarts(1)
    first.cancel()
    await expectCancellation(first)
    let replacement = request(2, key: workKey(namespace: UUID(), key: 1), governor: governor, probe: probe)
    try await waitFor(governor, running: 1, queued: 1, waiters: 1)
    #expect(await probe.starts.map(\.label) == [1])
    await probe.release(1)
    try await probe.waitForStarts(2)
    #expect(await probe.maximumRunning == 1)
    await probe.release(2)
    #expect(try await replacement.value == 2)
  }

  @Test("취소된 SD 읽기가 실제로 끝나기 전에는 내장 SSD 작업도 직렬 예산을 유지한다")
  func cancelledRemovableReadKeepsStorageBudgetUntilNativeCompletion() async throws {
    let governor = ImageResourceGovernor(snapshot: machine, storageResolver: { url in
      url.lastPathComponent == "sd.jpg" ? .removable : .internalSSD
    })
    let probe = GovernorWorkProbe()
    let sd = request(0, key: workKey(namespace: UUID(), key: 1),
      sourceURL: URL(fileURLWithPath: "/tmp/sd.jpg"), governor: governor, probe: probe)
    try await probe.waitForStarts(1)
    sd.cancel()
    await expectCancellation(sd)
    let firstInternal = request(1, key: workKey(namespace: UUID(), key: 1),
      governor: governor, probe: probe)
    let secondInternal = request(2, key: workKey(namespace: UUID(), key: 1),
      governor: governor, probe: probe)
    try await waitFor(governor, running: 1, queued: 2, waiters: 2)
    #expect(await probe.starts.map(\.label) == [0])
    await probe.release(0)
    try await probe.waitForStarts(3)
    #expect(await probe.maximumRunning == 2)
    await probe.release(1)
    await probe.release(2)
    #expect(try await firstInternal.value == 1)
    #expect(try await secondInternal.value == 2)
    try await waitFor(governor, running: 0, queued: 0, waiters: 0)
  }

  @Test("지연된 캐시 알림이 최신 모드 예산을 덮어쓰지 않도록 revision을 제공한다")
  func cacheClientsCanRejectLateOlderNotifications() async throws {
    let governor = ImageResourceGovernor(snapshot: machine, storageOverride: .internalSSD)
    let cache = GovernorCacheProbe()
    let clientIDs = [UUID(), UUID()]
    for id in clientIDs {
      await governor.registerCacheClient(id: id) { update in await cache.apply(update, id: id) }
    }
    let older = Task { await governor.setMode(.slow) }
    try await cache.waitForBlockedOldUpdate()
    await governor.setMode(.priority)
    await cache.releaseOldUpdate()
    await older.value
    let updates = await cache.latest
    for id in clientIDs {
      let update = try #require(updates[id])
      #expect(update.revision == 2)
      #expect(update.limits.renderCacheBytes == 256 * 1_024 * 1_024)
      #expect(update.limits.visibleTaskPriority == .userInitiated)
    }
    #expect(await cache.rejectedStaleUpdates >= 1)
  }

  @Test("이전 설정 메시지가 늦게 도착해도 새 동시 작업·우선순위·선읽기 설정이 유지된다")
  func staleSchedulerConfigurationCannotRestoreAggressiveWork() async throws {
    let scheduler = ImageWorkScheduler<Int, Int>(maxConcurrentTasks: 4)
    await scheduler.configure(concurrencyLimit: 1, executionPriority: .background,
      permitsPrefetch: false, revision: 20)
    await scheduler.configure(concurrencyLimit: 4, executionPriority: .userInitiated,
      permitsPrefetch: true, revision: 19)
    let probe = GovernorWorkProbe()
    let first = Task { try await scheduler.value(for: 1) { slot in await probe.run(1, slot: slot) } }
    try await probe.waitForStarts(1)
    let second = Task { try await scheduler.value(for: 2) { slot in await probe.run(2, slot: slot) } }
    let prefetch = Task { try await scheduler.value(for: 3, priority: .prefetch) { _ in 3 } }
    await expectCancellation(prefetch)
    let deadline = ContinuousClock.now + .seconds(3)
    while await scheduler.stateSnapshot().queuedCount == 0 && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await scheduler.stateSnapshot().runningCount == 1)
    #expect(await scheduler.stateSnapshot().queuedCount == 1)
    #expect(await probe.starts.first?.priority == .background)
    await probe.release(1)
    #expect(try await first.value == 1)
    try await probe.waitForStarts(2)
    #expect(await probe.starts.last?.priority == .background)
    await probe.release(2)
    #expect(try await second.value == 2)
  }

  private func workKey(namespace: UUID, key: Int) -> ImageResourceWorkKey {
    ImageResourceWorkKey(namespace: namespace, key: key)
  }

  private func request(
    _ label: Int, key: ImageResourceWorkKey, priority: ImageWorkPriority = .visible,
    sourceURL: URL? = nil,
    governor: ImageResourceGovernor, probe: GovernorWorkProbe
  ) -> Task<Int, any Error> {
    Task {
      try await governor.value(for: key, url: sourceURL ?? url, priority: priority) { slot in
        await probe.run(label, slot: slot)
      }
    }
  }

  private func waitFor(
    _ governor: ImageResourceGovernor, running: Int, queued: Int, waiters: Int
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
      let state = await governor.stateSnapshot()
      if state.runningCount == running && state.queuedCount == queued && state.waiterCount == waiters { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    throw GovernorTestError.timeout
  }

  private func expectCancellation(_ task: Task<Int, any Error>) async {
    do {
      _ = try await task.value
      Issue.record("Expected CancellationError")
    } catch is CancellationError {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}

private enum GovernorTestError: Error { case timeout }

private actor GovernorWorkProbe {
  struct Start: Sendable {
    let label: Int
    let slot: Int
    let priority: TaskPriority
  }

  private(set) var starts: [Start] = []
  private(set) var maximumRunning = 0
  private var running = 0
  private var pending: [Int: CheckedContinuation<Void, Never>] = [:]

  // Intentionally ignores cancellation, matching a native decode already in progress.
  func run(_ label: Int, slot: Int) async -> Int {
    starts.append(Start(label: label, slot: slot, priority: Task.currentPriority))
    running += 1
    maximumRunning = max(maximumRunning, running)
    await withCheckedContinuation { pending[label] = $0 }
    running -= 1
    return label
  }

  func release(_ label: Int) { pending.removeValue(forKey: label)?.resume() }

  func waitForStarts(_ count: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
      if starts.count >= count { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    throw GovernorTestError.timeout
  }
}

private actor GovernorCacheProbe {
  private(set) var latest: [UUID: ImageResourceUpdate] = [:]
  private(set) var rejectedStaleUpdates = 0
  private var blockedOldUpdate = false
  private var oldContinuation: CheckedContinuation<Void, Never>?

  func apply(_ update: ImageResourceUpdate, id: UUID) async {
    if update.revision == 1 && !blockedOldUpdate {
      blockedOldUpdate = true
      await withCheckedContinuation { oldContinuation = $0 }
    }
    if let current = latest[id], update.revision < current.revision {
      rejectedStaleUpdates += 1
      return
    }
    latest[id] = update
  }

  func releaseOldUpdate() {
    oldContinuation?.resume()
    oldContinuation = nil
  }

  func waitForBlockedOldUpdate() async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
      if blockedOldUpdate { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    throw GovernorTestError.timeout
  }
}
