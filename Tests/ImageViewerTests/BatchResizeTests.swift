import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

@Suite("일괄 크기·용량 변경")
struct BatchResizeTests {
  @Test("세로·가로 비율과 최소 1픽셀을 지키고 작은 원본은 확대하지 않는다")
  func proportionalDimensions() throws {
    let landscape = try BatchResizeOptions.longestEdge(1920).dimensions(width: 6000, height: 4000)
    #expect(landscape.width == 1920 && landscape.height == 1280)
    let portrait = try BatchResizeOptions.longestEdge(1920).dimensions(width: 4000, height: 6000)
    #expect(portrait.width == 1280 && portrait.height == 1920)
    let small = try BatchResizeOptions.longestEdge(1920).dimensions(width: 80, height: 100)
    #expect(small.width == 80 && small.height == 100)
    let narrow = try BatchResizeOptions.percentage(1).dimensions(width: 1, height: 100)
    #expect(narrow.width == 1 && narrow.height == 1)
    let odd = try BatchResizeOptions.percentage(50).dimensions(width: 101, height: 71)
    #expect(odd.width == 51 && odd.height == 36)
  }

  @Test("비정상·무한·확대 크기는 거절한다", arguments: [
    BatchResizeOptions.longestEdge(0), .longestEdge(65_537),
    .percentage(0), .percentage(101), .percentage(.nan), .percentage(.infinity),
  ])
  func rejectsInvalidDimensions(options: BatchResizeOptions) {
    #expect(throws: BatchResizeError.self) { try options.dimensions(width: 100, height: 100) }
  }

  @Test("회전·자르기를 적용한 뒤 일괄 축소하고 출력 메타데이터도 맞춘다",
    arguments: [BatchResizeOptions.longestEdge(80), .percentage(50)])
  func resizeAfterAdjustments(options: BatchResizeOptions) async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("original.png")
    try writePNG(source, width: 320, height: 200)
    let original = try Data(contentsOf: source)
    var adjustments = ImageAdjustments()
    adjustments.crop = NormalizedCrop(x: 0, y: 0, width: 0.5, height: 1)
    adjustments.rotateClockwise()
    adjustments.exposure = 0.25
    let items = try BatchImageExporter.plan(urls: [source], destinationFolder: directory, format: .png)
    let result = await BatchImageExporter(pipeline: ImagePipeline()).export(
      items: items, format: .png, quality: 1, resize: options,
      adjustments: [source: adjustments], progress: { _, _ in })
    #expect(result.failures.isEmpty)
    let item = try #require(result.completed.first)
    let expected = try options.dimensions(width: 200, height: 160)
    let outputSource = try #require(CGImageSourceCreateWithURL(item.destinationURL as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(outputSource, 0, nil))
    #expect(image.width == expected.width && image.height == expected.height)
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil)
      as? [CFString: Any])
    #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == expected.width)
    #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == expected.height)
    #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
    #expect(try Data(contentsOf: source) == original)
  }

  @Test("JPEG 품질을 낮추면 같은 크기의 복잡한 합성 사진 용량을 줄인다")
  func lossyQualityReducesFileSize() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("synthetic.png")
    try writePNG(source, width: 512, height: 320)
    let original = try Data(contentsOf: source)
    let exporter = ImageExporter(pipeline: ImagePipeline())
    let high = directory.appendingPathComponent("high.jpg")
    let low = directory.appendingPathComponent("low.jpg")
    for (destination, quality) in [(high, 1.0), (low, 0.35)] {
      try await exporter.export(sourceURL: source, destinationURL: destination,
        format: .jpeg, quality: quality, adjustments: .identity,
        resize: .longestEdge(256))
      let output = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
      let image = try #require(CGImageSourceCreateImageAtIndex(output, 0, nil))
      #expect(image.width == 256 && image.height == 160)
    }
    #expect(try Data(contentsOf: low).count < Data(contentsOf: high).count)
    #expect(try Data(contentsOf: source) == original)
  }

  @Test("잘못된 축소 설정은 결과 파일과 임시 파일을 남기지 않는다")
  func invalidSettingsLeaveNoOutput() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("original.png")
    try writePNG(source, width: 16, height: 8)
    let items = try BatchImageExporter.plan(urls: [source], destinationFolder: directory, format: .png)
    let result = await BatchImageExporter(pipeline: ImagePipeline()).export(
      items: items, format: .png, quality: 1, resize: .longestEdge(-1),
      adjustments: [:], progress: { _, _ in })
    #expect(result.completed.isEmpty && result.failures.count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["original.png"])
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imageviewer-batch-resize-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
  }

  private func writePNG(_ url: URL, width: Int, height: Int) throws {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let base = (y * width + x) * 4
        pixels[base] = UInt8((x * 37 + y * 13) % 256)
        pixels[base + 1] = UInt8((x * 17 + y * 41) % 256)
        pixels[base + 2] = UInt8((x * 7 + y * 61) % 256)
      }
    }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(width: width, height: height,
      bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
  }
}
