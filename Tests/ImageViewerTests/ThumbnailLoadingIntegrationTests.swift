import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

/// 실제 Quick Look 서비스를 사용하는 선택적 통합 시험입니다.
/// IMAGEVIEWER_NATIVE_THUMBNAILS=1 swift test --filter ThumbnailLoadingIntegrationTests
/// 300개 경로는 같은 33 MB TIFF의 하드 링크이므로 서로 다른 사진 300장의
/// 콜드 디스크 성능을 나타내지 않습니다. 대기열·취소·네이티브 생성 경로를 검증합니다.
@Suite("실제 Quick Look 대용량 로딩")
struct ThumbnailLoadingIntegrationTests {
  private struct DeadlineExceeded: Error {}

  private func withDeadline<Value: Sendable>(
    seconds: Int,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
      group.addTask(operation: operation)
      group.addTask {
        try await Task.sleep(for: .seconds(seconds))
        throw DeadlineExceeded()
      }
      defer { group.cancelAll() }
      return try #require(try await group.next())
    }
  }

  private func makeFixture(in folder: URL) throws -> [ImageAsset] {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let original = folder.appendingPathComponent("source.tiff")
    try autoreleasepool {
      let width = 3_840
      let height = 2_160
      let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      for row in stride(from: 0, to: height, by: 8) {
        context.setFillColor(CGColor(
          red: CGFloat(row) / CGFloat(height), green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: row, width: width, height: 8))
      }
      let image = try #require(context.makeImage())
      let destination = try #require(CGImageDestinationCreateWithURL(
        original as CFURL, UTType.tiff.identifier as CFString, 1, nil))
      let properties = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]]
      CGImageDestinationAddImage(destination, image, properties as CFDictionary)
      #expect(CGImageDestinationFinalize(destination))
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
    let byteCount = try #require((attributes[.size] as? NSNumber)?.int64Value)
    #expect(byteCount >= 30_000_000 && byteCount <= 100_000_000)
    let date = attributes[.modificationDate] as? Date
    print("QL_NATIVE_FIXTURE bytes=\(byteCount) paths=300 hardlinked=true")
    return try (0..<300).map { index in
      let url = folder.appendingPathComponent(String(format: "frame-%03d.tiff", index))
      try FileManager.default.linkItem(at: original, to: url)
      return ImageAsset(url: url, byteCount: byteCount, modificationDate: date)
    }
  }

  private static func load(
    _ assets: [ImageAsset], pipeline: ThumbnailPipeline, pixels: Int
  ) async throws -> Int {
    try await withThrowingTaskGroup(of: Bool.self) { group in
      for asset in assets {
        group.addTask {
          let image = try await pipeline.thumbnail(for: asset, maxPixelSize: pixels)
          return image.width > 0 && image.height > 0
        }
      }
      var count = 0
      for try await valid in group {
        #expect(valid)
        if valid { count += 1 }
      }
      return count
    }
  }

  @Test(
    "33 MB TIFF 300개 경로의 취소·중복·복구와 몽땅보기/10장 보기를 검증한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_NATIVE_THUMBNAILS"] == "1"),
    .timeLimit(.minutes(3)))
  func largeNativeThumbnails() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ImageViewerNativeThumbnail-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let assets = try makeFixture(in: folder)
    let pipeline = ThumbnailPipeline()

    try await withDeadline(seconds: 120) {
      // 100건을 빠르게 요청했다가 취소한 뒤에도 새 화면의 요청이 완료되어야 합니다.
      let cancelled = assets[40..<140].map { asset in
        Task {
          _ = try await pipeline.thumbnail(for: asset, maxPixelSize: 768)
        }
      }
      try await Task.sleep(for: .milliseconds(10))
      for task in cancelled { task.cancel() }
      for task in cancelled { _ = try? await task.value }

      let duplicateCount = try await Self.load(
        Array(repeating: assets[0], count: 8), pipeline: pipeline, pixels: 1_024)
      #expect(duplicateCount == 8)

      let firstStart = ProcessInfo.processInfo.systemUptime
      let firstCount = try await Self.load(
        Array(assets.prefix(20)), pipeline: pipeline, pixels: 256)
      let firstSeconds = ProcessInfo.processInfo.systemUptime - firstStart
      #expect(firstCount == 20)

      let allStart = ProcessInfo.processInfo.systemUptime
      let allCount = try await Self.load(assets, pipeline: pipeline, pixels: 256)
      let allSeconds = ProcessInfo.processInfo.systemUptime - allStart
      #expect(allCount == 300)

      let pageStart = ProcessInfo.processInfo.systemUptime
      let pageCount = try await Self.load(
        Array(assets[200..<210]), pipeline: pipeline, pixels: 1_024)
      let pageSeconds = ProcessInfo.processInfo.systemUptime - pageStart
      #expect(pageCount == 10)

      let cachedStart = ProcessInfo.processInfo.systemUptime
      let cachedCount = try await Self.load(assets, pipeline: pipeline, pixels: 256)
      let cachedSeconds = ProcessInfo.processInfo.systemUptime - cachedStart
      #expect(cachedCount == 300)
      print(String(
        format: "QL_NATIVE_TIMING first20=%.3fs all300=%.3fs page10=%.3fs repeat300=%.3fs",
        firstSeconds, allSeconds, pageSeconds, cachedSeconds))
    }
  }
}
