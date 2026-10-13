import Foundation
import Testing

@testable import ImageViewer

@Suite("이미지 로딩 작업 제한·우선순위·취소")
struct ImageWorkSchedulerTests {
  @Test("동시 디코딩 수를 제한하고 완료된 작업의 슬롯만 재사용한다")
  func boundsWorkAndReusesOnlyFreeSlots() async throws {
    let scheduler = ImageWorkScheduler<Int, Int>(maxConcurrentTasks: 2)
    let probe = ControlledImageWork()
    let first = request(1, scheduler: scheduler, probe: probe)
    let second = request(2, scheduler: scheduler, probe: probe)
    try await waitFor(scheduler, running: 2, queued: 0, waiters: 2)
    try await probe.waitForStarts(2)
    let third = request(3, scheduler: scheduler, probe: probe)
    try await waitFor(scheduler, running: 2, queued: 1, waiters: 3)

    await probe.release(1)
    #expect(try await first.value == 1)
    try await probe.waitForStarts(3)
    let starts = await probe.starts
    #expect(starts.first(where: { $0.label == 1 })?.slot == starts.last?.slot)
    #expect(starts.allSatisfy { (0..<2).contains($0.slot) })
    #expect(await probe.maximumRunning == 2)
    await probe.release(2)
    await probe.release(3)
    #expect(try await second.value == 2)
    #expect(try await third.value == 3)
    try await waitFor(scheduler, running: 0, queued: 0, waiters: 0)
  }

  @Test("같은 이미지의 동시 요청은 한 번만 디코딩한다")
  func coalescesIdenticalRequests() async throws {
    let scheduler = ImageWorkScheduler<Int, Int>(maxConcurrentTasks: 3)
    let probe = ControlledImageWork()
    let first = request(1, scheduler: scheduler, probe: probe)
    try await probe.waitForStarts(1)
    let second = request(1, label: 2, scheduler: scheduler, probe: probe)
    try await waitFor(scheduler, running: 1, queued: 0, waiters: 2)

    await probe.release(1)
    #expect(try await first.value == 1)
    #expect(try await second.value == 1)
    #expect(await probe.starts.map(\.label) == [1])
  }

  @Test("요청 하나의 취소가 같은 이미지를 기다리는 다른 요청을 취소하지 않는다")
  func cancelsIndividualWaiters() async throws {
    let scheduler = ImageWorkScheduler<Int, Int>(maxConcurrentTasks: 1)
    let probe = ControlledImageWork()
    let first = request(1, scheduler: scheduler, probe: probe)
    try await probe.waitForStarts(1)
    let second = request(1, label: 2, scheduler: scheduler, probe: probe)
    try await waitFor(scheduler, running: 1, queued: 0, waiters: 2)
    first.cancel()
    await expectCancellation(first)
    try await waitFor(scheduler, running: 1, queued: 0, waiters: 1)

    await probe.release(1)
    #expect(try await second.value == 1)
    #expect(await probe.cancelledCompletions.isEmpty)
  }

  @Test("화면에 보이는 이미지를 먼저 처리하고 중복 선읽기 요청의 우선순위를 올린다")
  func prioritizesVisibleWorkAndPromotesQueuedPrefetch() async throws {
    let scheduler = ImageWorkScheduler<Int, Int>(maxConcurrentTasks: 1)
    let probe = ControlledImageWork()
    let blocker = request(0, scheduler: scheduler, probe: probe)
    try await probe.waitForStarts(1)
    let firstPrefetch = request(1, priority: .prefetch, scheduler: scheduler, probe: probe)
    try await waitFor(scheduler, running: 1, queued: 1, waiters: 2)
    let promotedPrefetch = request(2, priority: .prefetch, scheduler: scheduler, probe: probe)
    try await waitFor(scheduler, running: 1, queued: 2, waiters: 3)
    let visible = request(3, scheduler: scheduler, probe: probe)
    try await waitFor(scheduler, running: 1, queued: 3, waiters: 4)
    let promotedVisible = request(2, label: 4, scheduler: scheduler, probe: probe)
    try await waitFor(scheduler, running: 1, queued: 3, waiters: 5)

    await probe.release(0)
    #expect(try await blocker.value == 0)
    try await probe.waitForStarts(2)
    #expect(await probe.starts.map(\.label) == [0, 2])
    await probe.release(2)
    #expect(try await promotedPrefetch.value == 2)
    #expect(try await promotedVisible.value == 2)
    try await probe.waitForStarts(3)
    #expect(await probe.starts.map(\.label) == [0, 2, 3])
    await probe.release(3)
    #expect(try await visible.value == 3)
    try await probe.waitForStarts(4)
    #expect(await probe.starts.map(\.label) == [0, 2, 3, 1])
    await probe.release(1)
    #expect(try await firstPrefetch.value == 1)
  }

