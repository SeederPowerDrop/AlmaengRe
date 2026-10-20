import AppKit
import Darwin
import Foundation

struct ReleaseOverviewDeadlineExceeded: Error { let phase: String }

/// Diagnostic start conditions are exact targets, never a maximum severity.
/// Ordinary runs keep the historical nominal requirement unless fair is explicit.
enum OverviewBenchmarkThermalTarget: Int, Sendable {
  case nominal = 0
  case fair = 1

  init?(environmentValue: String?) {
    switch environmentValue {
    case nil, "nominal": self = .nominal
    case "fair": self = .fair
    default: return nil
    }
  }

  func accepts(level: Int) -> Bool { level == rawValue }

  var name: String { self == .nominal ? "nominal" : "fair" }
  var progressStage: String { "waiting_comparable_native_idle_\(name)" }
  var timeoutFailurePhase: String { "comparable_native_idle_\(name)_start_timeout" }
  static let scope = "explicit_diagnostic_exact_start_thermal_target_nominal_or_fair_only_default_nominal_never_serious_or_critical"
}

struct ReleaseOverviewReport: Encodable {
  var runID = ""
  var status = "started"
  var mode = "automatic_background_preparation"
  var preparationMode = "cold_automatic_background"
  var resumeSourceRunID: String?
  var resumeSourceReportSHA256: String?
  var resumeCertificateSHA256: String?
  var fixtureManifestSHA256: String?
  var fixturePreviewManifestSHA256: String?
  var fixtureSourceMetadataSHA256: String?
  var fixtureCertificateSHA256: String?
  var fixtureProductSourceDigestSHA256: String?
  var fixtureMeasurementSourceDigestSHA256: String?
  var fixtureInitialDiskOnlyCompactVerified = false
  var fixtureInitialMemoryEmptyVerified = false
  var failurePhase = ""
  var sources = ReleaseOverviewSourceCounts(total: 0, nonempty: 0, nonemptyRAW: 0, empty: 0)
  var sourceSelection: OverviewBenchmarkSourceSelectionReport?
  var requestedPixelSize = 768
  var displayScale = 0.0
  var initialVisibleCount = 0
  var initialVisibleMinimum = -1
  var initialCache: ReleaseOverviewCacheReport?
  var afterPreparation: ReleaseOverviewCacheReport?
  var atEndCache: ReleaseOverviewCacheReport?
  var nativeStartCache: ReleaseOverviewCacheReport?
  var afterScrolls: ReleaseOverviewCacheReport?
  var filterValidation: ReleaseOverviewFilterValidationReport?
  var phases: [ReleaseOverviewPhaseReport] = []
  var scrolls: [ReleaseOverviewScrollReport] = []
  var samples: [ReleaseOverviewResourceSample] = []
  var sourceMetadataUnchanged = false
  var seedPreviewAssets = 0
  var newlyPreparedPreviewAssets = 0
  var preparationActivationSucceeded = false
  var nativeScrollActivationSucceeded = false
  var foregroundValidationComplete = false
  var visibleDemandPreparation: ReleaseOverviewVisiblePreparationReport?
  var nativeScrollAppWasActive = false
  var requiredStartThermalLevel = OverviewBenchmarkThermalTarget.nominal.rawValue
  let startThermalTargetScope = OverviewBenchmarkThermalTarget.scope
  var totalWallSeconds = 0.0
  var binaryIdentity: ReleaseOverviewBinaryIdentity?
  var coldDiskCacheVerified = false
  var runtimeCacheDirectory = ""
  var actualRootView = true
  var rootContentWidth = 0.0
  var rootContentHeight = 0.0
  var initialViewportWidth = 0.0
  var initialViewportHeight = 0.0
  var windowFrameWidth = 0.0
  var windowFrameHeight = 0.0
  var screenVisibleFrameWidth = 0.0
  var screenVisibleFrameHeight = 0.0
  var bitmapDisplayEvents: [ReleaseOverviewBitmapDisplayEvent] = []
  var bitmapDisplayScope = "actual_ThumbnailImageView_bitmap_State_assignment_and_next_naturally_observed_NSWindow_didUpdate_no_forced_layout_or_draw_not_physical_compositor_presentation"
  var existingInstanceProcessIDs: [Int32] = []
  var existingInstancesStillRunning: [Int32] = []
  var executableUnchangedAtEnd = false
  var initialVisibleRootWindowCount = 0
  var finalVisibleRootWindowCount = 0
  var applePersistenceIgnoreStateArgumentPresent = false
  let persistedThumbnailPixelsRetained = true
  let sourcePixelsExported = false
  let sourcePathsExported = false
  let cpuScope = "installed_release_process_getrusage_100_percent_equals_one_core"
  let systemCPUScope = "live_policy_filtered_whole_machine_fraction_not_app_GPU_usage"
  let firstPixelsScope = "separate_post_pass_cache_only_availability_for_unique_visible_assets_not_screen_paint_latency"
  let nativeScrollScope = "actual_marker_identified_RootView_overview_NSScrollView_at_least_79_equal_document_position_steps_per_direction_100ms_spacing_plus_async_visible_range_settle_no_per_step_forced_layout"
  let overviewScrollTargetScope = "unique_diagnostic_marker_enclosingScrollView_with_viewport_wider_than_half_RootView_not_largest_document"
  let resourcePolicyScope = "production_live_monitor_no_pressure_CPU_focus_or_power_overrides"
  let eventLoopScope = "installed_release_SwiftUI_App_real_AppKit_event_loop"
  let processID = getpid()
  var storageCacheScope = "fresh_app_disk_cache_OS_file_cache_and_QuickLook_cache_uncontrolled"
}

