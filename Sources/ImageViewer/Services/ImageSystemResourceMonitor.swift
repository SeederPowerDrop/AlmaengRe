import AppKit
import Darwin
import Foundation

/// One inexpensive monitor shared by all image loading paths. Mutable state is
/// confined to `queue`; notification callbacks only enqueue work onto that queue.
/// CPU samples describe the entire machine, including this app, not other apps'
/// identities or process statistics. No polling of images or storage is involved.
final class ImageSystemResourceMonitor: @unchecked Sendable {
  private let queue = DispatchQueue(label: "ImageViewer.systemResources", qos: .utility)
  private let pressureSource: any DispatchSourceMemoryPressure
  private let timer: any DispatchSourceTimer
  private let handler: @Sendable (ImageResourceSnapshot) -> Void
  private var observers: [NSObjectProtocol] = []
  private var snapshot: ImageResourceSnapshot
  private var lastDeliveredSnapshot: ImageResourceSnapshot?
  private var previousCPUTicks: ImageCPUTicks?
  private var cpuFilter = ImageCPUActivityFilter()

  init(
    isAppActive: Bool = true,
    handler: @escaping @Sendable (ImageResourceSnapshot) -> Void
  ) {
    self.handler = handler
    snapshot = .currentHardware
    snapshot.isAppActive = isAppActive
    pressureSource = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: queue)
    timer = DispatchSource.makeTimerSource(queue: queue)

    pressureSource.setEventHandler { [weak self] in
      guard let self else { return }
      let event = self.pressureSource.data
      if event.contains(.critical) {
        self.snapshot.memoryPressure = .critical
      } else if event.contains(.warning) {
        self.snapshot.memoryPressure = .warning
      } else if event.contains(.normal) {
        self.snapshot.memoryPressure = .normal
      }
      self.deliverIfChanged()
    }
    timer.setEventHandler { [weak self] in self?.sampleSystem() }
    timer.schedule(deadline: .now() + 2, repeating: .seconds(2), leeway: .milliseconds(400))

    let center = NotificationCenter.default
    for name in [
      ProcessInfo.thermalStateDidChangeNotification,
      Notification.Name.NSProcessInfoPowerStateDidChange,
    ] {
      observers.append(center.addObserver(forName: name, object: nil, queue: nil) {
        [weak self] _ in
        self?.queue.async { [weak self] in self?.refreshPowerState() }
      })
    }
    for (name, active) in [
      (NSApplication.didBecomeActiveNotification, true),
      (NSApplication.didResignActiveNotification, false),
    ] {
      observers.append(center.addObserver(forName: name, object: nil, queue: nil) {
        [weak self] _ in
        self?.queue.async { [weak self] in
          guard let self else { return }
          self.snapshot.isAppActive = active
          self.deliverIfChanged()
        }
      })
    }

    // Enqueue the first callback only after all stored properties are initialized.
    // Starting the host tick baseline here gives the next timer a full interval.
    queue.async { [weak self] in
      guard let self else { return }
      self.previousCPUTicks = ImageCPUTicks.read()
      self.refreshPowerState()
    }
    pressureSource.resume()
    timer.resume()
  }

  deinit {
    pressureSource.cancel()
    timer.cancel()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  private func sampleSystem() {
    let ticks = ImageCPUTicks.read()
    let fraction = ticks.flatMap { current in
      previousCPUTicks.flatMap { current.busyFraction(since: $0) }
    }
    previousCPUTicks = ticks
    snapshot.cpuBusyFraction = cpuFilter.update(fraction)
    refreshPowerState()
  }

  private func refreshPowerState() {
    let processInfo = ProcessInfo.processInfo
    snapshot.lowPowerMode = processInfo.isLowPowerModeEnabled
    switch processInfo.thermalState {
    case .nominal: snapshot.thermal = .nominal
    case .fair: snapshot.thermal = .fair
    case .serious: snapshot.thermal = .serious
    case .critical: snapshot.thermal = .critical
    @unknown default: snapshot.thermal = .serious
    }
    deliverIfChanged()
  }

  private func deliverIfChanged() {
    guard snapshot != lastDeliveredSnapshot else { return }
    lastDeliveredSnapshot = snapshot
    handler(snapshot)
  }
}

/// Severe CPU contention requires two high samples (~4s); recovery requires three
/// healthy ones (~6s). Moderate contention can reduce prefetch immediately. The
/// returned fraction is an effective policy input with hysteresis, not a CPU meter.
struct ImageCPUActivityFilter {
  private(set) var isBusy = false
  private var highSamples = 0
  private var healthySamples = 0

  mutating func update(_ fraction: Double?) -> Double? {
    guard let fraction, fraction.isFinite, (0...1).contains(fraction) else {
      highSamples = 0
      healthySamples = 0
      return isBusy ? 0.8 : nil
    }
    if isBusy {
      healthySamples = fraction <= 0.6 ? healthySamples + 1 : 0
      if healthySamples >= 3 {
        isBusy = false
        highSamples = 0
        healthySamples = 0
      }
    } else {
      highSamples = fraction >= 0.8 ? highSamples + 1 : 0
      if highSamples >= 2 {
        isBusy = true
        highSamples = 0
        healthySamples = 0
      }
    }
    return isBusy ? max(0.8, fraction) : min(0.79, fraction)
  }
}

struct ImageCPUTicks {
  let user: UInt32
  let system: UInt32
  let idle: UInt32
  let nice: UInt32

  func busyFraction(since previous: ImageCPUTicks) -> Double? {
    // Host counters are UInt32 and may wrap on long-running machines.
    let busy = Double(user &- previous.user) + Double(system &- previous.system)
      + Double(nice &- previous.nice)
    let total = busy + Double(idle &- previous.idle)
    guard total > 0 else { return nil }
    return min(1, max(0, busy / total))
  }

  static func read() -> ImageCPUTicks? {
    var info = host_cpu_load_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return ImageCPUTicks(
      user: info.cpu_ticks.0, system: info.cpu_ticks.1,
      idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
  }
}
