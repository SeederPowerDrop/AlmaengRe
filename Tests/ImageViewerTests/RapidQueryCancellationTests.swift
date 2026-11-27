import Foundation
import Testing
@testable import ImageViewer

@Suite("연속 탐색의 검색 취소·최신 결과·동시 실행 한도", .serialized)
struct RapidQueryCancellationTests {
  @Test("취소를 무시하는 두 작업이 있어도 대기 중 100개를 실행하지 않고 최신 요청으로 수렴한다")
  func boundedNativeWorkAndImmediateCallerCancellation() async throws {
    let executor = LibraryQueryExecutor(maxConcurrentTasks: 2), probe = QueryCancellationProbe()
    let first = Task { try await executor.value { await probe.run(0) } }
    let second = Task { try await executor.value { await probe.run(1) } }
    defer { first.cancel(); second.cancel(); Task { await probe.releaseAll() } }
    try await wait { await probe.started.count == 2 }
    first.cancel()
    await expectCancellation(first)
    #expect(await probe.completed.isEmpty, "Cancellation must stop waiting before native work finishes")
    for index in 2..<102 {
      let abandoned = Task { try await executor.value { await probe.run(index) } }
      try await wait { await executor.stateSnapshot().queuedCount == 1 }
      abandoned.cancel()
      await expectCancellation(abandoned)
    }
    let latest = Task { try await executor.value { await probe.run(102) } }
    defer { latest.cancel() }
    try await wait { await executor.stateSnapshot().queuedCount == 1 }
    #expect(await probe.started.count == 2)
    await probe.release(1)
    #expect(try await second.value == 1)
    try await wait { await probe.started.count == 3 }
    #expect(await probe.maximumRunning == 2)
    await probe.release(102)
    #expect(try await latest.value == 102)
    await probe.release(0)
    try await wait {
      let state = await executor.stateSnapshot()
      return state.runningCount == 0 && state.queuedCount == 0 && state.waiterCount == 0
    }
    #expect(Set(await probe.started) == [0,1,102])
    #expect(await probe.cancelledCompletions == [0])
  }

