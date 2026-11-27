import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Metal
import Testing

@testable import ImageViewer

/// Explicit component benchmark. Same fixed foreground policy and allowance on
/// both paths; no claim of GUI latency, full-pipeline GPU time, FPS or energy.
@Suite("실제 RAW Metal 편집 경로 비교", .serialized)
struct RealRAWMetalPerformanceTests {
  @Test("RAW 정밀 입력의 첫 보정·반복 보정·HDR·정리 비용을 비교한다",
    .enabled(if: ProcessInfo.processInfo.environment["RAW_METAL_PERFORMANCE"] == "1"),
    .timeLimit(.minutes(4)))
  func editingWorkload() async throws {
    let env = ProcessInfo.processInfo.environment
    let count = Int(env["RAW_METAL_SOURCE_COUNT"] ?? "4") ?? 4
    let edits = Int(env["RAW_METAL_EDITS"] ?? "8") ?? 8
    try #require((1...32).contains(count) && (1...16).contains(edits))
    let path = try #require(env["IMAGEVIEWER_RAW_DIRECTORY"])
    let files = try select(URL(fileURLWithPath: path), count: count)
    let versions = files.map { ImageFileVersion(url: $0) }
    let identities = zip(files, versions).map { url, version in
      [SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined(),
        String(version.byteCount ?? 0), String(version.modificationDate?.timeIntervalSince1970 ?? 0)]
    }
    let sourceDigest = SHA256.hash(data: try JSONSerialization.data(withJSONObject: identities,
      options: [.sortedKeys])).map { String(format: "%02x", $0) }.joined()
    let usesMetal = env["RAW_METAL_DISABLE"] != "1"
    // The production build enables both features. Measure each independently
    // to separate editing costs from memory reclaimed at purge.
    let releasesContexts: Bool
    if let override = env["RAW_METAL_RELEASE_CONTEXTS"] {
      try #require(["0", "1"].contains(override))
      releasesContexts = override == "1"
    } else {
      releasesContexts = usesMetal
    }
    var snapshot = ImageResourceSnapshot.currentHardware
    snapshot.isAppActive = true
    snapshot.memoryPressure = .normal
    snapshot.thermal = .nominal
    snapshot.lowPowerMode = false
    snapshot.cpuBusyFraction = 0.1
    let governor = ImageResourceGovernor(mode: .comfortable, snapshot: snapshot,
      storageOverride: .internalSSD, monitorsMemoryPressure: false)
    let pipeline = ImagePipeline(governor: governor, usesMetalRAWInputs: usesMetal,
      releasesRenderContextsOnPurge: releasesContexts)
    let started = now, CPUStart = cpu()
    var firstEdit: [Double] = [], preview: [Double] = [], detail: [Double] = [], identity: [Double] = []
    var renderCount = 0
    for url in files {
      let identityStarted = now
      let first = try await pipeline.renderFrame(url: url, maxPixelSize: 1_536,
        adjustments: .identity, prefersHDR: true)
      try consume(first.image)
      identity.append(now-identityStarted)
      renderCount += 1
      var adjustment = ImageAdjustments.identity
      for index in 0..<edits {
        adjustment.exposure = 0.2 + Double(index) * 0.07
        adjustment.temperature = Double(index % 4) * 4
        adjustment.vibrance = Double(index % 3) * 0.04
        let hdr = index >= edits/2
        let previewStarted = now
        // ViewerImageTile requests SDR for the interactive drag even on an HDR display.
        let small = try await pipeline.renderFrame(url: url, maxPixelSize: 512,
          adjustments: adjustment, prefersHDR: false, priority: .interactivePreview)
        try consume(small.image)
        preview.append(now-previewStarted)
        let detailStarted = now
        let large = try await pipeline.renderFrame(url: url, maxPixelSize: 1_536,
          adjustments: adjustment, prefersHDR: hdr)
        try consume(large.image)
        let duration = now-detailStarted
        detail.append(duration)
        if index == 0 { firstEdit.append(duration) }
        #expect(large.sourcePixelSize == first.sourcePixelSize)
        if hdr {
          #expect(large.image.bitsPerComponent >= 16 && large.image.bitmapInfo.contains(.floatComponents))
          #expect(large.image.colorSpace?.name == CGColorSpace.extendedLinearDisplayP3)
        }
        renderCount += 2
      }
    }
    let wall = now-started, CPU = cpu()-CPUStart
    let reused = await pipeline.decodeReuseSnapshot()
    let cache = await pipeline.cacheSnapshot()
    #expect(cache.byteCount <= cache.byteLimit)
    if usesMetal {
      #expect(reused.metalPreparedCount > 0 && reused.metalReuseCount > 0)
    } else {
      #expect(reused.metalPreparedCount == 0 && reused.metalReuseCount == 0)
    }
    #expect(files.map { ImageFileVersion(url: $0) } == versions)
    let live = footprint()
    let gpu = MTLCreateSystemDefaultDevice()
    let metalBytesBeforePurge = gpu?.currentAllocatedSize
    await pipeline.purgeCaches()
    #expect(await pipeline.cacheSnapshot().byteCount == 0)
    try await Task.sleep(for: .milliseconds(250))
    var fields: [String: Any] = [
      "usesMetal": usesMetal, "sourceCount": count, "editsPerSource": edits,
      "releasesRenderContextsOnPurge": releasesContexts, "interactivePreviewHDR": false,
      "renderCount": renderCount, "sourceIdentityDigest": sourceDigest,
      "wallSeconds": wall, "cpuSeconds": CPU,
      "identitySeconds": stats(identity), "firstPreciseEditSeconds": stats(firstEdit),
      "previewSeconds": stats(preview), "detailSeconds": stats(detail),
      "cacheBytes": cache.byteCount, "cacheLimitBytes": cache.byteLimit,
      "inputCacheBytes": reused.cache.byteCount, "inputCacheLimitBytes": reused.cache.byteLimit,
      "preparedInputCount": reused.decodedFrameCount, "inputReuseCount": reused.reuseCount,
      "metalPreparedCount": reused.metalPreparedCount, "metalReuseCount": reused.metalReuseCount,
      "sourceMetadataUnchanged": true, "cacheEmptyAfterPurge": true,
      "scope": "actual_ImagePipeline_fixed_active_visible_nominal_normal_pressure_CPU_busy_0.1_no_low_power_actual_hardware_internalSSD_same_cache_allowance_native_pressure_monitor_disabled_for_controlled_component_comparison_new_app_caches_OS_caches_uncontrolled",
      "timingScope": "includes_decode_color_conversion_CPU_sample_and_actor_admission_not_physical_paint_or_FPS",
      "gpuTimingScope": "Metal_prepared_input_kernels_only_not_total_GPU_time_or_utilization_legacy_not_instrumented",
      "metalAllocationScope": "MTLDevice_currentAllocatedSize_only_not_total_GPU_memory_or_utilization_IOSurface_storage_may_not_be_included",
      "sourcePathsExported": false, "sourcePixelsExported": false,
    ]
    fields["preparationGPUKernelSeconds"] = usesMetal ? reused.metalKernelSeconds : NSNull()
    fields["preparationKernelCompileSeconds"] = usesMetal ? reused.metalCompileSeconds : NSNull()
    if let live {
      fields["physicalFootprintBytesBeforePurge"] = live.current
      fields["processLifetimePeakPhysicalFootprintBytes"] = live.peak
    }
    if let released = footprint() { fields["physicalFootprintBytesAfterPurge"] = released.current }
    if let metalBytesBeforePurge { fields["metalDeviceAllocatedBytesBeforePurge"] = metalBytesBeforePurge }
    if let released = gpu?.currentAllocatedSize { fields["metalDeviceAllocatedBytesAfterPurge"] = released }
    let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    FileHandle.standardOutput.write(Data("RAW_METAL_PERFORMANCE ".utf8) + data + Data([10]))
  }

