import AppKit
import CryptoKit
import Darwin
import Foundation
@preconcurrency import MapKit

/// Explicit installed-app diagnostics only. Production budgets and source files
/// are never changed. All persistent state belongs to ManualViewerQAContext.
@MainActor
enum SustainedPerformanceValidation {
  private static var running = false

  /// The caller must already have opened its private ManualViewerQAContext.
  /// Returns after at least the requested observation interval, plus the final
  /// reference quiet window; cancellation/failure is recorded without exiting.
  /// True requires a complete observation, every instrumented scenario check,
  /// and a successfully written final report; elapsed time alone never passes.
  @discardableResult
  static func run(store: AppStore, output: URL, durationSeconds: Double) async -> Bool {
    let environment = ProcessInfo.processInfo.environment
    guard !running,
      SustainedPerformancePlan.isAuthorized(environment: environment, durationSeconds: durationSeconds),
      let context = ManualViewerQAContext.active, context.store === store,
      let sourcePath = environment["IMAGEVIEWER_MANUAL_QA_SOURCE"],
      let outputRootPath = environment["IMAGEVIEWER_MANUAL_QA_OUTPUT"] else {
      FileHandle.standardError.write(Data("SUSTAINED_QA rejected_nonprivate_or_invalid_configuration\n".utf8))
      return false
    }
    let source = URL(fileURLWithPath: sourcePath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let root = URL(fileURLWithPath: outputRootPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let destination = output.standardizedFileURL.resolvingSymlinksInPath()
    guard destination.pathComponents.starts(with: root.pathComponents),
      !destination.pathComponents.starts(with: source.pathComponents),
      !source.pathComponents.starts(with: destination.pathComponents) else {
      FileHandle.standardError.write(Data("SUSTAINED_QA rejected_output_scope\n".utf8)); return false
    }
    running = true
    defer { running = false }
    let workload = SustainedPerformanceRun(store: store, source: source, output: destination,
      duration: durationSeconds, privateSuite: context.suiteName)
    return await workload.perform()
  }
}

enum SustainedPerformanceAction: String, CaseIterable, Codable, Hashable, Sendable {
  case mixedOverview, fourPhotos, sixPhotos, filenameFilter, metadataFilter, mapSelection
  case videoOverview, fourVideos, sixVideos
}

enum SustainedPerformancePlan {
  static let minimumDurationSeconds = 1_800.0
  static let maximumDurationSeconds = 7_200.0
  static let checkpointIntervalSeconds = 300.0
  static let quietWindowSeconds = 30.0
  static let actions = SustainedPerformanceAction.allCases
  static let maximumLogRecords = 12_000
  static let maximumLogBytes = 32 * 1_024 * 1_024
  // ManualViewerQAContext constructs ThumbnailDiskCache with these unchanged
  // production defaults. Test each tier independently, as well as the sum.
  static let previewDiskByteLimit = 128 * 1_024 * 1_024
  static let exactDiskByteLimit = 384 * 1_024 * 1_024

  static func isAuthorized(environment: [String: String], durationSeconds: Double) -> Bool {
    environment["IMAGEVIEWER_SUSTAINED_QA"] == "1"
      && environment["IMAGEVIEWER_MANUAL_QA"] == "1"
      && (environment["IMAGEVIEWER_MANUAL_QA_SOURCE"]?.hasPrefix("/") ?? false)
      && (environment["IMAGEVIEWER_MANUAL_QA_OUTPUT"]?.hasPrefix("/") ?? false)
      && durationSeconds.isFinite && durationSeconds >= minimumDurationSeconds
      && durationSeconds <= maximumDurationSeconds
  }

  /// Selection can focus an inner tile without changing a valid page start.
  /// Compare against the actual captured page and ordered source versions.
  static func isPageRoundtripRestored<Version: Equatable>(
    initialPageStart: Int, initialVersions: [Version],
    finalPageStart: Int, finalVersions: [Version], expectedVisibleCount: Int
  ) -> Bool {
    expectedVisibleCount > 0 && initialVersions.count == expectedVisibleCount
      && finalPageStart == initialPageStart && finalVersions == initialVersions
  }

  /// Explicit conversion avoids selecting Double.init(bitPattern:) when the
  /// method reference Double.init is passed to map over UInt64 byte counters.
  static func medianByteCount(_ sorted: [UInt64]) -> Double {
    let values = sorted.map { Double($0) }
    guard !values.isEmpty else { return 0 }
    let middle = values.count / 2
    return values.count.isMultiple(of: 2)
      ? (values[middle - 1] + values[middle]) / 2 : values[middle]
  }

  static func validationSucceeded(observationCompleted: Bool,
    allScenarioChecksPassed: Bool, finalWriteSucceeded: Bool) -> Bool {
    observationCompleted && allScenarioChecksPassed && finalWriteSucceeded
  }

  /// Checkpoints are based on observed elapsed time. No synthetic elapsed time
  /// or timer tick count can establish a completed thirty-minute observation.
  static func checkpointDue(elapsed: Double, completedIndex: Int) -> Int? {
    guard elapsed.isFinite, elapsed >= checkpointIntervalSeconds else { return nil }
    let due = Int(floor(elapsed / checkpointIntervalSeconds))
    return due > completedIndex ? due : nil
  }
}

struct SustainedSourceStamp: Codable, Equatable, Sendable {
  let pathSHA256: String
  let bytes: Int64
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64
}

struct SustainedSourceInventory: Codable, Equatable, Sendable {
  let entries: [SustainedSourceStamp]

  /// Includes hidden regular files. It reads stat metadata only, never pixels,
  /// EXIF, bookmarks or file contents. Symlinks/directories are not followed.
  static func capture(directory: URL) throws -> Self {
    let urls = try FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: nil, options: [])
    let entries = try urls.compactMap { url -> SustainedSourceStamp? in
      var value = stat()
      guard lstat(url.path, &value) == 0 else { throw SustainedFailure("source_stat_failed") }
      guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
      return SustainedSourceStamp(pathSHA256: SustainedMetadataDigest.hash(Data(url.path.utf8)),
        bytes: value.st_size, modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
        modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec))
    }.sorted { $0.pathSHA256 < $1.pathSHA256 }
    return Self(entries: entries)
  }

  var digest: String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return SustainedMetadataDigest.hash((try? encoder.encode(self)) ?? Data())
  }
}

enum SustainedMetadataDigest {
  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  /// Canonicalizes property-list values only in memory. Only the digest leaves
  /// this function, so preferences containing filenames/URLs remain private.
  static func preferences(_ dictionary: [String: Any]) -> String {
    func normalized(_ value: Any) -> Any {
      if let dictionary = value as? [String: Any] { return dictionary.mapValues(normalized) }
      if let array = value as? [Any] { return array.map(normalized) }
      if let date = value as? Date { return ["date": date.timeIntervalSince1970] }
      if let data = value as? Data { return ["dataSHA256": hash(data)] }
      if let string = value as? String { return string }
      if let number = value as? NSNumber { return number }
      return ["unsupportedType": String(describing: type(of: value))]
    }
    let data = try? JSONSerialization.data(withJSONObject: normalized(dictionary), options: [.sortedKeys])
    return hash(data ?? Data())
  }
}

