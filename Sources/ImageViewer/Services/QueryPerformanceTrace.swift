import Foundation

/// Opt-in, bounded in-memory timings. No paths, filenames or image data are
/// recorded, and no file I/O runs inside the measured work.
final class QueryPerformanceTrace: @unchecked Sendable {
  struct Event: Codable, Sendable {
    let stage: String
    let startedUptime: Double
    let wallSeconds: Double
    let synchronous: Bool
    let endedOnMainThread: Bool
    let count: Int?
  }

  static let enabled = ProcessInfo.processInfo.environment["IMAGEVIEWER_QUERY_PROFILE"] == "1"
  private static let shared = QueryPerformanceTrace()
  private let lock = NSLock()
  private var events: [Event] = []

  static func start() -> Double {
    enabled ? ProcessInfo.processInfo.systemUptime : 0
  }

  static func record(_ stage: String, since started: Double, count: Int? = nil,
    synchronous: Bool = false) {
    guard enabled else { return }
    let event = Event(stage: stage, startedUptime: started,
      wallSeconds: max(0, ProcessInfo.processInfo.systemUptime - started),
      synchronous: synchronous, endedOnMainThread: Thread.isMainThread, count: count)
    shared.lock.lock()
    defer { shared.lock.unlock() }
    if shared.events.count < 20_000 { shared.events.append(event) }
  }

  static func measure<T>(_ stage: String, count: Int? = nil, _ work: () throws -> T) rethrows -> T {
    // Resource-policy calls can occur thousands of times while scrolling. They
    // are outside this query profile and must not consume its bounded ledger.
    guard enabled, !stage.hasPrefix("ffi.other.") else { return try work() }
    let started = start()
    defer { record(stage, since: started, count: count, synchronous: true) }
    return try work()
  }

  static func snapshot(since started: Double) -> [Event]? {
    guard enabled else { return nil }
    shared.lock.lock()
    defer { shared.lock.unlock() }
    return shared.events.filter { $0.startedUptime >= started }
  }

  static func reset() {
    guard enabled else { return }
    shared.lock.lock()
    defer { shared.lock.unlock() }
    shared.events.removeAll(keepingCapacity: true)
  }
}
