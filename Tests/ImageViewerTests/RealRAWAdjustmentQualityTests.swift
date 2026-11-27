import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

/// Isolated, opt-in quality check for a real DNG, including its direct HDR/gain-map
/// path. The export check reopens private temporary files; its report only
/// includes numeric measurements and format properties.
@Suite("실제 RAW 조정 입력 재사용의 픽셀 품질", .serialized)
struct RealRAWAdjustmentQualityTests {
  @Test("화면 크기·HDR·회전·크롭의 픽셀이 기존 경로와 일치하고 원본 출력은 우회한다",
    .enabled(if: ProcessInfo.processInfo.environment["RAW_ADJUSTMENT_PIXEL_PARITY"] == "1"),
    .timeLimit(.minutes(3)))
  func realRAWPixelParity() async throws {
    let url = try fixtureURL()
    let original = ImageFileVersion(url: url)
    let pipeline = makeQualityPipeline(metal: ProcessInfo.processInfo.environment["RAW_QUALITY_PREVIOUS_CG"] != "1")
    let reference = makeQualityPipeline(reusesInputs: false, metal: false)
    let previousCached = makeQualityPipeline(metal: false)
    var color = ImageAdjustments.identity
    color.exposure = 0.7
    color.temperature = 12
    var geometry = color
    geometry.quarterTurns = 1
    geometry.crop = NormalizedCrop(x: 0.125, y: 0.25, width: 0.5, height: 0.5)
    var cases: [Parity] = []
    var cachedComparisons: [Parity] = []
    var historicalDisplay: [Parity] = []
    var directDisplay: [Parity] = []
    let started = ProcessInfo.processInfo.systemUptime
    // The unedited single-view reference is the direct source render, as in
    // build 127. Record the pre-127 Float32 raster's differences separately.
    let previousDisplay = makeQualityPipeline(metal: false, preparesUnedited: true)
    for pixels in [512, 2_048] {
      for hdr in [false, true] {
        let direct = try await compare(url, adjustments: .identity, pixels: pixels,
          hdr: hdr, pipeline: pipeline, reference: reference)
        directDisplay.append(direct)
        cases.append(direct)
        historicalDisplay.append(try await measure(url, adjustments: .identity, pixels: pixels,
          hdr: hdr, pipeline: pipeline, reference: previousDisplay))
      }
    }
    await previousDisplay.purgeCaches()
    for adjustments in [color, geometry] {
      for pixels in [512, 2_048] {
        for hdr in [false, true] {
          cases.append(try await compare(url, adjustments: adjustments, pixels: pixels,
            hdr: hdr, pipeline: pipeline, reference: reference))
          cachedComparisons.append(try await compare(url, adjustments: adjustments, pixels: pixels,
            hdr: hdr, pipeline: pipeline, reference: previousCached))
        }
      }
    }
    // One additional color-only change must use the settled HDR working input.
    geometry.brightness = 0.08
    cases.append(try await compare(url, adjustments: geometry, pixels: 2_048,
      hdr: true, pipeline: pipeline, reference: reference))
    // Fractional fitted bounds must remain unchanged before edge-aware filters.
    geometry.crop = NormalizedCrop(x: 0.137, y: 0.213, width: 0.571, height: 0.619)
    geometry.sharpness = 0.6
    geometry.noiseReduction = 0.04
    for hdr in [false, true] {
      cases.append(try await compare(url, adjustments: geometry, pixels: 512,
        hdr: hdr, pipeline: pipeline, reference: reference))
    }
    _ = try await pipeline.renderFrame(url: url, maxPixelSize: 512,
      adjustments: geometry, prefersHDR: true, priority: .interactivePreview)
    let reuseBeforeSpatialDrag = await pipeline.decodeReuseSnapshot().reuseCount
    geometry.exposure += 0.05
    let sample = try await pipeline.renderFrame(url: url, maxPixelSize: 512,
      adjustments: geometry, prefersHDR: true, priority: .interactivePreview)
    #expect(await pipeline.decodeReuseSnapshot().reuseCount > reuseBeforeSpatialDrag)
    let settled = try await pipeline.renderFrame(url: url, maxPixelSize: 512,
      adjustments: geometry, prefersHDR: true)
    #expect(sample.image !== settled.image, "An interactive spatial sample replaced precise output")
    cases.append(try await compare(url, adjustments: geometry, pixels: 512,
      hdr: true, pipeline: pipeline, reference: reference))
    let reuse = await pipeline.decodeReuseSnapshot()
    #expect(reuse.reuseCount > 0, "Repeated color adjustment did not reuse prepared RAW input")
    if ProcessInfo.processInfo.environment["RAW_METAL_REQUIRED"] == "1" {
      #expect(reuse.metalPreparedCount > 0 && reuse.metalReuseCount > 0,
        "This Metal validation run must exercise the real texture path, without a silent fallback")
    }
    let displayWallSeconds = ProcessInfo.processInfo.systemUptime - started