/// A common prepared cache is valid for different products. Each executable and
/// product-source digest is bound independently; no same-product claim is made.
struct PreparedOverviewFixtureCertificate: Codable {
  let schemaVersion: Int
  let fixtureManifestSHA256: String
  let sourceDirectory: String
  let destinationCacheDirectory: String
  let currentExecutableSHA256: String
  let productSourceDigestSHA256: String
  let measurementSourceDigestSHA256: String
  let sourceFileMetadataSHA256: String
  let sourceMetadataUnchangedSinceFixture: Bool
  let verifiedPNGCount: Int
  let uniqueSourceHashes: Int
  let pngCRCAndDimensionsVerified: Bool
  let sourceAndDestinationPreviewManifestsIdentical: Bool
  let compactPreviewBytes: Int

  func initialFailure(initialDisk: ThumbnailDiskCacheSnapshot, executableSHA256: String) -> String? {
    func digest(_ value: String) -> Bool {
      value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    guard schemaVersion == 1,
      [fixtureManifestSHA256, currentExecutableSHA256, productSourceDigestSHA256,
       measurementSourceDigestSHA256, sourceFileMetadataSHA256].allSatisfy(digest)
      else { return "prepared_fixture_invalid_certificate_digest_or_version" }
    guard currentExecutableSHA256 == executableSHA256 else { return "prepared_fixture_executable_mismatch" }
    guard sourceMetadataUnchangedSinceFixture else { return "prepared_fixture_source_metadata_not_verified" }
    guard verifiedPNGCount == 717, uniqueSourceHashes == 717, pngCRCAndDimensionsVerified,
      sourceAndDestinationPreviewManifestsIdentical,
      compactPreviewBytes > 0, compactPreviewBytes <= 128 * 1_024 * 1_024
      else { return "prepared_fixture_PNG_certificate_invalid" }
    guard initialDisk.entryCount == 717, initialDisk.exactBytes == 0,
      initialDisk.previewBytes == compactPreviewBytes, initialDisk.byteCount == compactPreviewBytes
      else { return "prepared_fixture_initial_disk_must_be_only_717_compact_previews" }
    return nil
  }
}

struct PreparedOverviewFixtureManifest: Decodable {
  struct Preview: Decodable {
    let relativePath: String
    let bytes: Int
    let sha256: String
    let width: Int
    let height: Int
  }
  struct SourceMetadata: Decodable {
    let algorithm: String
    let fileCount: Int
    let files: [File]
    let sha256: String
    struct File: Decodable {
      let pathSHA256: String
      let sizeBytes: Int64
      let mtimeNanoseconds: Int64
    }
  }
  let schemaVersion: Int
  let cacheAlgorithmVersion: Int
  let previews: [Preview]
  let previewManifestSHA256: String
  let compactPreviewBytes: Int
  let sourceMetadata: SourceMetadata
}

struct ReleaseOverviewVisiblePreparationReport: Encodable {
  let nativeViewports: Int
  let uniqueNonemptyVisibleAssets: Int
  let wallSeconds: Double
  let sourceDemandScope = "test_only_moves_production_viewports_no_explicit_pipeline_decode_prefetch_or_bitmap_probe_requests"
  let focusScope = "actual_active_fraction_and_foreground_bundle_counts_in_preparation_phase"
}

struct ReleaseOverviewSourceCounts: Encodable {
  let total: Int
  let nonempty: Int
  let nonemptyRAW: Int
  let empty: Int
}

struct ReleaseOverviewCacheReport: Encodable {
  let memoryEntries: Int
  let memoryBytes: Int
  let memoryLimit: Int
  let diskEntries: Int
  let diskBytes: Int
  let diskLimit: Int
  let diskPreviewBytes: Int
  let diskExactBytes: Int
  let diskHits: UInt64
  let diskMisses: UInt64
  let previewCoveredAssets: Int
  let exactCoveredAssets: Int
  let runningLoads: Int
  let queuedLoads: Int
}

struct ReleaseOverviewProgress: Encodable {
  let stage: String
  let elapsedSeconds: Double
  let totalAssets: Int
  let isPreparing: Bool
  let visibleCount: Int
  let appIsActive: Bool
  let windowVisible: Bool
  let windowOcclusionVisible: Bool
  let cache: ReleaseOverviewCacheReport
  let latestSample: ReleaseOverviewResourceSample?
}

struct ReleaseOverviewScrollReport: Encodable {
  let name: String
  var nativeBitmapVisits: OverviewBitmapVisitReport?
  var nativeScrollSteps = 0
  var uniqueVisibleCount = 0
  var maximumVisibleCount = 0
  var finalVisibleMinimum = -1
  var finalVisibleMaximum = -1
  var cacheFirstPixelMisses = 0
  var cacheFirstPixels = ReleaseOverviewLatencyReport(values: [])
  var actualUICachedPreview: ReleaseOverviewUICachedPreviewReport?
  var startPosition = 0.0
  var endPosition = 0.0
  var wallSeconds = 0.0
}

/// Optional normal-library-query observations begin only after the original
/// cold/native/cache-probe results have been fixed. No source pixels are read
/// by the oracle, and no filenames, metadata values or source URLs are exported.
struct ReleaseOverviewFilterValidationReport: Encodable {
  var status = "started"
  var failurePhase = ""
  var originalQuery = LibraryQuery()
  var originalAssetCount = 0
  var firstMetadataQueryHadNoPreparedAssetFields = false
  var metadataAssetFieldsBeforeFirstQuery = 0
  var metadataAssetFieldsBeforeRepeat = 0
  var metadataVersionsRetainedBeforeRepeat = false
  var queryRestored = false
  var folderRestored = false
  var originalOrderedCollectionRestored = false
  var foregroundValidationComplete = false
  var afterFilters: ReleaseOverviewCacheReport?
  var steps: [ReleaseOverviewFilterStepReport] = []
  let measurementScope = "opt_in_after_completed_native_roundtrip_normal_AppStore_libraryQuery_real_RootView_no_forced_layout_or_bitmap_probe"
  let queryLatencyScope = "libraryQuery_assignment_to_isFiltering_false_and_new_libraryRevision_includes_normal_100ms_debounce_observed_at_100ms_poll_resolution"
  let oracleScope = "post_phase_RustImageEngine_query_on_same_committed_allAssets_no_metadata_pre_read_ordered_URL_equality_only_digests_exported"
  let metadataCacheScope = "first_query_and_second_identical_query_after_restore_report_existing_asset_metadata_and_versions_no_claim_of_OS_cold_cache_or_instrumented_reader_call_count"
  let bitmapScope = "actual_ThumbnailImageView_cachedPreview_returns_and_bitmap_State_callbacks_retained_cells_may_require_no_new_callback_not_physical_screen_paint"
}

struct ReleaseOverviewFilterStepReport: Encodable {
  let name: String
  let query: LibraryQuery
  let metadataReadExpectation: String
  var status = "started"
  var failurePhase = ""
  var queryCompletionWallSeconds = 0.0
  var postQueryViewportSettleSeconds = 0.0
  var expectedCount = 0
  var actualCount = 0
  var allAssetCount = 0
  var expectedOriginalOrderSHA256 = ""
  var actualOriginalOrderSHA256 = ""
  var orderedResultMatchesOracle = false
  var selectedCountBefore = 0
  var selectedCountAfter = 0
  var expectedRetainedSelectedCount = 0
  var selectedURLsMatchExpectedIntersection = false
  var focusRetainedWhenPresent = false
  var currentIndexIsValid = false
  var metadataAssetFieldsBefore = 0
  var metadataAssetFieldsAfter = 0
  var metadataSearchValuePresentCount = 0
  var metadataQueryMatchCount = 0
  var visibleCount = 0
  var visibleMinimum = -1
  var visibleMaximum = -1
  var viewportWiderThanHalfRoot = false
  var visibleRootWindowCount = 0
  var actualUICachedPreview: ReleaseOverviewUICachedPreviewReport?
  var firstBitmapStateCallbacks = 0
  var firstBitmapStateLatencies = ReleaseOverviewLatencyReport(values: [])
  var resources: ReleaseOverviewPhaseReport?
  var queryPerformanceEvents: [QueryPerformanceTrace.Event]?
}

struct ReleaseOverviewUICachedPreviewReport: Encodable {
  let recordedRequests: Int
  let totalNonemptyAssets: Int
  let passEligibleVisibleAssets: Int
  let eligibleRecordedRequests: Int
  let excludedEmptyOrOtherAssetRequests: Int
  let uncancelledHits: Int
  let uncancelledMisses: Int
  let cancelledRequests: Int
  let uniqueNonemptyAttemptedAssets: Int
  let uniqueNonemptyHitAssets: Int
  let uniqueNonemptyMissAssets: Int
  let uniqueNonemptyCancelledAssets: Int
  let uniqueVisibleNonemptyHitAssets: Int
  let hitLatencies: ReleaseOverviewLatencyReport
  let completedRequestLatencies: ReleaseOverviewLatencyReport
  let ledgerMayHaveReachedLimit: Bool
  let measurementScope = "actual_ThumbnailImageView_cachedPreview_entry_to_CGImage_return_including_pipeline_queue_not_screen_paint"
  let coverageScope = "already_displayed_or_retained_cells_may_show_without_a_new_pipeline_call"
}

struct ReleaseOverviewLatencyReport: Encodable {
  let count: Int
  let p50Seconds: Double
  let p95Seconds: Double
  let maximumSeconds: Double

