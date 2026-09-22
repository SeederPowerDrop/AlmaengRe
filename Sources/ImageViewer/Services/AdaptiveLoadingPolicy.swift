import Foundation

enum ImageStorageKind: String, Sendable {
  case internalSSD
  case external
  case removable
  case network
  case unknown
}

enum ImageResourcePressure: Int, Sendable {
  case normal
  case warning
  case critical
}

enum ImageThermalLevel: Int, Sendable {
  case nominal
  case fair
  case serious
  case critical
}

/// Measurements are supplied by a separate monitor; policy tests need no host state.
struct ImageResourceSnapshot: Equatable, Sendable {
  var physicalMemory: UInt64
  var activeProcessorCount: Int
  var appleSilicon: Bool
  var isAppActive: Bool
  var lowPowerMode: Bool
  var thermal: ImageThermalLevel
  var memoryPressure: ImageResourcePressure
  /// Overall sampled CPU load, including this app, after monitor hysteresis.
  var cpuBusyFraction: Double?

  init(
    physicalMemory: UInt64,
    activeProcessorCount: Int,
    appleSilicon: Bool,
    isAppActive: Bool = true,
    lowPowerMode: Bool = false,
    thermal: ImageThermalLevel = .nominal,
    memoryPressure: ImageResourcePressure = .normal,
    cpuBusyFraction: Double? = nil
  ) {
    self.physicalMemory = physicalMemory
    self.activeProcessorCount = activeProcessorCount
    self.appleSilicon = appleSilicon
    self.isAppActive = isAppActive
    self.lowPowerMode = lowPowerMode
    self.thermal = thermal
    self.memoryPressure = memoryPressure
    self.cpuBusyFraction = cpuBusyFraction
  }

  /// Initial hardware facts only. The monitor supplies live pressure, CPU and app state.
  static var currentHardware: Self {
    let process = ProcessInfo.processInfo
    let thermal: ImageThermalLevel
    switch process.thermalState {
    case .nominal: thermal = .nominal
    case .fair: thermal = .fair
    case .serious: thermal = .serious
    case .critical: thermal = .critical
    @unknown default: thermal = .serious
    }
    #if arch(arm64)
      let appleSilicon = true
    #else
      let appleSilicon = false
    #endif
    return Self(
      physicalMemory: process.physicalMemory,
      activeProcessorCount: process.activeProcessorCount,
      appleSilicon: appleSilicon,
      lowPowerMode: process.isLowPowerModeEnabled,
      thermal: thermal
    )
  }
}

enum ImageExecutionPriority: Sendable {
  case userInitiated
  case utility
  case background
}

struct ImageResourceLimits: Equatable, Sendable {
  /// One combined budget for precise decodes, thumbnail generation and prefetch.
  var totalConcurrentLoads: Int
  var renderCacheBytes: Int
  var thumbnailCacheBytes: Int
  var prefetchCount: Int
  var prefetchDelayMilliseconds: Int
  var visibleTaskPriority: ImageExecutionPriority
  var permitsSpeculation: Bool
  var interLoadDelayMilliseconds: Int
}

/// Conservative heuristics, not a claim to reserve CPU cores or bound codec workspace.
/// Pixel/detail policy remains independent: contention changes scheduling and caching.
enum AdaptiveLoadingPolicy {
  private static let mebibyte: UInt64 = 1_024 * 1_024
  private static let gibibyte: UInt64 = 1_024 * 1_024 * 1_024

