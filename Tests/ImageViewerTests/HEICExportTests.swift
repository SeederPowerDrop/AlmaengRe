import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

@Suite("HEIC 재개봉의 HDR·SDR·알파", .serialized)
struct HEICExportTests {
  @Test("반투명 영역에만 있는 HDR 하이라이트와 알파가 함께 보존된다")
  func transparentHighlight() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("bands.exr")
    let destination = directory.appendingPathComponent("export.heic")
    let pipeline = ImagePipeline()
    let linear = try #require(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
    let ci = CIContext(options: [.cacheIntermediates: false])
    var values: [Float] = []
    for _ in 0..<64 {
      for x in 0..<128 {
        // The right band's premultiplied components are below one.
        values += x < 64 ? [0.2, 0.2, 0.2, 1] : [0.60, 0.60, 0.60, 0.25]
      }
    }
    let input = CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: 128 * 16,
      size: CGSize(width: 128, height: 64), format: .RGBAf, colorSpace: linear)
    try ci.writeOpenEXRRepresentation(of: input, to: source, options: [:])
    let reference = try await pipeline.renderFrame(url: source, maxPixelSize: nil,
      adjustments: .identity, prefersHDR: true)
    try await ImageExporter(pipeline: pipeline).export(sourceURL: source, destinationURL: destination,
      format: .heic, quality: 1, adjustments: .identity)
    let output = try read(destination)
    #expect(CGColorSpaceUsesITUR_2100TF(try #require(output.colorSpace)))
    for x in [32, 96] {
      let before = pixel(reference.image, x: x, context: ci, space: linear)
      let after = pixel(output, x: x, context: ci, space: linear)
      let alpha: Float = x < 64 ? 1 : 0.25
      #expect(abs(before[3] - alpha) < 0.01 && abs(after[3] - alpha) < 0.02)
      if x == 96 { #expect(before[1] / before[3] > 2) }
      for channel in 0..<3 {
        #expect(abs(before[channel] / before[3] - after[channel] / after[3]) < 0.09)
      }
    }
  }

  @Test("고대비·고채도 광색역 SDR을 비정수 비율로 축소해도 HDR로 표시하지 않는다",
    arguments: [false, true])
  func wideGamutSDR(proPhoto: Bool) async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("sdr.tif")
    let destination = directory.appendingPathComponent("resized.heic")
    let space = try #require(CGColorSpace(name: proPhoto ? CGColorSpace.rommrgb : CGColorSpace.displayP3))
    let bitmap = try #require(CGContext(data: nil, width: 128, height: 64,
      bitsPerComponent: 8, bytesPerRow: 512, space: space,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let palette: [[CGFloat]] = [[0, 0, 0, 1], [1, 1, 1, 1], [1, 0, 0, 1], [0, 1, 0, 1]]
    for (index, color) in palette.enumerated() {
      bitmap.setFillColor(try #require(CGColor(colorSpace: space, components: color)))
      bitmap.fill(CGRect(x: index * 32, y: 0, width: 32, height: 64))
    }
    let image = try #require(bitmap.makeImage())
    let writer = try #require(CGImageDestinationCreateWithURL(source as CFURL,
      UTType.tiff.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(writer, image, nil)
    try #require(CGImageDestinationFinalize(writer))
    let bytes = try Data(contentsOf: source)
    try await ImageExporter(pipeline: ImagePipeline()).export(sourceURL: source, destinationURL: destination,
      format: .heic, quality: 1, adjustments: .identity, resize: .longestEdge(93))
    let output = try read(destination)
    #expect(output.width == 93)
    #expect(!CGColorSpaceUsesITUR_2100TF(try #require(output.colorSpace)))
    if #available(macOS 15.0, *) { #expect(output.contentHeadroom <= 1) }
    #expect(try Data(contentsOf: source) == bytes)
  }

  private func read(_ url: URL) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0,
      [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary))
  }

  private func pixel(_ image: CGImage, x: Int, context: CIContext, space: CGColorSpace) -> [Float] {
    var values = [Float](repeating: .nan, count: 4)
    context.render(CIImage(cgImage: image), toBitmap: &values, rowBytes: 16,
      bounds: CGRect(x: x, y: 32, width: 1, height: 1), format: .RGBAf, colorSpace: space)
    return values
  }

  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("heic-qa-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }
}
