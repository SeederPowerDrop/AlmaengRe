import CoreGraphics
import Darwin
import Foundation
import Testing

@testable import ImageViewer

/// Opt-in, read-only comparison of the actual editing pipeline. Run in isolation
/// with RAW_ADJUSTMENT_PERFORMANCE=1 and IMAGEVIEWER_RAW_FILE, or a RAW directory.
/// Logs aggregate timings/resources only; never exports pixels or records paths.
@Suite("실제 RAW 조정 응답 성능", .serialized)
struct RealRAWAdjustmentPerformanceTests {
  @Test("서로 다른 색상 조정의 미리보기·상세 표시와 HDR 품질을 측정한다",
    .enabled(if: ProcessInfo.processInfo.environment["RAW_ADJUSTMENT_PERFORMANCE"] == "1"),
    .timeLimit(.minutes(3)))
  func sequentialColorAdjustments() async throws {
    let url = try fixtureURL()
    let original = ImageFileVersion(url: url)
    let governor = ImageResourceGovernor(mode: .comfortable, storageOverride: .internalSSD)
    let reusesInputs = ProcessInfo.processInfo.environment["RAW_ADJUSTMENT_DISABLE_REUSE"] != "1"
    let pipeline = ImagePipeline(governor: governor, reusesDecodedInputs: reusesInputs)

    let warmStarted = now
    let identity = try await pipeline.renderFrame(url: url, maxPixelSize: 2_048,
      adjustments: .identity, prefersHDR: false)
    try validate(identity, maximumPixels: 2_048, sourceSize: nil)
    let warmSeconds = now - warmStarted
    let sourceSize = try #require(identity.sourcePixelSize)

    let before = processUsage()
    let started = now
    var previewSeconds: [Double] = []
    var detailSeconds: [Double] = []
    var adjustments = ImageAdjustments.identity
    for index in 0..<12 {
      // Cumulative, distinct values exercise the graph used by several sliders,
      // while alternating sizes reproduces preview/detail input contention.
      switch index % 6 {
      case 0: adjustments.exposure += 0.35
      case 1: adjustments.brightness += 0.08
      case 2: adjustments.contrast += 0.12
      case 3: adjustments.temperature += 12
      case 4: adjustments.vibrance += 0.15
      default: adjustments.saturation -= 0.08
      }
      let previewStarted = now
      let preview = try await pipeline.renderFrame(url: url, maxPixelSize: 512,
        adjustments: adjustments, prefersHDR: false, priority: .interactivePreview)
      try validate(preview, maximumPixels: 512, sourceSize: sourceSize)
      previewSeconds.append(now - previewStarted)

      let detailStarted = now
      let detail = try await pipeline.renderFrame(url: url, maxPixelSize: 2_048,
        adjustments: adjustments, prefersHDR: false)
      try validate(detail, maximumPixels: 2_048, sourceSize: sourceSize)
      detailSeconds.append(now - detailStarted)
    }
    let editWallSeconds = now - started
    let afterEdits = processUsage()
    let hdrStarted = now
    let hdr = try await pipeline.renderFrame(url: url, maxPixelSize: 2_048,
      adjustments: adjustments, prefersHDR: true)
    try validate(hdr, maximumPixels: 2_048, sourceSize: sourceSize)
    let hdrSeconds = now - hdrStarted
    #expect(hdr.image.bitsPerComponent >= 16)
    #expect(hdr.image.bitmapInfo.contains(.floatComponents))
    #expect(ImageFileVersion(url: url) == original, "Read-only editing changed source file metadata")

    let afterHDR = processUsage()
    let cache = await pipeline.cacheSnapshot()
    #expect(cache.byteCount <= cache.byteLimit)
    let sourceBytes: Int = original.byteCount ?? 0
    var fields: [String: Any] = [
      "readOnly": true,
      "inputReuseEnabled": reusesInputs,
      "editCount": 12,
      "renderCount": previewSeconds.count + detailSeconds.count,
      "sourceBytes": sourceBytes,
      "sourceWidth": sourceSize.width,
      "sourceHeight": sourceSize.height,
      "warmIdentitySeconds": warmSeconds,
      "wallSeconds": editWallSeconds,
      "cpuSeconds": max(0, afterEdits.cpuSeconds - before.cpuSeconds),
      "preview": statistics(previewSeconds),
      "detail": statistics(detailSeconds),
      "allRenders": statistics(previewSeconds + detailSeconds),
      "hdrFinalSeconds": hdrSeconds,
      "hdrCPUSeconds": max(0, afterHDR.cpuSeconds - afterEdits.cpuSeconds),
      "hdrBitsPerComponent": hdr.image.bitsPerComponent,
      "processPeakRSSBytes": afterHDR.peakResidentBytes,
      "renderCacheBytes": cache.byteCount,
      "renderCacheLimitBytes": cache.byteLimit,
      "memoryCounterScope": "process_lifetime_high_water_mark_includes_warmup",
      "cpuCounterScope": "calling_process_only",
    ]
    if let resources = footprintUsage() {
      fields["physicalFootprintBytes"] = resources.current
      fields["processLifetimePeakFootprintBytes"] = resources.peak
    }
    if reusesInputs {
      let reuse = await pipeline.decodeReuseSnapshot()
      fields["decodedInputCount"] = reuse.decodedFrameCount
      fields["decodedInputReuseCount"] = reuse.reuseCount
      fields["decodedInputCacheBytes"] = reuse.cache.byteCount
      fields["decodedInputCacheLimitBytes"] = reuse.cache.byteLimit
    }
    let encoded = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    FileHandle.standardOutput.write(Data("RAW_ADJUSTMENT_PERFORMANCE ".utf8) + encoded + Data("\n".utf8))
    await pipeline.purgeCaches()
  }

