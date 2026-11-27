import Foundation

/// Wakes the owning task only on cancellation, teardown or terminal failure.
/// Cancellation may arrive before the continuation is installed, on any thread.
final class VideoPlaybackMonitorLifetime: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, any Error>?
  private var result: Result<Void, any Error>?

  func wait() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if let result {
          lock.unlock()
          continuation.resume(with: result)
        } else {
          self.continuation = continuation
          lock.unlock()
        }
      }
    } onCancel: { self.finish(.failure(CancellationError())) }
  }

  func finish(_ result: Result<Void, any Error>) {
    lock.lock()
    guard self.result == nil else { lock.unlock(); return }
    self.result = result
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
  }
}
