import Foundation

/// Built outside the main actor. Legacy Dispatch handler blocks otherwise can
/// inherit an actor assertion even when their body creates a main-actor Task.
enum SustainedPressureCallback {
  static func make(_ receive: @escaping @MainActor @Sendable (ImageResourcePressure) -> Void)
    -> @Sendable (UInt) -> Void {
    { rawValue in
      let event = DispatchSource.MemoryPressureEvent(rawValue: rawValue)
      let level: ImageResourcePressure = event.contains(.critical) ? .critical
        : event.contains(.warning) ? .warning : .normal
      Task { @MainActor in receive(level) }
    }
  }
}