  @Test("취소·실패 뒤 복구하고 다른 반환형의 요청을 섞지 않으며 UI 스레드에서 실행하지 않는다")
  @MainActor
  func typedResultsAndRecovery() async throws {
    let executor = LibraryQueryExecutor(maxConcurrentTasks: 1)
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await executor.value {
        Issue.record("Cancelled query must not execute")
        return 1
      }
    }
    await expectCancellation(cancelled)
    do {
      _ = try await executor.value { () throws -> Int in throw RapidQueryFailure.expected }
      Issue.record("Expected operation failure")
    } catch RapidQueryFailure.expected {}
    let result = try await executor.value { (Self.onMainThread(), "latest") }
    #expect(!result.0 && result.1 == "latest")
    let numbers: [Int] = try await executor.value { [1,2,3] }
    #expect(numbers == [1,2,3])
  }

  @Test("폴더 로딩 중 조건 변경은 스캔을 보존하며 이전 검색만 취소한다")
  @MainActor
  func queryChangesDuringOpenCancelOnlyTheObsoleteQuery() async throws {
    let fixture = try QueryCancellationFixture()
    defer { fixture.remove() }
    let executor = LibraryQueryExecutor(maxConcurrentTasks: 1), probe = QueryCancellationProbe()
    let blocker = Task { try await executor.value { await probe.run(0) } }
    defer { blocker.cancel(); Task { await probe.releaseAll() } }
    try await wait { await probe.started.count == 1 }
    let store = fixture.store(executor)
    store.open(urls: [fixture.first])
    try await wait { await executor.stateSnapshot().queuedCount == 1 }
    #expect(store.isLoading)
    store.libraryQuery.searchText = "first1*"
    // The occupied worker remains occupied, but the old child query must leave
    // its queue before the retry's quiet interval finishes.
    try await wait { await executor.stateSnapshot().queuedCount == 0 }
    #expect(store.isLoading && store.allAssets.isEmpty)
    store.libraryQuery.sort = .nameDescending
    try await wait { await executor.stateSnapshot().queuedCount == 1 }
    await probe.release(0)
    #expect(try await blocker.value == 0)
    try await wait { !store.isLoading && !store.isFiltering }
    #expect(store.allAssets.count == 20)
    #expect(store.assets.map(\.filename) == (10...19).reversed().map { "first\($0).png" } + ["first1.png"])
    #expect(try store.assets == RustImageEngine.query(store.allAssets,options: store.libraryQuery))
    #expect(store.alert == nil)
  }

  @Test("막힌 검색 중 폴더를 반복 교체해도 일반·비교 보기에는 마지막 폴더와 조건만 반영한다")
  @MainActor
  func latestFolderWinsAcrossViewerAndComparison() async throws {
    let fixture = try QueryCancellationFixture()
    defer { fixture.remove() }
    let executor = LibraryQueryExecutor(maxConcurrentTasks: 1), probe = QueryCancellationProbe()
    let blocker = Task { try await executor.value { await probe.run(0) } }
    defer { blocker.cancel(); Task { await probe.releaseAll() } }
    try await wait { await probe.started.count == 1 }
    let store = fixture.store(executor)
    store.open(urls: [fixture.first])
    try await wait { await executor.stateSnapshot().queuedCount == 1 }
    store.open(urls: [fixture.second])
    store.libraryQuery.searchText = "second*"
    for pane in [store.folderComparison.first, store.folderComparison.second] {
      pane.open(urls: [fixture.first])
      pane.query = LibraryQuery(searchText: "first1*")
    }
    try await wait { await executor.stateSnapshot().queuedCount == 3 }
    for index in 0..<40 {
      store.libraryQuery.sort = index.isMultiple(of: 2) ? .sizeLargest : .nameDescending
      store.folderComparison.first.query.searchText = index.isMultiple(of: 2) ? "first1*" : "first2*"
      store.folderComparison.second.query.searchText = index.isMultiple(of: 2) ? "first2*" : "first1*"
      await Task.yield()
    }
    store.folderComparison.first.open(urls: [fixture.second])
    store.folderComparison.first.query = LibraryQuery(searchText: "second1*",sort: .nameDescending)
    await probe.release(0)
    #expect(try await blocker.value == 0)
    try await wait {
      !store.isLoading && !store.isFiltering
        && !store.folderComparison.first.isLoading && !store.folderComparison.first.isFiltering
        && !store.folderComparison.second.isLoading && !store.folderComparison.second.isFiltering
    }
    #expect(store.assets.count == 20 && store.assets.allSatisfy { $0.filename.hasPrefix("second") })
    #expect(store.folderComparison.first.assets.count == 11)
    #expect(store.folderComparison.first.assets.allSatisfy { $0.filename.hasPrefix("second1") })
    #expect(store.folderComparison.second.assets.count == 11)
    #expect(store.folderComparison.second.assets.allSatisfy { $0.filename.hasPrefix("first1") })
    #expect(store.alert == nil && store.folderComparison.first.errorMessage == nil && store.folderComparison.second.errorMessage == nil)
  }

  @Test("세션 복원 중 조건을 바꾸거나 새 폴더를 열면 이전 검색과 복원만 취소한다", arguments: [false,true])
  @MainActor
  func restoreRespectsNewInput(openOther: Bool) async throws {
    let fixture = try QueryCancellationFixture()
    defer { fixture.remove() }
    let executor = LibraryQueryExecutor(maxConcurrentTasks: 1), probe = QueryCancellationProbe()
    let original = fixture.store(executor)
    original.open(urls: [fixture.first])
    try await wait { !original.isLoading && !original.isFiltering }
    original.saveSessionNow()
    let blocker = Task { try await executor.value { await probe.run(0) } }
    defer { blocker.cancel(); Task { await probe.releaseAll() } }
    try await wait { await probe.started.count == 1 }
    let restored = fixture.store(executor)
    let restoring = Task { await restored.restoreLastSession() }
    defer { restoring.cancel() }
    try await wait { await executor.stateSnapshot().queuedCount == 1 }
    #expect(restored.isRestoringSession)
    if openOther {
      restored.open(urls: [fixture.second])
      restored.libraryQuery.searchText = "second1*"
      try await wait { !restored.isRestoringSession }
    } else {
      restored.libraryQuery.searchText = "first1*"
      restored.showsVideos = false
      try await wait { await executor.stateSnapshot().queuedCount == 0 }
      try await wait { await executor.stateSnapshot().queuedCount == 1 }
    }
    await probe.release(0)
    #expect(try await blocker.value == 0)
    await restoring.value
    try await wait { !restored.isLoading && !restored.isFiltering && !restored.isRestoringSession }
    #expect(restored.assets.count == 11)
    #expect(restored.assets.allSatisfy { $0.filename.hasPrefix(openOther ? "second1" : "first1") })
    #expect(restored.alert == nil)
  }

  private static func onMainThread() -> Bool { Thread.isMainThread }

  @Test("실제 RAW·영상 폴더에서 연속 조건 변경 뒤 최신 목록만 반영하고 원본을 보존한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_RAPID_DIRECTORY"] != nil),
    .timeLimit(.minutes(3)))
  @MainActor
  func realCorpusRapidQueries() async throws {
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["IMAGEVIEWER_RAPID_DIRECTORY"]))
    let suite = "RapidReal.\(UUID())", executor = LibraryQueryExecutor()
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults,monitorsSystemResources: false,thumbnailDiskCache: nil,
      queryExecutor: executor)
    store.open(urls: [directory])
    try await wait { !store.isLoading && !store.isFiltering }
    let source = store.allAssets
    try #require(source.count > 20 && source.contains { $0.fileExtension == "dng" } && source.contains( where: \.isVideo))
    let versions = source.map { ImageFileVersion(url: $0.url) }
    let started = ProcessInfo.processInfo.systemUptime
    store.libraryQuery = LibraryQuery(searchFilters: .init(metadataText: "Apple"))
    try await Task.sleep(for: .milliseconds(130))
    for index in 0..<64 {
      store.libraryQuery = index.isMultiple(of: 2)
        ? LibraryQuery(searchText: "*\(index % 10)*",sort: .nameDescending)
        : LibraryQuery(mediaKind: .videos)
      try await Task.sleep(for: .milliseconds(8))
    }
    let final = LibraryQuery(sort: .nameDescending,fileExtensions: ["dng","mp4"])
    let lastInput = ProcessInfo.processInfo.systemUptime
    store.libraryQuery = final
    try await wait { !store.isLoading && !store.isFiltering }
    let settled = ProcessInfo.processInfo.systemUptime
    let expected = try RustImageEngine.query(store.allAssets,options: final)
    #expect(store.assets == expected && !store.assets.isEmpty && store.alert == nil)
    #expect(source.map { ImageFileVersion(url: $0.url) } == versions)
    try await wait {
      let state = await executor.stateSnapshot()
      return state.runningCount == 0 && state.queuedCount == 0 && state.waiterCount == 0
    }
    if let output = ProcessInfo.processInfo.environment["IMAGEVIEWER_RAPID_OUTPUT"] {
      let root = URL(fileURLWithPath: output)
      try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
      let report: [String: Any] = ["sourceCount":source.count,"videoCount":source.filter(\.isVideo).count,
        "audioCount":source.filter(\.isAudio).count,"inputChanges":66,"finalMatches":store.assets.count,
        "finalCommitAfterLastInputSeconds":settled-lastInput,"wallSeconds":settled-started,
        "sourceMetadataUnchanged":true,"finalResultMatchesStatelessQuery":true,
        "engineWorkFullyDrained":true,"scope":"real AppStore rapid queries, includes debounce and header work; no pixel capture or cold IO claim"]
      try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys])
        .write(to: root.appendingPathComponent("real-rapid-queries.json"))
    }
  }

  private func expectCancellation(_ task: Task<Int, any Error>) async {
    do { _ = try await task.value; Issue.record("Expected caller cancellation") }
    catch { #expect(error is CancellationError) }
  }
  @MainActor
  private func wait(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await condition()) {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(1))
    }
  }
}

