import Foundation
import ImageIO
import Testing

@testable import ImageViewer

/// Opt-in read-only header workload. Logs include aggregate timings/counts only;
/// filenames, captured dates, locations and source pixels are never exported.
/// Filesystem caches are not flushed, so these are warm-system observations.
@Suite("실제 RAW 지도·EXIF 헤더 재사용 성능", .serialized)
struct RealRAWMetadataPerformanceTests {
  @Test("이전 GPS·EXIF 별도 읽기와 공용 헤더 읽기를 교대로 비교한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_METADATA_BENCHMARK"] == "1"),
    .timeLimit(.minutes(5)))
  func comparePreviousAndSharedHeaders() async throws {
    let environment = ProcessInfo.processInfo.environment
    let directory = URL(fileURLWithPath: try #require(environment["IMAGEVIEWER_RAW_DIRECTORY"]))
    let limit = max(1, Int(environment["IMAGEVIEWER_RAW_LIMIT"] ?? "36") ?? 36)
    let library = ImageLibrary()
    let opened = try await library.open(urls: [directory])
    let assets = Array(opened.assets.filter {
      ImageFormatRegistry.cameraRAWExtensions.contains($0.fileExtension) && ($0.byteCount ?? 0) > 0
    }.prefix(limit))
    try #require(!assets.isEmpty)
    // Alternate execution order with fresh application caches every time. Both
    // paths retain the same production governor for their EXIF phase, while the
    // old GPS phase deliberately follows its previous ungoverned serial path.
    for round in 0..<4 {
      let order = round.isMultiple(of: 2) ? [false, true] : [true, false]
      var previous: [ImageAsset] = [], shared: [ImageAsset] = []
      for usesSharedHeader in order {
        let cache = LibrarySortMetadataCache()
        let governor = ImageResourceGovernor(mode: .comfortable, storageOverride: .internalSSD)
        let start = ProcessInfo.processInfo.systemUptime
        let located = usesSharedHeader
          ? try await library.enrichLocations(assets, governor: governor, cache: cache)
          : try Self.previousLocations(assets)
        let prepared = try await library.enrichSortMetadata(located, for: .capturedNewest,
          governor: governor, cache: cache)
        log("\(usesSharedHeader ? "shared" : "previous")_round\(round + 1)",
          count: assets.count, start: start, reads: assets.count * (usesSharedHeader ? 1 : 2))
        if usesSharedHeader { shared = prepared } else { previous = prepared }
      }
      #expect(shared.map(\.location) == previous.map(\.location))
      #expect(shared.map(\.sortMetadata) == previous.map(\.sortMetadata))
    }
  }

  @Test("지도 뒤 EXIF 정렬과 새 라이브러리에서 추가 헤더 읽기를 피한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_METADATA_BENCHMARK"] == "1"),
    .timeLimit(.minutes(5)))
  func metadataReuse() async throws {
    let environment = ProcessInfo.processInfo.environment
    let directory = URL(fileURLWithPath: try #require(environment["IMAGEVIEWER_RAW_DIRECTORY"]))
    let limit = max(1, Int(environment["IMAGEVIEWER_RAW_LIMIT"] ?? "36") ?? 36)
    let library = ImageLibrary()
    let opened = try await library.open(urls: [directory])
    let assets = Array(opened.assets.filter {
      ImageFormatRegistry.cameraRAWExtensions.contains($0.fileExtension) && ($0.byteCount ?? 0) > 0
    }.prefix(limit))
    try #require(!assets.isEmpty)
    let counter = ReadCounter()
    let cache = LibrarySortMetadataCache { url, isVideo in
      await counter.increment()
      return try await LibrarySortMetadataReader.read(url, isVideo: isVideo)
    }
    let governor = ImageResourceGovernor(mode: .comfortable, storageOverride: .internalSSD)
    var start = ProcessInfo.processInfo.systemUptime
    let located = try await library.enrichLocations(assets, governor: governor, cache: cache)
    let indexedReads = await counter.value
    log("first_map_headers", count: assets.count, start: start, reads: indexedReads)
    #expect(indexedReads == assets.count && located.allSatisfy { $0.hasReadLocation })

    start = ProcessInfo.processInfo.systemUptime
    let prepared = try await library.enrichSortMetadata(located, for: .capturedNewest,
      governor: governor, cache: cache)
    let sortedReads = await counter.value
    log("followup_capture_sort", count: assets.count, start: start, reads: sortedReads - indexedReads)
    #expect(prepared.allSatisfy { $0.sortMetadata != nil })
    #expect(sortedReads == indexedReads)

    start = ProcessInfo.processInfo.systemUptime
    let rescanned = try await ImageLibrary().enrichLocations(assets, governor: governor, cache: cache)
    let revisitedReads = await counter.value
    log("fresh_library_map", count: assets.count, start: start, reads: revisitedReads - sortedReads)
    #expect(rescanned.map(\.location) == located.map(\.location))
    #expect(revisitedReads == indexedReads)
  }

  private func log(_ phase: String, count: Int, start: TimeInterval, reads: Int) {
    print(String(format:
      "RAW_METADATA_BENCHMARK phase=%@ count=%d seconds=%.6f headerReads=%d readOnly=true coldStorage=false",
      phase, count, ProcessInfo.processInfo.systemUptime - start, reads))
  }

  /// Reproduces the former map-only ImageIO read without invoking the revised
  /// shared cache. The source file remains untouched.
  private static func previousLocations(_ assets: [ImageAsset]) throws -> [ImageAsset] {
    var result = assets
    for index in result.indices {
      try Task.checkCancellation()
      result[index].location = autoreleasepool {
        guard let source = CGImageSourceCreateWithURL(result[index].url as CFURL,
          [kCGImageSourceShouldCache: false] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
          let latitude = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
          let longitude = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue,
          latitude.isFinite, longitude.isFinite, (0...90).contains(latitude),
          (0...180).contains(longitude) else { return nil }
        let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased()
        let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased()
        guard ["N", "S"].contains(latRef ?? ""), ["E", "W"].contains(lonRef ?? "") else { return nil }
        return ImageLocation(latitude: latRef == "S" ? -latitude : latitude,
          longitude: lonRef == "W" ? -longitude : longitude)
      }
      result[index].hasReadLocation = true
    }
    return result
  }

  private actor ReadCounter {
    var value = 0
    func increment() { value += 1 }
  }
}
