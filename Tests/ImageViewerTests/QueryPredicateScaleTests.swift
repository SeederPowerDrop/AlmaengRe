import Darwin
import Foundation
import Testing
@testable import ImageViewer

@Suite("대량 검색의 조건 준비·반복 비용", .serialized)
struct QueryPredicateScaleTests {
  @Test("1·20·2만·10만 파일의 무조건/확장자/종류 검색과 반복 메모리를 측정한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_QUERY_SCALE_OUTPUT"] != nil))
  func profileScale() async throws {
    try #require(QueryPerformanceTrace.enabled)
    struct Row: Codable { let count: Int; let condition: String; let round: Int; let matches: Int; let events: [QueryPerformanceTrace.Event] }
    var rows: [Row] = []
    let assets: [ImageAsset] = (0..<100_000).map { index in
      let ext = ["dng","jpeg","png","mp4","m4a"][index % 5]
      return ImageAsset(url: URL(fileURLWithPath: "/synthetic/photo\(100_000-index).\(ext)"),
        byteCount: Int64(index * 1000),modificationDate: nil)
    }
    let conditions = [("all",LibraryQuery()),
      ("extensions",LibraryQuery(fileExtensions: ["*.DNG"," png ",".MP4","%M4A%"])),
      ("images",LibraryQuery(mediaKind: .images)),
      ("bounds",LibraryQuery(searchFilters: .init(minimumBytes: 1000,maximumBytes: 20_000_000)))]
    for count in [1,20,20_000,100_000] {
      let input = Array(assets.prefix(count))
      for (condition,query) in conditions {
        for round in -1..<5 {
          let events = try await Task.detached {
            try autoreleasepool {
              QueryPerformanceTrace.reset()
              let start = QueryPerformanceTrace.start()
              let result = try RustImageEngine.query(input,options: query)
              return (result.count,try #require(QueryPerformanceTrace.snapshot(since: start)))
            }
          }.value
          if round >= 0 { rows.append(Row(count: count,condition: condition,round: round,matches: events.0,events: events.1)) }
        }
      }
    }
    func footprint() -> UInt64 {
      var usage = rusage_info_v4()
      let status = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self,capacity: 1) { proc_pid_rusage(getpid(),RUSAGE_INFO_V4,$0) }
      }
      return status == 0 ? usage.ri_phys_footprint : 0
    }
    let memoryBefore = footprint()
    for _ in 0..<20 {
      _ = try await Task.detached { try autoreleasepool { try RustImageEngine.query(assets,options: LibraryQuery()).count } }.value
    }
    let memoryAfter = footprint()
    #expect(memoryAfter < memoryBefore + 32 * 1024 * 1024,"Repeated queries must not accumulate whole-library copies")
    for _ in 0..<20 {
      _ = try await Task.detached { try autoreleasepool { try RustImageEngine.query(assets,options: LibraryQuery()).count } }.value
    }
    let memoryFinal = footprint()
    #expect(memoryFinal < memoryAfter + 16 * 1024 * 1024,"An additional batch must remain bounded after allocator warm-up")
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["IMAGEVIEWER_QUERY_SCALE_OUTPUT"]))
    try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
    try encoder.encode(rows).write(to: output.appendingPathComponent("query-scales.json"))
    try JSONSerialization.data(withJSONObject: ["before":memoryBefore,"after":memoryAfter,"final":memoryFinal,"repetitions":40],options: [.prettyPrinted,.sortedKeys])
      .write(to: output.appendingPathComponent("query-repeat-memory.json"))
  }
}