private enum RapidQueryFailure: Error { case expected }

private actor QueryCancellationProbe {
  private(set) var started: [Int] = [], completed: [Int] = [], cancelledCompletions: [Int] = []
  private(set) var maximumRunning = 0
  private var continuations: [Int: CheckedContinuation<Void,Never>] = [:]
  func run(_ index: Int) async -> Int {
    started.append(index)
    maximumRunning = max(maximumRunning,continuations.count + 1)
    await withCheckedContinuation { continuations[index] = $0 }
    completed.append(index)
    if Task.isCancelled { cancelledCompletions.append(index) }
    return index
  }
  func release(_ index: Int) { continuations.removeValue(forKey: index)?.resume() }
  func releaseAll() {
    let pending = continuations; continuations.removeAll()
    for continuation in pending.values { continuation.resume() }
  }
}

private struct QueryCancellationFixture {
  let root: URL, first: URL, second: URL, suite: String, defaults: UserDefaults
  init() throws {
    suite = "RapidQuery.\(UUID())"
    defaults = try #require(UserDefaults(suiteName: suite))
    root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    first = root.appendingPathComponent("First"); second = root.appendingPathComponent("Second")
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII="))
    for (folder,prefix) in [(first,"first"),(second,"second")] {
      try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
      for index in 0..<20 { try png.write(to: folder.appendingPathComponent("\(prefix)\(index).png")) }
    }
  }
  @MainActor func store(_ executor: LibraryQueryExecutor) -> AppStore {
    AppStore(defaults: defaults,monitorsSystemResources: false,thumbnailDiskCache: nil,queryExecutor: executor)
  }
  func remove() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}