  private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

  private func fixtureURL() throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    if let path = environment["IMAGEVIEWER_RAW_FILE"], !path.isEmpty {
      let url = URL(fileURLWithPath: path)
      try #require(url.pathExtension.lowercased() == "dng", "The fixture must be a DNG file")
      try #require((ImageFileVersion(url: url).byteCount ?? 0) > 0, "The fixture must contain data")
      return url
    }
    let path = try #require(environment["IMAGEVIEWER_RAW_DIRECTORY"], "A RAW file or directory is required")
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    let urls = try FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles])
    let candidates = try urls.filter { $0.pathExtension.lowercased() == "dng" }
      .compactMap { url -> (URL, Int)? in
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 0 else { return nil }
        return (url, bytes)
      }
    return try #require(candidates.max { $0.1 < $1.1 }?.0, "No nonempty DNG fixture was found")
  }

  private func validate(_ frame: RenderedFrame, maximumPixels: Int, sourceSize: CGSize?) throws {
    #expect(frame.image.width > 0 && frame.image.height > 0)
    #expect(max(frame.image.width, frame.image.height) <= maximumPixels)
    #expect(frame.frameCount > 0)
    let size = try #require(frame.sourcePixelSize)
    #expect(size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0)
    if let sourceSize { #expect(size == sourceSize) }
    // Materialize a tiny CPU-backed sample so a lazily supplied image cannot
    // make timing end before any pixels are consumed. Retain or log no samples.
    let side = 8
    let context = try #require(CGContext(data: nil, width: side, height: side,
      bitsPerComponent: 32, bytesPerRow: side * 4 * MemoryLayout<Float>.size,
      space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
    context.draw(frame.image, in: CGRect(x: 0, y: 0, width: side, height: side))
    let pixels = try #require(context.data).assumingMemoryBound(to: Float.self)
    #expect(UnsafeBufferPointer(start: pixels, count: side * side * 4).allSatisfy { $0.isFinite })
  }

  private func statistics(_ seconds: [Double]) -> [String: Any] {
    let sorted = seconds.sorted()
    func percentile(_ fraction: Double) -> Double {
      guard !sorted.isEmpty else { return 0 }
      return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))]
    }
    let maximum: Double = sorted.last ?? 0
    return ["count": seconds.count, "meanSeconds": seconds.reduce(0, +) / Double(max(1, seconds.count)),
      "p50Seconds": percentile(0.5), "p95Seconds": percentile(0.95), "maxSeconds": maximum]
  }

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