    // Full-size output follows the existing source path. Only one original-size
    // frame is held here, rather than retaining two large sensor outputs at once.
    await pipeline.purgeCaches()
    await reference.purgeCaches()
    await previousCached.purgeCaches()
    let beforeOriginal = await pipeline.decodeReuseSnapshot()
    let originalOutput = try await checkOriginalSizeOutput(url, adjustments: color, pipeline: pipeline)
    let previousOriginal = try await checkOriginalSizeOutput(url, adjustments: color, pipeline: reference)
    #expect(originalOutput.width == previousOriginal.width && originalOutput.height == previousOriginal.height)
    let originalSampleDifference = zip(originalOutput.pixels, previousOriginal.pixels)
      .reduce(Float.zero) { max($0, abs($1.0-$1.1)) }
    #expect(originalSampleDifference <= 0.001)
    let afterOriginal = await pipeline.decodeReuseSnapshot()
    #expect(afterOriginal.decodedFrameCount == beforeOriginal.decodedFrameCount)
    #expect(afterOriginal.reuseCount == beforeOriginal.reuseCount)
    #expect(afterOriginal.cache.byteCount == 0)
    let sourceUnchanged = ImageFileVersion(url: url) == original
    #expect(sourceUnchanged, "Read-only quality verification changed source metadata")

