import CoreGraphics
import CryptoKit
@preconcurrency import AVFoundation
import Darwin
import Foundation
import Testing

@testable import ImageViewer

/// Complete, read-only mixed image/video thumbnail coverage with two outstanding
/// requests. This is a pipeline/cache workload, not native UI, playback, screen
/// painting, FPS, or an adaptive-resource-policy benchmark.
/// IMAGEVIEWER_MIXED_THUMBNAILS=1 IMAGEVIEWER_RAW_DIRECTORY=/absolute/source
/// IMAGEVIEWER_MIXED_THUMBNAILS_OUTPUT=/absolute/fresh/report-directory
/// swift test --filter RealMixedThumbnailCorpusTests
@Suite("실제 전체 사진·영상의 제한된 썸네일 생성과 역순 캐시 복귀", .serialized)
struct RealMixedThumbnailCorpusTests {
  @Test("전체 nonempty 후보를 생산 경로로 생성하고 RAM 비우기 뒤 역순 캐시만 조회한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_MIXED_THUMBNAILS"] == "1"),
    .timeLimit(.minutes(10)))
  func allMixedThumbnailsAndReverseCacheOnlyReturn() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["IMAGEVIEWER_RAW_DIRECTORY"], path.hasPrefix("/") else {
      throw CorpusFailure("explicit_absolute_source_required")
    }
    let source = URL(fileURLWithPath: path, isDirectory: true)
    let wholeTopLevelBefore = try CorpusTopLevelInventory.capture(directory: source)
    let sourceURLs = try FileManager.default.contentsOfDirectory(at: source,
      includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
      .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    let versionsBefore = sourceURLs.map { ImageFileVersion(url: $0) }
    let sourceVersionFieldsAvailable = versionsBefore.allSatisfy { $0.byteCount != nil && $0.modificationDate != nil }
    let supportedURLs = Set(sourceURLs.filter { MediaFormatRegistry.canAttemptToOpen($0, includesVideos: true) }
      .map(\.standardizedFileURL))
    let listingStarted = ProcessInfo.processInfo.systemUptime
    let scanned = try await ImageLibrary().scan(folder: source, includesVideos: true)
    let ordered = try RustImageEngine.query(scanned, options: LibraryQuery())
    let listingSeconds = ProcessInfo.processInfo.systemUptime - listingStarted
    let candidateMembershipMatches = Set(ordered.map { $0.url.standardizedFileURL }) == supportedURLs
    #expect(candidateMembershipMatches, "Full listing must include the supported original source candidates")
    let nonempty = ordered.enumerated().filter { ($0.element.byteCount ?? 0) > 0 && !$0.element.isAudio }
    let empty = ordered.filter { ($0.byteCount ?? 0) == 0 }
    try #require(!nonempty.isEmpty, "A nonempty mixed thumbnail corpus is required")

    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("RealMixedThumbnailCorpus.\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let previewLimit = 128 * 1_024 * 1_024
    let exactLimit = 384 * 1_024 * 1_024
    let disk = ThumbnailDiskCache(directory: temporary.appendingPathComponent("thumbnails"),
      previewByteLimit: previewLimit, exactByteLimit: exactLimit)
    // Intentionally fixed admission/cache policy: preserve real hardware values,
    // but remove pressure/focus/heat-policy variation from this coverage pass.
    // The result must never be presented as real adaptive background behavior.
    var hardware = ImageResourceSnapshot.currentHardware
    hardware.isAppActive = true
    hardware.lowPowerMode = false
    hardware.thermal = .nominal
    hardware.memoryPressure = .normal
    hardware.cpuBusyFraction = 0.1
    let governor = ImageResourceGovernor(mode: .comfortable, snapshot: hardware,
      storageOverride: .internalSSD, monitorsMemoryPressure: false)
    let pipeline = ThumbnailPipeline(governor: governor, diskCache: disk)
    let limits = await governor.limits(for: nonempty[0].element.url)
    let initialDisk = await disk.snapshot()
    let initialMemory = await pipeline.cacheSnapshot()
    let initialAppCachesEmpty = initialDisk.entryCount == 0 && initialDisk.byteCount == 0
      && initialMemory.entryCount == 0 && initialMemory.byteCount == 0
    #expect(initialAppCachesEmpty)
    let samples = CorpusResourceSampler(pipeline: pipeline, disk: disk, governor: governor)

    let firstBegan = ProcessInfo.processInfo.systemUptime
    let firstCPU = Self.cpuSeconds()
    await samples.start(phase: "initial_generation")
    let first = await Self.pass(nonempty, pipeline: pipeline, cacheOnly: false)
    let firstWall = ProcessInfo.processInfo.systemUptime - firstBegan
    let firstCPUSeconds = max(0, Self.cpuSeconds() - firstCPU)
    let firstResources = await samples.finishPhase()
    let preparedDisk = await disk.snapshot()
    let preparedMemory = await pipeline.cacheSnapshot()
    let unsupported = first.filter { $0.failure == "native_playback_unsupported" && $0.nativePlayable == false }
    let unsupportedIndices = Set(unsupported.map(\.index))
    let decodableEntries = nonempty.filter { !unsupportedIndices.contains($0.offset) }
    let allInitialAccounted = first.count == nonempty.count
      && first.allSatisfy { $0.succeeded || unsupportedIndices.contains($0.index) }
    let preparedCoverage = await pipeline.overviewCachedAssetCounts(
      assets: nonempty.map(\.element), maxPixelSize: 256)

    var reverse: [CorpusRequestResult] = []
    var reverseWall = 0.0, reverseCPUSeconds = 0.0
    var reverseResources: [CorpusResourceSample] = []
    var purgedMemoryBytes: Int? = nil
    var diskHitsBefore: UInt64? = nil, diskHitsAfter: UInt64? = nil
    var reverseWasRun = false
    if allInitialAccounted {
      await pipeline.purgeCache() // RAM only; preserve every generated PNG.
      let purged = await pipeline.cacheSnapshot()
      purgedMemoryBytes = purged.byteCount
      #expect(purged.byteCount == 0 && purged.entryCount == 0)
      diskHitsBefore = await disk.snapshot().hits
      await pipeline.setCachedPreviewDiagnosticPhase("reverse_cache_only_after_RAM_purge")
      let reverseBegan = ProcessInfo.processInfo.systemUptime
      let reverseCPU = Self.cpuSeconds()
      await samples.start(phase: "reverse_cache_only")
      reverse = await Self.pass(Array(decodableEntries.reversed()), pipeline: pipeline, cacheOnly: true)
      reverseWall = ProcessInfo.processInfo.systemUptime - reverseBegan
      reverseCPUSeconds = max(0, Self.cpuSeconds() - reverseCPU)
      reverseResources = await samples.finishPhase()
      await pipeline.setCachedPreviewDiagnosticPhase(nil)
      diskHitsAfter = await disk.snapshot().hits
      reverseWasRun = true
    }
    let cacheLedger = await pipeline.cachedPreviewDiagnosticsSnapshot()
    let finalMemory = await pipeline.cacheSnapshot()
    let finalDisk = await disk.snapshot()
    let versionsAfter = sourceURLs.map { ImageFileVersion(url: $0) }
    let wholeTopLevelAfter = try CorpusTopLevelInventory.capture(directory: source)
    let wholeTopLevelMetadataUnchanged = wholeTopLevelAfter == wholeTopLevelBefore
    let nonhiddenRegularVersionsUnchanged = versionsAfter == versionsBefore
    let sourceMetadataUnchanged = nonhiddenRegularVersionsUnchanged && wholeTopLevelMetadataUnchanged
    let allRows = first + reverse
    let nonarchiveRows = allRows.filter { $0.sourceVersionScope != "archive_member_asset_metadata_lstat_not_applicable" }
    let rowSourceVersionsVerified = nonarchiveRows.allSatisfy {
      $0.sourceVersionScope == "direct_regular_lstat" && $0.sourceVersionPreservedDuringRequest == true
    }
    let initialBudgetValid = preparedMemory.byteCount <= preparedMemory.byteLimit
      && preparedDisk.previewBytes <= previewLimit && preparedDisk.exactBytes <= exactLimit
    let finalBudgetValid = finalMemory.byteCount <= finalMemory.byteLimit
      && finalDisk.previewBytes <= previewLimit && finalDisk.exactBytes <= exactLimit
    let sampledBudgetValid = (firstResources + reverseResources).allSatisfy {
      $0.memoryBytes <= $0.memoryLimit && $0.previewDiskBytes <= previewLimit && $0.exactDiskBytes <= exactLimit
    }
    let reverseAllHit = reverseWasRun && reverse.count == decodableEntries.count && reverse.allSatisfy(\.succeeded)
      && cacheLedger.count == decodableEntries.count && cacheLedger.allSatisfy { $0.cacheHit && !$0.cancelled }
    let passed = sourceVersionFieldsAvailable && rowSourceVersionsVerified && candidateMembershipMatches && initialAppCachesEmpty && allInitialAccounted
      && reverseAllHit && sourceMetadataUnchanged && initialBudgetValid && finalBudgetValid && sampledBudgetValid

    var output: [String: Any] = [
      "schemaVersion": 1, "status": passed ? "completed" : "failed",
      "sourcePathsExported": false, "sourcePixelsExported": false,
      // Historical sourceRegularFilesPreserved counts only nonhidden regular
      // sourceURLs. Whole top-level evidence separately includes hidden entries,
      // directories and symlinks, and never treats a directory as a regular file.
      "sourceRegularFilesPreserved": sourceURLs.count, "sourceMetadataUnchanged": sourceMetadataUnchanged,
      "sourceRegularFilesPreservedScope": "nonhidden_regular_sourceURLs_only",
      "nonhiddenRegularVersionsUnchanged": nonhiddenRegularVersionsUnchanged,
      "wholeTopLevelMetadataUnchanged": wholeTopLevelMetadataUnchanged,
      "wholeTopLevelMetadataBefore": try Self.jsonObject(wholeTopLevelBefore),
      "wholeTopLevelMetadataAfter": try Self.jsonObject(wholeTopLevelAfter),
      "wholeTopLevelEntryCount": wholeTopLevelBefore.entries.count,
      "wholeTopLevelRegularCount": wholeTopLevelBefore.regularCount,
      "wholeTopLevelDirectoryCount": wholeTopLevelBefore.directoryCount,
      "wholeTopLevelSymlinkCount": wholeTopLevelBefore.symlinkCount,
      "wholeTopLevelHiddenRegularCount": wholeTopLevelBefore.hiddenRegularCount,
      "wholeTopLevelIntegrityScope": "fresh_direct_entry_membership_lstat_kind_mode_size_nanosecond_mtime_including_hidden_no_symlink_following_no_content_hash",
      "sourceVersionFieldsAvailable": sourceVersionFieldsAvailable,
      "sourceIntegrityScope": "all_top_level_entry_lstat_before_after_plus_each_nonarchive_request_lstat_before_after_not_content_hash",
      "rowSourceVersionEvidenceVerified": rowSourceVersionsVerified,
      "rowSourceVersionEvidenceScope": "sourcePathSHA256_is_standardized_absolute_path_SHA256; sourceByteCount_and_modifiedSeconds_Nanoseconds_are_actual_lstat_before_request; after_request_equality_is_verified; no_Date_rounding_or_content_read",
      "archiveRowsWithLstatNotApplicable": allRows.count - nonarchiveRows.count,
      "archiveSourceVersionScope": "archive_container_absolute_path_hash_plus_existing_member_asset_byteCount_and_Date_seconds_only; physical_member_lstat_not_applicable",
      "sourceStampCostIncludedInRequestAndPassTiming": true,
      "candidateMembershipMatchesIndependentInventory": candidateMembershipMatches,
      "listedCandidateCount": ordered.count, "nonemptyThumbnailCandidates": nonempty.count,
      "nativeUnsupportedVideoCount": unsupported.count, "decodableThumbnailCandidates": decodableEntries.count,
      "unsupportedScope": "independent_AVURLAsset_isPlayable_false_after_production_poster_failure_no_unsupported_decode_success_claim",
      "excludedEmptyCandidates": empty.count, "excludedEmptyDNGs": empty.filter { $0.fileExtension == "dng" }.count,
      "audioCandidatesExcluded": ordered.filter(\.isAudio).count,
      "listingSeconds": listingSeconds, "initialAppCachesEmpty": initialAppCachesEmpty,
      "OSFileAndQuickLookCachesFlushed": false, "maximumOutstandingRequests": 2,
      "OSFileAndQuickLookCacheStateControlled": false,
      "requestedThumbnailMaximumPixelSize": 256, "previewDiskByteLimit": previewLimit,
      "exactDiskByteLimit": exactLimit, "productionCacheBudgetsIncreased": false,
      "policyScope": "fixed_active_nominal_thermal_normal_pressure_CPU_busy_0.1_no_low_power_comfortable_internalSSD_actual_hardware_memory_and_cores_no_pressure_monitor",
      "measurementScope": "production_ThumbnailPipeline_browsingThumbnail_and_cachedPreview_return_including_admission_decode_PNG_write_or_restore_and_actor_wait_not_screen_or_playback",
      "requestValidityScope": "nonempty_CGImage_data_provider_positive_dimensions_maximum_edge_256_all_sources_without_black_pixel_rejection",
      "CPUCostIncludesValidityChecksAndResourceSampling": true,
      "physicalMemoryBytes": hardware.physicalMemory, "activeProcessorCount": hardware.activeProcessorCount,
      "appleSilicon": hardware.appleSilicon,
      "GPUUsageMeasured": false, "adaptiveBackgroundPolicyMeasured": false,
      "initialGeneration": Self.summary(first, wall: firstWall, cpu: firstCPUSeconds, cacheOnly: false),
      "initialRows": try Self.jsonObject(first),
      "initialResourceSamples": try Self.jsonObject(firstResources),
      "preparedCompactCoverage": preparedCoverage.preview,
      "preparedMemory": Self.memoryJSON(preparedMemory), "preparedDisk": Self.diskJSON(preparedDisk),
      "reverseWasRun": reverseWasRun,
      "reverseSkippedReason": reverseWasRun ? "" : "initial_generation_failed_no_partial_pass_claim",
      "reverseCacheOnly": Self.summary(reverse, wall: reverseWall, cpu: reverseCPUSeconds, cacheOnly: true),
      "reverseRows": try Self.jsonObject(reverse),
      "reverseResourceSamples": try Self.jsonObject(reverseResources),
      "reverseLedgerRequests": cacheLedger.count,
      "reverseLedgerHits": cacheLedger.filter(\.cacheHit).count,
      "reverseLedgerMisses": cacheLedger.filter { !$0.cacheHit }.count,
      "reverseLedgerCancelled": cacheLedger.filter(\.cancelled).count,
      "finalMemory": Self.memoryJSON(finalMemory), "finalDisk": Self.diskJSON(finalDisk),
      "initialBudgetValid": initialBudgetValid, "finalBudgetValid": finalBudgetValid,
      "sampledBudgetsValid": sampledBudgetValid,
      "actualGovernedConcurrencyLimit": limits.totalConcurrentLoads,
      "actualGovernedThumbnailRAMLimit": limits.thumbnailCacheBytes,
    ]
    output["RAMBytesImmediatelyAfterPurge"] = purgedMemoryBytes.map { $0 as Any } ?? NSNull()
    output["reverseDiskHitsBefore"] = diskHitsBefore.map { $0 as Any } ?? NSNull()
    output["reverseDiskHitsAfter"] = diskHitsAfter.map { $0 as Any } ?? NSNull()
    if let before = diskHitsBefore, let after = diskHitsAfter, after >= before {
      output["reverseDiskHitDelta"] = after - before
    } else { output["reverseDiskHitDelta"] = NSNull() }
    try #require(JSONSerialization.isValidJSONObject(output), "The aggregate report must contain concrete JSON values")
    let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    if let outputPath = environment["IMAGEVIEWER_MIXED_THUMBNAILS_OUTPUT"], outputPath.hasPrefix("/") {
      let directory = URL(fileURLWithPath: outputPath, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let reportURL = directory.appendingPathComponent("mixed-thumbnail-corpus-report.json")
      guard !FileManager.default.fileExists(atPath: reportURL.path) else { throw CorpusFailure("fresh_output_required") }
      try data.write(to: reportURL, options: .atomic)
    }
    // Aggregate-only stdout keeps failures reviewable without serializing URLs
    // through #expect's automatic argument expansion.
    let compact: [String: Any] = ["status": passed ? "completed" : "failed", "listed": ordered.count,
      "nonempty": nonempty.count, "initialFailures": first.filter { !$0.succeeded }.count,
      "nativeUnsupportedVideoCount": unsupported.count,
      "reverseMisses": reverse.filter { !$0.succeeded }.count, "sourceMetadataUnchanged": sourceMetadataUnchanged,
      "initialWallSeconds": firstWall, "reverseWallSeconds": reverseWall]
    FileHandle.standardOutput.write(Data("MIXED_THUMBNAIL_CORPUS ".utf8)
      + (try JSONSerialization.data(withJSONObject: compact, options: [.sortedKeys])) + Data("\n".utf8))
    #expect(sourceMetadataUnchanged, "Read-only thumbnail validation must preserve all top-level metadata")
    #expect(rowSourceVersionsVerified, "Every direct source request needs exact before/after lstat version evidence")
    #expect(allInitialAccounted, "Every failure must be independently explained as native playback unsupported")
    #expect(reverseAllHit, "Every reverse request must be a successful cache-only hit")
    #expect(initialBudgetValid && finalBudgetValid && sampledBudgetValid,
      "Existing byte-accounted RAM and disk tier budgets must remain respected")
    #expect(passed, "Every aggregate coverage, integrity, cache-return and budget check must pass")
    await pipeline.purgeCache()
  }

  @Test("원본 경로 대신 해시와 실제 lstat 나노초를 기록하고 모든 최상위 항목을 보존한다")
  func privateSourceVersionEvidenceUsesExactLstatAndWholeMembership() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CorpusEvidence.\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("private-source-name.mp4")
    try Data([1, 2, 3]).write(to: file)
    try Data([4]).write(to: folder.appendingPathComponent(".hidden"))
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("directory"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("dangling").path,
      withDestinationPath: folder.appendingPathComponent("missing").path)
    // Deliberately wrong asset metadata proves direct rows use lstat, not Date rounding.
    let asset = ImageAsset(url: file, byteCount: 999, modificationDate: Date(timeIntervalSince1970: 0))
    let version = CorpusSourceVersion.capture(asset: asset)
    var actual = stat()
    try #require(lstat(file.path, &actual) == 0)
    #expect(version.sourceByteCount == actual.st_size && version.sourceByteCount == 3)
    #expect(version.sourceModifiedSeconds == Int64(actual.st_mtimespec.tv_sec))
    #expect(version.sourceModifiedNanoseconds == Int64(actual.st_mtimespec.tv_nsec))
    #expect(version.sourcePathSHA256 == corpusPathHash(file) && version.sourcePathSHA256.count == 64)
    #expect(version.sourceVersionScope == "direct_regular_lstat")
    let initial = try CorpusTopLevelInventory.capture(directory: folder)
    #expect(initial.entries.count == 4 && initial.regularCount == 2 && initial.hiddenRegularCount == 1)
    #expect(initial.directoryCount == 1 && initial.symlinkCount == 1 && initial.otherCount == 0)
    #expect(try CorpusTopLevelInventory.capture(directory: folder) == initial)
    let encoded = String(decoding: try JSONEncoder().encode(["source": version]), as: UTF8.self)
    #expect(!encoded.contains(file.lastPathComponent) && !encoded.contains(folder.path))
    try Data([1, 2, 3, 4]).write(to: file)
    #expect(CorpusSourceVersion.capture(asset: asset) != version)
    #expect(try CorpusTopLevelInventory.capture(directory: folder) != initial)
    let missing = ImageAsset(url: folder.appendingPathComponent("missing"), byteCount: nil, modificationDate: nil)
    #expect(CorpusSourceVersion.capture(asset: missing).sourceVersionScope == "lstat_failed")
    var archive = asset
    archive.archiveOrigin = ArchiveImageOrigin(archiveURL: folder.appendingPathComponent("not-opened.zip"), entryPath: "member.dng")
    let logical = CorpusSourceVersion.capture(asset: archive)
    #expect(logical.sourceVersionScope == "archive_member_asset_metadata_lstat_not_applicable")
    #expect(logical.sourceByteCount == 999 && logical.sourceModifiedSeconds == nil && logical.sourceModifiedNanoseconds == nil)
    #expect(logical.archiveAssetModificationDateSeconds == 0)
  }

  /// The group never owns more than two requests, and the shared production
  /// governor still controls all admitted native work below that outer bound.
  private static func pass(_ entries: [(offset: Int, element: ImageAsset)], pipeline: ThumbnailPipeline,
    cacheOnly: Bool) async -> [CorpusRequestResult] {
    await withTaskGroup(of: CorpusRequestResult.self) { group in
      var next = 0, completed: [CorpusRequestResult] = []
      while next < min(2, entries.count) {
        let entry = entries[next]
        group.addTask { await request(entry, pipeline: pipeline, cacheOnly: cacheOnly) }
        next += 1
      }
      while let value = await group.next() {
        completed.append(value)
        if completed.count.isMultiple(of: 100) || completed.count == entries.count {
          let line = "MIXED_THUMBNAIL_PROGRESS cacheOnly=\(cacheOnly) completed=\(completed.count) total=\(entries.count) failures=\(completed.filter { !$0.succeeded }.count)\n"
          FileHandle.standardOutput.write(Data(line.utf8))
        }
        if next < entries.count, !Task.isCancelled {
          let entry = entries[next]
          group.addTask { await request(entry, pipeline: pipeline, cacheOnly: cacheOnly) }
          next += 1
        }
      }
      return completed
    }
  }
  private static func request(_ entry: (offset: Int, element: ImageAsset), pipeline: ThumbnailPipeline,
    cacheOnly: Bool) async -> CorpusRequestResult {
    let started = ProcessInfo.processInfo.systemUptime
    let kind = entry.element.isVideo ? "video" : entry.element.fileExtension
    let sourceVersionBefore = CorpusSourceVersion.capture(asset: entry.element)
    do {
      let image: CGImage
      if cacheOnly {
        guard let cached = await pipeline.cachedPreview(for: entry.element, maxPixelSize: 256,
          prefersCompact: true) else {
          return CorpusRequestResult(index: entry.offset, kind: kind, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started,
            succeeded: false, width: 0, height: 0, bitmapBytes: 0, failure: "cache_miss", errorDomain: nil, errorCode: nil)
            .recordingSourceVersion(sourceVersionBefore, asset: entry.element, started: started)
        }
        image = cached
      } else { image = try await pipeline.browsingThumbnail(for: entry.element, maxPixelSize: 256) }
      let elapsed = ProcessInfo.processInfo.systemUptime - started
      let valid = autoreleasepool {
        guard let bytes = image.dataProvider?.data else { return false }
        return image.width > 0 && image.height > 0 && max(image.width, image.height) <= 256 && CFDataGetLength(bytes) > 0
      }
      return CorpusRequestResult(index: entry.offset, kind: kind,
        elapsedSeconds: elapsed, succeeded: valid,
        width: image.width, height: image.height, bitmapBytes: image.bytesPerRow * image.height,
        failure: valid ? nil : "invalid_or_oversized_bitmap", errorDomain: nil, errorCode: nil)
        .recordingSourceVersion(sourceVersionBefore, asset: entry.element, started: started)
    } catch {
      let native = error as NSError
      let playable = entry.element.isVideo
        ? (try? await AVURLAsset(url: entry.element.url).load(.isPlayable)) : nil
      return CorpusRequestResult(index: entry.offset, kind: kind,
        elapsedSeconds: ProcessInfo.processInfo.systemUptime - started, succeeded: false,
        width: 0, height: 0, bitmapBytes: 0,
        failure: error is CancellationError ? "cancelled" : playable == false
          ? "native_playback_unsupported" : "thumbnail_generation_error",
        errorDomain: native.domain, errorCode: native.code, nativePlayable: playable)
        .recordingSourceVersion(sourceVersionBefore, asset: entry.element, started: started)
    }
  }
  private static func summary(_ rows: [CorpusRequestResult], wall: Double, cpu: Double, cacheOnly: Bool) -> [String: Any] {
    let byKind = Dictionary(grouping: rows, by: \.kind).mapValues { values in
      ["requests": values.count, "successes": values.filter(\.succeeded).count,
        "failures": values.filter { !$0.succeeded }.count,
        "latencySeconds": distribution(values.map(\.elapsedSeconds))] as [String: Any]
    }
    return ["requests": rows.count, "successes": rows.filter(\.succeeded).count,
      "failures": rows.filter { !$0.succeeded }.count, "wallSeconds": wall, "processCPUSeconds": cpu,
      "nativeUnsupported": rows.filter { $0.failure == "native_playback_unsupported" }.count,
      "averageCPUPercentOneCore": wall > 0 ? cpu / wall * 100 : 0,
      "latencySeconds": distribution(rows.map(\.elapsedSeconds)), "byKind": byKind,
      "sourceIOOnMissAllowed": !cacheOnly]
  }
  private static func distribution(_ values: [Double]) -> [String: Any] {
    let sorted = values.sorted()
    let maximum: Double = sorted.last ?? 0
    return ["count": sorted.count, "p50": releaseOverviewPercentile(sorted, fraction: 0.5),
      "p95": releaseOverviewPercentile(sorted, fraction: 0.95), "maximum": maximum]
  }
  private static func memoryJSON(_ snapshot: ImageCacheSnapshot) -> [String: Any] {
    ["entries": snapshot.entryCount, "bytes": snapshot.byteCount, "limit": snapshot.byteLimit]
  }
  private static func diskJSON(_ snapshot: ThumbnailDiskCacheSnapshot) -> [String: Any] {
    ["entries": snapshot.entryCount, "bytes": snapshot.byteCount, "limit": snapshot.byteLimit,
      "previewBytes": snapshot.previewBytes, "exactBytes": snapshot.exactBytes,
      "hits": snapshot.hits, "misses": snapshot.misses]
  }
  private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
  }
  fileprivate static func cpuSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }
}

