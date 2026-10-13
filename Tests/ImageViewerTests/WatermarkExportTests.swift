import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

@Suite("워터마크 설정과 사본 저장")
struct WatermarkExportTests {
  @Test("설정 저장은 기본 비활성화를 지키고 잘못된 범위를 복원하지 않는다")
  func persistedSettingsAreValidated() throws {
    let empty = try JSONDecoder().decode(WatermarkOptions.self, from: Data("{}".utf8))
    #expect(empty == .disabled)
    var valid = WatermarkOptions()
    valid.isEnabled = true
    valid.text = "Signature"
    valid.metadataFields = [.filename, .captureDate]
    valid.position = .topLeading
    valid.customPosition = WatermarkPoint(x: -0.15, y: 1.1)
    valid.expandsCanvas = true
    valid.textColor = .black
    valid.readability = .background
    valid.logoURL = URL(fileURLWithPath: "/tmp/logo.png")
    #expect(try JSONDecoder().decode(WatermarkOptions.self, from: JSONEncoder().encode(valid)) == valid)
    for json in [#"{"opacity":2}"#, #"{"sizeFraction":0}"#,
      #"{"marginFraction":-0.1}"#, #"{"logoURL":"https://example.com/logo.png"}"#,
      #"{"position":"unknown"}"#, #"{"customPosition":{"x":6,"y":0.5}}"#,
      #"{"customPosition":{"x":0,"y":-5}}"#] {
      #expect(throws: (any Error).self) {
        try JSONDecoder().decode(WatermarkOptions.self, from: Data(json.utf8))
      }
    }
    for size in [Double.nan, .infinity, -.infinity] {
      var invalid = WatermarkOptions(); invalid.sizeFraction = size
      #expect(throws: WatermarkError.invalidOptions) { try invalid.validate() }
      invalid = WatermarkOptions(); invalid.customPosition = WatermarkPoint(x: size, y: 0.5)
      #expect(throws: WatermarkError.invalidOptions) { try invalid.validate() }
    }
    var longText = WatermarkOptions(); longText.text = String(repeating: "x", count: 2_001)
    #expect(throws: WatermarkError.invalidOptions) { try longText.validate() }
  }

  @Test("확장한 사본의 치수를 기록하며 PNG는 투명 여백, JPEG는 흰 여백으로 저장한다",
    arguments: [ExportFormat.png, .jpeg])
  func expandedExportUsesCorrectCanvas(format: ExportFormat) async throws {
    let directory = try WatermarkTestImages.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.tiff")
    let logo = directory.appendingPathComponent("logo.png")
    try WatermarkTestImages.write(WatermarkTestImages.image(width: 200, height: 120,
      color: (0, 0, 1, 1)), to: source, metadata: WatermarkTestImages.exif(make: "Demo"))
    try WatermarkTestImages.write(WatermarkTestImages.image(width: 80, height: 40,
      color: (1, 0, 0, 1)), to: logo)
    let originalBytes = try Data(contentsOf: source)
    var watermark = WatermarkOptions()
    watermark.isEnabled = true
    watermark.logoURL = logo
    watermark.opacity = 1
    watermark.readability = .none
    watermark.customPosition = WatermarkPoint(x: -0.25, y: 0.5)
    watermark.expandsCanvas = true
    let destination = directory.appendingPathComponent("copy.\(format.fileExtension)")
    try await ImageExporter(pipeline: ImagePipeline()).export(sourceURL: source,
      destinationURL: destination, format: format, quality: 1, adjustments: .identity,
      watermark: watermark)
    let container = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
    let output = try #require(CGImageSourceCreateImageAtIndex(container, 0, nil))
    #expect(output.width == 276 && output.height == 120)
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as? [CFString: Any])
    #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == output.width)
    #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == output.height)
    let padding = WatermarkTestImages.pixel(output, x: 5, y: output.height - 5)
    if format == .png {
      #expect(padding[3] == 0)
    } else {
      #expect(padding.allSatisfy { $0 > 245 })
    }
    let originalPixel = WatermarkTestImages.pixel(output, x: output.width - 10, y: 10)
    #expect(originalPixel[0] < 10 && originalPixel[1] < 10 && originalPixel[2] > 245)
    #expect(try Data(contentsOf: source) == originalBytes)
  }

  @Test("일괄 저장은 서로 다른 비율의 사진에 같은 정규화 중심과 원본 기준 크기를 적용한다")
  func batchCustomPlacementUsesEachOriginalSize() async throws {
    let directory = try WatermarkTestImages.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let outputDirectory = directory.appendingPathComponent("outputs")
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: false)
    let logo = directory.appendingPathComponent("logo.png")
    try WatermarkTestImages.write(WatermarkTestImages.image(width: 80, height: 40,
      color: (1, 0, 0, 1)), to: logo)
    let sizes = [(400, 200), (200, 400)]
    let sources = try sizes.enumerated().map { index, size in
      let url = directory.appendingPathComponent("source-\(index).png")
      try WatermarkTestImages.write(WatermarkTestImages.image(width: size.0, height: size.1), to: url)
      return url
    }
    let originalBytes = try sources.map { try Data(contentsOf: $0) }
    var watermark = WatermarkOptions()
    watermark.isEnabled = true
    watermark.logoURL = logo
    watermark.sizeFraction = 0.2
    watermark.opacity = 1
    watermark.readability = .none
    watermark.customPosition = WatermarkPoint(x: 0.75, y: 1.1)
    watermark.expandsCanvas = true
    let plan = try BatchImageExporter.plan(urls: sources, destinationFolder: outputDirectory, format: .png)
    let result = await BatchImageExporter(pipeline: ImagePipeline()).export(items: plan,
      format: .png, quality: 1, watermark: watermark, adjustments: [:], progress: { _, _ in })
    #expect(result.completed.count == 2 && result.failures.isEmpty)
    for (index, item) in result.completed.enumerated() {
      let container = try #require(CGImageSourceCreateWithURL(item.destinationURL as CFURL, nil))
      let output = try #require(CGImageSourceCreateImageAtIndex(container, 0, nil))
      let size = sizes[index]
      #expect(output.width == size.0 && output.height > size.1)
      // The requested center is normalized against each unexpanded source.
      let centerX = Int(Double(size.0) * 0.75)
      let centerY = output.height - Int(Double(size.1) * 1.1)
      #expect(WatermarkTestImages.pixel(output, x: centerX, y: centerY) == [255, 0, 0, 255])
      #expect(WatermarkTestImages.pixel(output, x: 5, y: 5)[3] == 0)
      #expect(WatermarkTestImages.pixel(output, x: 5, y: output.height - 5) == [0, 0, 0, 255])
    }
    #expect(try sources.map { try Data(contentsOf: $0) } == originalBytes)
  }

  @Test("자르기·회전·축소 후 최종 사본 위치에 넣고 원본과 로고는 보존한다")
  func watermarkFollowsFinalDimensions() async throws {
    let directory = try WatermarkTestImages.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.png")
    let logo = directory.appendingPathComponent("logo.png")
    try WatermarkTestImages.write(WatermarkTestImages.image(width: 400, height: 200), to: source)
    try WatermarkTestImages.write(WatermarkTestImages.image(width: 80, height: 40, color: (1, 0, 0, 1)), to: logo)
    let sourceBytes = try Data(contentsOf: source)
    let logoBytes = try Data(contentsOf: logo)
    var adjustments = ImageAdjustments()
    adjustments.crop = NormalizedCrop(x: 0, y: 0, width: 0.5, height: 1)
    adjustments.rotateClockwise()
    var watermark = WatermarkOptions()
    watermark.isEnabled = true
    watermark.logoURL = logo
    watermark.sizeFraction = 0.4
    watermark.marginFraction = 0.1
    watermark.position = .topLeading
    watermark.opacity = 1
    watermark.readability = .none
    let destination = directory.appendingPathComponent("copy.png")
    try await ImageExporter(pipeline: ImagePipeline()).export(sourceURL: source,
      destinationURL: destination, format: .png, quality: 1, adjustments: adjustments,
      resize: .percentage(50), watermark: watermark)
    let outputSource = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
    let output = try #require(CGImageSourceCreateImageAtIndex(outputSource, 0, nil))
    #expect(output.width == 100 && output.height == 100)
    #expect(WatermarkTestImages.pixel(output, x: 30, y: 80)[0] > 240)
    #expect(WatermarkTestImages.pixel(output, x: 70, y: 20) == [0, 0, 0, 255])
    #expect(try Data(contentsOf: source) == sourceBytes)
    #expect(try Data(contentsOf: logo) == logoBytes)
    do {
      try await ImageExporter(pipeline: ImagePipeline()).export(sourceURL: source,
        destinationURL: source, format: .png, quality: 1, adjustments: .identity, watermark: watermark)
      Issue.record("원본 파일을 덮어썼습니다.")
    } catch ImageExportError.sourceOverwrite {} catch { Issue.record("다른 오류: \(error)") }
    #expect(try Data(contentsOf: source) == sourceBytes)
  }

  @Test("일괄 사본은 원본마다 다른 메타데이터를 쓰며 기존 출력과 충돌하지 않는다")
  func batchUsesEachSourcesMetadata() async throws {
    let directory = try WatermarkTestImages.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let outputDirectory = directory.appendingPathComponent("outputs")
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: false)
    let image = try WatermarkTestImages.image(width: 320, height: 200)
    let sources = [directory.appendingPathComponent("one.tiff"), directory.appendingPathComponent("two.tiff")]
    try WatermarkTestImages.write(image, to: sources[0], metadata: WatermarkTestImages.exif(make: "IIII"))
    try WatermarkTestImages.write(image, to: sources[1], metadata: WatermarkTestImages.exif(make: "WWWW"))
    let originalBytes = try sources.map { try Data(contentsOf: $0) }
    let existing = outputDirectory.appendingPathComponent("one.png")
    try Data("Existing output remains intact".utf8).write(to: existing)
    var watermark = WatermarkOptions()
    watermark.isEnabled = true
    watermark.metadataFields = [.cameraMake]
    watermark.opacity = 1
    watermark.readability = .none
    watermark.sizeFraction = 0.6
    let plan = try BatchImageExporter.plan(urls: sources, destinationFolder: outputDirectory, format: .png)
    #expect(plan[0].destinationURL.lastPathComponent == "one-2.png")
    let result = await BatchImageExporter(pipeline: ImagePipeline()).export(items: plan,
      format: .png, quality: 1, watermark: watermark, adjustments: [:], progress: { _, _ in })
    #expect(result.completed.count == 2 && result.failures.isEmpty && !result.wasCancelled)
    let outputImages = try result.completed.map { item -> CGImage in
      let source = try #require(CGImageSourceCreateWithURL(item.destinationURL as CFURL, nil))
      return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    #expect(WatermarkTestImages.rgba(outputImages[0]) != WatermarkTestImages.rgba(outputImages[1]))
    #expect(try String(contentsOf: existing, encoding: .utf8) == "Existing output remains intact")
    #expect(try sources.map { try Data(contentsOf: $0) } == originalBytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
      .allSatisfy { !$0.hasPrefix(".imageviewer-convert-") })
  }

  @Test("잘못된 로고의 일괄 출력은 실패를 보고하고 불완전한 파일을 지운다")
  func invalidLogoLeavesNoOutput() async throws {
    let directory = try WatermarkTestImages.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.png")
    try WatermarkTestImages.write(WatermarkTestImages.image(width: 32, height: 24), to: source)
    var watermark = WatermarkOptions()
    watermark.isEnabled = true
    watermark.logoURL = directory.appendingPathComponent("missing-logo.png")
    let plan = try BatchImageExporter.plan(urls: [source], destinationFolder: directory, format: .png)
    let result = await BatchImageExporter(pipeline: ImagePipeline()).export(items: plan,
      format: .png, quality: 1, watermark: watermark, adjustments: [:], progress: { _, _ in })
    #expect(result.completed.isEmpty && result.failures.count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["source.png"])
  }

  @Test("ImageIO가 읽지 않는 앱 코덱의 원본도 파일명 워터마크를 쓸 수 있다")
  func filenameDoesNotRequireImageIO() async throws {
    let directory = try WatermarkTestImages.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("custom-source.qoi")
    // The source pixel image has already been decoded by the app's custom codec.
    // The watermark service needs only a file identity and an optional EXIF snapshot.
    try Data("Not an ImageIO container".utf8).write(to: source)
    let renderer = WatermarkRenderer()
    let image = try WatermarkTestImages.image(width: 128, height: 96)
    var options = WatermarkOptions()
    options.isEnabled = true
    options.metadataFields = [.filename]
    let output = try await renderer.render(image: image, sourceURL: source, options: options)
    #expect(WatermarkTestImages.rgba(output) != WatermarkTestImages.rgba(image))
    #expect(await renderer.metadataLoadCount == 0)
    #expect(try await renderer.metadataValues(sourceURL: source) == [.filename: "custom-source.qoi"])
  }
}