  static func limits(
    mode: ImageLoadingMode,
    snapshot: ImageResourceSnapshot,
    storage: ImageStorageKind
  ) -> ImageResourceLimits {
    let coreCount = max(1, snapshot.activeProcessorCount)
    let memoryConcurrency = snapshot.physicalMemory >= 16 * gibibyte ? 4
      : snapshot.physicalMemory >= 8 * gibibyte ? 2 : 1
    let aggressiveConcurrency = min(
      snapshot.appleSilicon ? 4 : 2, max(1, coreCount / 2), memoryConcurrency)
    let gentleConcurrency = min(
      snapshot.appleSilicon ? 2 : 1, max(1, coreCount / 4),
      snapshot.physicalMemory >= 16 * gibibyte ? 2 : 1)

    var result: ImageResourceLimits
    switch mode {
    case .priority:
      result = ImageResourceLimits(
        totalConcurrentLoads: aggressiveConcurrency,
        renderCacheBytes: cacheBytes(256, memory: snapshot.physicalMemory, fraction: 64),
        thumbnailCacheBytes: cacheBytes(128, memory: snapshot.physicalMemory, fraction: 128),
        prefetchCount: 4, prefetchDelayMilliseconds: 150,
        visibleTaskPriority: .userInitiated, permitsSpeculation: true,
        interLoadDelayMilliseconds: 0)
    case .comfortable:
      result = ImageResourceLimits(
        totalConcurrentLoads: gentleConcurrency,
        renderCacheBytes: cacheBytes(128, memory: snapshot.physicalMemory, fraction: 128),
        thumbnailCacheBytes: cacheBytes(64, memory: snapshot.physicalMemory, fraction: 256),
        prefetchCount: 2, prefetchDelayMilliseconds: 350,
        visibleTaskPriority: .utility, permitsSpeculation: true,
        interLoadDelayMilliseconds: 0)
    case .normal:
      result = ImageResourceLimits(
        totalConcurrentLoads: 1,
        renderCacheBytes: cacheBytes(96, memory: snapshot.physicalMemory, fraction: 160),
        thumbnailCacheBytes: cacheBytes(48, memory: snapshot.physicalMemory, fraction: 320),
        prefetchCount: 1, prefetchDelayMilliseconds: 650,
        visibleTaskPriority: .utility, permitsSpeculation: true,
        interLoadDelayMilliseconds: 25)
    case .slow:
      result = ImageResourceLimits(
        totalConcurrentLoads: 1,
        renderCacheBytes: cacheBytes(64, memory: snapshot.physicalMemory, fraction: 256),
        thumbnailCacheBytes: cacheBytes(32, memory: snapshot.physicalMemory, fraction: 512),
        prefetchCount: 0, prefetchDelayMilliseconds: 1_000,
        visibleTaskPriority: .background, permitsSpeculation: false,
        interLoadDelayMilliseconds: 100)
    }

    switch storage {
    case .internalSSD:
      break
    case .external:
      result.totalConcurrentLoads = min(2, result.totalConcurrentLoads)
      result.prefetchCount = min(1, result.prefetchCount)
      result.prefetchDelayMilliseconds = max(600, result.prefetchDelayMilliseconds)
    case .removable, .network, .unknown:
      result.totalConcurrentLoads = 1
      result.prefetchCount = 0
      result.interLoadDelayMilliseconds = max(40, result.interLoadDelayMilliseconds)
    }

    // A negative, missing or nonfinite sample is unavailable, not evidence of overload.
    let cpuBusy = snapshot.cpuBusyFraction.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0
    if snapshot.thermal == .fair {
      result.totalConcurrentLoads = min(2, result.totalConcurrentLoads)
      result.prefetchCount = min(1, result.prefetchCount)
      result.prefetchDelayMilliseconds = max(600, result.prefetchDelayMilliseconds)
      if result.visibleTaskPriority == .userInitiated { result.visibleTaskPriority = .utility }
    }
    if cpuBusy >= 0.65 {
      result.totalConcurrentLoads = min(2, result.totalConcurrentLoads)
      result.prefetchCount = 0
      if result.visibleTaskPriority == .userInitiated { result.visibleTaskPriority = .utility }
    }

    let mustYield = !snapshot.isAppActive || snapshot.lowPowerMode
      || snapshot.thermal.rawValue >= ImageThermalLevel.serious.rawValue
      || snapshot.memoryPressure != .normal || cpuBusy >= 0.8
    if mustYield {
      result.totalConcurrentLoads = 1
      result.prefetchCount = 0
      result.prefetchDelayMilliseconds = max(1_000, result.prefetchDelayMilliseconds)
      result.interLoadDelayMilliseconds = max(60, result.interLoadDelayMilliseconds)
      if result.visibleTaskPriority == .userInitiated { result.visibleTaskPriority = .utility }
    }
    if !snapshot.isAppActive {
      result.visibleTaskPriority = .background
    }

    // Cached images can be reconstructed. Reclaim them before taking RAM from other apps.
    if snapshot.memoryPressure == .critical {
      result.renderCacheBytes = 0
      result.thumbnailCacheBytes = 0
      result.interLoadDelayMilliseconds = max(150, result.interLoadDelayMilliseconds)
    } else if snapshot.memoryPressure == .warning || !snapshot.isAppActive {
      result.renderCacheBytes /= 4
      result.thumbnailCacheBytes /= 4
    }
    if snapshot.thermal == .critical {
      result.visibleTaskPriority = .background
      result.interLoadDelayMilliseconds = max(150, result.interLoadDelayMilliseconds)
    }

    result.permitsSpeculation = result.prefetchCount > 0
    return result
  }

  private static func cacheBytes(_ maximumMiB: UInt64, memory: UInt64, fraction: UInt64) -> Int {
    Int(min(maximumMiB * mebibyte, memory / fraction))
  }
}