private struct CorpusFailure: Error {
  let reason: String
  init(_ reason: String) { self.reason = reason }
}
private struct CorpusRequestResult: Codable, Sendable {
  let index: Int
  let kind: String
  var elapsedSeconds: Double
  let succeeded: Bool
  let width: Int
  let height: Int
  let bitmapBytes: Int
  let failure: String?
  let errorDomain: String?
  let errorCode: Int?
  var nativePlayable: Bool? = nil
  var sourcePathSHA256: String = ""
  var sourceByteCount: Int64? = nil
  var sourceModifiedSeconds: Int64? = nil
  var sourceModifiedNanoseconds: Int64? = nil
  var sourceVersionScope: String = "not_recorded"
  var sourceStatErrorCode: Int? = nil
  var archiveAssetModificationDateSeconds: Double? = nil
  var sourceVersionPreservedDuringRequest: Bool? = nil

  func recordingSourceVersion(_ before: CorpusSourceVersion, asset: ImageAsset,
    started: Double) -> Self {
    let after = CorpusSourceVersion.capture(asset: asset)
    var result = self
    result.sourcePathSHA256 = before.sourcePathSHA256
    result.sourceByteCount = before.sourceByteCount
    result.sourceModifiedSeconds = before.sourceModifiedSeconds
    result.sourceModifiedNanoseconds = before.sourceModifiedNanoseconds
    result.sourceVersionScope = before.sourceVersionScope
    result.sourceStatErrorCode = before.sourceStatErrorCode
    result.archiveAssetModificationDateSeconds = before.archiveAssetModificationDateSeconds
    // Archive members use existing logical metadata; they must never claim a
    // physical member lstat. Every direct regular-file row must verify equality.
    result.sourceVersionPreservedDuringRequest = before.sourceVersionScope == "archive_member_asset_metadata_lstat_not_applicable"
      ? nil : before.sourceVersionScope == "direct_regular_lstat" && before == after
    result.elapsedSeconds = ProcessInfo.processInfo.systemUptime - started
    return result
  }
}