/// Source tuples are asset metadata, not a restat or proof of native painting.
/// External validation joins their path hashes/size/Unix modification time to
/// the separately preserved whole-folder and corpus lstat evidence.
struct SustainedDiagnosticSourceVersion: Codable, Equatable, Sendable {
  let sourcePathSHA256: String
  let sourceByteCount: Int64?
  let sourceModificationTime: Double?
  let sourceArchiveIdentitySHA256: String?
  let isAudio: Bool

  init(_ asset: ImageAsset) {
    sourcePathSHA256 = SustainedMetadataDigest.hash(Data(asset.url.path.utf8))
    sourceByteCount = asset.byteCount
    sourceModificationTime = asset.modificationDate.map(\.timeIntervalSince1970)
      .flatMap { $0.isFinite ? $0 : nil }
    sourceArchiveIdentitySHA256 = asset.archiveOrigin.map {
      SustainedMetadataDigest.hash(Data(($0.archiveURL.path + "\n" + $0.entryPath).utf8))
    }
    isAudio = asset.isAudio
  }

  var digest: String? {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(self)).map(SustainedMetadataDigest.hash)
  }

  func json(slotIndex: Int) -> [String: Any] {
    ["slotIndex": slotIndex, "sourcePathSHA256": sourcePathSHA256,
      "sourceByteCount": sourceByteCount.map { $0 as Any } ?? NSNull(),
      "sourceModificationTime": sourceModificationTime.map { $0 as Any } ?? NSNull(),
      "diagnosticSourceVersionSHA256": digest.map { $0 as Any } ?? NSNull(),
      "sourceArchiveIdentitySHA256": sourceArchiveIdentitySHA256.map { $0 as Any } ?? NSNull(),
      "isAudio": isAudio,
      "sourceVersionScope": "asset_identity_metadata_not_fresh_stat_or_physical_paint"]
  }
}

/// One latest outcome per source version, including failures, with no pixels.
/// Metadata-only enrichment and pixel-size changes share a source; replacement
/// versions never match an older outcome. No global/production negative cache.
struct SustainedPosterOutcomeLedger {
  private let capacity: Int
  private var events: [VideoPosterDiagnosticEvent] = []
  private(set) var evictions = 0
  var count: Int { events.count }

  init(capacity: Int = 512) { self.capacity = min(512, max(1, capacity)) }

  mutating func record(_ event: VideoPosterDiagnosticEvent) {
    events.removeAll { $0.request.hasSameSource(as: event.request) }
    events.append(event)
    if events.count > capacity {
      events.removeFirst(events.count - capacity)
      evictions += 1
    }
  }

  func event(for asset: ImageAsset) -> VideoPosterDiagnosticEvent? {
    let target = VideoTilePosterRequest(asset: asset, maxPixelSize: 256)
    return events.last { $0.request.hasSameSource(as: target) }
  }
}

/// An explicit private run owns one observation and restores its predecessor.
/// This never installs itself during ordinary application launch.
@MainActor
final class SustainedPosterDiagnosticObservation {
  private let previous: VideoPosterLoader.DiagnosticObserver?
  private var active = true

  init(receive: @escaping VideoPosterLoader.DiagnosticObserver) {
    previous = VideoPosterLoader.diagnosticObserver
    let predecessor = previous
    VideoPosterLoader.diagnosticObserver = { event in
      predecessor?(event)
      receive(event)
    }
  }

  func stop() {
    guard active else { return }
    active = false
    VideoPosterLoader.diagnosticObserver = previous
  }
}

@MainActor
struct SustainedCurrentSlotOutcomes {
  let versions: [[String: Any]]
  let acceptedIndices: [Int]
  let terminalSlots: [[String: Any]]
  let unsupportedSlots: [[String: Any]]
  let unverifiedIndices: [Int]

  init(assets: [ImageAsset], presented: [Int: AppStore.PresentedAssetVersion],
    posterLedger: SustainedPosterOutcomeLedger) {
    versions = assets.enumerated().map { SustainedDiagnosticSourceVersion($0.element).json(slotIndex: $0.offset) }
    var accepted: [Int] = [], terminal: [[String: Any]] = [], unsupported: [[String: Any]] = [], missing: [Int] = []
    for (slot, asset) in assets.enumerated() {
      // A newer explicit terminal outcome must not be hidden by an older
      // publication entry that happens to contain the same source version.
      if asset.isVideo, let event = posterLedger.event(for: asset),
        case .terminalFailure(let failure) = event.outcome {
        var row = SustainedDiagnosticSourceVersion(event.request.asset).json(slotIndex: slot)
        row["sourceVersionMatchesCurrent"] = event.request.hasSameSource(as:
          VideoTilePosterRequest(asset: asset, maxPixelSize: 256))
        row["failureKind"] = failure.kind.rawValue
        row["errorDomain"] = failure.errorDomain
        row["errorCode"] = failure.errorCode
        terminal.append(row)
        if failure.kind == .unsupported { unsupported.append(row) }
      } else if presented[slot] == AppStore.PresentedAssetVersion(asset) {
        accepted.append(slot)
      } else { missing.append(slot) }
    }
    acceptedIndices = accepted; terminalSlots = terminal
    unsupportedSlots = unsupported; unverifiedIndices = missing
  }
}

private struct SustainedFailure: Error {
  let phase: String
  init(_ phase: String) { self.phase = phase }
}

@MainActor
private final class SustainedPerformanceRun {
  private struct Sample {
    let elapsed: Double
    let cpu: Double
    let intervalCPU: Double
    let footprint: UInt64?
    let resident: UInt64?
    let queued: Int
    let running: Int
    let ownForeground: Bool
    let windowVisible: Bool
    let referencePresented: Bool
    let referenceGeometryMatches: Bool
    let budgetsValid: Bool
    let thermal: Int
  }
  private struct ReferenceFrame {
    let version: AppStore.PresentedAssetVersion
    let imageIdentity: ObjectIdentifier
    let pixels: Int
    let expectedPixels: Double
    let refined: Bool
    let hdr: Bool
    let policy: ViewerFrameLoadingPolicy
  }
  private struct OriginalState {
    let query: LibraryQuery
    let mode: PresentationMode
    let count: Int
    let currentURL: URL?
    let placement: ThumbnailPanelPlacement
    let size: CGFloat
    let folderTree: Bool
    let inspector: InspectorPanel?
    let comparison: MagnificationComparisonLayout
    let markFilter: PhotoMarkFilter
    let showsVideos: Bool
    let focus: Bool
    let wraps: Bool
    let scale: BaseScaleMode
    let zoom: CGFloat
    let pan: CGSize
  }

