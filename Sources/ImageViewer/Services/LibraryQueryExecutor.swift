import Foundation

/// CPU-only queries share a small lane across the viewer and comparison panes.
/// Cancellation releases the caller immediately; a noninterruptible native call
/// retains its worker until it actually returns. Abandoned queued work never runs.
struct LibraryQueryExecutor: Sendable {
  static let shared = LibraryQueryExecutor()
  private struct Output: Sendable { let value: any Sendable }
  private let scheduler: ImageWorkScheduler<UUID, Output>
  let maximumConcurrentTasks: Int

  init(maxConcurrentTasks: Int = min(2, max(1, ProcessInfo.processInfo.activeProcessorCount / 4))) {
    maximumConcurrentTasks = max(1, maxConcurrentTasks)
    scheduler = ImageWorkScheduler(maxConcurrentTasks: maxConcurrentTasks)
  }

  func value<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
    let output = try await scheduler.value(for: UUID()) { _ in
      Output(value: try await operation())
    }
    // Each key is unique to this invocation and has exactly one return type.
    guard let value = output.value as? Value else { preconditionFailure("Invalid query result type") }
    return value
  }

  func stateSnapshot() async -> ImageWorkSchedulerState { await scheduler.stateSnapshot() }
}
