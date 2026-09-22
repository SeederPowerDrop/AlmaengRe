import Foundation

/// Only immutable, Sendable keys enter this type erasure. A separate namespace per
/// pipeline/result type prevents accidental sharing between metadata and pixels.
struct ImageResourceWorkKey: Hashable, @unchecked Sendable {
  let namespace: UUID
  private let key: AnyHashable

  init<Key: Hashable & Sendable>(namespace: UUID, key: Key) {
    self.namespace = namespace
    self.key = AnyHashable(key)
  }
}

private struct ImageResourceResult: Sendable {
  let value: any Sendable
}

struct ImageResourceUpdate: Sendable {
  let limits: ImageResourceLimits
  let revision: UInt64
}

/// The app has ONE execution budget for ImageIO, metadata and Quick Look combined.
/// Limits adjust while work is queued. A native decoder keeps its slot until it returns.
actor ImageResourceGovernor {
  private struct Request {
    let storage: ImageStorageKind
    var waiters: Int
  }

  private var mode: ImageLoadingMode
  private var snapshot: ImageResourceSnapshot
  private let classifier: ImageStorageClassifier
  private let storageOverride: ImageStorageKind?
  private let storageResolver: (@Sendable (URL) async -> ImageStorageKind)?
  private let maximumConcurrentLoadsOverride: Int?
  private let scheduler = ImageWorkScheduler<ImageResourceWorkKey, ImageResourceResult>(
    maxConcurrentTasks: 4)
  private var requests: [ImageResourceWorkKey: Request] = [:]
  private var activeOperations: [UUID: ImageStorageKind] = [:]
  private var schedulingRevision: UInt64 = 0
  private var resourceRevision: UInt64 = 0
  private var clients: [UUID: @Sendable (ImageResourceUpdate) async -> Void] = [:]
  private var pressureMonitor: ImageMemoryPressureMonitor?

  init(
    mode: ImageLoadingMode = .comfortable,
    snapshot: ImageResourceSnapshot = .currentHardware,
    storageOverride: ImageStorageKind? = nil,
    storageResolver: (@Sendable (URL) async -> ImageStorageKind)? = nil,
    maximumConcurrentLoadsOverride: Int? = nil
  ) {
    self.mode = mode
    self.snapshot = snapshot
    self.storageOverride = storageOverride
    self.storageResolver = storageResolver
    self.maximumConcurrentLoadsOverride = maximumConcurrentLoadsOverride
    classifier = ImageStorageClassifier()
  }

  func setMode(_ mode: ImageLoadingMode) async {
    guard self.mode != mode else { return }
    self.mode = mode
    resourceRevision &+= 1
    await refreshScheduling()
    await notifyCacheClients()
  }

  func update(_ snapshot: ImageResourceSnapshot) async {
    guard self.snapshot != snapshot else { return }
    self.snapshot = snapshot
    resourceRevision &+= 1
    await refreshScheduling()
    await notifyCacheClients()
  }

  func limits(for url: URL) async -> ImageResourceLimits {
    let storage = await storageKind(for: url)
    return limits(for: storage)
  }

  func registerCacheClient(
    id: UUID, handler: @escaping @Sendable (ImageResourceUpdate) async -> Void
  ) async {
    clients[id] = handler
    beginMonitoringPressure()
    await handler(ImageResourceUpdate(limits: limits(for: .internalSSD), revision: resourceRevision))
  }

  func value<Value: Sendable>(
    for key: ImageResourceWorkKey, url: URL, priority: ImageWorkPriority = .visible,
    operation: @escaping @Sendable (Int) async throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    beginMonitoringPressure()
    let storage = await storageKind(for: url)
    try Task.checkCancellation()
    if priority == .prefetch, !limits(for: storage).permitsSpeculation {
      throw CancellationError()
    }
    if var request = requests[key] {
      request.waiters += 1
      requests[key] = request
    } else {
      requests[key] = Request(storage: storage, waiters: 1)
    }
    await refreshScheduling()
    let result: ImageResourceResult
    let executionID = UUID()
    do {
      result = try await scheduler.value(for: key, priority: priority) { slot in
        await self.operationStarted(executionID, storage: storage)
        do {
          // Evaluate pacing at execution time, not when a long queue was created.
          let delay = await self.executionDelay(for: storage)
          if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
          try Task.checkCancellation()
          let value = try await operation(slot)
          await self.operationFinished(executionID)
          return ImageResourceResult(value: value)
        } catch {
          await self.operationFinished(executionID)
          throw error
        }
      }
    } catch {
      await finishedWaiting(for: key)
      throw error
    }
    await finishedWaiting(for: key)
    try Task.checkCancellation()
    // A namespace is permanently bound to its operation's return type.
    guard let value = result.value as? Value else { preconditionFailure("Image resource result type mismatch") }
    return value
  }

  func stateSnapshot() async -> ImageWorkSchedulerState { await scheduler.stateSnapshot() }

  private func storageKind(for url: URL) async -> ImageStorageKind {
    if let storageOverride { return storageOverride }
    if let storageResolver { return await storageResolver(url) }
    return await classifier.storageKind(for: url)
  }

  private func limits(for storage: ImageStorageKind) -> ImageResourceLimits {
    var limits = AdaptiveLoadingPolicy.limits(mode: mode, snapshot: snapshot, storage: storage)
    if let maximumConcurrentLoadsOverride {
      limits.totalConcurrentLoads = min(limits.totalConcurrentLoads, max(1, maximumConcurrentLoadsOverride))
    }
    return limits
  }

  private func executionDelay(for storage: ImageStorageKind) -> Int {
    limits(for: storage).interLoadDelayMilliseconds
  }

  private func operationStarted(_ id: UUID, storage: ImageStorageKind) async {
    activeOperations[id] = storage
    await refreshScheduling()
  }

  private func operationFinished(_ id: UUID) async {
    activeOperations.removeValue(forKey: id)
    await refreshScheduling()
  }

  private func finishedWaiting(for key: ImageResourceWorkKey) async {
    if var request = requests[key] {
      request.waiters -= 1
      requests[key] = request.waiters > 0 ? request : nil
    }
    await refreshScheduling()
  }

  private func refreshScheduling() async {
    let base = limits(for: .internalSSD)
    // Mixed selections use the most conservative outstanding source's I/O limit.
    let waitingLimit = requests.values.reduce(base.totalConcurrentLoads) {
      min($0, limits(for: $1.storage).totalConcurrentLoads)
    }
    let concurrent = activeOperations.values.reduce(waitingLimit) {
      min($0, limits(for: $1).totalConcurrentLoads)
    }
    schedulingRevision &+= 1
    await scheduler.configure(
      concurrencyLimit: concurrent, executionPriority: base.visibleTaskPriority,
      permitsPrefetch: base.permitsSpeculation, revision: schedulingRevision)
  }

  private func notifyCacheClients() async {
    let update = ImageResourceUpdate(limits: limits(for: .internalSSD), revision: resourceRevision)
    for client in clients.values { await client(update) }
  }

  private func beginMonitoringPressure() {
    guard pressureMonitor == nil else { return }
    // Standalone exporters/tests can use a pipeline without an AppStore monitor.
    pressureMonitor = ImageMemoryPressureMonitor { [weak self] rawValue in
      Task { await self?.memoryPressureChanged(rawValue) }
    }
  }

  private func memoryPressureChanged(_ rawValue: UInt) async {
    let event = DispatchSource.MemoryPressureEvent(rawValue: rawValue)
    var updated = snapshot
    updated.memoryPressure = event.contains(.critical) ? .critical
      : event.contains(.warning) ? .warning : .normal
    await update(updated)
  }
}
