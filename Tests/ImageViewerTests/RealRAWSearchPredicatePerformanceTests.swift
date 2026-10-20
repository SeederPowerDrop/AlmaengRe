import Darwin
import Foundation
import Testing

@testable import ImageViewer

/// Alternating, same-process comparison of the previous per-asset preparation
/// with the compiled predicate. This measures filtering of already read headers,
/// not folder opening, UI updates, cold storage, or final screen paint.
@Suite("실제 RAW 검색 조건 준비 비용", .serialized)
struct RealRAWSearchPredicatePerformanceTests {
  @Test("실제 RAW 헤더에서 이전 검색과 준비된 검색의 결과·작업 비용을 비교한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_PREDICATE_BENCHMARK"] == "1"),
    .timeLimit(.minutes(5)))
  func comparePreparedPredicate() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_DIRECTORY"])
    let library = ImageLibrary()
    let opened = try await library.open(urls: [URL(fileURLWithPath: path)])
    let photos = opened.assets.filter { ($0.byteCount ?? 0) > 0
      && ImageFormatRegistry.cameraRAWExtensions.contains($0.fileExtension) }
    let versions = photos.map { ImageFileVersion(url: $0.url) }
    let query = LibraryQuery(searchFilters: LibrarySearchFilters(metadataText: "Apple"))
    let assets = try await library.enrichQueryMetadata(photos, for: query)
    try #require(!assets.isEmpty)
    let calendar = LibraryCalendarDay.calendar
    let cases: [(String, LibrarySearchFilters)] = [
      ("inactive_text_fields", .init()), ("EXIF_Apple", .init(metadataText: "Apple")),
      ("GPS_only", .init(gps: .present)), ("location_text", .init(locationText: "Paris")),
    ]
    var rows: [[String: Any]] = []
    for (label, filters) in cases {
      var legacySamples: [Double] = [], preparedSamples: [Double] = []
      var legacyCPU = 0.0, preparedCPU = 0.0, matched = 0
      let predicate = LibrarySearchPredicate(filters: filters, calendar: calendar)
      for round in 0..<6 {
        for prepared in (round.isMultiple(of: 2) ? [false, true] : [true, false]) {
          let beforeCPU = cpuSeconds(), started = ProcessInfo.processInfo.systemUptime
          let result = assets.filter { prepared ? predicate.matches($0)
            : previousMatches(filters, asset: $0, calendar: calendar) }.map(\.id)
          let elapsed = ProcessInfo.processInfo.systemUptime - started
          let cpu = cpuSeconds() - beforeCPU
          #expect(result == assets.filter(predicate.matches).map(\.id))
          matched = result.count
          if prepared { preparedSamples.append(elapsed); preparedCPU += cpu }
          else { legacySamples.append(elapsed); legacyCPU += cpu }
        }
      }
      rows.append(["condition": label, "matches": matched,
        "legacyWallSeconds": legacySamples, "preparedWallSeconds": preparedSamples,
        "legacyCPUSeconds": legacyCPU, "preparedCPUSeconds": preparedCPU])
    }
    let sourceUnchanged = photos.map { ImageFileVersion(url: $0.url) } == versions
    #expect(sourceUnchanged)
    let report: [String: Any] = ["sourceCount": assets.count, "rounds": 6,
      "scope": "prepared_real_RAW_headers_predicate_only_alternating_same_process",
      "sourceMetadataUnchanged": sourceUnchanged, "OSFileCachesUncontrolled": true, "conditions": rows]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    FileHandle.standardOutput.write(Data("RAW_SEARCH_PREDICATE_PERFORMANCE ".utf8) + data + Data("\n".utf8))
  }

  private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }

  /// Preserved build85 algorithm, independent of the new compiled predicate.
  private func previousMatches(_ filters: LibrarySearchFilters, asset: ImageAsset,
    calendar: Calendar) -> Bool {
    if filters.minimumBytes != nil || filters.maximumBytes != nil {
      guard let bytes = asset.byteCount else { return false }
      if let minimum = filters.minimumBytes, bytes < minimum { return false }
      if let maximum = filters.maximumBytes, bytes > maximum { return false }
    }
    if let date = filters.date, !date.matches(asset, calendar: calendar) { return false }
    let metadata = asset.sortMetadata
    let location = metadata.map { $0.embeddedLocation } ?? asset.location
    if filters.gps == .present && location == nil { return false }
    if filters.gps == .absent && location != nil { return false }
    if !LibraryTextMatcher(pattern: filters.metadataText, anchorsWildcards: false)
      .matches(metadata?.searchableText ?? "") { return false }
    let locationValue = [metadata?.locationText, location?.coordinateDescription]
      .compactMap { $0 }.joined(separator: "\n")
    return LibraryTextMatcher(pattern: filters.locationText, anchorsWildcards: false).matches(locationValue)
  }
}
