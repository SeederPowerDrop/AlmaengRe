import AppKit
import SwiftUI
import Testing

@testable import ImageViewer

/// Uses the real tile and decoded synthetic image: a filename overlay used to
/// cover the top of fitted portraits even though the scale calculation was right.
@Suite("파일명 아래의 실제 이미지 맞춤 영역", .serialized)
@MainActor
struct ViewerImageFitLayoutTests {
  @Test("파일명 크기만큼 맞춤 영역을 줄이고 이름을 숨기면 전체 높이를 사용한다",
    arguments: [BaseScaleMode.fit, .fitHeight])
  func headerReservesSpace(mode: BaseScaleMode) async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ViewerImageFitLayout-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("synthetic-portrait-with-visible-edges.png")
    try writePortrait(to: url)
    let asset = ImageAsset(url: url, byteCount: nil, modificationDate: nil)
    let pipeline = ImagePipeline()
    let thumbnails = ThumbnailPipeline()
    var heights: [CGFloat] = []
    for filenameSize in [FilenameDisplaySize.hidden, .medium, .extraLarge] {
      let geometry = try await renderedGeometry(asset: asset, pipeline: pipeline,
        thumbnails: thumbnails, filenameSize: filenameSize, mode: mode)
      #expect(abs(geometry.viewportSize.width - 480) < 1)
      #expect(abs(geometry.baseImageSize.height - (geometry.viewportSize.height - 2)) < 1,
        "The portrait must fit the unobscured space below its filename")
      #expect(abs(geometry.baseImageSize.width * 4 - geometry.baseImageSize.height) < 1)
      #expect(geometry.constrained(CGSize(width: 100, height: 100), zoom: 1) == .zero)
      heights.append(geometry.viewportSize.height)
    }
    #expect(abs(heights[0] - 420) < 1, "A hidden filename must not reserve an empty header")
    #expect(heights[1] < heights[0] - 10, "A visible header must not cover the fitted image")
    #expect(heights[2] < heights[1], "Larger filename text must reserve its natural additional height")
  }

  private func renderedGeometry(asset: ImageAsset, pipeline: ImagePipeline,
    thumbnails: ThumbnailPipeline, filenameSize: FilenameDisplaySize,
    mode: BaseScaleMode) async throws -> ImagePanGeometry
  {
    var measured: ImagePanGeometry?
    let root = ViewerImageTile(asset: asset, itemCount: 1, thumbnailPipeline: thumbnails,
      pipeline: pipeline, adjustments: .identity, prefersHDR: false,
      interpolationMode: .smooth, comparisonLayout: .off, filenameDisplaySize: filenameSize,
      baseScaleMode: mode, committedZoom: 1, effectiveZoom: 1, effectivePan: .zero,
      showsTileBoundary: false, highlightsSelection: false,
      onPanGeometryChange: { _, geometry in measured = geometry })
      .frame(width: 480, height: 420)
    let host = NSHostingView(rootView: root)
    host.frame = NSRect(x: 0, y: 0, width: 480, height: 420)
    let window = NSWindow(contentRect: NSRect(x: -3_000, y: -3_000, width: 480, height: 420),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while measured == nil, ContinuousClock.now < deadline {
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
    return try #require(measured, "The real tile must decode and lay out the synthetic portrait")
  }

  private func writePortrait(to url: URL) throws {
    let context = try #require(CGContext(data: nil, width: 120, height: 480,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.systemBlue.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 120, height: 480))
    context.setStrokeColor(NSColor.yellow.cgColor)
    context.setLineWidth(8)
    context.stroke(CGRect(x: 4, y: 4, width: 112, height: 472))
    let image = try #require(context.makeImage())
    let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try data.write(to: url)
  }
}
