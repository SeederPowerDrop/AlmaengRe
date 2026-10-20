import Foundation

enum ImageWorkPriority: Int, Comparable, Sendable {
  /// Compact overview preparation can continue on an idle machine in the background.
  case idleThumbnail = -1
  case prefetch
  case visible
  /// A small first bitmap unblocks navigation before metadata or full-size rendering.
  case interactivePreview

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

struct ImageWorkSchedulerState: Sendable {
  let runningCount: Int
  let queuedCount: Int
  let waiterCount: Int
}

/// Cancellation handlers run outside the actor. Recording cancellation immediately prevents
/// a new request from joining an abandoned decode before its cleanup reaches the actor.
private final class ImageWorkCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool { lock.withLock { cancelled } }

  func cancel() { lock.withLock { cancelled = true } }
}

/// Bounds expensive work, shares identical requests, and starts visible work before prefetches.
/// A running operation retains its worker slot until it actually returns, even if it ignores
/// cancellation. This is essential for synchronous image decoders and per-worker CIContexts.
actor ImageWorkScheduler<Key: Hashable & Sendable, Value: Sendable> {
  private struct Waiter {
    let continuation: CheckedContinuation<Value, any Error>
    let cancellation: ImageWorkCancellation
    let priority: ImageWorkPriority
  }

  private final class Job {
    let id = UUID()
    let key: Key
    let operation: @Sendable (Int) async throws -> Value
    var priority: ImageWorkPriority
    var waiters: [UUID: Waiter]
    var slot: Int?
    var task: Task<Void, Never>?

    init(
      key: Key,
      priority: ImageWorkPriority,
      waiterID: UUID,
      waiter: Waiter,
      operation: @escaping @Sendable (Int) async throws -> Value
    ) {
      self.key = key
      self.priority = priority
      self.waiters = [waiterID: waiter]
      self.operation = operation
    }
  }

  private let maximumConcurrency: Int
  private var concurrencyLimit: Int
  private var jobs: [UUID: Job] = [:]
  private var currentJobs: [Key: UUID] = [:]
  private var pendingOrder: [UUID] = []
  private var runningSlots: [Int: UUID] = [:]
  private var executionPriority: ImageExecutionPriority = .userInitiated
  private var permitsPrefetch = true
  private var permitsIdleThumbnails = false
  private var configurationRevision: UInt64 = 0

  init(maxConcurrentTasks: Int) {
    let limit = max(1, maxConcurrentTasks)
    maximumConcurrency = limit
    concurrencyLimit = limit
  }

  func value(
    for key: Key,
    priority: ImageWorkPriority = .visible,
    operation: @escaping @Sendable (Int) async throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    if priority == .prefetch, !permitsPrefetch { throw CancellationError() }
    if priority == .idleThumbnail, !permitsIdleThumbnails { throw CancellationError() }
    let waiterID = UUID()
    let cancellation = ImageWorkCancellation()
    let value: Value = try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        guard !cancellation.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        enqueue(
          key: key,
          priority: priority,
          waiterID: waiterID,
          waiter: Waiter(continuation: continuation, cancellation: cancellation, priority: priority),
          operation: operation
        )
      }
    } onCancel: {
      cancellation.cancel()
      Task { await self.cancelWaiter(waiterID, for: key) }
    }
    try Task.checkCancellation()
    return value
  }

  func cancelAll() {
    for job in Array(jobs.values) { abandon(job) }
  }

  /// Lowering the limit lets existing decoders finish; it never reuses an occupied slot.
  func setConcurrencyLimit(_ value: Int) {
    concurrencyLimit = min(maximumConcurrency, max(1, value))
    startPendingJobs()
  }

  /// Revision checks also protect against reordered actor hops during fast mode changes.
  func configure(
    concurrencyLimit: Int, executionPriority: ImageExecutionPriority,
    permitsPrefetch: Bool, permitsIdleThumbnails: Bool = false, revision: UInt64
  ) {
    guard revision >= configurationRevision else { return }
    configurationRevision = revision
    self.concurrencyLimit = min(maximumConcurrency, max(1, concurrencyLimit))
    self.executionPriority = executionPriority
    self.permitsPrefetch = permitsPrefetch
    self.permitsIdleThumbnails = permitsIdleThumbnails
    if !permitsPrefetch || !permitsIdleThumbnails {
      // Shared work promoted by a visible waiter survives speculative cancellation.
      for job in Array(jobs.values) { removeCancelledWaiters(from: job) }
    }
    startPendingJobs()
  }

  func stateSnapshot() -> ImageWorkSchedulerState {
    ImageWorkSchedulerState(
      runningCount: runningSlots.count,
      queuedCount: pendingOrder.count,
      waiterCount: jobs.values.reduce(0) { $0 + $1.waiters.count }
    )
  }

  private func enqueue(
    key: Key,
    priority: ImageWorkPriority,
    waiterID: UUID,
    waiter: Waiter,
    operation: @escaping @Sendable (Int) async throws -> Value
  ) {
    if let id = currentJobs[key], let job = jobs[id] {
      removeCancelledWaiters(from: job)
      if !job.waiters.isEmpty {
        job.waiters[waiterID] = waiter
        job.priority = max(job.priority, priority)
        startPendingJobs()
        return
      }
    }
    let job = Job(
      key: key, priority: priority, waiterID: waiterID, waiter: waiter, operation: operation
    )
    jobs[job.id] = job
    currentJobs[key] = job.id
    pendingOrder.append(job.id)
    startPendingJobs()
  }

  private func cancelWaiter(_ waiterID: UUID, for key: Key) {
    guard let id = currentJobs[key], let job = jobs[id],
      let waiter = job.waiters.removeValue(forKey: waiterID)
    else { return }
    waiter.continuation.resume(throwing: CancellationError())
    removeCancelledWaiters(from: job)
    startPendingJobs()
  }

  private func removeCancelledWaiters(from job: Job) {
    for (id, waiter) in job.waiters where waiter.cancellation.isCancelled {
      job.waiters.removeValue(forKey: id)
      waiter.continuation.resume(throwing: CancellationError())
    }
    if job.waiters.isEmpty {
      abandon(job)
    } else {
      job.priority = job.waiters.values.map(\.priority).max() ?? .prefetch
      if !permitsPrefetch, job.priority == .prefetch { abandon(job) }
      if !permitsIdleThumbnails, job.priority == .idleThumbnail { abandon(job) }
    }
  }

  private func abandon(_ job: Job) {
    if currentJobs[job.key] == job.id { currentJobs.removeValue(forKey: job.key) }
    for waiter in job.waiters.values {
      waiter.continuation.resume(throwing: CancellationError())
    }
    job.waiters.removeAll()
    if job.slot == nil {
      pendingOrder.removeAll { $0 == job.id }
      jobs.removeValue(forKey: job.id)
    } else {
      // Task.cancel() is only a request: finish(), not cancellation, releases this slot.
      job.task?.cancel()
    }
  }

  private func startPendingJobs() {
    for id in pendingOrder {
      if let job = jobs[id] { removeCancelledWaiters(from: job) }
    }
    while runningSlots.count < concurrencyLimit {
      var nextIndex: Int?
      for index in pendingOrder.indices {
        guard let candidate = jobs[pendingOrder[index]] else { continue }
        if let selected = nextIndex,
          let previous = jobs[pendingOrder[selected]],
          candidate.priority <= previous.priority
        { continue }
        nextIndex = index
      }
      guard let index = nextIndex,
        let slot = (0..<maximumConcurrency).first(where: { runningSlots[$0] == nil })
      else { return }
      let id = pendingOrder.remove(at: index)
      guard let job = jobs[id] else { continue }
      job.slot = slot
      runningSlots[slot] = id
      let operation = job.operation
      let taskPriority: TaskPriority
      if job.priority == .idleThumbnail {
        // Explicitly requested folder preparation must make progress under
        // contention. Queue order, admission and adaptive pacing remain idle work.
        taskPriority = .utility
      } else if job.priority == .prefetch {
        taskPriority = .background
      } else {
        switch executionPriority {
        case .userInitiated: taskPriority = .userInitiated
        case .utility: taskPriority = .utility
        case .background: taskPriority = .background
        }
      }
      job.task = Task.detached(priority: taskPriority) {
        let result: Result<Value, any Error>
        do {
          try Task.checkCancellation()
          let value = try await operation(slot)
          try Task.checkCancellation()
          result = .success(value)
        } catch {
          result = .failure(error)
        }
        await self.finish(id, slot: slot, result: result)
      }
    }
  }

  private func finish(_ id: UUID, slot: Int, result: Result<Value, any Error>) {
    guard let job = jobs.removeValue(forKey: id) else { return }
    if currentJobs[job.key] == id { currentJobs.removeValue(forKey: job.key) }
    if runningSlots[slot] == id { runningSlots.removeValue(forKey: slot) }
    for waiter in job.waiters.values {
      if waiter.cancellation.isCancelled {
        waiter.continuation.resume(throwing: CancellationError())
      } else {
        waiter.continuation.resume(with: result)
      }
    }
    startPendingJobs()
  }
}
