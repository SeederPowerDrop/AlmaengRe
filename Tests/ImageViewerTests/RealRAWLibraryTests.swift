import Foundation
import Testing

@testable import ImageViewer

/// Opt-in, read-only source coverage:
/// IMAGEVIEWER_RAW_DIRECTORY=/path/to/photos swift test --filter RealRAWLibraryTests
/// This measures library state changes, not native view rendering or UI frame rate.
/// Source names, paths and metadata are never included in diagnostic output.
@Suite("실제 RAW 폴더의 목록·검색·페이지 이동", .serialized)
@MainActor
struct RealRAWLibraryTests {
  private enum FixtureError: Error {
    case missingDirectory, inventoryFailed, scanFailed, operationTimedOut
  }

  private struct Inventory: Sendable {
    let supportedURLs: Set<URL>
    let rawURLs: Set<URL>
    let dngCount: Int
    let emptyDNGCount: Int
    let heicCount: Int
  }

  @Test(
    "실제 폴더를 격리된 설정으로 열고 필터·선택·빠른 페이지 이동을 검증한다",
    .enabled(if: !(ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_DIRECTORY"] ?? "").isEmpty),
    .timeLimit(.minutes(2)))
  func realFolderLibraryOperations() async throws {
    guard let path = ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_DIRECTORY"],
      !path.isEmpty else { throw FixtureError.missingDirectory }
    let folder = URL(fileURLWithPath: path, isDirectory: true)
    // Include the full RAW filter family, beyond the shorter default-app association menu.
    let rawExtensions: Set<String> = [
      "raw", "dng", "cr2", "cr3", "crw", "nef", "nefx", "nrw", "arw", "sr2", "srf",
      "orf", "rw2", "raf", "pef", "iiq", "3fr", "fff", "rwl", "x3f", "erf", "mrw",
      "mos", "kdc", "dcr", "mef", "bay", "cap",
    ]
    let inventory = try await Task.detached {
      try Self.inventory(folder: folder, rawExtensions: rawExtensions)
    }.value
    try #require(!inventory.rawURLs.isEmpty, "The selected fixture must contain RAW images")

    let scanStarted = ProcessInfo.processInfo.systemUptime
    let scanned: [ImageAsset]
    do { scanned = try await ImageLibrary().scan(folder: folder) }
    catch { throw FixtureError.scanFailed }
    let scanSeconds = ProcessInfo.processInfo.systemUptime - scanStarted
    let scanMatchesInventory = Set(scanned.map { $0.url.standardizedFileURL }) == inventory.supportedURLs
    #expect(scanMatchesInventory)
    // Empty DNGs remain list entries; decoding failures belong to the pipeline suite.
    #expect(scanned.filter { $0.fileExtension == "dng" && $0.byteCount == 0 }.count
      == inventory.emptyDNGCount)

    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("RealRAWLibrary-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let suite = "RealRAWLibraryTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: temporary.appendingPathComponent("marks.sqlite"))
    defer {
      store.presentationMode = .overview
      store.folderComparison.cancelLoads()
      store.saveSessionNow()
      defaults.removePersistentDomain(forName: suite)
    }
    await store.photoMarks.waitUntilReady()
    try #require(store.photoMarks.isReady)

    let openStarted = ProcessInfo.processInfo.systemUptime
    store.open(urls: [folder])
    try await waitUntil { !store.isLoading && !store.isFiltering }
    let openSeconds = ProcessInfo.processInfo.systemUptime - openStarted
    #expect(store.alert == nil)
    #expect(store.assets.count == scanned.count)
    let openedMatchesScan = Set(store.assets.map { $0.url.standardizedFileURL })
      == Set(scanned.map { $0.url.standardizedFileURL })
    #expect(openedMatchesScan)
    try #require(!store.assets.isEmpty)
    store.presentationMode = .overview

    store.libraryQuery.formats = [.raw]
    try await waitUntil { !store.isFiltering }
    #expect(store.assets.count == inventory.rawURLs.count)
    let rawMatchesInventory = Set(store.assets.map { $0.url.standardizedFileURL }) == inventory.rawURLs
    #expect(rawMatchesInventory)
    #expect(store.allAssets.count == scanned.count)
    try #require(!store.assets.isEmpty)
    let rawCount = store.assets.count

    store.libraryQuery.sort = .sizeLargest
    try await waitUntil { !store.isFiltering }
    let descendingSizes = store.assets.compactMap(\.byteCount)
    #expect(zip(descendingSizes, descendingSizes.dropFirst()).allSatisfy { $0 >= $1 })
    store.libraryQuery.sort = .sizeSmallest
    try await waitUntil { !store.isFiltering }
    let ascendingSizes = store.assets.compactMap(\.byteCount)
    #expect(zip(ascendingSizes, ascendingSizes.dropFirst()).allSatisfy { $0 <= $1 })

    store.libraryQuery.sort = .nameAscending
    try await waitUntil { !store.isFiltering }
    let ascendingIDs = store.assets.map(\.sessionID)
    let selectedIndex = min(store.assets.count - 1, store.assets.count / 2)
    store.select(index: selectedIndex)
    let selectedID = store.currentAsset?.sessionID
    store.libraryQuery.sort = .nameDescending
    try await waitUntil { !store.isFiltering }
    let reversedOrderIsCorrect = store.assets.map(\.sessionID) == Array(ascendingIDs.reversed())
    #expect(reversedOrderIsCorrect)
    let selectionSurvivedSort = store.currentAsset?.sessionID == selectedID
    #expect(selectionSurvivedSort)

    // A full existing filename avoids assumptions about the user's naming scheme.
    let searchName = try #require(store.currentAsset).filename
    store.libraryQuery.searchText = searchName
    try await waitUntil { !store.isFiltering }
    #expect(!store.assets.isEmpty)
    let searchRetainsSelected = store.assets.contains { $0.sessionID == selectedID }
    #expect(searchRetainsSelected)
    let namesMatchSearch = store.assets.allSatisfy { $0.filename.localizedCaseInsensitiveContains(searchName) }
    #expect(namesMatchSearch)

    store.libraryQuery.searchText = ""
    try await waitUntil { !store.isFiltering }
    #expect(store.assets.count == rawCount)
    store.selectAllAssets()
    #expect(store.selectedURLs.count == rawCount)
    store.clearSelection()
    #expect(store.selectedURLs.isEmpty)

    var navigationCount = 0
    store.presentationMode = .viewer
    for pageSize in [1, 4, 5, 10] {
      store.setImagesPerPage(pageSize)
      store.wrapsNavigation = false
      store.select(index: 0)
      for direction in [1, -1] {
        // Traverse every page and push beyond the boundary to exercise clamping.
        for step in 0..<(rawCount / pageSize + 3) {
          store.navigatePage(direction)
          navigationCount += 1
          #expect(store.assets.indices.contains(store.currentIndex))
          #expect(store.assets.indices.contains(store.pageStartIndex))
          #expect(store.currentIndex == store.pageStartIndex)
          if step.isMultiple(of: 32) { await Task.yield() }
        }
        #expect(store.pageStartIndex == (direction > 0 ? max(0, rawCount - pageSize) : 0))
      }
      store.wrapsNavigation = true
      store.navigatePage(-1)
      #expect(store.pageStartIndex == max(0, rawCount - pageSize))
      store.navigatePage(1)
      #expect(store.pageStartIndex == 0)
      navigationCount += 2
    }
    #expect(store.alert == nil)
    store.presentationMode = .overview

    store.resetLibraryQuery()
    try await waitUntil { !store.isFiltering }
    #expect(store.assets.count == scanned.count)
    #expect(store.allAssets.count == scanned.count)

    try printDiagnostic([
      "scenario": "real_raw_library",
      "scan_seconds": scanSeconds,
      "open_seconds": openSeconds,
      "supported_count": scanned.count,
      "raw_count": rawCount,
      "dng_count": inventory.dngCount,
      "empty_dng_count": inventory.emptyDNGCount,
      "heic_count": inventory.heicCount,
      "page_navigation_operations": navigationCount,
      "isolated_preferences": true,
      "isolated_photo_marks": true,
      "system_resource_monitor": false,
    ])

    // End on an empty query so metadata and prefetch tasks release source references.
    store.libraryQuery.searchText = "real-raw-test-no-match-\(UUID())"
    try await waitUntil { !store.isFiltering }
    #expect(store.assets.isEmpty)
    await store.pipeline.purgeCaches()
    await store.thumbnailPipeline.purgeCache()
    try await waitForDrain(store.loadingGovernor)
  }

  nonisolated private static func inventory(folder: URL, rawExtensions: Set<String>) throws -> Inventory {
    do {
      let urls = try FileManager.default.contentsOfDirectory(at: folder,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
        options: [.skipsHiddenFiles])
      var supported: Set<URL> = [], raw: Set<URL> = []
      var dngCount = 0, emptyDNGCount = 0, heicCount = 0
      for url in urls {
        // Match the scanner's handling of file symlinks while retaining the listed URL.
        let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
          ImageFormatRegistry.canAttemptToDecode(url) else { continue }
        let canonical = url.standardizedFileURL
        supported.insert(canonical)
        let suffix = url.pathExtension.lowercased()
        if rawExtensions.contains(suffix) { raw.insert(canonical) }
        if suffix == "dng" {
          dngCount += 1
          if values.fileSize == 0 { emptyDNGCount += 1 }
        }
        if ["heic", "heif", "heics", "hif"].contains(suffix) { heicCount += 1 }
      }
      return Inventory(supportedURLs: supported, rawURLs: raw, dngCount: dngCount,
        emptyDNGCount: emptyDNGCount, heicCount: heicCount)
    } catch { throw FixtureError.inventoryFailed }
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while !condition() {
      guard ContinuousClock.now < deadline else { throw FixtureError.operationTimedOut }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func waitForDrain(_ governor: ImageResourceGovernor) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while true {
      let state = await governor.stateSnapshot()
      if state.runningCount == 0 && state.queuedCount == 0 && state.waiterCount == 0 { return }
      guard ContinuousClock.now < deadline else { throw FixtureError.operationTimedOut }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func printDiagnostic(_ values: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    print("RAW_LIBRARY \(String(decoding: data, as: UTF8.self))")
  }
}
