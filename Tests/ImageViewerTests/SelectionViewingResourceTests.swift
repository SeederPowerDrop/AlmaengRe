import Darwin
import Foundation
import Testing
@testable import ImageViewer

@Suite("선택 보기 자원 비용", .serialized)
@MainActor
struct SelectionViewingResourceTests {
  @Test("2만 파일 선택 보기 왕복의 CPU·메모리·저장 크기를 측정한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_SELECTION_RESOURCE_OUTPUT"] != nil))
  func largeCollectionResources() async throws {
    let suite = "SelectionResource.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    let folder = root.appendingPathComponent("Photos")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let qoi = Data([0x71,0x6f,0x69,0x66,0,0,0,1,0,0,0,1,3,0,0xfe,255,0,0,0,0,0,0,0,0,0,1])
    for i in 0..<20_000 { try qoi.write(to: folder.appendingPathComponent("photo\(i).qoi")) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: root.appendingPathComponent("marks.sqlite"), thumbnailDiskCache: nil)
    store.open(urls: [folder])
    let deadline = ContinuousClock.now + .seconds(30)
    while store.isLoading || store.isFiltering {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
    await store.photoMarks.waitUntilReady()
    store.returnToOverview()
    let original = store.assets
    try #require(original.count == 20_000)
    let buffer = original.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    store.selectForBatch(index: 0, modifiers: [])
    for index in stride(from: 500, to: 16_000, by: 500) { store.selectForBatch(index: index, modifiers: .command) }
    let chosen = store.selectedURLs
    func cycle() {
      store.viewSelectedFiles(together: true)
      store.returnToOverview()
    }
    for _ in 0..<5 { autoreleasepool { cycle() } }
    let before = footprint()
    let cpuStart = OverviewWarmCPUCost.processCPUSeconds() ?? 0
    var entry: [Double] = [], back: [Double] = []
    var sharedBuffers = true
    for _ in 0..<30 {
      autoreleasepool {
        var start = ProcessInfo.processInfo.systemUptime
        store.viewSelectedFiles(together: true)
        entry.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        sharedBuffers = sharedBuffers && store.selectionViewingContext?.overviewAssets.withUnsafeBufferPointer {
          UInt(bitPattern: $0.baseAddress) == buffer
        } == true
        start = ProcessInfo.processInfo.systemUptime
        store.returnToOverview()
        back.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
      }
    }
    let cpu = (OverviewWarmCPUCost.processCPUSeconds() ?? cpuStart) - cpuStart
    let after = footprint()
    #expect(sharedBuffers, "The overview metadata buffer must be shared rather than copied")
    #expect(store.selectionViewingContext == nil && store.selectedURLs == chosen)
    let sourceCount = try FileManager.default.contentsOfDirectory(atPath: folder.path).count
    #expect(sourceCount == 20_000, "Viewing must never copy or create source files")
    store.selectAllAssets()
    store.saveSessionNow()
    let normalBytes = defaults.data(forKey: ViewerSessionPersistence.sessionKey)?.count ?? 0
    store.viewSelectedFiles(together: true)
    store.saveSessionNow()
    let scopedBytes = defaults.data(forKey: ViewerSessionPersistence.sessionKey)?.count ?? 0
    #expect(scopedBytes <= normalBytes + 10_000,
      "An all-selected scope must not serialize its member IDs more than once")
    store.returnToOverview()
    try await Task.sleep(for: .seconds(1))
    let idleStart = OverviewWarmCPUCost.processCPUSeconds() ?? 0
    try await Task.sleep(for: .seconds(2))
    let idleCPU = (OverviewWarmCPUCost.processCPUSeconds() ?? idleStart) - idleStart
    let report: [String: Any] = ["fileCount": sourceCount, "selectedCount": chosen.count, "cycles": 30,
      "entryMilliseconds": entry, "returnMilliseconds": back, "processCPUSeconds": cpu,
      "footprintBefore": before, "footprintAfter": after, "sharedOverviewBuffer": sharedBuffers,
      "normalSessionBytesAllSelected": normalBytes, "scopedSessionBytesAllSelected": scopedBytes,
      "idleProcessCPUSecondsOver2Seconds": idleCPU,
      "measurement": "warm synchronous scope commits; includes process background work, excludes native rendering"]
    try reportResult(report, name: "large-collection-resources")
  }

  func footprint() -> UInt64 {
    var usage = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &usage) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return status == 0 ? usage.ri_phys_footprint : 0
  }
  func reportResult(_ result: [String: Any], name: String) throws {
    let output = try #require(ProcessInfo.processInfo.environment["IMAGEVIEWER_SELECTION_RESOURCE_OUTPUT"])
    let directory = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
      .write(to: directory.appendingPathComponent(name + ".json"))
    print("SELECTION_RESOURCE_REPORT \(name)")
  }
}
