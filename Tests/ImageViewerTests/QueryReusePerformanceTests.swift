import Darwin
import Foundation
import Testing
@testable import ImageViewer

@Suite("반복 검색 정보 재사용의 규모별 측정", .serialized)
struct QueryReusePerformanceTests {
  @Test("작은 목록·2만·10만·실제 RAW/영상 목록의 첫 검색과 반복 검색을 비교한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_QUERY_REUSE_OUTPUT"] != nil),
    .timeLimit(.minutes(10)))
  func profile() async throws {
    try #require(QueryPerformanceTrace.enabled)
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["IMAGEVIEWER_QUERY_REUSE_OUTPUT"]))
    try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
    let synthetic: [ImageAsset] = (0..<100_000).map { i in
      var asset = ImageAsset(url: URL(fileURLWithPath: "/synthetic/photo\(100_000-i).\(["dng","mp4","m4a","png"][i % 4])"),
        byteCount: Int64(i * 1000),modificationDate: nil)
      asset.sortMetadata = LibrarySortMetadata(cameraMake: "Apple",cameraModel: "iPhone")
      return asset
    }
    var corpora = [1,20,20_000,100_000].map { ("synthetic_\($0)",Array(synthetic.prefix($0))) }
    if let path = ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_DIRECTORY"] {
      let library = ImageLibrary()
      let opened = try await library.open(urls: [URL(fileURLWithPath: path)],includesVideos: true)
      let prepared = try await library.enrichQueryMetadata(opened.assets,
        for: LibraryQuery(searchFilters: .init(metadataText: "Apple")))
      corpora.append(("real_mixed",prepared))
    }
    struct Row: Codable {
      let corpus: String; let count: Int; let condition: String; let reuse: Bool; let round: Int
      let matches: Int; let wallSeconds: Double; let cpuSeconds: Double; let retainedBytes: Int
      let events: [QueryPerformanceTrace.Event]
    }
    var rows: [Row] = [], memoryRows: [[String: Any]] = []
    for (label,source) in corpora {
      let versions = label == "real_mixed" ? source.map { ImageFileVersion(url: $0.url) } : []
      let pool = RustQueryReusePool(), session = RustQuerySession(pool: pool)
      let conditions = [("names",LibraryQuery()),("size",LibraryQuery(sort: .sizeLargest)),
        ("rebuilt_names",LibraryQuery()),
        ("text",LibraryQuery(searchText: "*1*")),("extensions",LibraryQuery(fileExtensions: ["dng","mp4"])),
        ("audio",LibraryQuery(mediaKind: .audio)),
        ("EXIF",LibraryQuery(searchFilters: .init(metadataText: "Apple"))),
        ("empty",LibraryQuery(searchText: "impossible_match_zzz"))]
      for (condition,query) in conditions {
        let input = condition == "rebuilt_names" ? source.map { $0.replacingURL(URL(fileURLWithPath: $0.url.path)) } : source
        let expected = try RustImageEngine.query(source,options: query)
        for round in -1..<5 {
          for reuse in (round.isMultiple(of: 2) ? [false,true] : [true,false]) {
            let measured = try await Task.detached {
              try autoreleasepool {
                QueryPerformanceTrace.reset()
                let start = ProcessInfo.processInfo.systemUptime, cpu = Self.cpuSeconds()
                let result = try RustImageEngine.query(input,options: query,session: reuse ? session : nil)
                return (result,ProcessInfo.processInfo.systemUptime-start,Self.cpuSeconds()-cpu,
                  try #require(QueryPerformanceTrace.snapshot(since: start)))
              }
            }.value
            #expect(measured.0 == expected)
            rows.append(Row(corpus: label,count: source.count,condition: condition,reuse: reuse,round: round,
              matches: measured.0.count,wallSeconds: measured.1,cpuSeconds: measured.2,
              retainedBytes: pool.retainedBytes,events: measured.3))
          }
        }
      }
      #expect(source.count < 256 ? pool.retainedBytes == 0 : pool.retainedBytes > 0)
      #expect(pool.retainedBytes <= pool.byteLimit)
      if label == "synthetic_100000" {
        let before = Self.footprint()
        for _ in 0..<20 {
          _ = try await Task.detached { try autoreleasepool {
            try RustImageEngine.query(source,options: .init(sort: .sizeLargest),session: session).count
          } }.value
        }
        let after = Self.footprint()
        for _ in 0..<20 {
          _ = try await Task.detached { try autoreleasepool {
            try RustImageEngine.query(source,options: .init(searchText: "*1*"),session: session).count
          } }.value
        }
        let final = Self.footprint()
        #expect(after < before + 32 * 1024 * 1024)
        #expect(final < after + 32 * 1024 * 1024)
        let retained = pool.retainedBytes
        pool.setReuseAllowed(false)
        #expect(pool.retainedBytes == 0)
        memoryRows.append(["corpus":label,"before":before,"after":after,"final":final,
          "retainedMetadataBytes":retained,"afterPressureBytes":pool.retainedBytes,"repetitions":40,
          "budgetBytes":pool.byteLimit,"assetStride":MemoryLayout<ImageAsset>.stride])
      }
      if label == "real_mixed" { #expect(source.map { ImageFileVersion(url: $0.url) } == versions) }
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
    try encoder.encode(rows).write(to: output.appendingPathComponent("query-reuse.json"))
    try JSONSerialization.data(withJSONObject: memoryRows,options: [.prettyPrinted,.sortedKeys])
      .write(to: output.appendingPathComponent("query-reuse-memory.json"))
  }

  private static func cpuSeconds() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }
  private static func footprint() -> UInt64 {
    var usage = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &usage) {
      $0.withMemoryRebound(to: rusage_info_t?.self,capacity: 1) { proc_pid_rusage(getpid(),RUSAGE_INFO_V4,$0) }
    }
    return status == 0 ? usage.ri_phys_footprint : 0
  }
}
