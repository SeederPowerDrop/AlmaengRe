import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ImageViewer

struct ImagePipelineLoadingTests {
  @Test("Apple Silicon concurrency adapts to available cores and memory")
  func hardwareConcurrencyBudget() {
    let gib: UInt64 = 1_024 * 1_024 * 1_024
    #expect(ImageLoadingPolicy.decodeConcurrency(physicalMemory: 24 * gib,
      activeProcessorCount: 8, appleSilicon: true) == 4)
    #expect(ImageLoadingPolicy.decodeConcurrency(physicalMemory: 8 * gib,
      activeProcessorCount: 8, appleSilicon: true) == 2)
    #expect(ImageLoadingPolicy.decodeConcurrency(physicalMemory: 4 * gib,
      activeProcessorCount: 8, appleSilicon: true) == 1)
    #expect(ImageLoadingPolicy.decodeConcurrency(physicalMemory: 24 * gib,
      activeProcessorCount: 2, appleSilicon: true) == 1)
    #expect(ImageLoadingPolicy.decodeConcurrency(physicalMemory: 24 * gib,
      activeProcessorCount: 8, appleSilicon: false) == 2)
  }

  @Test("HDR preference does not expand an unadjusted SDR thumbnail to half float")
  func sdrFastPathAndColorProfile() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try writePNG(url: url, width: 1200, height: 800)
    let pipeline = ImagePipeline()
    let frame = try await pipeline.renderFrame(url: url, maxPixelSize: 512,
      adjustments: .identity, prefersHDR: true)
    #expect(frame.image.width == 512)
    #expect(frame.image.height <= 342)
    #expect(frame.image.bitsPerComponent == 8)
    #expect(frame.image.colorSpace?.name == CGColorSpace.sRGB)
    #expect(frame.sourcePixelSize == CGSize(width: 1200, height: 800))
    let again = try await pipeline.renderFrame(url: url, maxPixelSize: 510,
      adjustments: .identity, prefersHDR: true)
    #expect(frame.image === again.image)
  }

  @Test("Replacing the same file invalidates both source and rendered caches")
  func replacedFile() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let pipeline = ImagePipeline()
    try writePNG(url: url, width: 80, height: 40)
    let first = try await pipeline.renderFrame(url: url, maxPixelSize: 256,
      adjustments: .identity, prefersHDR: false)
    try writePNG(url: url, width: 40, height: 80)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
      ofItemAtPath: url.path)
    let second = try await pipeline.renderFrame(url: url, maxPixelSize: 256,
      adjustments: .identity, prefersHDR: false)
    #expect(first.image.width == 80)
    #expect(second.image.width == 40)
    #expect(second.image.height == 80)
    let metadata = try await pipeline.metadata(for: url)
    #expect(metadata.pixelWidth == 40)
  }

  @Test("EXIF orientation is applied in the direct path and original pixel dimensions")
  func orientation() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try writePNG(url: url, width: 80, height: 40, orientation: 6)
    let frame = try await ImagePipeline().renderFrame(url: url, maxPixelSize: 256,
      adjustments: .identity, prefersHDR: true)
    #expect(frame.image.width == 40)
    #expect(frame.image.height == 80)
    #expect(frame.sourcePixelSize == CGSize(width: 40, height: 80))
  }

  @Test("Shared page requests return the same decoded bitmap")
  func sharedPageRequests() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try writePNG(url: url, width: 1600, height: 1200)
    let pipeline = ImagePipeline()
    let frames = try await withThrowingTaskGroup(of: RenderedFrame.self) { group in
      for _ in 0..<10 {
        group.addTask {
          try await pipeline.renderFrame(url: url, maxPixelSize: 512,
            adjustments: .identity, prefersHDR: true)
        }
      }
      var frames: [RenderedFrame] = []
      for try await frame in group { frames.append(frame) }
      return frames
    }
    #expect(frames.count == 10)
    #expect(frames.allSatisfy { $0.image === frames[0].image })
  }

  @Test("A canceled request can be retried and a purge prevents cache reuse")
  func cancellationAndPurge() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try writePNG(url: url, width: 800, height: 600)
    let pipeline = ImagePipeline()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await pipeline.renderFrame(url: url, maxPixelSize: 256,
        adjustments: .identity, prefersHDR: true)
    }
    do { _ = try await task.value; Issue.record("Canceled request completed") }
    catch is CancellationError {} catch { throw error }
    let first = try await pipeline.renderFrame(url: url, maxPixelSize: 256,
      adjustments: .identity, prefersHDR: true)
    await pipeline.purgeCaches()
    let second = try await pipeline.renderFrame(url: url, maxPixelSize: 256,
      adjustments: .identity, prefersHDR: true)
    #expect(first.image !== second.image)
  }

  @Test("The fitted page bitmap budget holds across 4, 5 and 10 images")
  func pagePixelBudget() {
    for memoryGiB in [4, 8, 16, 32, 64] {
      for count in [1, 4, 5, 10] {
        let memory = UInt64(memoryGiB) * 1_024 * 1_024 * 1_024
        let pixels = ImageLoadingPolicy.requestedPixels(tileSize: CGSize(width: 2000, height: 1500),
          displayScale: 2, zoom: 1, actualPixels: false, itemCount: count, physicalMemory: memory)
        #expect(pixels * pixels * 8 * count <= 256 * ImageLoadingPolicy.mebibyte)
        #expect(pixels.isMultiple(of: 256))
        #expect(ImageLoadingPolicy.previewPixels(for: pixels) <= 1024)
      }
    }
  }

  @Test("Explicit zoom and actual pixels preserve the existing 8K inspection ceiling")
  func inspectionResolution() {
    let memory: UInt64 = 8 * 1_024 * 1_024 * 1_024
    for count in [1, 4, 5, 10] {
      for actualPixels in [true, false] {
        let pixels = ImageLoadingPolicy.requestedPixels(tileSize: CGSize(width: 2000, height: 1500),
          displayScale: 2, zoom: 16, actualPixels: actualPixels, itemCount: count, physicalMemory: memory)
        #expect(pixels == 8192)
      }
    }
  }

  @Test("The LRU never keeps more decoded bytes than its budget")
  func strictCacheBudget() {
    var cache = ImageCostCache<String, Int>(costLimit: 100)
    cache.insert(1, for: "a", cost: 40)
    cache.insert(2, for: "b", cost: 40)
    #expect(cache.value(for: "a") == 1)
    cache.insert(3, for: "c", cost: 40)
    #expect(cache.value(for: "b") == nil)
    #expect(cache.totalCost == 80)
    cache.insert(4, for: "huge", cost: 101)
    #expect(cache.value(for: "huge") == nil)
    cache.costLimit = 0
    #expect(cache.totalCost == 0)
    #expect(cache.value(for: "a") == nil)
  }

  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("imageviewer-load-\(UUID()).png")
  }

  private func writePNG(url: URL, width: Int, height: Int, orientation: Int = 1) throws {
    let context = try #require(CGContext(data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 0.6))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
      UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image,
      [kCGImagePropertyOrientation: orientation] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
  }
}