  @Test("대기 중 취소한 이미지는 디코딩을 시작하지 않는다")
  func removesCancelledQueuedWork() async throws {
    let scheduler = ImageWorkScheduler<Int, Int>(maxConcurrentTasks: 1)
    let probe = ControlledImageWork()
    let blocker = request(1, scheduler: scheduler, probe: probe)
    try await probe.waitForStarts(1)
    let queued = request(2, scheduler: scheduler, probe: probe)
    try await waitFor(scheduler, running: 1, queued: 1, waiters: 2)
    queued.cancel()
    await expectCancellation(queued)
    try await waitFor(scheduler, running: 1, queued: 0, waiters: 1)
    await probe.release(1)
    #expect(try await blocker.value == 1)
    try await waitFor(scheduler, running: 0, queued: 0, waiters: 0)
    #expect(await probe.starts.map(\.label) == [1])
  }

  @Test("빠른 탐색 미리보기는 대기 중인 정밀 이미지보다 먼저 처리한다")
  func prioritizesInteractivePreviewWithoutInterruptingActiveDecoder() async throws {
    let scheduler = ImageWorkScheduler<Int, Int>(maxConcurrentTasks: 1)
    let probe = ControlledImageWork()
    let blocker = request(0, scheduler: scheduler, probe: probe)
    try await probe.waitForStarts(1)
    let fullImage = request(1, scheduler: scheduler, probe: probe)
    try await waitFor(scheduler, running: 1, queued: 1, waiters: 2)
    let preview = request(2, priority: .interactivePreview, scheduler: scheduler, probe: probe)
    try await waitFor(scheduler, running: 1, queued: 2, waiters: 3)
    #expect(await probe.starts.map(\.label) == [0])

    await probe.release(0)
    #expect(try await blocker.value == 0)
    try await probe.waitForStarts(2)
    #expect(await probe.starts.map(\.label) == [0, 2])
    await probe.release(2)
    #expect(try await preview.value == 2)
    try await probe.waitForStarts(3)
    await probe.release(1)
    #expect(try await fullImage.value == 1)
    #expect(await probe.maximumRunning == 1)
    try await waitFor(scheduler, running: 0, queued: 0, waiters: 0)
  }

  @Test("취소를 무시하는 디코더가 끝날 때까지 슬롯을 유지하며 같은 이미지의 재요청을 분리한다")
  func preservesSlotAndSeparatesReplacementAfterCancellation() async throws {
    let scheduler = ImageWorkScheduler<Int, Int>(maxConcurrentTasks: 1)
    let probe = ControlledImageWork()
    let original = request(1, scheduler: scheduler, probe: probe)
    try await probe.waitForStarts(1)
    original.cancel()
    // Immediately request the same key, without waiting for actor-side cancellation cleanup.
    let replacement = request(1, label: 2, scheduler: scheduler, probe: probe)
    await expectCancellation(original)
    try await waitFor(scheduler, running: 1, queued: 1, waiters: 1)
    #expect(await probe.starts.map(\.label) == [1])
    await probe.release(1)
    try await probe.waitForStarts(2)
    let joinedReplacement = request(1, label: 3, scheduler: scheduler, probe: probe)
    try await waitFor(scheduler, running: 1, queued: 0, waiters: 2)
    await probe.release(2)
    #expect(try await replacement.value == 2)
    #expect(try await joinedReplacement.value == 2)
    #expect(await probe.starts.map(\.label) == [1, 2])
    #expect(await probe.starts.map(\.slot) == [0, 0])
    #expect(await probe.cancelledCompletions == [1])
    #expect(await probe.maximumRunning == 1)
  }

  @Test("전체 취소 뒤에도 실행 중인 작업이 실제로 끝나기 전에는 새 작업을 시작하지 않는다")
  func cancelAllKeepsOccupiedSlotsAndAllowsFreshRequests() async throws {
    let scheduler = ImageWorkScheduler<Int, Int>(maxConcurrentTasks: 1)
    let probe = ControlledImageWork()
    let active = request(1, scheduler: scheduler, probe: probe)
    try await probe.waitForStarts(1)
    let queued = request(2, scheduler: scheduler, probe: probe)
    try await waitFor(scheduler, running: 1, queued: 1, waiters: 2)
    await scheduler.cancelAll()
    await expectCancellation(active)
    await expectCancellation(queued)
    try await waitFor(scheduler, running: 1, queued: 0, waiters: 0)
    let replacement = request(1, label: 3, scheduler: scheduler, probe: probe)
    try await waitFor(scheduler, running: 1, queued: 1, waiters: 1)
    await probe.release(1)
    try await probe.waitForStarts(2)
    #expect(await probe.starts.map(\.label) == [1, 3])
    await probe.release(3)
    #expect(try await replacement.value == 3)
    #expect(await probe.maximumRunning == 1)
  }

