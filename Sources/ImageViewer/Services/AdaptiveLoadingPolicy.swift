import Foundation

enum ImageStorageKind: String, Codable, Sendable {
  case internalSSD
  case external
  case removable
  case network
  case unknown
}

enum ImageResourcePressure: Int, Codable, Sendable {
  case normal
  case warning
  case critical
}

enum ImageThermalLevel: Int, Codable, Sendable {
  case nominal
  case fair
  case serious
  case critical
}

/// Measurements are supplied by a separate monitor; policy tests need no host state.
struct ImageResourceSnapshot: Equatable, Codable, Sendable {
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

enum ImageExecutionPriority: String, Codable, Sendable {
  case userInitiated
  case utility
  case background
}

struct ImageResourceLimits: Equatable, Codable, Sendable {
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
  static func limits(mode: ImageLoadingMode, snapshot: ImageResourceSnapshot,
    storage: ImageStorageKind) -> ImageResourceLimits {
    // Hardware observations stay native; Rust owns the complete adaptive budget policy.
    // If an unexpected ABI failure occurs, one visible load with no caches is safe.
    (try? RustImageEngine.limits(mode: mode, snapshot: snapshot, storage: storage))
      ?? ImageResourceLimits(totalConcurrentLoads: 1, renderCacheBytes: 0,
        thumbnailCacheBytes: 0, prefetchCount: 0, prefetchDelayMilliseconds: 1_000,
        visibleTaskPriority: .background, permitsSpeculation: false,
        interLoadDelayMilliseconds: 150)
  }
}
