import CryptoKit
import Foundation
import Testing

@testable import ImageViewer

/// Measures the actual Swift predicates, record conversion and JSON ABI using
/// the same fixed RAW inventory as the installed-app run. Header preparation
/// and inventory checks are outside the timed engine calls; there is no UI.
@Suite("실제 대량 사진의 Swift·Rust 전달 단계 측정", .serialized)
struct RealQueryStageProfileTests {
  @Test("고정된 실제 사진 목록의 쿼리 단계를 반복 측정한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_REAL_QUERY_PROFILE"] == "1"),
    .timeLimit(.minutes(3)))
  func profileRealInventory() async throws {
    let env = ProcessInfo.processInfo.environment
    try #require(QueryPerformanceTrace.enabled)
    let directory = URL(fileURLWithPath: try #require(env["IMAGEVIEWER_RAW_DIRECTORY"]))
    let inventory = URL(fileURLWithPath: try #require(env["IMAGEVIEWER_QUERY_PROFILE_INVENTORY"]))
    let output = URL(fileURLWithPath: try #require(env["IMAGEVIEWER_QUERY_PROFILE_OUTPUT"]))
    let discovered = try FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.isRegularFileKey]).filter {
        try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
      }
    let selected = try OverviewBenchmarkSourceSelection.select(sourceURLs: discovered,
      inventoryData: Data(contentsOf: inventory))
    let before = selected.sourceURLs.map { ImageFileVersion(url: $0) }
    let photos = selected.sourceURLs.filter {
      !MediaFormatRegistry.isPlaybackMedia($0) && ImageFormatRegistry.canAttemptToDecode($0)
    }
    let library = ImageLibrary()
    let opened = try await library.open(urls: photos)
    try #require(opened.assets.count == 729)
    let metadataQuery = LibraryQuery(searchFilters: .init(metadataText: "Apple"))
    let assets = try await library.enrichQueryMetadata(opened.assets, for: metadataQuery)
    let cases: [(String, LibraryQuery)] = [
      ("name_ascending", LibraryQuery()),
      ("name_descending", LibraryQuery(sort: .nameDescending)),
      ("filename_subset", LibraryQuery(searchText: "IMG_00")),
      ("metadata_Apple", metadataQuery),
      ("camera_make", LibraryQuery(sort: .makeAscending)),
    ]
    struct Row: Encodable {
      let condition: String
      let round: Int
      let matches: Int
      let orderedResultSHA256: String
      let events: [QueryPerformanceTrace.Event]
    }
    var rows: [Row] = []
    for (label, query) in cases {
      let expected = try await Task.detached { try RustImageEngine.query(assets, options: query).map(\.id) }.value
      for round in -2..<7 {
        QueryPerformanceTrace.reset()
        let started = QueryPerformanceTrace.start()
        let result = try await Task.detached { try RustImageEngine.query(assets, options: query).map(\.id) }.value
        #expect(result == expected)
        if round >= 0 {
          let digest = SHA256.hash(data: Data(result.map(\.absoluteString).joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
          rows.append(Row(condition: label, round: round, matches: result.count,
            orderedResultSHA256: digest, events: try #require(QueryPerformanceTrace.snapshot(since: started))))
        }
      }
    }
    let unchanged = before == selected.sourceURLs.map { ImageFileVersion(url: $0) }
    #expect(unchanged)
    struct Report: Encodable {
      let scope = "actual_fixed_729_photo_headers_engine_stages_only_no_UI_no_image_decode_no_cold_IO_claim"
      let sourceMetadataUnchanged: Bool
      let originalRegularFileCount = 734
      let photos = 729
      let warmupsPerCondition = 2
      let measuredRoundsPerCondition = 7
      let rows: [Row]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(Report(sourceMetadataUnchanged: unchanged, rows: rows))
      .write(to: output, options: .atomic)
    print("REAL_QUERY_STAGE_PROFILE photos=729 rounds=7 conditions=5 sourceMetadataUnchanged=\(unchanged)")
  }
}