  init(values: [Double]) {
    let sorted = values.sorted()
    count = sorted.count
    p50Seconds = releaseOverviewPercentile(sorted, fraction: 0.5)
    p95Seconds = releaseOverviewPercentile(sorted, fraction: 0.95)
    maximumSeconds = sorted.last ?? 0
  }
}

struct ReleaseOverviewResourceSample: Encodable {
  let uptime: Double
  let intervalSeconds: Double
  let cpuPercentOneCore: Double
  let footprintBytes: UInt64
  let residentBytes: UInt64
  let lifetimePeakFootprintBytes: UInt64
  let lifetimePeakResidentBytes: Int64
  let appIsActive: Bool
  let windowVisible: Bool
  let windowOcclusionVisible: Bool
  let foregroundBundleID: String
  let foregroundProcessID: Int32
  let foregroundIsOtherProcess: Bool
  let systemCPUAvailable: Bool
  let systemCPUBusyFraction: Double
  let memoryPressure: Int
  let thermalLevel: Int
  let lowPowerMode: Bool
}

struct ReleaseOverviewPhaseReport: Encodable {
  let name: String
  let wallSeconds: Double
  let startedUptime: Double
  let endedUptime: Double
  let processCPUSeconds: Double
  let averageCPUPercentOneCore: Double
  let sampledCPUPercentOneCoreP95: Double
  let sampleCount: Int
  let inactiveSampleFraction: Double
  let otherForegroundSampleFraction: Double
  let foregroundBundleIDCounts: [String: Int]
  let footprintMinimumBytes: UInt64
  let footprintMaximumBytes: UInt64
  let footprintEndBytes: UInt64
  let heartbeatSamples: Int
  let heartbeatGapP95Seconds: Double
  let heartbeatGapMaximumSeconds: Double
  let warningMemorySamples: Int
  let criticalMemorySamples: Int
}

@MainActor
final class ReleaseOverviewResourceSampler {
  struct Phase {
    let name: String
    let started: Double
    let cpuStarted: Double
    let firstSample: Int
    let firstHeartbeat: Int
  }