  private var now: Double { ProcessInfo.processInfo.systemUptime }

  @Test("같은 내보내기 엔진에서 원본 크기 HDR HEIC를 연속 저장한 뒤 메모리를 측정한다",
    .enabled(if: ProcessInfo.processInfo.environment["RAW_HEIC_BATCH_PERFORMANCE"] == "1"),
    .timeLimit(.minutes(4)))
  func repeatedHEICSaves() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_DIRECTORY"])
    let files = try select(URL(fileURLWithPath: path), count: 4)
    let originals = files.map { ImageFileVersion(url: $0) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("heic-batch-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let pipeline = ImagePipeline()
    let exporter = ImageExporter(pipeline: pipeline)
    let destination = directory.appendingPathComponent("export.heic")
    var adjustment = ImageAdjustments.identity
    adjustment.exposure = 0.7
    var afterSave: [UInt64] = []
    let initial = try #require(footprint())
    let start = now
    for _ in 0..<3 {
      for source in files {
        try await exporter.export(sourceURL: source, destinationURL: destination,
          format: .heic, quality: 1, adjustments: adjustment)
        try autoreleasepool {
          let container = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
          let image = try #require(CGImageSourceCreateImageAtIndex(container, 0,
            [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
              kCGImageSourceShouldCache: false] as CFDictionary))
          #expect(CGColorSpaceUsesITUR_2100TF(try #require(image.colorSpace)))
        }
        try FileManager.default.removeItem(at: destination)
        afterSave.append(try #require(footprint()).current)
      }
    }
    let seconds = now - start
    let beforePurge = try #require(footprint())
    await pipeline.purgeCaches()
    try await Task.sleep(for: .milliseconds(250))
    let afterPurge = try #require(footprint())
    withExtendedLifetime(exporter) {}
    #expect(files.map { ImageFileVersion(url: $0) } == originals)
    let metrics: [String: Any] = ["uniqueDNGs": files.count, "saves": afterSave.count,
      "wallSeconds": seconds, "initialPhysicalFootprint": initial.current,
      "afterEachSave": afterSave, "physicalFootprintBeforePurge": beforePurge.current,
      "physicalFootprintAfterPurge": afterPurge.current, "processLifetimePeak": afterPurge.peak,
      "scope": "one process, the same exporter kept alive, twelve full-resolution saves of four real files"]
    let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
    FileHandle.standardOutput.write(Data("RAW_HEIC_BATCH ".utf8) + data + Data([10]))
  }