  let store: AppStore
  let source: URL
  let output: URL
  let duration: Double
  let privateSuite: String
  private var window: NSWindow?
  private var referenceAsset: ImageAsset?
  private var referenceFrame: ReferenceFrame?
  private var referenceWindowFrame = CGRect.zero
  private var referenceContentSize = CGSize.zero
  private var referenceViewerViewportSize: CGSize?
  private var original: OriginalState?
  private var file: FileHandle?
  private var writtenBytes = 0
  private var recordCount = 0
  private var loggingFailed = false
  private var sampleTask: Task<Void, Never>?
  private var pressureSource: (any DispatchSourceMemoryPressure)?
  private var observedPressure: ImageResourcePressure?
  private var previousTicks: ImageCPUTicks?
  private var began = 0.0
  private var initialCPU = 0.0
  private var lastCPU = 0.0
  private var lastSample = 0.0
  private var lastProgress = -Double.infinity
  private var phase = "setup"
  private var cycle = 0
  private var actionCount = 0
  private var actionFailures = 0
  private var failureCounts: [String: Int] = [:]
  private var actionCounts: [String: Int] = [:]
  private var recentSamples: [Sample] = []
  private var checkpoints: [[String: Any]] = []
  private var sampleCount = 0
  private var peakFootprint: UInt64 = 0
  private var peakResident: UInt64 = 0
  private var maximumIntervalCPU = 0.0
  private var maximumQueue = 0
  private var budgetViolations = 0
  private var foregroundSamples = 0
  private var sourceBefore: SustainedSourceInventory?
  private var normalPreferencesBefore = ""
  private var windowPreferencesBefore = ""
  private var volatilePreferencesBefore = ""
  private var stopReason = ""
  private var previousObserver: ((ViewerFrameRequest, RenderedFrame, Bool) -> Void)?
  private var observerInstalled = false
  private var posterObservation: SustainedPosterDiagnosticObservation?
  private var posterOutcomes = SustainedPosterOutcomeLedger()
  private var snapshotActive = false

  init(store: AppStore, source: URL, output: URL, duration: Double, privateSuite: String) {
    self.store = store; self.source = source; self.output = output
    self.duration = duration; self.privateSuite = privateSuite
  }
  private var now: Double { ProcessInfo.processInfo.systemUptime }
  private var elapsed: Double { max(0, now - began) }

