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

enum ImageResourceWorkload: Equatable, Sendable {
  case source
  /// Read still-image properties/headers, with no bitmap generation fallback.
  /// Keep the shared slot and pressure limits without full-decode pacing.
  case metadataHeader
  /// Only restore an existing thumbnail PNG; never fall through to source decoding.
  case cachedThumbnail
  /// A compact overview job already waited through its dedicated adaptive policy.
  /// It still uses the shared worker and idle-work admission checks.
  case overviewPreview

  func pacingDelayMilliseconds(_ plannedDelay: Int) -> Int {
    switch self {
    case .source: plannedDelay
    case .metadataHeader, .cachedThumbnail, .overviewPreview: 0
    }
  }
}

/// The app has ONE execution budget for ImageIO, metadata and Quick Look combined.
/// Limits adjust while work is queued. A native decoder keeps its slot until it returns.
actor ImageResourceGovernor {
  private struct OverviewWarmDurationKey: Hashable {
    let storage: ImageStorageKind
    let workKind: OverviewWarmWorkKind
  }

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
  private let monitorsMemoryPressure: Bool
  private let scheduler = ImageWorkScheduler<ImageResourceWorkKey, ImageResourceResult>(
    maxConcurrentTasks: 4)
  private var requests: [ImageResourceWorkKey: Request] = [:]
  private var activeOperations: [UUID: ImageStorageKind] = [:]
  private var schedulingRevision: UInt64 = 0
  private var resourceRevision: UInt64 = 0
  private var clients: [UUID: @Sendable (ImageResourceUpdate) async -> Void] = [:]
  private var pressureMonitor: ImageMemoryPressureMonitor?
  private var overviewWarmDurationEstimates: [OverviewWarmDurationKey: Double] = [:]

  init(
    mode: ImageLoadingMode = .comfortable,
    snapshot: ImageResourceSnapshot = .currentHardware,
    storageOverride: ImageStorageKind? = nil,
    storageResolver: (@Sendable (URL) async -> ImageStorageKind)? = nil,
    maximumConcurrentLoadsOverride: Int? = nil,
    monitorsMemoryPressure: Bool = true
  ) {
    self.mode = mode
    self.snapshot = snapshot
    self.storageOverride = storageOverride
    self.storageResolver = storageResolver
    self.maximumConcurrentLoadsOverride = maximumConcurrentLoadsOverride
    self.monitorsMemoryPressure = monitorsMemoryPressure
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

  /// One compact, disk-only worker can continue with adaptive pacing while the
  /// app is inactive. Critical pressure, serious heat and power-saving choices
  /// still pause it; ordinary CPU contention and warnings increase the interval.
  func overviewWarmDelay(for url: URL,
    workKind: OverviewWarmWorkKind = .sourceFallback) async -> Int? {
    let storage = await storageKind(for: url)
    let key = OverviewWarmDurationKey(storage: storage, workKind: workKind)
    return OverviewWarmPacingPolicy.delayMilliseconds(mode: mode, snapshot: snapshot,
      storage: storage, estimatedWorkSeconds: overviewWarmDurationEstimates[key] ?? 0,
      workKind: workKind)
  }

  /// Called inside the governed operation around native decode plus PNG work,
  /// excluding both scheduler queue time and the adaptive inter-item sleep.
  func recordOverviewWarmDuration(_ seconds: Double, for url: URL,
    workKind: OverviewWarmWorkKind = .sourceFallback) async {
    guard seconds.isFinite, seconds >= 0 else { return }
    let storage = await storageKind(for: url)
    let key = OverviewWarmDurationKey(storage: storage, workKind: workKind)
    let observed = min(10, seconds)
    if let previous = overviewWarmDurationEstimates[key] {
      // React immediately to a costly RAW, then decay cautiously after cheaper
      // embedded previews instead of repeating bursts at the minimum interval.
      overviewWarmDurationEstimates[key] = max(observed, previous * 0.75 + observed * 0.25)
    } else {
      overviewWarmDurationEstimates[key] = observed
    }
  }

  private func permitsIdleThumbnails(for storage: ImageStorageKind) -> Bool {
    OverviewWarmPacingPolicy.delayMilliseconds(mode: mode, snapshot: snapshot,
      storage: storage) != nil
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
    workload: ImageResourceWorkload = .source,
    operation: @escaping @Sendable (Int) async throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    beginMonitoringPressure()
    let storage = await storageKind(for: url)
    try Task.checkCancellation()
    if priority == .prefetch, !limits(for: storage).permitsSpeculation {
      throw CancellationError()
    }
    if priority == .idleThumbnail, !permitsIdleThumbnails(for: storage) {
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
          // Evaluate source pacing at execution time. Cache-only PNG restoration
          // retains this same worker slot and scheduling/pressure limits without
          // waiting through a delay intended for expensive source decoding.
          let delay = await self.executionDelay(for: storage, workload: workload)
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

  private func executionDelay(for storage: ImageStorageKind, workload: ImageResourceWorkload) -> Int {
    workload.pacingDelayMilliseconds(limits(for: storage).interLoadDelayMilliseconds)
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
      permitsPrefetch: base.permitsSpeculation,
      permitsIdleThumbnails: permitsIdleThumbnails(for: .internalSSD), revision: schedulingRevision)
  }

  private func notifyCacheClients() async {
    let update = ImageResourceUpdate(limits: limits(for: .internalSSD), revision: resourceRevision)
    for client in clients.values { await client(update) }
  }

  private func beginMonitoringPressure() {
    guard monitorsMemoryPressure, pressureMonitor == nil else { return }
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