  private func select(_ directory: URL, count: Int) throws -> [URL] {
    let candidates = try FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
      .filter { $0.pathExtension.lowercased() == "dng" }
      .compactMap { url -> (URL, Int)? in
        let value = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard value.isRegularFile == true, let size = value.fileSize, size > 0 else { return nil }
        return (url, size)
      }.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }
    var selected: [URL] = []
    for (url, _) in candidates.prefix(128) {
      guard let source = CGImageSourceCreateWithURL(url as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary) else { continue }
      var hdr = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
      if #available(macOS 15.0, *), !hdr {
        hdr = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
      }
      if hdr { selected.append(url) }
      if selected.count == count { break }
    }
    try #require(selected.count == count, "Enough gain-map DNG files are required")
    return selected
  }

  private func stats(_ values: [Double]) -> [String: Double] {
    let sorted = values.sorted()
    return ["mean": values.reduce(0,+)/Double(values.count),
      "p50": sorted[sorted.count/2], "p95": sorted[Int(ceil(Double(sorted.count)*0.95))-1]]
  }

  private func consume(_ image: CGImage) throws {
    let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 32,
      bytesPerRow: 8*16, space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
      bitmapInfo: CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
    let samples = context.data!.assumingMemoryBound(to: Float.self)
    #expect(UnsafeBufferPointer(start: samples, count: 8*8*4).allSatisfy { $0.isFinite })
  }

  private func cpu() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)/1_000_000
  }

  private func footprint() -> (current: UInt64, peak: UInt64)? {
    var usage = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
      }
    }
    return status == 0 ? (usage.ri_phys_footprint, usage.ri_lifetime_max_phys_footprint) : nil
  }
}
