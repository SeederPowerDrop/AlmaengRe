import CoreGraphics
import Foundation
import Testing

@testable import ImageViewer

/// Explicitly enabled, read-only sweep of the current thumbnail path. At most
/// four requests exist at once and the production governor further limits native
/// decoding and cache residency. Does not export pixels or print filenames.
@Suite("실제 RAW 폴더 전체 썸네일 검사", .serialized)
struct RealRAWFullDirectoryTests {
  private struct Outcome: Sendable {
    let decoded: Bool
    let validDimensions: Bool
  }

  @Test("폴더의 비어 있지 않은 RAW 전체를 제한된 작업 수와 메모리로 읽는다",
    .enabled(if: ProcessInfo.processInfo.environment["RAW_FULL_SCAN"] == "1"),
    .timeLimit(.minutes(10)))
  func allCurrentThumbnails() async throws {
    let environment = ProcessInfo.processInfo.environment
    let directory = URL(fileURLWithPath: try #require(environment["IMAGEVIEWER_RAW_DIRECTORY"]))
    let started = ProcessInfo.processInfo.systemUptime
    let urls = try FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
      options: [.skipsHiddenFiles])
      .filter { ImageFormatRegistry.cameraRAWExtensions.contains($0.pathExtension.lowercased()) }
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    var emptyFiles = 0
    let assets = try urls.compactMap { url -> ImageAsset? in
      let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
      guard values.isRegularFile == true else { return nil }
      guard let size = values.fileSize, size > 0 else { emptyFiles += 1; return nil }
      return ImageAsset(url: url, byteCount: Int64(size), modificationDate: values.contentModificationDate)
    }
    try #require(!assets.isEmpty)
    log(String(format:
      "RAW_FULL_SCAN phase=listing candidates=%d nonempty=%d skippedEmpty=%d seconds=%.6f readOnly=true coldStorage=false",
      urls.count, assets.count, emptyFiles, ProcessInfo.processInfo.systemUptime - started))
    let governor = ImageResourceGovernor(mode: .comfortable, storageOverride: .internalSSD)
    let thumbnails = ThumbnailPipeline(governor: governor)
    let decodingStarted = ProcessInfo.processInfo.systemUptime
    var completed = 0, failures = 0, invalidDimensions = 0
    try await withThrowingTaskGroup(of: Outcome.self) { group in
      var nextIndex = 0
      for asset in assets.prefix(4) {
        group.addTask { try await Self.decode(asset, pipeline: thumbnails) }
        nextIndex += 1
      }
      while let outcome = try await group.next() {
        completed += 1
        if !outcome.decoded { failures += 1 }
        else if !outcome.validDimensions { invalidDimensions += 1 }
        let snapshot = await thumbnails.cacheSnapshot()
        #expect(snapshot.byteCount <= snapshot.byteLimit)
        if completed.isMultiple(of: 100) || completed == assets.count {
          log(String(format:
            "RAW_FULL_SCAN phase=decoding completed=%d total=%d failures=%d invalidDimensions=%d seconds=%.6f cacheEntries=%d cacheBytes=%d cacheLimit=%d",
            completed, assets.count, failures, invalidDimensions,
            ProcessInfo.processInfo.systemUptime - decodingStarted,
            snapshot.entryCount, snapshot.byteCount, snapshot.byteLimit))
        }
        if nextIndex < assets.count {
          let asset = assets[nextIndex]
          group.addTask { try await Self.decode(asset, pipeline: thumbnails) }
          nextIndex += 1
        }
      }
    }
    #expect(completed == assets.count)
    #expect(failures == 0)
    #expect(invalidDimensions == 0)
    await thumbnails.purgeCache()
    #expect(await thumbnails.cacheSnapshot().byteCount == 0)
  }

  private static func decode(_ asset: ImageAsset, pipeline: ThumbnailPipeline) async throws -> Outcome {
    do {
      let image = try await pipeline.thumbnail(for: asset, maxPixelSize: 512)
      return Outcome(decoded: true, validDimensions: image.width > 0 && image.height > 0
        && max(image.width, image.height) <= 512 && image.bitsPerComponent == 8)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return Outcome(decoded: false, validDimensions: false)
    }
  }

  private func log(_ message: String) {
    // Direct writes let a long redirected run report progress immediately.
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
  }
}
