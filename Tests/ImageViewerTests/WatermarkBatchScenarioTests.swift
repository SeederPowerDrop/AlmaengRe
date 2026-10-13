import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

@Suite("워터마크 실제 크기 일괄 사본 시나리오")
struct WatermarkBatchScenarioTests {
  @Test("합성 JPEG 8장에 서명·로고·촬영 정보를 적용한 PNG와 JPEG 사본을 검증한다")
  func eightPhotoStudyBatch() async throws {
    let directory = try WatermarkTestImages.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // Match the manual demo's dimensions and EXIF, but never depend on that
    // machine's /tmp fixtures, selected files, installed font, or output folder.
    let sizes = [(1200, 800), (1600, 1000), (900, 1300), (1400, 1000),
      (1100, 800), (1800, 1200), (1000, 800), (1500, 900)]
    let days = [1, 4, 7, 2, 5, 8, 3, 6]
    let exposures = [1.0 / 60, 1.0 / 125, 1.0 / 250, 1.0 / 500,
      1.0 / 1000, 1.0 / 30, 1.0 / 200, 1.0 / 400]
    let apertures = [2.8, 4.0, 5.6, 8.0, 11.0, 2.0, 3.2, 6.3]
    var sources: [URL] = []
    for (index, size) in sizes.enumerated() {
      let source = directory.appendingPathComponent(String(format: "Study-%02d.jpg", index + 1))
      let date = String(format: "2026:10:%02d 08:%02d:00", days[index], index * 5)
      let properties: [CFString: Any] = [
        kCGImagePropertyTIFFDictionary: [
          kCGImagePropertyTIFFMake: index.isMultiple(of: 2) ? "ALMAENG CAMERA" : "NORTHCAM",
          kCGImagePropertyTIFFModel: "Studio \(index % 3 + 1)",
        ],
        kCGImagePropertyExifDictionary: [
          kCGImagePropertyExifDateTimeOriginal: date,
          kCGImagePropertyExifExposureTime: exposures[index],
          kCGImagePropertyExifFNumber: apertures[index],
        ],
        kCGImageDestinationLossyCompressionQuality: 0.95,
      ]
      try WatermarkTestImages.write(WatermarkTestImages.studyImage(width: size.0,
        height: size.1, index: index), to: source, metadata: properties)
      sources.append(source)
    }
    let logoURL = directory.appendingPathComponent("Demo-Signature.png")
    try WatermarkTestImages.write(WatermarkTestImages.image(width: 700, height: 190,
      color: (1, 1, 1, 0.7)), to: logoURL)
    let sourceHashes = try sources.map(Self.hash)
    let logoHash = try Self.hash(logoURL)

    var watermark = WatermarkOptions()
    watermark.isEnabled = true
    watermark.text = "LightStudy"
    // CoreText substitutes an installed fallback when NanumBrush is unavailable.
    // No assertion depends on a machine-specific glyph shape or installed font.
    watermark.fontPostScriptName = "NanumBrush"
    watermark.metadataFields = [.captureDate, .cameraModel, .shutterSpeed, .aperture]
    watermark.logoURL = logoURL
    watermark.sizeFraction = 0.255
    watermark.marginFraction = 0.042
    watermark.opacity = 0.825
    watermark.customPosition = WatermarkPoint(x: 0.63, y: 0.963)
    watermark.expandsCanvas = true

    let pipeline = ImagePipeline()
    let metadataReader = WatermarkRenderer()
    for (index, source) in sources.enumerated() {
      let values = try await metadataReader.metadataValues(sourceURL: source)
      #expect(watermark.metadataFields.allSatisfy { values[$0] != nil })
      #expect(values[.cameraModel] == "Studio \(index % 3 + 1)")
    }
    var pngSizes: [CGSize] = []
    for format in [ExportFormat.png, .jpeg] {
      let outputs = directory.appendingPathComponent(format.fileExtension, isDirectory: true)
      try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: false)
      let plan = try BatchImageExporter.plan(urls: sources, destinationFolder: outputs, format: format)
      let result = await BatchImageExporter(pipeline: pipeline).export(items: plan, format: format,
        quality: 0.95, watermark: watermark, adjustments: [:], progress: { _, _ in })
      #expect(result.failures.isEmpty && !result.wasCancelled)
      try #require(result.completed.count == sizes.count)
      for (index, item) in result.completed.enumerated() {
        #expect(item.sourceURL == sources[index])
        let container = try #require(CGImageSourceCreateWithURL(item.destinationURL as CFURL, nil))
        let output = try #require(CGImageSourceCreateImageAtIndex(container, 0, nil))
        let size = sizes[index]
        // No resize was requested. The canvas keeps the original dimensions and
        // adds space below an overlay centered at 96.3% of original height.
        #expect(output.width >= size.0 && output.height > size.1)
        #expect(output.width <= 32_768 && output.height <= 32_768)
        #expect(output.width * output.height <= 64_000_000)
        let outputSize = CGSize(width: output.width, height: output.height)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == output.width)
        #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == output.height)
        let padding = WatermarkTestImages.pixel(output, x: 2, y: 2)
        if format == .png {
          pngSizes.append(outputSize)
          #expect(padding[3] == 0)
          let originalContainer = try #require(CGImageSourceCreateWithURL(sources[index] as CFURL, nil))
          let original = try #require(CGImageSourceCreateImageAtIndex(originalContainer, 0, nil))
          let before = WatermarkTestImages.pixel(original, x: 20, y: original.height - 20)
          let after = WatermarkTestImages.pixel(output, x: 20, y: output.height - 20)
          #expect(zip(before, after).allSatisfy { pair in abs(Int(pair.0) - Int(pair.1)) <= 2 })
        } else {
          #expect(outputSize == pngSizes[index])
          #expect(padding.allSatisfy { $0 > 245 })
        }
      }
      let files = try FileManager.default.contentsOfDirectory(atPath: outputs.path)
      #expect(files.count == 8 && !files.contains { $0.hasPrefix(".imageviewer-convert-") })
      #expect(try sources.map(Self.hash) == sourceHashes)
      #expect(try Self.hash(logoURL) == logoHash)
    }
  }

  private static func hash(_ url: URL) throws -> SHA256.Digest {
    SHA256.hash(data: try Data(contentsOf: url))
  }
}
