import Combine
import Foundation
import MapKit
import Testing

@testable import ImageViewer

/// Explicitly enabled model-level QA against the original full folder. The
/// source is only read; private defaults and an in-memory marks database isolate
/// workspace state. The report contains aggregate counts, booleans and observed
/// wall times, never source paths, filenames, image data or GPS coordinates.
@Suite("실제 RAW 폴더의 비교 화면 전환", .serialized)
@MainActor
struct RealRAWComparisonWorkspaceTests {
  @Test("지도 헤더 읽기 중 빈 비교로 전환하고 원래 작업을 복원한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_COMPARISON_WORKSPACE_QA"] == "1"),
    .timeLimit(.minutes(5)))
  func originalFolderWorkspaceTransitions() async throws {
    let environment = ProcessInfo.processInfo.environment
    let sourcePath = try #require(environment["IMAGEVIEWER_RAW_DIRECTORY"])
    let outputPath = try #require(environment["IMAGEVIEWER_COMPARISON_WORKSPACE_OUTPUT"])
    let directory = URL(fileURLWithPath: sourcePath).standardizedFileURL.resolvingSymlinksInPath()
    let output = URL(fileURLWithPath: outputPath).standardizedFileURL.resolvingSymlinksInPath()
    let outputIsOutsideSource = output != directory && !output.path.hasPrefix(directory.path + "/")
    try #require(outputIsOutsideSource)
    let started = ProcessInfo.processInfo.systemUptime
    let before = try inventory(directory)
    try #require(before.imageCount >= 7)
    let suite = "RealRAWComparisonWorkspace.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let store = AppStore(defaults: defaults, monitorsSystemResources: false, thumbnailDiskCache: nil)
    defer {
      store.folderComparison.cancelLoads()
      store.saveSessionNow()
      defaults.removePersistentDomain(forName: suite)
    }
    await store.photoMarks.waitUntilReady()
    store.libraryQuery.sort = .nameDescending
    let openingStarted = ProcessInfo.processInfo.systemUptime
    store.open(urls: [directory])
    try await wait(seconds: 90) { !store.isLoading && !store.isFiltering }
    let openingSeconds = ProcessInfo.processInfo.systemUptime - openingStarted
    let initialOpenSucceeded = store.alert == nil && !store.assets.isEmpty
    try #require(initialOpenSucceeded)
    let loadedMediaURLs = Set(store.allAssets.map { absoluteSourceURL($0.id) })
    let missingLoadedMediaCount = before.mediaURLs.subtracting(loadedMediaURLs).count
    let unexpectedLoadedMediaCount = loadedMediaURLs.subtracting(before.mediaURLs).count
    let loadedEntireFolder = store.allAssets.count == before.mediaURLs.count
      && missingLoadedMediaCount == 0 && unexpectedLoadedMediaCount == 0
    #expect(loadedEntireFolder)

    store.presentationMode = .overview
    let photoIndices = store.assets.indices.filter { !store.assets[$0].isPlaybackMedia }
    try #require(photoIndices.count >= 7)
    let selectedIndex = photoIndices[min(17, photoIndices.count - 1)]
    store.select(index: selectedIndex)
    store.setImagesPerPage(7)
    store.presentationMode = .viewer
    #expect(store.imagesPerPage == 7 && store.isMultiImageViewer)
    let sourceIDs = store.allAssets.map(\.id)
    let visibleIDs = store.assets.map(\.id)
    let mapIDs = store.mapAssets.map(\.id)
    let selectedID = store.currentAsset?.id
    let selectedURLs = store.selectedURLs
    let query = store.libraryQuery
    let mapCollectionID = store.mapCollectionID
    let viewport = store.photoMapViewport
    // Synthetic camera state verifies restoration without recording a location.
    let camera = MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: 0, longitude: 0),
      fromDistance: 100_000, pitch: 20, heading: 35)
    viewport.camera = camera
    let callbacks = CallbackProbe()
    let observers = [
      store.$allAssets.dropFirst().sink { _ in callbacks.collections += 1 },
      store.$assets.dropFirst().sink { _ in callbacks.collections += 1 },
      store.$mapAssets.dropFirst().sink { _ in callbacks.collections += 1 },
      store.$locationScanCount.dropFirst().sink { _ in callbacks.progress += 1 },
      store.$isIndexingLocations.dropFirst().sink { _ in callbacks.indexing += 1 },
      store.$isFiltering.dropFirst().sink { _ in callbacks.filtering += 1 },
    ]
    defer { observers.forEach { $0.cancel() } }
    let initialMapStarted = ProcessInfo.processInfo.systemUptime
    store.presentationMode = .map
    try await wait(seconds: 20) {
      store.isIndexingLocations && store.isFiltering
        && store.locationScanCount > 0 && store.locationScanCount < store.allAssets.count
    }
    let mapStartObservedSeconds = ProcessInfo.processInfo.systemUptime - initialMapStarted
    let activeScanBeforeCancellation = store.isIndexingLocations && store.isFiltering
      && store.locationScanCount < store.allAssets.count
    try #require(activeScanBeforeCancellation)
    let governorAtCancellation = await store.loadingGovernor.stateSnapshot()
    // Recheck after the actor hop: the transition must interrupt an active scan.
    let stillActiveBeforeTransition = store.isIndexingLocations && store.isFiltering
      && store.locationScanCount > 0 && store.locationScanCount < store.allAssets.count
    try #require(stillActiveBeforeTransition)
    let progressAtCancellation = store.locationScanCount
    let callbacksBeforeCancellation = callbacks.snapshot
    let comparisonStarted = ProcessInfo.processInfo.systemUptime
    store.presentationMode = .folderComparison
    let comparisonSetterObservedSeconds = ProcessInfo.processInfo.systemUptime - comparisonStarted
    let stoppedImmediately = !store.isFiltering && !store.isIndexingLocations && !store.isLoading
    #expect(stoppedImmediately)
    let emptyComparison = store.folderComparison.first.assets.isEmpty
      && store.folderComparison.second.assets.isEmpty && !store.folderComparison.isMatching
    #expect(emptyComparison)
    let drainStarted = ProcessInfo.processInfo.systemUptime
    let drained = try await drain(store.loadingGovernor, seconds: 30)
    let drainObservedSeconds = ProcessInfo.processInfo.systemUptime - drainStarted
    let callbacksAtDrain = callbacks.snapshot
    let observationStarted = ProcessInfo.processInfo.systemUptime
    try await Task.sleep(for: .milliseconds(350))
    let hiddenObservationSeconds = ProcessInfo.processInfo.systemUptime - observationStarted
    let hiddenCallbacks = callbacks.snapshot.subtracting(callbacksAtDrain)
    #expect(hiddenCallbacks.total == 0)
    let hiddenProgressUnchanged = store.locationScanCount == progressAtCancellation
    let hiddenCollectionsPreserved = store.allAssets.map(\.id) == sourceIDs
      && store.assets.map(\.id) == visibleIDs && store.mapAssets.map(\.id) == mapIDs
    let hiddenSelectionPreserved = store.currentAsset?.id == selectedID
      && store.selectedURLs == selectedURLs && store.libraryQuery == query
    let hiddenCameraPreserved = store.photoMapViewport === viewport
      && store.photoMapViewport.camera === camera && store.mapCollectionID == mapCollectionID
    #expect(hiddenProgressUnchanged && hiddenCollectionsPreserved)
    #expect(hiddenSelectionPreserved && hiddenCameraPreserved)

    let returnStarted = ProcessInfo.processInfo.systemUptime
    store.presentationMode = .map
    try await wait(seconds: 150) { !store.isLoading && !store.isFiltering && !store.isIndexingLocations }
    let returnMapObservedSeconds = ProcessInfo.processInfo.systemUptime - returnStarted
    let completedHeaders = store.allAssets.allSatisfy(\.hasReadLocation)
    let returnCollectionsPreserved = store.allAssets.map(\.id) == sourceIDs
      && store.assets.map(\.id) == visibleIDs && store.mapAssets.map(\.id) == mapIDs
    let returnSelectionPreserved = store.currentAsset?.id == selectedID
      && store.selectedURLs == selectedURLs && store.libraryQuery == query
    let returnCameraPreserved = store.photoMapViewport === viewport
      && store.photoMapViewport.camera === camera && store.mapCollectionID == mapCollectionID
    let noFinalAlert = store.alert == nil
    #expect(completedHeaders && returnCollectionsPreserved && returnSelectionPreserved)
    #expect(returnCameraPreserved && noFinalAlert)
    let after = try inventory(directory)
    let sourceInventoryUnchanged = Set(before.versions.keys) == Set(after.versions.keys)
    let sourceStatUnchanged = before.versions == after.versions
    #expect(sourceInventoryUnchanged && sourceStatUnchanged)

    let report = Report(sourceRegularFiles: before.versions.count, sourceImages: before.imageCount,
      sourceRAWImages: before.rawCount, sourcePlaybackFiles: before.playbackCount,
      sourceBytes: before.bytes, loadedSourceCount: sourceIDs.count, visibleCount: visibleIDs.count, mapCount: mapIDs.count,
      loadedSourceInventoryMatched: loadedEntireFolder, missingLoadedMediaCount: missingLoadedMediaCount,
      unexpectedLoadedMediaCount: unexpectedLoadedMediaCount,
      sourceInventoryUnchanged: sourceInventoryUnchanged,
      sourceStatUnchanged: sourceStatUnchanged, activeScanBeforeCancellation: activeScanBeforeCancellation,
      scanProgressAtCancellation: progressAtCancellation, stoppedImmediately: stoppedImmediately,
      emptyComparison: emptyComparison, governorAtCancellation: WorkState(governorAtCancellation),
      governorAfterDrain: WorkState(drained),
      callbacksDuringCancellationAndDrain: callbacksAtDrain.subtracting(callbacksBeforeCancellation),
      callbacksWhileHiddenAfterDrain: hiddenCallbacks, hiddenProgressUnchanged: hiddenProgressUnchanged,
      hiddenCollectionsPreserved: hiddenCollectionsPreserved, hiddenSelectionPreserved: hiddenSelectionPreserved,
      hiddenCameraPreserved: hiddenCameraPreserved, completedHeadersOnReturn: completedHeaders,
      returnCollectionsPreserved: returnCollectionsPreserved, returnSelectionPreserved: returnSelectionPreserved,
      returnCameraPreserved: returnCameraPreserved, openingObservedSeconds: openingSeconds,
      mapStartObservedSeconds: mapStartObservedSeconds, comparisonSetterObservedSeconds: comparisonSetterObservedSeconds,
      drainObservedSeconds: drainObservedSeconds, hiddenObservationSeconds: hiddenObservationSeconds,
      returnMapObservedSeconds: returnMapObservedSeconds,
      totalObservedSeconds: ProcessInfo.processInfo.systemUptime - started)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: output, options: .atomic)
    print("REAL_RAW_COMPARISON_WORKSPACE images=\(before.imageCount) playback=\(before.playbackCount) "
      + "missing=\(missingLoadedMediaCount) unexpected=\(unexpectedLoadedMediaCount) "
      + "hiddenCallbacks=\(hiddenCallbacks.total) sourceStatUnchanged=\(sourceStatUnchanged)")
  }

  private func wait(seconds: Double, until condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !condition() {
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw QAError.timeout }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  private func drain(_ governor: ImageResourceGovernor, seconds: Double) async throws -> ImageWorkSchedulerState {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while true {
      let state = await governor.stateSnapshot()
      if state.runningCount == 0 && state.queuedCount == 0 && state.waiterCount == 0 { return state }
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw QAError.timeout }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func inventory(_ directory: URL) throws -> Inventory {
    do {
      let urls = try FileManager.default.contentsOfDirectory(at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])
      var result = Inventory()
      for enumeratedURL in urls {
        // FileManager may return URLs relative to its directory base, whereas
        // Rust creates absolute file URLs. Compare the same complete identity.
        let url = absoluteSourceURL(enumeratedURL)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { continue }
        result.versions[url] = LibrarySortFileVersion(url: url)
        result.bytes += Int64(values.fileSize ?? 0)
        if MediaFormatRegistry.isPlaybackMedia(url) {
          result.playbackCount += 1
          result.mediaURLs.insert(url)
        } else if ImageFormatRegistry.canAttemptToDecode(url) {
          result.imageCount += 1
          result.mediaURLs.insert(url)
          if ImageFormatRegistry.cameraRAWExtensions.contains(url.pathExtension.lowercased()) { result.rawCount += 1 }
        }
      }
      return result
    } catch { throw QAError.inventoryReadFailed }
  }

  private func absoluteSourceURL(_ url: URL) -> URL {
    URL(fileURLWithPath: url.path).standardizedFileURL
  }

  private enum QAError: Error { case timeout, inventoryReadFailed }
  private struct Inventory {
    var versions: [URL: LibrarySortFileVersion] = [:]
    var mediaURLs = Set<URL>()
    var bytes: Int64 = 0
    var imageCount = 0
    var rawCount = 0
    var playbackCount = 0
  }
  private final class CallbackProbe {
    var collections = 0, progress = 0, indexing = 0, filtering = 0
    var snapshot: Callbacks { Callbacks(collections: collections, progress: progress, indexing: indexing, filtering: filtering) }
  }
  private struct Callbacks: Encodable {
    let collections: Int, progress: Int, indexing: Int, filtering: Int
    var total: Int { collections + progress + indexing + filtering }
    func subtracting(_ previous: Self) -> Self {
      Self(collections: collections - previous.collections, progress: progress - previous.progress,
        indexing: indexing - previous.indexing, filtering: filtering - previous.filtering)
    }
  }
  private struct WorkState: Encodable {
    let running: Int, queued: Int, waiters: Int
    init(_ state: ImageWorkSchedulerState) {
      running = state.runningCount; queued = state.queuedCount; waiters = state.waiterCount
    }
  }
  private struct Report: Encodable {
    let scope = "read_only_original_folder_model_lifecycle_no_UI_observed_times_only"
    let coldStorageClaim = false
    let libraryQueryCancellationTransitions = 1
    let sourceRegularFiles: Int, sourceImages: Int, sourceRAWImages: Int, sourcePlaybackFiles: Int
    let sourceBytes: Int64
    let loadedSourceCount: Int, visibleCount: Int, mapCount: Int
    let loadedSourceInventoryMatched: Bool
    let missingLoadedMediaCount: Int, unexpectedLoadedMediaCount: Int
    let sourceInventoryUnchanged: Bool, sourceStatUnchanged: Bool, activeScanBeforeCancellation: Bool
    let scanProgressAtCancellation: Int
    let stoppedImmediately: Bool, emptyComparison: Bool
    let governorAtCancellation: WorkState, governorAfterDrain: WorkState
    let callbacksDuringCancellationAndDrain: Callbacks, callbacksWhileHiddenAfterDrain: Callbacks
    let hiddenProgressUnchanged: Bool, hiddenCollectionsPreserved: Bool, hiddenSelectionPreserved: Bool
    let hiddenCameraPreserved: Bool, completedHeadersOnReturn: Bool, returnCollectionsPreserved: Bool
    let returnSelectionPreserved: Bool, returnCameraPreserved: Bool
    let openingObservedSeconds: Double, mapStartObservedSeconds: Double, comparisonSetterObservedSeconds: Double
    let drainObservedSeconds: Double, hiddenObservationSeconds: Double, returnMapObservedSeconds: Double
    let totalObservedSeconds: Double
  }
}
