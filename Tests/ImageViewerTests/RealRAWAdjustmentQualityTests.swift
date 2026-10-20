import CoreGraphics
import Foundation
import Testing

@testable import ImageViewer

/// Isolated, opt-in quality check for a real DNG, including its direct HDR/gain-map
/// path. The only output is aggregate numeric parity data; no pixels are saved.
@Suite("실제 RAW 조정 입력 재사용의 픽셀 품질", .serialized)
struct RealRAWAdjustmentQualityTests {
  @Test("화면 크기·HDR·회전·크롭의 픽셀이 기존 경로와 일치하고 원본 출력은 우회한다",
    .enabled(if: ProcessInfo.processInfo.environment["RAW_ADJUSTMENT_PIXEL_PARITY"] == "1"),
    .timeLimit(.minutes(3)))
  func realRAWPixelParity() async throws {
    let url = try fixtureURL()
    let original = ImageFileVersion(url: url)
    let pipeline = ImagePipeline(reusesDecodedInputs: true)
    let reference = ImagePipeline(reusesDecodedInputs: false)
    var color = ImageAdjustments.identity
    color.exposure = 0.7
    color.temperature = 12
    var geometry = color
    geometry.quarterTurns = 1
    geometry.crop = NormalizedCrop(x: 0.125, y: 0.25, width: 0.5, height: 0.5)
    var cases: [Parity] = []
    let started = ProcessInfo.processInfo.systemUptime
    for adjustments in [color, geometry] {
      for pixels in [512, 2_048] {
        for hdr in [false, true] {
          cases.append(try await compare(url, adjustments: adjustments, pixels: pixels,
            hdr: hdr, pipeline: pipeline, reference: reference))
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
    let displayWallSeconds = ProcessInfo.processInfo.systemUptime - started

    // Full-size output follows the existing source path. Only one original-size
    // frame is held here, rather than retaining two large sensor outputs at once.
    await pipeline.purgeCaches()
    await reference.purgeCaches()
    let beforeOriginal = await pipeline.decodeReuseSnapshot()
    let originalOutput = try await checkOriginalSizeOutput(url, adjustments: color, pipeline: pipeline)
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
      "decodedInputCount": reuse.decodedFrameCount,
      "decodedInputReuseCount": reuse.reuseCount,
      "originalWidth": originalOutput.width,
      "originalHeight": originalOutput.height,
      "originalBitsPerComponent": originalOutput.bits,
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

  private func compare(_ url: URL, adjustments: ImageAdjustments, pixels: Int,
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
    #expect(parity.maximumNormalDifference <= 0.001,
      "Prepared input changed normal-range rendered samples")
    #expect(parity.maximumHDRRelativeDifference <= 0.001,
      "Prepared input changed HDR samples beyond floating-point output precision")
    return parity
  }

  private func checkOriginalSizeOutput(_ url: URL, adjustments: ImageAdjustments,
    pipeline: ImagePipeline) async throws -> (width: Int, height: Int, bits: Int)
  {
    let frame = try await pipeline.renderFrame(url: url, maxPixelSize: nil,
      adjustments: adjustments, prefersHDR: true)
    let sourceSize = try #require(frame.sourcePixelSize)
    #expect(frame.image.width == Int(sourceSize.width) && frame.image.height == Int(sourceSize.height))
    #expect(frame.image.bitsPerComponent >= 16 && frame.image.bitmapInfo.contains(.floatComponents))
    #expect(try sampledPixels(frame.image).allSatisfy { $0.isFinite })
    return (frame.image.width, frame.image.height, frame.image.bitsPerComponent)
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