  private(set) var samples: [ReleaseOverviewResourceSample] = []
  weak var observedWindow: NSWindow?
  private var heartbeatGaps: [Double] = []
  private var task: Task<Void, Never>?
  private var heartbeat: Task<Void, Never>?
  private var monitor: ImageSystemResourceMonitor?
  private var resources = ImageResourceSnapshot.currentHardware
  private var previousUsage: (uptime: Double, cpuSeconds: Double)?

  func start() {
    monitor = ImageSystemResourceMonitor(isAppActive: NSApp.isActive) { [weak self] snapshot in
      Task { @MainActor in self?.resources = snapshot }
    }
    sample()
    task = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        self?.sample()
      }
    }
    heartbeat = Task { @MainActor [weak self] in
      var previous = ProcessInfo.processInfo.systemUptime
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
        let now = ProcessInfo.processInfo.systemUptime
        self?.heartbeatGaps.append(max(0, now - previous - 0.016))
        previous = now
      }
    }
  }

  func stop() {
    task?.cancel()
    heartbeat?.cancel()
    task = nil
    heartbeat = nil
    monitor = nil
  }

  func beginPhase(_ name: String) -> Phase {
    sample()
    return Phase(name: name, started: ProcessInfo.processInfo.systemUptime,
      cpuStarted: processUsage().cpuSeconds, firstSample: samples.count,
      firstHeartbeat: heartbeatGaps.count)
  }

  func endPhase(_ phase: Phase) -> ReleaseOverviewPhaseReport {
    sample()
    let wall = max(0.000_001, ProcessInfo.processInfo.systemUptime - phase.started)
    let cpu = max(0, processUsage().cpuSeconds - phase.cpuStarted)
    let observations = Array(samples.dropFirst(phase.firstSample))
    let gaps = Array(heartbeatGaps.dropFirst(phase.firstHeartbeat)).sorted()
    let cpuValues = observations.filter { $0.intervalSeconds >= 0.5 }.map(\.cpuPercentOneCore).sorted()
    var bundles: [String: Int] = [:]
    for observation in observations { bundles[observation.foregroundBundleID, default: 0] += 1 }
    let denominator = Double(max(1, observations.count))
    return ReleaseOverviewPhaseReport(name: phase.name, wallSeconds: wall, startedUptime: phase.started,
      endedUptime: ProcessInfo.processInfo.systemUptime, processCPUSeconds: cpu,
      averageCPUPercentOneCore: cpu / wall * 100,
      sampledCPUPercentOneCoreP95: releaseOverviewPercentile(cpuValues, fraction: 0.95),
      sampleCount: observations.count,
      inactiveSampleFraction: Double(observations.filter { !$0.appIsActive }.count) / denominator,
      otherForegroundSampleFraction: Double(observations.filter(\.foregroundIsOtherProcess).count) / denominator,
      foregroundBundleIDCounts: bundles,
      footprintMinimumBytes: observations.map(\.footprintBytes).min() ?? 0,
      footprintMaximumBytes: observations.map(\.footprintBytes).max() ?? 0,
      footprintEndBytes: observations.last?.footprintBytes ?? 0,
      heartbeatSamples: gaps.count, heartbeatGapP95Seconds: releaseOverviewPercentile(gaps, fraction: 0.95),
      heartbeatGapMaximumSeconds: gaps.last ?? 0,
      warningMemorySamples: observations.filter { $0.memoryPressure == ImageResourcePressure.warning.rawValue }.count,
      criticalMemorySamples: observations.filter { $0.memoryPressure == ImageResourcePressure.critical.rawValue }.count)
  }

  private func sample() {
    let now = ProcessInfo.processInfo.systemUptime
    let process = processUsage()
    let footprint = footprintUsage()
    let cpu: Double
    let interval: Double
    if let previousUsage, now > previousUsage.uptime + 0.000_001 {
      interval = now - previousUsage.uptime
      cpu = max(0, process.cpuSeconds - previousUsage.cpuSeconds) / interval * 100
    } else {
      cpu = 0
      interval = 0
    }
    previousUsage = (now, process.cpuSeconds)
    let frontmost = NSWorkspace.shared.frontmostApplication
    samples.append(ReleaseOverviewResourceSample(uptime: now, intervalSeconds: interval, cpuPercentOneCore: cpu,
      footprintBytes: footprint.current, residentBytes: footprint.resident,
      lifetimePeakFootprintBytes: footprint.peak, lifetimePeakResidentBytes: process.peakResidentBytes,
      appIsActive: NSApp.isActive, windowVisible: observedWindow?.isVisible ?? false,
      windowOcclusionVisible: observedWindow?.occlusionState.contains(.visible) ?? false,
      foregroundBundleID: frontmost?.bundleIdentifier ?? "unavailable",
      foregroundProcessID: frontmost?.processIdentifier ?? -1,
      foregroundIsOtherProcess: frontmost.map { $0.processIdentifier != getpid() } ?? false,
      systemCPUAvailable: resources.cpuBusyFraction != nil,
      systemCPUBusyFraction: resources.cpuBusyFraction ?? 0,
      memoryPressure: resources.memoryPressure.rawValue, thermalLevel: resources.thermal.rawValue,
      lowPowerMode: resources.lowPowerMode))
  }

  private func processUsage() -> (cpuSeconds: Double, peakResidentBytes: Int64) {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return (0, 0) }
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    return (user + system, Int64(usage.ru_maxrss))
  }

  private func footprintUsage() -> (current: UInt64, resident: UInt64, peak: UInt64) {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
      }
    }
    guard result == 0 else { return (0, 0, 0) }
    return (usage.ri_phys_footprint, usage.ri_resident_size, usage.ri_lifetime_max_phys_footprint)
  }
}

func releaseOverviewPercentile(_ sorted: [Double], fraction: Double) -> Double {
  guard !sorted.isEmpty else { return 0 }
  return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))]
}

struct ReleaseOverviewBinaryIdentity: Encodable {
  let processID: Int32
  let executablePath: String
  let executableSHA256: String
  let bundleIdentifier: String
  let appVersion: String
  let appBuild: String
  let compiledWithDebugConfiguration: Bool
  let executionScope: String
}

struct ReleaseOverviewBitmapDisplayEvent: Encodable {
  let phase: String
  let assetIndex: Int
  let requestStartedUptime: Double
  let stateAppliedUptime: Double
  var nextNativeWindowUpdateObservedUptime: Double?
  let pixelWidth: Int
  let pixelHeight: Int
  let isRefinement: Bool
  let visibleAtStateApplication: Bool
  var visibleAtWindowUpdate: Bool
  var appActiveAtWindowUpdate: Bool
  var windowOcclusionVisibleAtWindowUpdate: Bool
}
