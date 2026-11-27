import Darwin
import Foundation
import Testing
@testable import ImageViewer

@Suite("작은 목록·대량 목록 엔진 전달 비용", .serialized)
struct EngineTransferPerformanceTests {
  @Test("1·20·2만 파일과 실제 RAW·영상 목록의 전달 단계를 분리한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_FOUNDATION_OUTPUT"] != nil))
  func profileQueries() async throws {
    try #require(QueryPerformanceTrace.enabled)
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["IMAGEVIEWER_FOUNDATION_OUTPUT"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let synthetic = (0..<20_000).map { index in
      ImageAsset(url: URL(fileURLWithPath: "/synthetic/여행/photo\(20_000-index).\(index % 3 == 0 ? "mp4" : "dng")"),
        byteCount: Int64(index * 1000), modificationDate: Date(timeIntervalSince1970: Double(index)))
    }
    var corpora: [(String, [ImageAsset])] = [("one",Array(synthetic.prefix(1))),
      ("twenty",Array(synthetic.prefix(20))), ("twenty_thousand",synthetic)]
    if let path = ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_DIRECTORY"] {
      let opened = try await ImageLibrary().open(urls: [URL(fileURLWithPath: path)], includesVideos: true)
      corpora.append(("real_mixed",opened.assets))
    }
    struct Row: Encodable {
      var corpus: String, count: Int, condition: String, round: Int, matches: Int
      var events: [QueryPerformanceTrace.Event]
    }
    var rows: [Row] = []
    for (label, assets) in corpora {
      for (condition, options) in [("names",LibraryQuery()),
        ("size",LibraryQuery(sort: .sizeLargest)), ("empty_match",LibraryQuery(searchText: "impossible_match_zzz"))] {
        let expected = try RustImageEngine.query(assets, options: options).map(\.id)
        for round in 0..<5 {
          QueryPerformanceTrace.reset()
          let start = QueryPerformanceTrace.start()
          let result = try await Task.detached { try RustImageEngine.query(assets, options: options) }.value
          #expect(result.map(\.id) == expected)
          rows.append(Row(corpus: label, count: assets.count, condition: condition, round: round,
            matches: result.count, events: try #require(QueryPerformanceTrace.snapshot(since: start))))
        }
      }
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
    try encoder.encode(rows).write(to: output.appendingPathComponent("query-stages.json"))
  }
}
