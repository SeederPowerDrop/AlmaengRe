import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

/// Isolated fitted-frame workload, not screen latency/FPS or a live resource-
/// policy measurement. App caches start empty; OS/codec caches are uncontrolled.
@Suite("실제 보정 없는 RAW의 중간 복사 비용", .serialized)
struct RealRAWUneditedDisplayTests {
  @Test("동일한 RAW·SDR/HDR 크기를 이전 경로와 비교하고 중간 보유량을 검사한다",
    .enabled(if: ProcessInfo.processInfo.environment["RAW_UNEDITED_DISPLAY_PERFORMANCE"] == "1"),
    .timeLimit(.minutes(3)))
  func displayWithoutPreparingEditingInputs() async throws {
    let environment = ProcessInfo.processInfo.environment
    let path = try #require(environment["IMAGEVIEWER_RAW_DIRECTORY"])
    let requestedCount = Int(environment["RAW_UNEDITED_DISPLAY_SOURCE_COUNT"] ?? "4") ?? 4
    try #require((1...32).contains(requestedCount))
    let source = URL(fileURLWithPath: path, isDirectory: true)
    let urls = try FileManager.default.contentsOfDirectory(at: source,
      includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
      .filter { $0.pathExtension.lowercased() == "dng" }
      .sorted { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        > (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
    var selected: [URL] = []
    for url in urls.prefix(128) {
      guard let imageSource = CGImageSourceCreateWithURL(url as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary) else { continue }
      if CGImageSourceCopyAuxiliaryDataInfoAtIndex(imageSource, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
        selected.append(url)
      } else if #available(macOS 15.0, *),
        CGImageSourceCopyAuxiliaryDataInfoAtIndex(imageSource, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil {
        selected.append(url)
      }
      if selected.count == requestedCount { break }
    }
    try #require(selected.count == requestedCount, "Enough nonempty gain-map DNGs are needed for this workload")
    let before = selected.map { ImageFileVersion(url: $0) }
    let prepares = environment["RAW_ADJUSTMENT_PREPARE_UNEDITED"] == "1"
    var snapshot = ImageResourceSnapshot.currentHardware
    snapshot.isAppActive = true
    snapshot.memoryPressure = .normal
    snapshot.thermal = .nominal
    snapshot.lowPowerMode = false
    snapshot.cpuBusyFraction = 0.1
    let governor = ImageResourceGovernor(mode: .comfortable, snapshot: snapshot, storageOverride: .internalSSD)
    let pipeline = ImagePipeline(governor: governor, preparesUneditedRAWInputs: prepares)
    let started = ProcessInfo.processInfo.systemUptime
    let cpuBefore = cpuSeconds()
    var elapsed: [Double] = []
    var renderCount = 0
    for hdr in [false, true] {
      for pixels in [512, 1_536] {
        for url in selected {
          let start = ProcessInfo.processInfo.systemUptime
          let frame = try await pipeline.renderFrame(url: url, maxPixelSize: pixels,
            adjustments: .identity, prefersHDR: hdr)
          try consume(frame.image)
          elapsed.append(ProcessInfo.processInfo.systemUptime - start)
          renderCount += 1
          #expect(max(frame.image.width, frame.image.height) <= pixels)
          if hdr {
            #expect(frame.image.bitsPerComponent >= 16 && frame.image.bitmapInfo.contains(.floatComponents))
            #expect(frame.image.colorSpace?.name == CGColorSpace.extendedLinearDisplayP3)
          }
        }
      }
    }
    let wall = ProcessInfo.processInfo.systemUptime - started
    let cpu = cpuSeconds() - cpuBefore
    let inputs = await pipeline.decodeReuseSnapshot()
    let cache = await pipeline.cacheSnapshot()
    let displayFootprint = footprint()
    #expect(cache.byteCount <= cache.byteLimit)
    if prepares { #expect(inputs.decodedFrameCount > 0) }
    else { #expect(inputs.decodedFrameCount == 0 && inputs.cache.byteCount == 0) }
    // The first edit deliberately pays preparation on demand. Measure that
    // separately so faster browsing cannot hide a first-edit regression, and
    // verify that the following edit still reuses the precise working plane.
    let lastURL = try #require(selected.last)
    var adjustment = ImageAdjustments.identity
    adjustment.exposure = 0.4
    let firstEditStarted = ProcessInfo.processInfo.systemUptime
    let firstEdit = try await pipeline.renderFrame(url: lastURL, maxPixelSize: 1_536,
      adjustments: adjustment, prefersHDR: true)
    try consume(firstEdit.image)
    let firstEditSeconds = ProcessInfo.processInfo.systemUptime - firstEditStarted
    let beforeSecond = await pipeline.decodeReuseSnapshot()
    adjustment.exposure = 0.5
    let secondEditStarted = ProcessInfo.processInfo.systemUptime
    let secondEdit = try await pipeline.renderFrame(url: lastURL, maxPixelSize: 1_536,
      adjustments: adjustment, prefersHDR: true)
    try consume(secondEdit.image)
    let secondEditSeconds = ProcessInfo.processInfo.systemUptime - secondEditStarted
    #expect(await pipeline.decodeReuseSnapshot().reuseCount > beforeSecond.reuseCount)
    #expect(selected.map { ImageFileVersion(url: $0) } == before)
    var fields: [String: Any] = ["sourceCount": selected.count, "renderCount": renderCount,
      "preparesUneditedRAWInputs": prepares, "wallSeconds": wall, "cpuSeconds": cpu,
      "p50RenderSeconds": elapsed.sorted()[elapsed.count / 2],
      "p95RenderSeconds": elapsed.sorted()[Int(ceil(Double(elapsed.count) * 0.95)) - 1],
      "intermediatePlanesCreated": inputs.decodedFrameCount,
      "retainedInputBytes": inputs.cache.byteCount, "cacheBytes": cache.byteCount,
      "firstEditSeconds": firstEditSeconds, "secondEditSeconds": secondEditSeconds,
      "subsequentEditReusedPreparedInput": true,
      "cacheLimitBytes": cache.byteLimit, "sourceMetadataUnchanged": true,
      "sourcePathsExported": false, "sourcePixelsExported": false,
      "scope": "fitted_frame_pipeline_plus_8x8_CPU_consumption_not_physical_paint_or_GPU_utilization",
      "policy": "fixed_active_visible_nominal_normal_pressure_no_low_power_CPU_busy_0.1_actual_hardware",
      "cacheScope": "new_app_caches_OS_and_decoder_caches_uncontrolled_no_purge",
    ]
    if let footprint = displayFootprint { fields["displayPhysicalFootprintBytes"] = footprint }
    if let footprint = footprint() { fields["physicalFootprintBytes"] = footprint }
    fields["footprintScope"] = "displayPhysicalFootprintBytes_before_edits_physicalFootprintBytes_after_two_edits_not_heap_leak_proof"
    let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    FileHandle.standardOutput.write(Data("RAW_UNEDITED_DISPLAY_PERFORMANCE ".utf8) + data + Data([10]))
    await pipeline.purgeCaches()
  }

  private func consume(_ image: CGImage) throws {
    let side = 8
    let context = try #require(CGContext(data: nil, width: side, height: side,
      bitsPerComponent: 32, bytesPerRow: side * 16,
      space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    let data = try #require(context.data).assumingMemoryBound(to: Float.self)
    #expect(UnsafeBufferPointer(start: data, count: side * side * 4).allSatisfy { $0.isFinite })
  }

  private func cpuSeconds() -> Double {
    var value = rusage()
    guard getrusage(RUSAGE_SELF, &value) == 0 else { return 0 }
    return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
      + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
  }

  private func footprint() -> UInt64? {
    var value = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &value) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
      }
    }
    return status == 0 ? value.ri_phys_footprint : nil
  }
}