  func perform() async -> Bool {
    do {
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      let logURL = output.appendingPathComponent("samples.jsonl")
      guard !FileManager.default.fileExists(atPath: logURL.path),
        FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
        throw SustainedFailure("fresh_output_log_required")
      }
      file = try FileHandle(forWritingTo: logURL)
      sourceBefore = try SustainedSourceInventory.capture(directory: source)
      normalPreferencesBefore = normalPreferencesDigest()
      windowPreferencesBefore = normalPreferencesDigest(category: "window")
      volatilePreferencesBefore = normalPreferencesDigest(category: "volatile")
      guard !store.showsHome, !store.isLoading, !store.isFiltering, !store.allAssets.isEmpty,
        Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
        throw SustainedFailure("actual_installed_private_library_must_be_ready")
      }
      window = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width >= 700 }
        .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
      guard let window, window.contentView != nil else { throw SustainedFailure("actual_root_window_missing") }
      referenceWindowFrame = window.frame
      referenceContentSize = window.contentView?.bounds.size ?? .zero
      original = OriginalState(query: store.libraryQuery, mode: store.presentationMode,
        count: store.imagesPerPage, currentURL: store.currentAsset?.url,
        placement: store.thumbnailPanelPlacement, size: store.thumbnailSize,
        folderTree: store.showsFolderTree, inspector: store.inspectorPanel,
        comparison: store.comparisonLayout, markFilter: store.photoMarkFilter,
        showsVideos: store.showsVideos, focus: store.isFocusMode,
        wraps: store.wrapsNavigation, scale: store.baseScaleMode, zoom: store.zoom, pan: store.panOffset)
      guard let reference = store.allAssets.first(where: {
        !$0.isPlaybackMedia && ($0.byteCount ?? 0) > 0
          && ImageFormatRegistry.cameraRAWExtensions.contains($0.fileExtension)
      }) else { throw SustainedFailure("nonempty_RAW_reference_required") }
      referenceAsset = reference
      // Suppress this diagnostic window's autosave; ordinary preference-domain
      // hashes are checked independently rather than silently rewritten.
      window.setFrameAutosaveName("")
      previousObserver = ViewerFrameLoader.diagnosticPresentationObserver
      ViewerFrameLoader.diagnosticPresentationObserver = { [weak self] request, rendered, refined in
        self?.previousObserver?(request, rendered, refined)
        guard let self, request.asset.url == self.referenceAsset?.url else { return }
        let bucket = ImageLoadingPolicy.pixelBucket(request.maxPixelSize)
        let expected = min(Double(bucket), rendered.sourcePixelSize.map { Double(max($0.width, $0.height)) } ?? Double(bucket))
        self.referenceFrame = ReferenceFrame(version: AppStore.PresentedAssetVersion(request.asset),
          imageIdentity: ObjectIdentifier(rendered.image), pixels: max(rendered.image.width, rendered.image.height),
          expectedPixels: expected, refined: refined, hdr: request.prefersHDR, policy: request.loadingPolicy)
      }
      observerInstalled = true
      posterObservation = SustainedPosterDiagnosticObservation { [weak self] event in
        self?.posterOutcomes.record(event)
      }
      began = now; initialCPU = Self.cpuSeconds(); lastCPU = initialCPU; lastSample = began
      previousTicks = ImageCPUTicks.read()
      startPressureObservation()
      try append(["kind": "start", "durationSeconds": duration,
        "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        "processID": getpid(), "sourceFiles": sourceBefore?.entries.count ?? 0,
        "allAssets": store.allAssets.count, "videoAssets": store.allAssets.filter(\.isVideo).count,
        "sourceInventoryDigest": sourceBefore?.digest ?? "", "normalPreferencesDigest": normalPreferencesBefore,
        "privateDefaultsSuiteHash": SustainedMetadataDigest.hash(Data(privateSuite.utf8)),
        "sourcePathsExported": false, "sourcePixelsExported": false,
        "scope": "actual_installed_RootView_private_AppStore_product_navigation_and_native_viewport_changes_not_OS_input_injection_or_physical_paint",
        "resourcePolicy": "production_live_monitor_no_budget_focus_thermal_pressure_or_CPU_policy_override",
        "cacheScope": "private_context_existing_bounded_caches_no_purge_or_enlargement_OS_file_and_QuickLook_caches_uncontrolled"])
      sampleTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          guard let self else { return }
          await self.sample()
          do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
      }
      await checkpoint(index: 0)
      var checkpointIndex = 0
      while elapsed < duration && !Task.isCancelled && !loggingFailed && stopReason.isEmpty {
        for action in SustainedPerformancePlan.actions {
          if elapsed >= duration || Task.isCancelled || loggingFailed || !stopReason.isEmpty { break }
          await execute(action)
          if let due = SustainedPerformancePlan.checkpointDue(elapsed: elapsed, completedIndex: checkpointIndex) {
            await checkpoint(index: due); checkpointIndex = due
          }
        }
        cycle += 1
      }
      if Task.isCancelled { stopReason = "cancelled_before_requested_observation_finished" }
      else if loggingFailed { stopReason = "bounded_log_write_failed_or_limit_reached" }
      if !Task.isCancelled && !loggingFailed && stopReason.isEmpty { await checkpoint(index: max(checkpointIndex + 1, Int(duration / 300))) }
    } catch {
      stopReason = (error as? SustainedFailure)?.phase ?? "sustained_setup_error"
    }
    let task = sampleTask; sampleTask?.cancel(); sampleTask = nil; await task?.value
    pressureSource?.setEventHandler {}; pressureSource?.cancel(); pressureSource = nil
    if observerInstalled { ViewerFrameLoader.diagnosticPresentationObserver = previousObserver }
    posterObservation?.stop(); posterObservation = nil
    let measuredWall = began > 0 ? elapsed : 0
    let measuredCPU = began > 0 ? max(0, Self.cpuSeconds() - initialCPU) : 0
    var sourceUnchanged = false
    var sourceAfterDigest = ""
    do {
      let after = try SustainedSourceInventory.capture(directory: source)
      sourceUnchanged = after == sourceBefore
      sourceAfterDigest = after.digest
    } catch { if stopReason.isEmpty { stopReason = "source_after_stat_failed" } }
    await restoreOriginalPrivateState()
    let normalPreferencesUnchanged = normalPreferencesDigest() == normalPreferencesBefore
    let windowPreferencesUnchanged = normalPreferencesDigest(category: "window") == windowPreferencesBefore
    let volatilePreferencesUnchanged = normalPreferencesDigest(category: "volatile") == volatilePreferencesBefore
    let durationCompleted = measuredWall >= duration
    let quietComparable = checkpoints.filter { ($0["comparableReferenceQuiet"] as? Bool) == true }.count
    let completed = stopReason.isEmpty && durationCompleted && sourceUnchanged
      && normalPreferencesUnchanged && !loggingFailed && budgetViolations == 0
    let allScenarioChecksPassed = actionFailures == 0 && actionCount >= SustainedPerformancePlan.actions.count
      && SustainedPerformancePlan.actions.allSatisfy { (actionCounts[$0.rawValue] ?? 0) > 0 }
      && checkpoints.allSatisfy { ($0["status"] as? String) == "observed" } && quietComparable >= 2
    let status = completed ? (allScenarioChecksPassed ? "completed_observation" : "completed_with_validation_gaps") : "failed_or_incomplete"
    let result: [String: Any] = [
      "schemaVersion": 1, "status": status,
      "stopReason": stopReason, "requestedDurationSeconds": duration, "observedWallSeconds": measuredWall,
      "minimumThirtyMinutesActuallyObserved": durationCompleted && measuredWall >= 1_800,
      "processCPUSeconds": measuredCPU,
      "averageCPUPercentOneCore": measuredWall > 0 ? measuredCPU / measuredWall * 100 : 0,
      "sampledCPUPercentOneCoreMaximum": maximumIntervalCPU,
      "sampledFootprintMaximumBytes": peakFootprint, "sampledRSSMaximumBytes": peakResident,
      "resourceSampleCount": sampleCount, "ownForegroundSampleFraction": sampleCount > 0 ? Double(foregroundSamples) / Double(sampleCount) : 0,
      "maximumQueuedOperations": maximumQueue, "cacheBudgetViolations": budgetViolations,
      "actionCount": actionCount, "actionFailureCount": actionFailures,
      "actionCounts": actionCounts, "failureCounts": failureCounts,
      "checkpoints": checkpoints, "comparableReferenceQuietCheckpointCount": quietComparable,
      "sourceBeforeDigest": sourceBefore?.digest ?? "", "sourceAfterDigest": sourceAfterDigest,
      "sourceFileCount": sourceBefore?.entries.count ?? 0, "sourceMetadataUnchanged": sourceUnchanged,
      "normalUserPreferencesUnchanged": normalPreferencesUnchanged,
      "normalWorkSettingsUnchanged": normalPreferencesUnchanged,
      "normalWindowPreferenceValuesUnchangedDuringObservation": windowPreferencesUnchanged,
      "normalVolatileHomeQuotePreferencesUnchangedDuringObservation": volatilePreferencesUnchanged,
      "normalPreferencesScope": "work_settings_exclude_NSWindow_Frame_values_and_volatile_HomeQuote; outer_operator_verifies_or_restores_window_geometry_after_diagnostic_process",
      "privateOriginalStateRestorationAttempted": original != nil,
      "allScenarioChecksPassed": allScenarioChecksPassed,
      "sourcePathsExported": false, "sourcePixelsExported": false,
      "CPU100PercentEqualsOneCore": true, "samplingMayAddOverhead": true,
      "sourceIntegrityScope": "regular_file_membership_size_and_nanosecond_mtime_not_content_hash",
      "observationCompletionIsPerformanceAcceptance": false,
      "limitations": ["No physical paint, FPS, input-to-photon, GPU or energy measurement.",
        "One-second resource samples can miss shorter peaks; memory pressure is recorded only after an OS notification.",
        "Quiet floor is comparable only when the same exact reference/native backing, geometry and visible foreground conditions were verified.",
        "Mixed actions include programmed waits; their phase wall time is not a thumbnail latency metric.",
        "No global caches were cleared and no production cache or scheduling limit was increased."]]
    var finalWriteSucceeded = true
    do {
      try writeJSON(result, name: "sustained-report.json")
      try writeJSON(["status": status,
        "elapsedSeconds": measuredWall, "durationSeconds": duration, "sourceMetadataUnchanged": sourceUnchanged,
        "normalWorkSettingsUnchanged": normalPreferencesUnchanged, "actionCount": actionCount,
        "actionFailureCount": actionFailures, "stopReason": stopReason], name: "progress.json")
    } catch { finalWriteSucceeded = false }
    try? file?.synchronize(); try? file?.close(); file = nil
    FileHandle.standardOutput.write(Data("SUSTAINED_QA finished status=\(finalWriteSucceeded ? status : "final_report_write_failed") elapsed=\(measuredWall)\n".utf8))
    return SustainedPerformancePlan.validationSucceeded(observationCompleted: completed,
      allScenarioChecksPassed: allScenarioChecksPassed, finalWriteSucceeded: finalWriteSucceeded)
  }

  private func execute(_ action: SustainedPerformanceAction) async {
    phase = action.rawValue
    let start = now, cpu = Self.cpuSeconds()
    var details: [String: Any] = [:]
    var failure = ""
    do {
      try checkBudgetAndDeadline()
      store.pauseSlideshow(); store.videoGridPlayback.pauseAll(); store.isFocusMode = false
      store.setComparisonLayout(.off); store.inspectorPanel = nil
      store.presentationMode = .overview
      switch action {
      case .mixedOverview, .videoOverview:
        var query = LibraryQuery()
        if action == .videoOverview { query.mediaKind = .videos }
        store.libraryQuery = query
        try await ready(45)
        store.thumbnailPanelPlacement = .hidden
        store.thumbnailSize = cycle.isMultiple(of: 2) ? 150 : 226.4
        let jumps = try await scrollOverview()
        details = ["nativeViewportJumps": jumps, "visibleCollectionCount": store.assets.count,
          "videoItemsInCollection": store.assets.filter(\.isVideo).count,
          "mode": action == .videoOverview ? "video_posters_no_playback_or_audio" : "all_mixed_candidates"]
      case .fourPhotos, .sixPhotos, .fourVideos, .sixVideos:
        let count = action == .fourPhotos || action == .fourVideos ? 4 : 6
        let videoPage = action == .fourVideos || action == .sixVideos
        var query = LibraryQuery(); query.mediaKind = videoPage ? .videos : .images
        query.searchFilters.minimumBytes = 1
        store.libraryQuery = query; try await ready(45)
        try require(store.assets.count > count * 3, "insufficient_nonempty_viewer_candidates")
        store.presentationMode = .viewer; store.setImagesPerPage(count); store.wrapsNavigation = false
        store.thumbnailPanelPlacement = count == 4 ? .left : .bottom
        let startIndex = (cycle * 37) % max(1, store.assets.count - count * 3)
        store.select(index: startIndex); store.setFitToWindow()
        let initialPageStart = store.pageStartIndex
        let initialVersions = store.visibleAssets.map { AppStore.PresentedAssetVersion($0) }
        let initialSelectedIndex = store.currentIndex
        let selectedTargetMatches = store.selectedURLs == Set([store.assets[startIndex].url])
          && initialSelectedIndex == startIndex
        var observedPageStarts = [initialPageStart]
        var observedSelectedIndices = [initialSelectedIndex]
        details = ["requestedSelectionIndex": startIndex,
          "initialPageSlotVersions": store.visibleAssets.enumerated().map {
            SustainedDiagnosticSourceVersion($0.element).json(slotIndex: $0.offset)
          },
          "initialSelectedIndex": initialSelectedIndex,
          "initialPageStartIndex": initialPageStart, "initialVisibleCount": initialVersions.count,
          "initialSelectedTargetMatches": selectedTargetMatches,
          "observedPageStartIndices": observedPageStarts,
          "observedSelectedIndices": observedSelectedIndices,
          "viewerCollectionCount": store.assets.count,
          "actualVisibleCount": store.visibleAssets.count,
          "pageInputs": 0, "pageIdentityRestored": false,
          "loadingPolicy": count <= 4 ? "quality" : "responsive",
          "media": videoPage ? "video_posters" : "photos"]
        try require(selectedTargetMatches, "viewer_selected_target")
        for direction in [1, 1, -1, -1] {
          store.navigatePage(direction)
          observedPageStarts.append(store.pageStartIndex)
          observedSelectedIndices.append(store.currentIndex)
          // Publish the mutation values before a cancellable wait, so a
          // failed attempt still retains its actual navigation evidence.
          details["pageInputs"] = observedPageStarts.count - 1
          details["observedPageStartIndices"] = observedPageStarts
          details["observedSelectedIndices"] = observedSelectedIndices
          try await pause(0.16)
          if videoPage { store.videoGridPlayback.pauseAll() }
        }
        let restored = SustainedPerformancePlan.isPageRoundtripRestored(
          initialPageStart: initialPageStart, initialVersions: initialVersions,
          finalPageStart: store.pageStartIndex,
          finalVersions: store.visibleAssets.map { AppStore.PresentedAssetVersion($0) },
          expectedVisibleCount: count)
        details["finalPageStartIndex"] = store.pageStartIndex
        details["finalPageSlotVersions"] = store.visibleAssets.enumerated().map {
          SustainedDiagnosticSourceVersion($0.element).json(slotIndex: $0.offset)
        }
        details["finalSelectedIndex"] = store.currentIndex
        details["actualVisibleCount"] = store.visibleAssets.count
        details["pageIdentityRestored"] = restored
        try require(restored, "viewer_page_roundtrip_membership")
        let earlyObservationStarted = now
        try await pause(2)
        let earlyObservationElapsed = now - earlyObservationStarted
        if videoPage { store.videoGridPlayback.pauseAll() }
        let acceptedSlots = store.visibleAssets.enumerated().compactMap { slot, asset in
          store.viewerPresentedAssets[slot] == AppStore.PresentedAssetVersion(asset) ? slot : nil
        }
        let unverifiedSlots = Array(store.visibleAssets.indices).filter { !acceptedSlots.contains($0) }
        details["acceptedCurrentSlotVersions"] = acceptedSlots.count
        details["acceptedCurrentSlotIndices"] = acceptedSlots
        details["unverifiedCurrentSlotIndices"] = unverifiedSlots
        details["allCurrentSlotVersionsAccepted"] = unverifiedSlots.isEmpty
        details["earlyObservationRequestedSeconds"] = 2
        details["earlyObservationSeconds"] = earlyObservationElapsed
        details["tileEvidenceScope"] = "current_source_version_publication_ledger_after_two_seconds_not_all_slot_native_backing_quality_or_physical_paint"
        details["allSlotNativeBackingVerified"] = false
        details["allSlotSettledQualityVerified"] = false
        let settleAssets = store.visibleAssets
        let settleVersions = settleAssets.map { AppStore.PresentedAssetVersion($0) }
        var final = SustainedCurrentSlotOutcomes(assets: settleAssets,
          presented: store.viewerPresentedAssets, posterLedger: posterOutcomes)
        details["currentSlotVersions"] = final.versions
        let settleStarted = now
        let settleLimit = 15.0
        let settleDeadline = settleStarted + settleLimit
        while !final.unverifiedIndices.isEmpty && now < settleDeadline {
          try Task.checkCancellation(); try checkBudgetAndDeadline()
          try require(store.pageStartIndex == initialPageStart
            && store.visibleAssets.map { AppStore.PresentedAssetVersion($0) } == settleVersions,
            "viewer_settle_membership_changed")
          // Only this bounded diagnostic wait is added. The early two-second
          // publication snapshot above is never rewritten by later completion.
          try await Task.sleep(for: .seconds(min(0.1, max(0, settleDeadline - now))))
          final = SustainedCurrentSlotOutcomes(assets: store.visibleAssets,
            presented: store.viewerPresentedAssets, posterLedger: posterOutcomes)
        }
        try require(store.pageStartIndex == initialPageStart
          && store.visibleAssets.map { AppStore.PresentedAssetVersion($0) } == settleVersions,
          "viewer_settle_membership_changed")
        details["finalAcceptedCurrentSlotVersions"] = final.acceptedIndices.count
        details["finalAcceptedCurrentSlotIndices"] = final.acceptedIndices
        details["terminalCurrentSlots"] = final.terminalSlots
        details["unsupportedCurrentSlots"] = final.unsupportedSlots
        details["finalUnverifiedCurrentSlotIndices"] = final.unverifiedIndices
        details["finalAllCurrentSlotVersionsAccepted"] = final.acceptedIndices.count == count
        details["allCurrentSlotsAcceptedOrTypedTerminal"] = final.unverifiedIndices.isEmpty
        details["typedTerminalCurrentSlotOutcomesVerified"] = true
        details["unsupportedCurrentSlotOutcomesVerified"] = !final.unsupportedSlots.isEmpty
        let settleElapsed = now - settleStarted
        details["finalSettleSeconds"] = settleElapsed
        details["finalSettleLimitSeconds"] = settleLimit
        details["finalSettleTimedOut"] = !final.unverifiedIndices.isEmpty || settleElapsed > settleLimit
        details["finalSettleScope"] = "additional_bounded_observation_after_early_snapshot; elapsed_includes_main_actor_scheduler_delay; no_quality_or_physical_paint_claim"
        details["posterOutcomeLedgerCount"] = posterOutcomes.count
        details["posterOutcomeLedgerEvictions"] = posterOutcomes.evictions
        details["posterOutcomeLedgerLimit"] = 512
        details["explicitVideoPlayingCount"] = store.videoGridPlayback.playingIDs.count
        details["audioOwnerPresent"] = store.videoGridPlayback.audioID != nil
        details["posterScope"] = "current_source_version_publication_or_actual_loader_typed_terminal_error; no_localized_reason_or_physical_paint"
        try require(final.unverifiedIndices.isEmpty, videoPage
          ? "video_current_slot_outcomes_unverified_after_bounded_settle"
          : "photo_current_slot_versions_unaccepted_after_bounded_settle")
        try require(settleElapsed <= settleLimit, "viewer_final_settle_deadline_exceeded")
      case .filenameFilter:
        guard let name = referenceAsset?.filename else { throw SustainedFailure("reference_missing") }
        let stem = String(name.prefix(3))
        var query = LibraryQuery(); query.searchText = stem + "*"
        let first = now; store.libraryQuery = query; try await ready(30)
        let firstSeconds = now - first, firstCount = store.assets.count
        try await pause(0.8)
        query.searchText = String(name.prefix(6)) + "*"
        let second = now; store.libraryQuery = query; try await ready(30)
        let secondSeconds = now - second, secondCount = store.assets.count
        try await pause(0.8)
        store.libraryQuery = LibraryQuery(); try await ready(30)
        try require(store.assets.count == store.allAssets.count, "filename_restore_full_collection")
        try await pause(1)
        details = ["firstQuerySeconds": firstSeconds, "secondQuerySeconds": secondSeconds,
          "firstMatches": firstCount, "secondMatches": secondCount, "fullCollectionRestored": true]
      case .metadataFilter:
        var query = LibraryQuery(); query.searchFilters.metadataText = "Apple"
        let first = now; store.libraryQuery = query; try await ready(75)
        let querySeconds = now - first, matched = store.assets.count
        // Give the actual overview a visible rendering opportunity before
        // exercising the same EXIF result in the responsive six-photo viewer.
        try await pause(1.5)
        let canShowSix = store.assets.count >= 6 && store.assets.prefix(6).allSatisfy {
          !$0.isPlaybackMedia && ($0.byteCount ?? 0) > 0
        }
        if canShowSix {
          store.presentationMode = .viewer; store.setImagesPerPage(6)
          store.thumbnailPanelPlacement = .bottom; store.select(index: 0)
          try await pause(1); store.navigatePage(1); try await pause(0.18)
          store.navigatePage(-1); try await pause(1)
        }
        store.presentationMode = .overview
        store.libraryQuery = LibraryQuery(); try await ready(30)
        try require(store.assets.count == store.allAssets.count, "metadata_restore_full_collection")
        try await pause(1)
        details = ["querySeconds": querySeconds, "metadataMatches": matched, "fullCollectionRestored": true,
          "filteredSixPhotoViewerExercised": canShowSix, "filteredOverviewHoldSeconds": 1.5]
      case .mapSelection:
        store.libraryQuery = LibraryQuery(); store.presentationMode = .map
        try await ready(75)
        try await wait(15) { self.nativeMap() != nil }
        guard let map = nativeMap() else { throw SustainedFailure("native_map_missing") }
        try await pause(0.5) // Let initial SwiftUI selection/reset callbacks finish.
        let located = store.mapAssets.filter { $0.location != nil }
        details["locatedItems"] = located.count
        guard !located.isEmpty else { throw SustainedFailure("map_selection_not_exercised_no_GPS_sources") }
        let annotationDeadline = now + 10
        while map.annotations.filter({ !($0 is MKUserLocation) }).isEmpty && now < annotationDeadline {
          try await pause(0.2)
        }
        let annotations = map.annotations.filter { !($0 is MKUserLocation) }
        details["nativeMapAnnotations"] = annotations.count
        try require(!annotations.isEmpty, "native_map_annotation_creation_not_observed")
        if !annotations.isEmpty {
          let annotation = annotations[cycle % annotations.count]
          map.setCenter(annotation.coordinate, animated: false)
          map.selectAnnotation(annotation, animated: false)
          try await pause(2)
          details["nativePinSelectionPublished"] = store.photoMapPreview.hasSelection
          try require(store.photoMapPreview.hasSelection, "native_pin_selection_callback_not_observed")
          map.deselectAnnotation(annotation, animated: false)
        }
        if let location = located.first?.location {
          store.libraryQuery.geographicSelection = .radius(center: GeoCoordinate(latitude: location.latitude,
            longitude: location.longitude), meters: 1_000)
          try await ready(45)
          let count = store.assets.count
          store.showMapSelection(in: .overview)
          try require(store.assets.count == count && store.libraryQuery.geographicSelection != nil,
            "map_filter_preserved_in_overview")
          try await pause(1)
          details["geographicSubsetCount"] = count
        }
        details["nativeMapAnnotations"] = annotations.count
        details["locatedItems"] = located.count
        details["nativeProgrammaticPinSelectionAttempted"] = !annotations.isEmpty
        details["tileNetworkPaintMeasured"] = false
      }
      actionCounts[action.rawValue, default: 0] += 1
    } catch { failure = (error as? SustainedFailure)?.phase ?? "mixed_action_error" }
    if ["log_unavailable", "root_window_disappeared", "overall_diagnostic_deadline"].contains(failure) { stopReason = failure }
    actionCount += 1
    if !failure.isEmpty { actionFailures += 1; failureCounts[failure, default: 0] += 1 }
    details.merge(["kind": "action", "action": action.rawValue, "cycle": cycle,
      "status": failure.isEmpty ? "completed" : "failed", "failure": failure,
      "elapsedSeconds": elapsed, "wallSeconds": now - start,
      "processCPUSeconds": max(0, Self.cpuSeconds() - cpu)], uniquingKeysWith: { _, new in new })
    do { try append(details) } catch { loggingFailed = true }
    await progress(force: true)
  }

  private func checkpoint(index: Int) async {
    phase = "reference_quiet_\(index)"
    let checkpointBegan = now
    var failure = ""
    var stableQueue = false
    let sampleFloor = sampleCount
    var quietStart = now
    var quietCPU = Self.cpuSeconds()
    var quietWasStarted = false
    do {
      try require(referenceAsset != nil, "reference_missing")
      store.pauseSlideshow(); store.videoGridPlayback.pauseAll()
      store.presentationMode = .overview; store.resetLibraryQuery(); store.showsVideos = true
      try await ready(60)
      guard let referenceAsset,
        let index = store.assets.firstIndex(where: { $0.url == referenceAsset.url }) else {
        throw SustainedFailure("reference_not_in_full_collection")
      }
      store.setComparisonLayout(.off); store.isFocusMode = false; store.inspectorPanel = nil
      store.showsFolderTree = false; store.thumbnailPanelPlacement = .hidden
      store.presentationMode = .viewer; store.setImagesPerPage(1)
      store.select(index: index); store.setFitToWindow()
      if let window, window.frame != referenceWindowFrame { window.setFrame(referenceWindowFrame, display: true) }
      try await wait(45) { self.referencePresented() && self.referenceGeometryMatches() }
      if referenceViewerViewportSize == nil { referenceViewerViewportSize = store.viewerViewportSize }
      let idleDeadline = min(began + duration + 180, now + 60)
      var idleSince: Double?
      while now < idleDeadline {
        try Task.checkCancellation()
        let queue = await store.loadingGovernor.stateSnapshot()
        if queue.runningCount == 0 && queue.queuedCount == 0 {
          if idleSince == nil { idleSince = now }
          if now - (idleSince ?? now) >= 1 { stableQueue = true; break }
        } else { idleSince = nil }
        try await pause(0.2)
      }
      quietStart = now; quietCPU = Self.cpuSeconds()
      quietWasStarted = true
      try await pause(SustainedPerformancePlan.quietWindowSeconds)
    } catch { failure = (error as? SustainedFailure)?.phase ?? "reference_quiet_error" }
    if ["log_unavailable", "root_window_disappeared", "overall_diagnostic_deadline"].contains(failure) { stopReason = failure }
    let samples = quietWasStarted ? recentSamples.filter { $0.elapsed >= quietStart - began } : []
    let comparable = quietWasStarted && failure.isEmpty && stableQueue && !samples.isEmpty && samples.allSatisfy {
      $0.referencePresented && $0.referenceGeometryMatches && $0.ownForeground && $0.windowVisible
        && $0.queued == 0 && $0.running == 0
    }
    let footprints = samples.compactMap(\.footprint).sorted()
    let residents = samples.compactMap(\.resident).sorted()
    let cpus = samples.map(\.intervalCPU).sorted()
    let quietWall = quietWasStarted ? max(0, now - quietStart) : 0
    let quietCost = quietWasStarted ? max(0, Self.cpuSeconds() - quietCPU) : 0
    let row: [String: Any] = ["kind": "checkpoint", "index": index, "elapsedSeconds": elapsed,
      "checkpointWallSeconds": now - checkpointBegan, "quietWallSeconds": quietWall,
      "quietWindowStarted": quietWasStarted,
      "quietCPUSeconds": quietCost, "quietAverageCPUPercentOneCore": quietWall > 0 ? quietCost / quietWall * 100 : 0,
      "status": failure.isEmpty ? "observed" : "failed", "failure": failure,
      "sameReferencePathHash": referenceAsset.map { SustainedMetadataDigest.hash(Data($0.url.path.utf8)) } ?? "",
      "sameReferenceNativeFrameVerifiedAtEnd": referencePresented(),
      "sameReferenceGeometryVerifiedAtEnd": referenceGeometryMatches(),
      "referenceViewerViewportWidth": store.viewerViewportSize?.width ?? 0,
      "referenceViewerViewportHeight": store.viewerViewportSize?.height ?? 0,
      "queueReachedStableIdleBeforeQuiet": stableQueue, "comparableReferenceQuiet": comparable,
      "samplesSinceCheckpointPreparation": sampleCount - sampleFloor, "quietSampleCount": samples.count,
      "footprintMedianBytes": SustainedPerformancePlan.medianByteCount(footprints),
      "footprintMinimumBytes": footprints.first.map { $0 as Any } ?? NSNull(),
      "footprintMaximumBytes": footprints.last.map { $0 as Any } ?? NSNull(),
      "RSSMedianBytes": SustainedPerformancePlan.medianByteCount(residents),
      "sampledCPUPercentOneCoreP95": releaseOverviewPercentile(cpus, fraction: 0.95),
      "queuedMaximum": samples.map(\.queued).max() ?? 0, "runningMaximum": samples.map(\.running).max() ?? 0,
      "thermalRawValues": Array(Set(samples.map(\.thermal))).sorted(),
      "quietBudgetsValid": samples.allSatisfy(\.budgetsValid),
      "sampleScope": "same_current_photo_version_accepted_precise_native_CGImage_and_window_geometry_not_physical_paint"]
    checkpoints.append(row)
    if !failure.isEmpty { failureCounts[failure, default: 0] += 1 }
    do { try append(row) } catch { loggingFailed = true }
    await progress(force: true)
  }

  private func sample() async {
    guard !snapshotActive else { return }
    snapshotActive = true
    defer { snapshotActive = false }
    let phaseAtStart = phase
    async let rendered = store.pipeline.cacheSnapshot()
    async let thumbnails = store.thumbnailPipeline.cacheSnapshot()
    async let disk = store.thumbnailPipeline.diskCacheSnapshot()
    async let queue = store.loadingGovernor.stateSnapshot()
    let (renderedCache, thumbCache, diskCache, work) = await (rendered, thumbnails, disk, queue)
    let at = now, cpu = Self.cpuSeconds(), interval = max(0.000_001, at - lastSample)
    let cpuPercent = max(0, cpu - lastCPU) / interval * 100
    let ticks = ImageCPUTicks.read()
    let systemBusy = ticks.flatMap { tick in previousTicks.flatMap { tick.busyFraction(since: $0) } }
    previousTicks = ticks; lastCPU = cpu; lastSample = at
    var usage = rusage_info_v4()
    let usageStatus = withUnsafeMutablePointer(to: &usage) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    let footprint: UInt64? = usageStatus == 0 ? usage.ri_phys_footprint : nil
    let resident: UInt64? = usageStatus == 0 ? usage.ri_resident_size : nil
    let ownForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
    let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
    let tierBudgets = diskCache.map {
      $0.isComplete && $0.previewBytes <= SustainedPerformancePlan.previewDiskByteLimit
        && $0.exactBytes <= SustainedPerformancePlan.exactDiskByteLimit
    } == true
    let budgets = renderedCache.byteCount <= renderedCache.byteLimit && thumbCache.byteCount <= thumbCache.byteLimit
      && diskCache.map { $0.isComplete && $0.byteCount <= $0.byteLimit } == true && tierBudgets
    let thermal = ProcessInfo.processInfo.thermalState.rawValue
    let sample = Sample(elapsed: at - began, cpu: cpu, intervalCPU: cpuPercent,
      footprint: footprint, resident: resident, queued: work.queuedCount, running: work.runningCount,
      ownForeground: ownForeground, windowVisible: visible, referencePresented: referencePresented(),
      referenceGeometryMatches: referenceGeometryMatches(), budgetsValid: budgets, thermal: thermal)
    recentSamples.append(sample)
    if recentSamples.count > 100 { recentSamples.removeFirst(recentSamples.count - 100) }
    sampleCount += 1; foregroundSamples += ownForeground ? 1 : 0
    peakFootprint = max(peakFootprint, footprint ?? 0); peakResident = max(peakResident, resident ?? 0)
    if interval >= 0.25 { maximumIntervalCPU = max(maximumIntervalCPU, cpuPercent) }
    maximumQueue = max(maximumQueue, work.queuedCount)
    if !budgets { budgetViolations += 1 }
    var row: [String: Any] = ["kind": "resource", "phase": phaseAtStart, "phaseAfterSnapshot": phase,
      "phaseChangedDuringSnapshot": phaseAtStart != phase, "elapsedSeconds": sample.elapsed,
      "sampleIntervalSeconds": interval, "processCPUSecondsSinceStart": max(0, cpu - initialCPU),
      "intervalCPUPercentOneCore": cpuPercent, "runningOperations": work.runningCount,
      "queuedOperations": work.queuedCount, "waiters": work.waiterCount,
      "renderedBitmapRAMBytes": renderedCache.byteCount, "renderedBitmapRAMLimit": renderedCache.byteLimit,
      "thumbnailRAMBytes": thumbCache.byteCount, "thumbnailRAMLimit": thumbCache.byteLimit,
      "diskAccountingComplete": diskCache?.isComplete ?? false, "diskSnapshotAvailable": diskCache != nil, "diskBytes": diskCache?.byteCount ?? 0,
      "diskLimit": diskCache?.byteLimit ?? 0, "diskPreviewBytes": diskCache?.previewBytes ?? 0,
      "diskExactBytes": diskCache?.exactBytes ?? 0, "cacheBudgetsValid": budgets,
      "diskTierBudgetsValid": tierBudgets,
      "previewDiskByteLimit": SustainedPerformancePlan.previewDiskByteLimit,
      "exactDiskByteLimit": SustainedPerformancePlan.exactDiskByteLimit,
      "ownForeground": ownForeground, "windowVisibleAndUnoccluded": visible,
      "thermalRawValue": thermal, "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
      "referencePresented": sample.referencePresented, "referenceGeometryMatches": sample.referenceGeometryMatches,
      "memoryPressureObserved": observedPressure != nil]
    row["footprintBytes"] = footprint.map { $0 as Any } ?? NSNull()
    row["residentBytes"] = resident.map { $0 as Any } ?? NSNull()
    row["systemCPUBusyFraction"] = systemBusy.map { $0 as Any } ?? NSNull()
    row["observedMemoryPressureRawValue"] = observedPressure.map { $0.rawValue as Any } ?? NSNull()
    do { try append(row) } catch { loggingFailed = true }
    await progress(force: false)
  }

  private func referencePresented() -> Bool {
    guard let referenceAsset, let referenceFrame, store.presentationMode == .viewer,
      store.visibleAssets.count == 1, store.currentAsset?.url == referenceAsset.url,
      store.viewerPresentedAssets[0] == AppStore.PresentedAssetVersion(referenceAsset),
      referenceFrame.version == AppStore.PresentedAssetVersion(referenceAsset),
      referenceFrame.refined, referenceFrame.policy == .quality,
      referenceFrame.hdr == store.prefersHDR,
      Double(referenceFrame.pixels) >= referenceFrame.expectedPixels - 1,
      let root = window?.contentView else { return false }
    let backings = descendants(ExtendedRangeBackingView.self, in: root).filter {
      !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty && $0.layer?.contents != nil
    }
    guard backings.count == 1, let contents = backings[0].layer?.contents else { return false }
    return ObjectIdentifier(contents as AnyObject) == referenceFrame.imageIdentity
  }
  private func referenceGeometryMatches() -> Bool {
    guard let window, let content = window.contentView else { return false }
    let viewportMatches = referenceViewerViewportSize.map { expected in
      store.viewerViewportSize.map { abs($0.width - expected.width) <= 1 && abs($0.height - expected.height) <= 1 } ?? false
    } ?? true
    return viewportMatches && abs(window.frame.width - referenceWindowFrame.width) <= 1
      && abs(window.frame.height - referenceWindowFrame.height) <= 1
      && abs(content.bounds.width - referenceContentSize.width) <= 1
      && abs(content.bounds.height - referenceContentSize.height) <= 1
  }
  private func nativeMap() -> MKMapView? {
    guard let root = window?.contentView else { return nil }
    return descendants(MKMapView.self, in: root).first { !$0.isHiddenOrHasHiddenAncestor }
  }
  private func scrollOverview() async throws -> Int {
    try await wait(15) { self.overviewScroll() != nil }
    guard let scroll = overviewScroll(), let document = scroll.documentView else {
      throw SustainedFailure("actual_overview_scroll_missing")
    }
    let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
    for fraction in [0.0, 0.8, 0.2, 1.0, 0.0] {
      scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum * fraction))
      scroll.reflectScrolledClipView(scroll.contentView)
      try await pause(0.16)
    }
    try await pause(2)
    return 5
  }
  private func overviewScroll() -> NSScrollView? {
    guard let root = window?.contentView, store.presentationMode == .overview else { return nil }
    if let marked = OverviewBenchmarkScrollTarget.find(in: root) { return marked }
    return descendants(NSScrollView.self, in: root).filter {
      !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > root.bounds.width * 0.5
        && $0.bounds.height > 150 && ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height
    }.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
  }
  private func descendants<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
    if let typed = root as? T { return [typed] }
    return root.subviews.flatMap { descendants(type, in: $0) }
  }
  private func ready(_ seconds: Double) async throws {
    try await wait(seconds) { !self.store.isLoading && !self.store.isFiltering && !self.store.isIndexingLocations }
  }
  private func wait(_ seconds: Double, until ready: () -> Bool) async throws {
    let deadline = min(began + duration + 180, now + seconds)
    while !ready() {
      try Task.checkCancellation(); try checkBudgetAndDeadline()
      try require(now < deadline, phase + "_timeout")
      try await Task.sleep(for: .milliseconds(100))
    }
  }
  private func pause(_ seconds: Double) async throws {
    let deadline = now + seconds
    while now < deadline {
      try Task.checkCancellation(); try checkBudgetAndDeadline()
      try await Task.sleep(for: .milliseconds(100))
    }
  }
  private func checkBudgetAndDeadline() throws {
    try require(!loggingFailed, "log_unavailable")
    try require(now <= began + duration + 180, "overall_diagnostic_deadline")
    try require(window?.contentView != nil, "root_window_disappeared")
  }
  private func require(_ condition: Bool, _ failure: String) throws {
    if !condition { throw SustainedFailure(failure) }
  }
  private func progress(force: Bool) async {
    guard force || elapsed - lastProgress >= 15 else { return }
    lastProgress = elapsed
    do {
      try writeJSON(["status": "running", "phase": phase, "elapsedSeconds": elapsed,
        "durationSeconds": duration, "remainingSeconds": max(0, duration - elapsed),
        "processID": getpid(), "cycle": cycle, "actionCount": actionCount,
        "actionFailureCount": actionFailures, "checkpointCount": checkpoints.count,
        "resourceSampleCount": sampleCount, "latestQueuedOperations": recentSamples.last?.queued ?? 0,
        "latestRunningOperations": recentSamples.last?.running ?? 0,
        "sampledFootprintMaximumBytes": peakFootprint, "sampledRSSMaximumBytes": peakResident,
        "cacheBudgetViolations": budgetViolations, "sourcePathsExported": false], name: "progress.json")
    } catch { loggingFailed = true }
  }
  private func normalPreferencesDigest(category: String = "work") -> String {
    let domain = Bundle.main.bundleIdentifier ?? "org.openimageviewer.ImageViewer"
    let values = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
    let selected = values.filter { key, _ in
      let window = key.hasPrefix("NSWindow Frame")
      let volatile = key == "ImageViewer.HomeQuote.PreviousID.v1"
      if category == "window" { return window }
      if category == "volatile" { return volatile }
      return !window && !volatile
    }
    return SustainedMetadataDigest.preferences(selected)
  }
  private func append(_ row: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])
    guard recordCount < SustainedPerformancePlan.maximumLogRecords,
      writtenBytes <= SustainedPerformancePlan.maximumLogBytes - data.count, let file else {
      throw SustainedFailure("bounded_log_limit_or_handle_unavailable")
    }
    try file.write(contentsOf: data)
    recordCount += 1; writtenBytes += data.count
  }
  private func writeJSON(_ value: [String: Any], name: String) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent(name), options: .atomic)
  }
  private func startPressureObservation() {
    let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
    pressureSource = source
    source.setEventHandler { [weak self] in
      let data = source.data
      let level: ImageResourcePressure = data.contains(.critical) ? .critical : data.contains(.warning) ? .warning : .normal
      Task { @MainActor [weak self] in self?.observedPressure = level }
    }
    source.resume()
  }
  private func restoreOriginalPrivateState() async {
    guard let original else { return }
    store.presentationMode = .overview; store.showsVideos = original.showsVideos
    store.photoMarkFilter = original.markFilter; store.libraryQuery = original.query
    let until = now + 15
    while store.isFiltering && now < until { try? await Task.sleep(for: .milliseconds(100)) }
    store.setImagesPerPage(original.count)
    if let url = original.currentURL, let index = store.assets.firstIndex(where: { $0.url == url }) { store.select(index: index) }
    store.thumbnailPanelPlacement = original.placement; store.thumbnailSize = original.size
    store.showsFolderTree = original.folderTree; store.inspectorPanel = original.inspector
    store.setComparisonLayout(original.comparison); store.isFocusMode = original.focus
    store.wrapsNavigation = original.wraps; store.baseScaleMode = original.scale
    store.zoom = original.zoom; store.panOffset = original.pan; store.presentationMode = original.mode
  }
  private static func cpuSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }
}