  @Test("메모리 압박으로 동시 실행 수를 줄이면 기존 작업 종료를 기다린다")
  func reducesAndRestoresConcurrencyWithoutOvercommitting() async throws {
    let scheduler = ImageWorkScheduler<Int, Int>(maxConcurrentTasks: 3)
    let probe = ControlledImageWork()
    let first = request(1, scheduler: scheduler, probe: probe)
    let second = request(2, scheduler: scheduler, probe: probe)
    let third = request(3, scheduler: scheduler, probe: probe)
    try await probe.waitForStarts(3)
    await scheduler.setConcurrencyLimit(1)
    let fourth = request(4, scheduler: scheduler, probe: probe)
    try await waitFor(scheduler, running: 3, queued: 1, waiters: 4)
    await probe.release(1)
    #expect(try await first.value == 1)
    try await waitFor(scheduler, running: 2, queued: 1, waiters: 3)
    await probe.release(2)
    #expect(try await second.value == 2)
    try await waitFor(scheduler, running: 1, queued: 1, waiters: 2)
    #expect(await probe.starts.count == 3)
    await probe.release(3)
    #expect(try await third.value == 3)
    try await probe.waitForStarts(4)
    await scheduler.setConcurrencyLimit(100)
    let fifth = request(5, scheduler: scheduler, probe: probe)
    let sixth = request(6, scheduler: scheduler, probe: probe)
    try await probe.waitForStarts(6)
    #expect(await probe.maximumRunning == 3)
    await probe.release(4)
    await probe.release(5)
    await probe.release(6)
    #expect(try await fourth.value == 4)
    #expect(try await fifth.value == 5)
    #expect(try await sixth.value == 6)
    try await waitFor(scheduler, running: 0, queued: 0, waiters: 0)
  }

  @Test("미리 취소된 요청은 실행하지 않고 실패한 요청 뒤에도 다시 처리한다")
  func skipsAlreadyCancelledCallersAndRecoversAfterFailure() async throws {
    let scheduler = ImageWorkScheduler<Int, Int>(maxConcurrentTasks: 1)
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await scheduler.value(for: 1) { _ in
        Issue.record("An already cancelled request must not decode")
        return 1
      }
    }
    await expectCancellation(cancelled)
    try await waitFor(scheduler, running: 0, queued: 0, waiters: 0)
    do {
      _ = try await scheduler.value(for: 2) { _ in throw ImageWorkTestError.expected }
      Issue.record("Expected the decode error")
    } catch ImageWorkTestError.expected {
    }
    #expect(try await scheduler.value(for: 2) { slot in slot + 10 } == 10)
    try await waitFor(scheduler, running: 0, queued: 0, waiters: 0)
  }

  private func request(
    _ key: Int,
    label: Int? = nil,
    priority: ImageWorkPriority = .visible,
    scheduler: ImageWorkScheduler<Int, Int>,
    probe: ControlledImageWork
  ) -> Task<Int, any Error> {
    Task {
      try await scheduler.value(for: key, priority: priority) { slot in
        await probe.run(label ?? key, slot: slot)
      }
    }
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

  private func waitFor(
    _ scheduler: ImageWorkScheduler<Int, Int>, running: Int, queued: Int, waiters: Int
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      let state = await scheduler.stateSnapshot()
      if state.runningCount == running && state.queuedCount == queued
        && state.waiterCount == waiters
      { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    throw ImageWorkTestError.timeout
  }
}

private enum ImageWorkTestError: Error {
  case expected
  case timeout
}

/// Tests release each decode explicitly. The continuation intentionally ignores task
/// cancellation, like a synchronous ImageIO decode that cannot stop halfway through.
private actor ControlledImageWork {
  struct Start: Sendable {
    let label: Int
    let slot: Int
  }

  private(set) var starts: [Start] = []
  private(set) var maximumRunning = 0
  private(set) var cancelledCompletions: [Int] = []
  private var running = 0
  private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

  func run(_ label: Int, slot: Int) async -> Int {
    running += 1
    maximumRunning = max(maximumRunning, running)
    starts.append(Start(label: label, slot: slot))
    await withCheckedContinuation { continuations[label] = $0 }
    if Task.isCancelled { cancelledCompletions.append(label) }
    running -= 1
    return label
  }

  func release(_ label: Int) {
    continuations.removeValue(forKey: label)?.resume()
  }

  func waitForStarts(_ count: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if starts.count >= count { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    throw ImageWorkTestError.timeout
  }
}
