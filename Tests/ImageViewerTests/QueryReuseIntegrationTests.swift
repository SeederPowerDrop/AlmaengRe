import Foundation
import Testing
@testable import ImageViewer

@Suite("화면별 검색 정보 재사용 연결", .serialized)
@MainActor
struct QueryReuseIntegrationTests {
  @Test("일반 보기와 비교보기의 반복 필터·정렬·초기화가 원본 목록과 같다")
  func viewerAndComparison() async throws {
    let suite = "QueryReuseIntegration.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII="))
    for i in 0..<320 { try png.write(to: root.appendingPathComponent("photo\(i).png")) }
    let store = AppStore(defaults: defaults,monitorsSystemResources: false,thumbnailDiskCache: nil)
    store.open(urls: [root]); try await ready { store.isLoading || store.isFiltering }
    #expect(store.allAssets.count == 320)
    let original = store.allAssets
    let queries = [LibraryQuery(sort: .sizeLargest),LibraryQuery(searchText: "photo1*"),
      LibraryQuery(fileExtensions: [".PNG"]),LibraryQuery(searchFilters: .init(metadataText: "Apple")),LibraryQuery()]
    for query in queries {
      let started = QueryPerformanceTrace.start()
      store.libraryQuery = query; try await ready { store.isLoading || store.isFiltering }
      #expect(try store.assets == RustImageEngine.query(store.allAssets,options: query))
      if QueryPerformanceTrace.enabled, query.searchText == "photo1*" {
        #expect(QueryPerformanceTrace.snapshot(since: started)?.contains { $0.stage == "ffi.query.reuse_input" } == true)
      }
    }
    for pane in [store.folderComparison.first,store.folderComparison.second] {
      pane.open(urls: [root]); try await ready { pane.isLoading || pane.isFiltering }
      for query in queries {
        let started = QueryPerformanceTrace.start()
        pane.query = query; try await ready { pane.isLoading || pane.isFiltering }
        #expect(try pane.assets.map(\.url) == RustImageEngine.query(original,options: query).map(\.url))
        if QueryPerformanceTrace.enabled, query.searchText == "photo1*" {
          #expect(QueryPerformanceTrace.snapshot(since: started)?.contains { $0.stage == "ffi.query.reuse_input" } == true)
        }
      }
      pane.cancelLoad()
    }
    store.showHome()
  }
  private func ready(_ isBusy: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while isBusy() {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
