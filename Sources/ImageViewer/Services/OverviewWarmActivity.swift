import Foundation

/// A finite user-requested preparation keeps running when its window is covered.
/// The lease may outlive a cancelled waiter while a native decoder still holds
/// its worker slot. Immutable ownership makes the Foundation token safe to carry
/// across those tasks; its final release is the only place that ends activity.
final class OverviewWarmActivity: @unchecked Sendable {
  private let processToken: (any NSObjectProtocol)?
  private let onEnd: (@Sendable () -> Void)?

  private init(processToken: any NSObjectProtocol) {
    self.processToken = processToken
    onEnd = nil
  }

  /// Tests observe lifecycle without changing process-wide activity assertions.
  init(onEnd: @escaping @Sendable () -> Void) {
    processToken = nil
    self.onEnd = onEnd
  }

  static func begin(options: ProcessInfo.ActivityOptions) -> OverviewWarmActivity {
    OverviewWarmActivity(processToken: ProcessInfo.processInfo.beginActivity(
      options: options, reason: "Preparing requested overview previews"))
  }

  deinit {
    if let processToken { ProcessInfo.processInfo.endActivity(processToken) }
    onEnd?()
  }
}