private struct CorpusSourceVersion: Codable, Equatable, Sendable {
  let sourcePathSHA256: String
  let sourceByteCount: Int64?
  let sourceModifiedSeconds: Int64?
  let sourceModifiedNanoseconds: Int64?
  let sourceVersionScope: String
  let sourceStatErrorCode: Int?
  let archiveAssetModificationDateSeconds: Double?

  static func capture(asset: ImageAsset) -> Self {
    let physicalURL = asset.archiveOrigin?.archiveURL ?? asset.url
    let pathHash = corpusPathHash(physicalURL)
    if asset.archiveOrigin != nil {
      return Self(sourcePathSHA256: pathHash, sourceByteCount: asset.byteCount,
        sourceModifiedSeconds: nil, sourceModifiedNanoseconds: nil,
        sourceVersionScope: "archive_member_asset_metadata_lstat_not_applicable",
        sourceStatErrorCode: nil, archiveAssetModificationDateSeconds: asset.modificationDate?.timeIntervalSince1970)
    }
    var value = stat()
    guard lstat(physicalURL.path, &value) == 0 else {
      return Self(sourcePathSHA256: pathHash, sourceByteCount: nil,
        sourceModifiedSeconds: nil, sourceModifiedNanoseconds: nil,
        sourceVersionScope: "lstat_failed", sourceStatErrorCode: Int(errno),
        archiveAssetModificationDateSeconds: nil)
    }
    let regular = value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    return Self(sourcePathSHA256: pathHash, sourceByteCount: value.st_size,
      sourceModifiedSeconds: Int64(value.st_mtimespec.tv_sec),
      sourceModifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
      sourceVersionScope: regular ? "direct_regular_lstat" : "lstat_not_regular",
      sourceStatErrorCode: nil, archiveAssetModificationDateSeconds: nil)
  }
}