    let maximumAbsolute: Double = cases.map(\.maximumAbsoluteDifference).max() ?? 0
    let maximumNormal: Double = cases.map(\.maximumNormalDifference).max() ?? 0
    let maximumHDRRelative: Double = cases.map(\.maximumHDRRelativeDifference).max() ?? 0
    let maximumReference: Double = cases.map(\.maximumReferenceValue).max() ?? 0
    let maximumActual: Double = cases.map(\.maximumActualValue).max() ?? 0
    let fields: [String: Any] = [
      "readOnly": true,
      "cases": cases.count,
      "sampleGridSide": 64,
      "displayWallSeconds": displayWallSeconds,
      "maximumAbsoluteDifference": maximumAbsolute,
      "maximumNormalRangeDifference": maximumNormal,
      "maximumHDRRelativeDifference": maximumHDRRelative,
      "maximumReferenceValue": maximumReference,
      "maximumActualValue": maximumActual,
      "previousCachedPathComparisons": cachedComparisons.count,
      "previousCachedPathMaximumDifference": cachedComparisons.map(\.maximumAbsoluteDifference).max() ?? 0,
      "directSourceIdentityCases": directDisplay.count,
      "directSourceIdentityMaximumDifference": directDisplay.map(\.maximumAbsoluteDifference).max() ?? 0,
      "pre127RasterIdentityCases": historicalDisplay.count,
      "pre127RasterIdentityMaximumNormalDifference": historicalDisplay.map(\.maximumNormalDifference).max() ?? 0,
      "pre127RasterIdentityMaximumHDRRelativeDifference": historicalDisplay.map(\.maximumHDRRelativeDifference).max() ?? 0,
      "qualityPolicy": "fixed_active_nominal_normal_pressure_no_low_power_CPU_busy_0.1_native_pressure_observer_disabled_for_deterministic_pixel_coverage",
      "decodedInputCount": reuse.decodedFrameCount,
      "decodedInputReuseCount": reuse.reuseCount,
      "metalPreparedCount": reuse.metalPreparedCount,
      "metalReuseCount": reuse.metalReuseCount,
      "originalWidth": originalOutput.width,
      "originalHeight": originalOutput.height,
      "originalBitsPerComponent": originalOutput.bits,
      "originalOutputMaximumSampleDifference": originalSampleDifference,
      "originalExportBypassedReuse": true,
      "sourceMetadataUnchanged": sourceUnchanged,
      "memoryScope": "quality_pass_runs_separately_from_performance_measurement",
    ]
    let encoded = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    FileHandle.standardOutput.write(Data("RAW_ADJUSTMENT_PIXEL_PARITY ".utf8) + encoded + Data("\n".utf8))
    await pipeline.purgeCaches()
  }

  private struct Parity {
    var maximumAbsoluteDifference: Double = 0
    var maximumNormalDifference: Double = 0
    var maximumHDRRelativeDifference: Double = 0
    var maximumReferenceValue: Double = 0
    var maximumActualValue: Double = 0
  }

  private func makeQualityPipeline(reusesInputs: Bool = true, metal: Bool = true,
    preparesUnedited: Bool = false) -> ImagePipeline {
    var snapshot = ImageResourceSnapshot.currentHardware
    snapshot.isAppActive = true
    snapshot.memoryPressure = .normal
    snapshot.thermal = .nominal
    snapshot.lowPowerMode = false
    snapshot.cpuBusyFraction = 0.1
    let governor = ImageResourceGovernor(mode: .comfortable, snapshot: snapshot,
      storageOverride: .internalSSD, monitorsMemoryPressure: false)
    return ImagePipeline(governor: governor, reusesDecodedInputs: reusesInputs,
      preparesUneditedRAWInputs: preparesUnedited, usesMetalRAWInputs: metal)
  }

  @Test("실제 내보내기로 저장한 HEIC를 HDR로 다시 열어 밝은 영역과 구형 경로를 대조한다",
    .enabled(if: ProcessInfo.processInfo.environment["RAW_HDR_EXPORT_ROUNDTRIP"] == "1"),
    .timeLimit(.minutes(3)))
  func encodedHEICHighlights() async throws {
    let source = try fixtureURL()
    let sourceVersion = ImageFileVersion(url: source)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imageviewer-hdr-review-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    var adjustments = ImageAdjustments.identity
    adjustments.exposure = 0.7
    adjustments.temperature = 12
    var previousPixels: [Float]?
    for metal in [false, true] {
      let pipeline = makeQualityPipeline(metal: metal)
      let reference = try await checkOriginalSizeOutput(source, adjustments: adjustments, pipeline: pipeline)
      let destination = directory.appendingPathComponent(metal ? "metal.heic" : "previous.heic")
      try await ImageExporter(pipeline: pipeline).export(sourceURL: source, destinationURL: destination,
        format: .heic, quality: 1, adjustments: adjustments)
      let encoded = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
      #expect(CGImageSourceGetType(encoded) as String? == ExportFormat.heic.typeIdentifier)
      let properties = try #require(CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [CFString: Any])
      let decoded = try #require(CGImageSourceCreateImageAtIndex(encoded, 0,
        [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary))
      #expect(decoded.width == reference.width && decoded.height == reference.height)
      let samples = try sampledPixels(decoded)
      try #require(samples.count == reference.pixels.count)
      let rgb = samples.indices.filter { $0 % 4 != 3 }
      let sourcePeak = try #require(rgb.map { reference.pixels[$0] }.max())
      let decodedPeak = try #require(rgb.map { samples[$0] }.max())
      // Reopen through the same fitted HDR render used by the viewer as well
      // as ImageIO's reference decoder. Fitting may change individual peaks.
      let viewed = try await pipeline.renderFrame(url: destination, maxPixelSize: 1_536,
        adjustments: .identity, prefersHDR: true)
      let viewedPixels = try sampledPixels(viewed.image)
      let viewedPeak = try #require(rgb.map { viewedPixels[$0] }.max())
      try #require(samples.allSatisfy(\.isFinite) && sourcePeak > 2,
        "Select an HDR fixture with substantial highlight detail before encoding")
      // With this high-headroom fixture, a small out-of-gamut RGB overshoot
      // around SDR white does not by itself demonstrate surviving highlights.
      let bright = rgb.filter { reference.pixels[$0] > 2 }
      let surviving = bright.filter { samples[$0] > 1.25 }
      let legacyDifference = previousPixels.map { old in
        zip(old, samples).reduce(Float.zero) { max($0, abs($1.0 - $1.1)) }
      }
      var metrics: [String: Any] = [
        "usesMetal": metal, "width": decoded.width, "height": decoded.height,
        "originalFloatBits": reference.bits, "encodedDepth": properties[kCGImagePropertyDepth] ?? NSNull(),
        "decodedSpace": decoded.colorSpace?.name as String? ?? "unknown",
        "decodedBits": decoded.bitsPerComponent, "sourcePeak": sourcePeak, "reopenedPeak": decodedPeak,
        "viewerFittedPeak": viewedPeak,
        "brightSourceChannels": bright.count, "retainedBrightChannels": surviving.count,
        "gridSide": 64, "previousPathMaximumDifference": legacyDifference.map { $0 as Any } ?? NSNull(),
      ]
      if #available(macOS 15.0, *) {
        metrics["decodedContentHeadroom"] = CIImage(cgImage: decoded).contentHeadroom
      }
      let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
      FileHandle.standardOutput.write(Data("RAW_HDR_EXPORT_ROUNDTRIP ".utf8) + data + Data([10]))
      #expect(surviving.count >= Int(ceil(Double(bright.count) * 0.95)),
        "Strong HDR highlights did not survive HEIC export and ImageIO HDR decode")
      #expect(decodedPeak >= 0.9 * sourcePeak && decodedPeak <= 1.1 * sourcePeak)
      #expect(viewed.image.bitsPerComponent >= 16 && viewedPeak > 1.25)
      #expect((properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 0 >= 10)
      let decodedSpace = try #require(decoded.colorSpace)
      #expect(CGColorSpaceUsesITUR_2100TF(decodedSpace))
      if #available(macOS 15.0, *) { #expect(decoded.contentHeadroom > 1) }
      if let legacyDifference { #expect(legacyDifference <= 0.001) }
      previousPixels = samples
      await pipeline.purgeCaches()
    }
    #expect(ImageFileVersion(url: source) == sourceVersion)
  }

  private func compare(_ url: URL, adjustments: ImageAdjustments, pixels: Int,
    hdr: Bool, pipeline: ImagePipeline, reference: ImagePipeline) async throws -> Parity
  {
    let parity = try await measure(url, adjustments: adjustments, pixels: pixels, hdr: hdr,
      pipeline: pipeline, reference: reference)
    #expect(parity.maximumNormalDifference <= 0.001,
      "Prepared input changed normal-range rendered samples (\(pixels)px, HDR: \(hdr))")
    #expect(parity.maximumHDRRelativeDifference <= 0.001,
      "Prepared input changed HDR samples beyond floating-point output precision (\(pixels)px, HDR: \(hdr))")
    return parity
  }

  private func measure(_ url: URL, adjustments: ImageAdjustments, pixels: Int,
    hdr: Bool, pipeline: ImagePipeline, reference: ImagePipeline) async throws -> Parity
  {
    let actual = try await pipeline.renderFrame(url: url, maxPixelSize: pixels,
      adjustments: adjustments, prefersHDR: hdr)
    let expected = try await reference.renderFrame(url: url, maxPixelSize: pixels,
      adjustments: adjustments, prefersHDR: hdr)
    #expect(actual.image.width == expected.image.width && actual.image.height == expected.image.height)
    #expect(actual.sourcePixelSize == expected.sourcePixelSize)
    #expect(actual.image.bitsPerComponent == expected.image.bitsPerComponent)
    #expect(actual.image.colorSpace?.name == expected.image.colorSpace?.name)
    if #available(macOS 15.0, *), hdr {
      #expect(CIImage(cgImage: actual.image).contentHeadroom == CIImage(cgImage: expected.image).contentHeadroom)
    }
    if hdr {
      #expect(actual.image.bitsPerComponent >= 16)
      #expect(actual.image.bitmapInfo.contains(.floatComponents))
    }
    let actualPixels = try sampledPixels(actual.image)
    let expectedPixels = try sampledPixels(expected.image)
    try #require(actualPixels.count == expectedPixels.count)
    var parity = Parity()
    for (actual, expected) in zip(actualPixels, expectedPixels) {
      try #require(actual.isFinite && expected.isFinite, "RAW adjustment produced nonfinite sample values")
      let difference = Double(abs(actual - expected))
      parity.maximumAbsoluteDifference = max(parity.maximumAbsoluteDifference, difference)
      parity.maximumReferenceValue = max(parity.maximumReferenceValue, Double(expected))
      parity.maximumActualValue = max(parity.maximumActualValue, Double(actual))
      if abs(expected) <= 1 {
        parity.maximumNormalDifference = max(parity.maximumNormalDifference, difference)
      } else {
        parity.maximumHDRRelativeDifference = max(parity.maximumHDRRelativeDifference,
          difference / Double(abs(expected)))
      }
      if hdr, expected > 1.001 {
        #expect(actual > 1, "Prepared input clipped an HDR sample to SDR white")
      }
    }
    return parity
  }

  private func checkOriginalSizeOutput(_ url: URL, adjustments: ImageAdjustments,
    pipeline: ImagePipeline) async throws -> (width: Int, height: Int, bits: Int, pixels: [Float])
  {
    let frame = try await pipeline.renderFrame(url: url, maxPixelSize: nil,
      adjustments: adjustments, prefersHDR: true)
    let sourceSize = try #require(frame.sourcePixelSize)
    #expect(frame.image.width == Int(sourceSize.width) && frame.image.height == Int(sourceSize.height))
    #expect(frame.image.bitsPerComponent >= 16 && frame.image.bitmapInfo.contains(.floatComponents))
    let pixels = try sampledPixels(frame.image)
    #expect(pixels.allSatisfy { $0.isFinite })
    return (frame.image.width, frame.image.height, frame.image.bitsPerComponent, pixels)
  }

  private func sampledPixels(_ image: CGImage) throws -> [Float] {
    let side = 64
    let context = try #require(CGContext(data: nil, width: side, height: side,
      bitsPerComponent: 32, bytesPerRow: side * 4 * MemoryLayout<Float>.size,
      space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
    // Sample the same positions in both frames without averaging away small
    // rendering discrepancies or highlight values above SDR white.
    context.interpolationQuality = .none
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    let pixels = try #require(context.data).assumingMemoryBound(to: Float.self)
    return Array(UnsafeBufferPointer(start: pixels, count: side * side * 4))
  }

  private func fixtureURL() throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    if let path = environment["IMAGEVIEWER_RAW_FILE"], !path.isEmpty {
      let url = URL(fileURLWithPath: path)
      try #require(url.pathExtension.lowercased() == "dng", "The quality fixture must be a DNG file")
      try #require((ImageFileVersion(url: url).byteCount ?? 0) > 0, "The quality fixture must contain data")
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
    return try #require(candidates.max { $0.1 < $1.1 }?.0, "No nonempty DNG quality fixture was found")
  }
}
