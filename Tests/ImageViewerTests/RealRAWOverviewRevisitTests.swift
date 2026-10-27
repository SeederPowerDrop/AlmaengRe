import CoreGraphics
import Darwin
import Foundation
import Testing

@testable import ImageViewer

/// Opt-in, read-only measurements of overview thumbnails and returning to an
/// evicted area. Aggregate timings are logged; source paths and pixels are not.
@Suite("실제 RAW 몽땅보기 재방문 성능", .serialized)
struct RealRAWOverviewRevisitTests {
  @Test("메모리에서 지워진 RAW 썸네일의 디스크 재사용 비용을 비교한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_OVERVIEW_REVISIT"] == "1"),
    .timeLimit(.minutes(5)))
  func overviewAfterMemoryEviction() async throws {
    let assets = try fixtures()
    let originalVersions = assets.map { ImageFileVersion(url: $0.url) }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ImageViewer-overview-revisit-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = ThumbnailDiskCache(directory: directory,
      previewByteLimit: 128 * 1_024 * 1_024, exactByteLimit: 384 * 1_024 * 1_024)

    // The OS file cache is intentionally left alone. This compares app behavior
    // on the same real files; it does not claim cold-storage throughput.
    let baseline = try await phase(assets: assets, disk: nil)
    let enabled = try await phase(assets: assets, disk: disk)
    let diskSnapshot = await disk.snapshot()
    let compact = try await compactWarm(assets: Array(assets.prefix(16)))
    #expect(enabled.revisitDiskHits >= UInt64(assets.count),
      "Every revisit after the RAM purge must reuse a persisted thumbnail")
    #expect(diskSnapshot.byteCount <= diskSnapshot.byteLimit)
    #expect(baseline.revisitCache.byteLimit == enabled.revisitCache.byteLimit)
    #expect(assets.map { ImageFileVersion(url: $0.url) } == originalVersions,
      "Read-only overview loading changed source file metadata")

    let fields = reportFields(sourceCount: assets.count,
      sourceBytes: assets.compactMap(\.byteCount).reduce(Int64(0), +),
      baseline: baseline, enabled: enabled, disk: diskSnapshot, compact: compact)
    // Foundation can raise an Objective-C exception rather than throw for a boxed
    // Swift Optional. Validate first so a reporting error cannot abort the process.
    try #require(JSONSerialization.isValidJSONObject(fields),
      "Invalid benchmark JSON values: \(invalidJSONValues(in: fields).joined(separator: ", "))")
    let encoded = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    FileHandle.standardOutput.write(
      Data("RAW_OVERVIEW_REVISIT_PERFORMANCE ".utf8) + encoded + Data("\n".utf8))
    await disk.removeAll()
  }

  @Test("집계 보고서의 혼합 숫자와 중첩 객체가 유효한 JSON이다")
  func aggregateReportIsValidJSON() throws {
    let pass = Pass(wallSeconds: 0.04, cpuSeconds: 0.02, latencies: [0.01, 0.03],
      totalBitmapBytes: 100, sampledPeakFootprintBytes: 200,
      processLifetimePeakFootprintBytes: 300, processLifetimePeakRSSBytes: 400)
    let cache = ImageCacheSnapshot(entryCount: 2, byteCount: 100, byteLimit: 200)
    let phase = Phase(first: pass, revisit: pass, firstCache: cache, revisitCache: cache,
      revisitDiskHits: 2)
    let disk = ThumbnailDiskCacheSnapshot(entryCount: 2, byteCount: 20, byteLimit: 100,
      previewBytes: 5, exactBytes: 15, hits: 2, misses: 1)
    let compact: [String: Any] = [
      "sourceCount": 2,
      "averageDiskBytesPerImage": 10.0,
      "cacheOnlyRestoration": pass.fields,
      "restorationDiskHits": UInt64(2),
    ]
    let fields = reportFields(sourceCount: 2, sourceBytes: 1_000,
      baseline: phase, enabled: phase, disk: disk, compact: compact)
    #expect(pass.fields["maximumSeconds"] as? Double == 0.03)
    try #require(JSONSerialization.isValidJSONObject(fields),
      "Invalid benchmark JSON values: \(invalidJSONValues(in: fields).joined(separator: ", "))")
    let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    let decodedObject = try JSONSerialization.jsonObject(with: data)
    let decoded = try #require(decodedObject as? [String: Any])
    #expect(decoded["disk"] is [String: Any])
    #expect(decoded["withDisk"] is [String: Any])
    #expect(invalidJSONValues(in: ["optional": Optional<Double>.some(1) as Any])
      == ["$.optional: Swift.Optional<Swift.Double>"])
  }

  private func reportFields(sourceCount: Int, sourceBytes: Int64, baseline: Phase,
    enabled: Phase, disk: ThumbnailDiskCacheSnapshot, compact: [String: Any]) -> [String: Any] {
    let diskFields: [String: Any] = [
      "entryCount": disk.entryCount,
      "byteCount": disk.byteCount,
      "byteLimit": disk.byteLimit,
      "previewBytes": disk.previewBytes,
      "exactBytes": disk.exactBytes,
      "hits": disk.hits,
      "misses": disk.misses,
    ]
    return [
      "readOnly": true,
      "sourceCount": sourceCount,
      "requestedPixelSize": 768,
      "sourceBytes": sourceBytes,
      "baselineWithoutDisk": baseline.fields,
      "withDisk": enabled.fields,
      "compactWarmSample": compact,
      "revisitWallRatioWithDiskToBaseline": enabled.revisit.wallSeconds
        / max(0.000_001, baseline.revisit.wallSeconds),
      "disk": diskFields,
      "measurementScope": "sequential_visible_requests_without_stable_visibility_delay",
      "evictionScope": "explicit_RAM_only_purge_after_first_pass",
      "cpuCounterScope": "calling_process_only",
      "storageCacheScope": "OS_file_cache_uncontrolled_baseline_precedes_disk_phase",
      "resourcePolicyScope": "fixed_normal_pressure_nominal_thermal_active_comfortable_internal_SSD_CPU_fraction_0.1_live_pressure_monitor_disabled_for_benchmark_only",
      "memoryCounterScope": "sampled_physical_footprint_per_pass_and_process_lifetime_high_water_mark",
    ]
  }

  private func invalidJSONValues(in value: Any, path: String = "$") -> [String] {
    if Mirror(reflecting: value).displayStyle == .optional {
      return ["\(path): \(String(reflecting: type(of: value)))"]
    }
    if let dictionary = value as? [String: Any] {
      return dictionary.keys.sorted().flatMap { key in
        invalidJSONValues(in: dictionary[key]!, path: path + "." + key)
      }
    }
    if let array = value as? [Any] {
      return array.enumerated().flatMap { index, element in
        invalidJSONValues(in: element, path: path + "[\(index)]")
      }
    }
    if let number = value as? NSNumber {
      return number.doubleValue.isFinite ? [] : ["\(path): nonfinite number"]
    }
    if value is String || value is NSNull { return [] }
    return ["\(path): \(String(reflecting: type(of: value)))"]
  }

  private func compactWarm(assets: [ImageAsset]) async throws -> [String: Any] {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ImageViewer-overview-compact-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = ThumbnailDiskCache(directory: directory,
      previewByteLimit: 128 * 1_024 * 1_024, exactByteLimit: 384 * 1_024 * 1_024)
    var snapshot = ImageResourceSnapshot.currentHardware
    snapshot.isAppActive = true
    snapshot.lowPowerMode = false
    snapshot.thermal = .nominal
    snapshot.memoryPressure = .normal
    snapshot.cpuBusyFraction = 0.1
    let governor = ImageResourceGovernor(mode: .comfortable, snapshot: snapshot,
      storageOverride: .internalSSD, monitorsMemoryPressure: false)
    let pipeline = ThumbnailPipeline(governor: governor, diskCache: disk)

    let warmBefore = processUsage()
    let warmStarted = now
    for asset in assets {
      try Task.checkCancellation()
      #expect(await pipeline.warmOverviewPreviews(assets: [asset]))
    }
    let warmWall = now - warmStarted
    let warmAfter = processUsage()
    let beforeRestoring = await pipeline.cacheSnapshot()
    #expect(beforeRestoring.byteCount == 0 && beforeRestoring.entryCount == 0,
      "Idle compact warming must not occupy the thumbnail RAM cache")
    let diskBefore = await disk.snapshot()
    #expect(diskBefore.entryCount == assets.count)
    #expect(diskBefore.exactBytes == 0)

    let restoreBefore = processUsage()
    let restoreStarted = now
    var restoreLatencies: [Double] = []
    var bitmapBytes = 0
    var peakFootprint = footprintUsage()?.current ?? 0
    for asset in assets {
      let requested = now
      let image = try #require(await pipeline.cachedPreview(for: asset, maxPixelSize: 768),
        "The compact disk preview should provide immediate first pixels without reading RAW")
      #expect(max(image.width, image.height) <= 256)
      try materialize(image)
      restoreLatencies.append(now - requested)
      bitmapBytes += image.bytesPerRow * image.height
      peakFootprint = max(peakFootprint, footprintUsage()?.current ?? 0)
    }
    let restoreWall = now - restoreStarted
    let restoreAfter = processUsage()
    let restoreFootprint = footprintUsage()
    let restoration = Pass(wallSeconds: restoreWall,
      cpuSeconds: max(0, restoreAfter.cpuSeconds - restoreBefore.cpuSeconds),
      latencies: restoreLatencies, totalBitmapBytes: bitmapBytes,
      sampledPeakFootprintBytes: peakFootprint,
      processLifetimePeakFootprintBytes: restoreFootprint?.peak ?? 0,
      processLifetimePeakRSSBytes: restoreAfter.peakResidentBytes)
    let diskAfter = await disk.snapshot()
    #expect(diskAfter.hits - diskBefore.hits >= UInt64(assets.count))
    let restoredMemory = await pipeline.cacheSnapshot()
    #expect(restoredMemory.byteCount <= restoredMemory.byteLimit)
    let averageBytes = Double(diskBefore.byteCount) / Double(max(1, assets.count))
    let fields: [String: Any] = [
      "sourceCount": assets.count,
      "maximumPixelSize": 256,
      "warmWallSeconds": warmWall,
      "warmCPUSeconds": max(0, warmAfter.cpuSeconds - warmBefore.cpuSeconds),
      "memoryBytesBeforeCachedRestores": beforeRestoring.byteCount,
      "diskBytes": diskBefore.byteCount,
      "diskPreviewBytes": diskBefore.previewBytes,
      "diskExactBytes": diskBefore.exactBytes,
      "averageDiskBytesPerImage": averageBytes,
      "estimatedDiskBytesFor729Images": averageBytes * 729,
      "estimateScope": "linear_extrapolation_from_first_16_images_not_full_folder_measurement",
      "resourcePolicyScope": "normal_pressure_nominal_thermal_active_comfortable_internal_SSD_CPU_fraction_0.1_override",
      "cacheOnlyRestoration": restoration.fields,
      "restorationDiskHits": diskAfter.hits - diskBefore.hits,
      "memoryBytesAfterCachedRestores": restoredMemory.byteCount,
      "memoryCacheLimitBytes": restoredMemory.byteLimit,
    ]
    await pipeline.purgeCache()
    await disk.removeAll()
    return fields
  }

  private struct Pass {
    let wallSeconds: Double
    let cpuSeconds: Double
    let latencies: [Double]
    let totalBitmapBytes: Int
    let sampledPeakFootprintBytes: UInt64
    let processLifetimePeakFootprintBytes: UInt64
    let processLifetimePeakRSSBytes: Int64

    var fields: [String: Any] {
      let sorted = latencies.sorted()
      func percentile(_ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))]
      }
      // Give nil coalescing an explicit numeric context before erasing to Any.
      // Otherwise Swift may box the Optional itself inside the JSON dictionary.
      let maximum: Double = sorted.last ?? 0
      return [
        "count": latencies.count,
        "wallSeconds": wallSeconds,
        "cpuSeconds": cpuSeconds,
        "p50Seconds": percentile(0.5),
        "p95Seconds": percentile(0.95),
        "maximumSeconds": maximum,
        "totalBitmapBytes": totalBitmapBytes,
        "sampledPeakFootprintBytes": sampledPeakFootprintBytes,
        "processLifetimePeakFootprintBytes": processLifetimePeakFootprintBytes,
        "processLifetimePeakRSSBytes": processLifetimePeakRSSBytes,
      ]
    }
  }

  private struct Phase {
    let first: Pass
    let revisit: Pass
    let firstCache: ImageCacheSnapshot
    let revisitCache: ImageCacheSnapshot
    let revisitDiskHits: UInt64

    var fields: [String: Any] {
      [
        "first": first.fields,
        "revisit": revisit.fields,
        "memoryCacheLimitBytes": revisitCache.byteLimit,
        "firstMemoryCacheBytes": firstCache.byteCount,
        "firstMemoryCacheEntries": firstCache.entryCount,
        "revisitMemoryCacheBytes": revisitCache.byteCount,
        "revisitMemoryCacheEntries": revisitCache.entryCount,
        "revisitDiskHits": revisitDiskHits,
        "bitmapWorkingSetExceedsMemoryLimit": first.totalBitmapBytes > firstCache.byteLimit,
      ]
    }
  }

  private func phase(assets: [ImageAsset], disk: ThumbnailDiskCache?) async throws -> Phase {
    var snapshot = ImageResourceSnapshot.currentHardware
    snapshot.isAppActive = true
    snapshot.lowPowerMode = false
    snapshot.thermal = .nominal
    snapshot.memoryPressure = .normal
    snapshot.cpuBusyFraction = 0.1
    let governor = ImageResourceGovernor(mode: .comfortable, snapshot: snapshot,
      storageOverride: .internalSSD, monitorsMemoryPressure: false)
    let pipeline = ThumbnailPipeline(governor: governor, diskCache: disk)
    let first = try await pass(assets: assets, pipeline: pipeline)
    let firstCache = await pipeline.cacheSnapshot()
    #expect(firstCache.byteCount <= firstCache.byteLimit)
    await pipeline.purgeCache()
    let purged = await pipeline.cacheSnapshot()
    #expect(purged.byteCount == 0 && purged.entryCount == 0)
    let beforeHits = await disk?.snapshot().hits ?? 0
    let revisit = try await pass(assets: assets, pipeline: pipeline)
    let afterHits = await disk?.snapshot().hits ?? 0
    let revisitCache = await pipeline.cacheSnapshot()
    #expect(revisitCache.byteCount <= revisitCache.byteLimit)
    await pipeline.purgeCache()
    return Phase(first: first, revisit: revisit, firstCache: firstCache,
      revisitCache: revisitCache, revisitDiskHits: afterHits - beforeHits)
  }

  private func pass(assets: [ImageAsset], pipeline: ThumbnailPipeline) async throws -> Pass {
    let before = processUsage()
    let started = now
    var latencies: [Double] = []
    var bitmapBytes = 0
    var peakFootprint = footprintUsage()?.current ?? 0
    for asset in assets {
      try Task.checkCancellation()
      let requestStarted = now
      let image = try await pipeline.thumbnail(for: asset, maxPixelSize: 768, priority: .visible,
        waitsForStableVisibility: false)
      try materialize(image)
      latencies.append(now - requestStarted)
      bitmapBytes += image.bytesPerRow * image.height
      peakFootprint = max(peakFootprint, footprintUsage()?.current ?? 0)
    }
    let wall = now - started
    let after = processUsage()
    let footprint = footprintUsage()
    return Pass(wallSeconds: wall, cpuSeconds: max(0, after.cpuSeconds - before.cpuSeconds),
      latencies: latencies, totalBitmapBytes: bitmapBytes,
      sampledPeakFootprintBytes: peakFootprint,
      processLifetimePeakFootprintBytes: footprint?.peak ?? 0,
      processLifetimePeakRSSBytes: after.peakResidentBytes)
  }

  private func fixtures() throws -> [ImageAsset] {
    let path = ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_DIRECTORY"]
      ?? "/Users/hyunjinkim/Pictures/iPhoneRAW"
    let urls = try FileManager.default.contentsOfDirectory(
      at: URL(fileURLWithPath: path, isDirectory: true),
      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
      options: [.skipsHiddenFiles])
    let assets = try urls.filter { $0.pathExtension.lowercased() == "dng" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { url -> ImageAsset? in
        let values = try url.resourceValues(
          forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 0 else { return nil }
        return ImageAsset(url: url, byteCount: Int64(bytes), modificationDate: values.contentModificationDate)
      }
    try #require(assets.count >= 48, "At least 48 nonempty DNG fixtures are required")
    return Array(assets.prefix(48))
  }

  private func materialize(_ image: CGImage) throws {
    #expect(image.width > 0 && image.height > 0)
    #expect(max(image.width, image.height) <= 768)
    let side = 8
    let context = try #require(CGContext(data: nil, width: side, height: side,
      bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    #expect(context.data != nil)
  }

  private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

  private func processUsage() -> (cpuSeconds: Double, peakResidentBytes: Int64) {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return (0, 0) }
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    return (user + system, Int64(usage.ru_maxrss))
  }

  private func footprintUsage() -> (current: UInt64, peak: UInt64)? {
    var usage = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
      }
    }
    guard status == 0 else { return nil }
    return (usage.ri_phys_footprint, usage.ri_lifetime_max_phys_footprint)
  }
}