private struct CorpusTopLevelEntry: Codable, Equatable, Sendable {
  let pathSHA256: String
  let kind: String
  let mode: UInt32
  let byteCount: Int64
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64
}

private struct CorpusTopLevelInventory: Codable, Equatable, Sendable {
  let entries: [CorpusTopLevelEntry]
  let regularCount: Int
  let directoryCount: Int
  let symlinkCount: Int
  let otherCount: Int
  let hiddenRegularCount: Int

  static func capture(directory: URL) throws -> Self {
    let urls = try FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: nil, options: [])
    var entries: [CorpusTopLevelEntry] = []
    var regular = 0, directories = 0, symlinks = 0, other = 0, hidden = 0
    for url in urls {
      var value = stat()
      guard lstat(url.path, &value) == 0 else { throw CorpusFailure("top_level_lstat_failed") }
      let type = value.st_mode & mode_t(S_IFMT)
      let kind: String
      if type == mode_t(S_IFREG) { kind = "regular"; regular += 1; if url.lastPathComponent.hasPrefix(".") { hidden += 1 } }
      else if type == mode_t(S_IFDIR) { kind = "directory"; directories += 1 }
      else if type == mode_t(S_IFLNK) { kind = "symlink"; symlinks += 1 }
      else { kind = "other"; other += 1 }
      entries.append(CorpusTopLevelEntry(pathSHA256: corpusPathHash(url), kind: kind,
        mode: UInt32(value.st_mode), byteCount: value.st_size,
        modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec)))
    }
    return Self(entries: entries.sorted { $0.pathSHA256 < $1.pathSHA256 },
      regularCount: regular, directoryCount: directories, symlinkCount: symlinks,
      otherCount: other, hiddenRegularCount: hidden)
  }
}

