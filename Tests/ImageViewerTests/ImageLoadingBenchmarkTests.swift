import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ImageViewer

/// Opt-in: IMAGEVIEWER_BENCHMARK=1 swift test --filter ImageLoadingBenchmarkTests
/// Distinct paths share one generated photo's bytes; this measures a warm filesystem,
/// not a cold disk or 300 different camera files. Fixtures are removed after the run.
struct ImageLoadingBenchmarkTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_WORKER_TUNING"] == "1"))
  func appleSiliconWorkerTuning() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imageviewer-worker-tuning-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appendingPathComponent("fixture.jpg")
    try autoreleasepool { try makePhoto(at: original) }
    var urls: [URL] = []
    for index in 0..<10 {
      let url = directory.appendingPathComponent("photo-\(index).jpg")
      try FileManager.default.linkItem(at: original, to: url)
      urls.append(url)
    }
    let clock = ContinuousClock()
    // Rotate order to reduce the bias from warmup and thermal changes.
    for (round, limits) in [[2, 3, 4], [4, 2, 3], [3, 4, 2]].enumerated() {
      for limit in limits {
        let pipeline = ImagePipeline(maxConcurrentDecodes: limit)
        let start = clock.now
        let bytes = try await render(urls, pixels: 1280, pipeline: pipeline)
        print("WORKER_TUNING round=\(round + 1) workers=\(limit) seconds=\(seconds(start.duration(to: clock.now))) bitmapBytes=\(bytes)")
      }
    }
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_BENCHMARK"] == "1"))
  func largePhotoPages() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imageviewer-benchmark-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appendingPathComponent("fixture.jpg")
    try autoreleasepool { try makePhoto(at: original) }
    let count = Int(ProcessInfo.processInfo.environment["IMAGEVIEWER_BENCHMARK_COUNT"] ?? "300") ?? 300
    var urls: [URL] = []
    for index in 0..<max(10, count) {
      let url = directory.appendingPathComponent("photo-\(index).jpg")
      try FileManager.default.linkItem(at: original, to: url)
      urls.append(url)
    }
    let byteCount = try original.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    print("BENCHMARK fixture=6000x4000 JPEG bytes=\(byteCount) paths=\(urls.count)")
    let pipeline = ImagePipeline()
    let clock = ContinuousClock()
    for pageSize in [10, 5, 4] {
      await pipeline.purgeCaches()
      let page = Array(urls.prefix(pageSize))
      for pass in ["first", "cached"] {
        let start = clock.now
        let outputBytes = try await render(page, pixels: 1280, pipeline: pipeline)
        print("BENCHMARK page=\(pageSize) pass=\(pass) seconds=\(seconds(start.duration(to: clock.now))) bitmapBytes=\(outputBytes)")
      }
    }
    await pipeline.purgeCaches()
    let start = clock.now
    // Model scrolling through the folder, with 20 visible cells at a time.
    for offset in stride(from: 0, to: urls.count, by: 20) {
      _ = try await render(Array(urls[offset..<min(offset + 20, urls.count)]), pixels: 512, pipeline: pipeline)
    }
    print("BENCHMARK folder=\(urls.count) pixels=512 seconds=\(seconds(start.duration(to: clock.now)))")
  }

  private func render(_ urls: [URL], pixels: Int, pipeline: ImagePipeline) async throws -> Int {
    try await withThrowingTaskGroup(of: Int.self) { group in
      for url in urls {
        group.addTask {
          let frame = try await pipeline.renderFrame(url: url, maxPixelSize: pixels,
            adjustments: .identity, prefersHDR: true)
          return frame.image.bytesPerRow * frame.image.height
        }
      }
      var bytes = 0
      for try await cost in group { bytes += cost }
      return bytes
    }
  }

  private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }

  private func makePhoto(at url: URL) throws {
    let width = 6000, height = 4000
    var bytes = Data(count: width * height * 4)
    bytes.withUnsafeMutableBytes { raw in
      let buffer = raw.bindMemory(to: UInt8.self)
      var random: UInt32 = 12345
      for offset in stride(from: 0, to: buffer.count, by: 4) {
        random ^= random << 13; random ^= random >> 17; random ^= random << 5
        buffer[offset] = UInt8(truncatingIfNeeded: random)
        buffer[offset + 1] = UInt8(truncatingIfNeeded: random >> 8)
        buffer[offset + 2] = UInt8(truncatingIfNeeded: random >> 16)
        buffer[offset + 3] = 255
      }
    }
    let provider = try #require(CGDataProvider(data: bytes as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
      bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
      UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image,
      [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
  }
}