private func corpusPathHash(_ url: URL) -> String {
  SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
}
private struct CorpusResourceSample: Codable, Sendable {
  let elapsedSeconds: Double
  let processCPUSeconds: Double
  let sampledCPUPercentOneCore: Double
  let footprintBytes: UInt64?
  let memoryBytes: Int
  let memoryLimit: Int
  let previewDiskBytes: Int
  let exactDiskBytes: Int
  let diskBytes: Int
  let runningGovernedOperations: Int
  let queuedGovernedOperations: Int
}
private actor CorpusResourceSampler {
  let pipeline: ThumbnailPipeline
  let disk: ThumbnailDiskCache
  let governor: ImageResourceGovernor
  private var task: Task<Void, Never>?
  private var rows: [CorpusResourceSample] = []
  private var began = 0.0
  private var previousTime = 0.0
  private var previousCPU = 0.0
  init(pipeline: ThumbnailPipeline, disk: ThumbnailDiskCache, governor: ImageResourceGovernor) {
    self.pipeline = pipeline; self.disk = disk; self.governor = governor
  }
  func start(phase: String) async {
    task?.cancel(); rows.removeAll()
    began = ProcessInfo.processInfo.systemUptime
    previousTime = began; previousCPU = RealMixedThumbnailCorpusTests.cpuSeconds()
    await sample()
    task = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        guard let self else { return }
        await self.sample()
      }
    }
  }
  func finishPhase() async -> [CorpusResourceSample] {
    let previousTask = task
    task?.cancel(); task = nil
    await previousTask?.value
    await sample()
    return rows
  }
  private func sample() async {
    let memory = await pipeline.cacheSnapshot()
    let diskSnapshot = await disk.snapshot()
    let work = await governor.stateSnapshot()
    let now = ProcessInfo.processInfo.systemUptime, cpu = RealMixedThumbnailCorpusTests.cpuSeconds()
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    rows.append(CorpusResourceSample(elapsedSeconds: now - began, processCPUSeconds: cpu,
      sampledCPUPercentOneCore: max(0, cpu - previousCPU) / max(0.000001, now - previousTime) * 100,
      footprintBytes: result == 0 ? usage.ri_phys_footprint : nil,
      memoryBytes: memory.byteCount, memoryLimit: memory.byteLimit,
      previewDiskBytes: diskSnapshot.previewBytes, exactDiskBytes: diskSnapshot.exactBytes, diskBytes: diskSnapshot.byteCount,
      runningGovernedOperations: work.runningCount, queuedGovernedOperations: work.queuedCount))
    previousCPU = cpu; previousTime = now
  }
}
