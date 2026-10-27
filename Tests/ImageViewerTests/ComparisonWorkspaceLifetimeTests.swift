import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

@Suite("비교 진입 시 이전 작업 공간의 작업 수명")
@MainActor
struct ComparisonWorkspaceLifetimeTests {
  @Test("몽땅보기와 7장 보기의 대기 검색은 비교에서 멈추고 돌아온 뒤 선택을 이어서 적용한다")
  func pendingQueryWaitsForTheOriginalWorkspace() async throws {
    for mode in [PresentationMode.overview, .viewer] {
      let fixture = try Fixture()
      let store = fixture.makeStore()
      defer { fixture.cleanup(store) }
      try await open(store, fixture: fixture)
      store.setImagesPerPage(7)
      store.presentationMode = mode
      store.select(index: 1)
      let selected = try #require(store.currentAsset)
      let originalAssets = store.assets
      let revision = store.libraryRevision

      // Enter before the query's debounce expires, so cancellation is independent
      // of filesystem speed and the size of the synthetic photo files.
      store.libraryQuery.searchText = "bravo"
      #expect(store.isFiltering)
      store.presentationMode = .folderComparison

      #expect(!store.isFiltering && !store.isIndexingLocations)
      try await Task.sleep(for: .milliseconds(160))
      #expect(store.assets == originalAssets && store.libraryRevision == revision)
      #expect(store.currentAsset == selected && store.currentIndex == 1)
      #expect(store.selectedURLs == [selected.url])

      store.presentationMode = mode
      #expect(store.isFiltering)
      #expect(store.assets == originalAssets && store.currentIndex == 1)
      #expect(store.currentAsset == selected && store.selectedURLs == [selected.url])
      try await wait { !store.isFiltering }
      #expect(store.assets.map(\.filename) == ["02-bravo.jpg"])
      #expect(store.currentAsset?.id == selected.id && store.currentIndex == 0)
      #expect(store.selectedURLs == [selected.url] && store.imagesPerPage == 7)
    }
  }

  @Test("비교 중 분류 변경과 검색·영상 설정은 이전 목록을 갱신하지 않고 복귀 시 최신 조건을 쓴다")
  func deferredChangesIncludeMarksAndLatestQueryPreferences() async throws {
    let fixture = try Fixture(includesVideo: true)
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await open(store, fixture: fixture)
    let bravo = try #require(store.assets.first { $0.filename == "02-bravo.jpg" })
    let charlie = try #require(store.assets.first { $0.filename == "03-charlie.jpg" })
    let video = try #require(store.assets.first { $0.isVideo })
    store.photoMarks.set(.one, enabled: true, for: [bravo, video])
    store.photoMarkFilter = PhotoMarkFilter(slots: [.one])
    try await wait { !store.isFiltering }
    store.select(asset: bravo)
    let beforeMarks = store.assets
    let markRevision = store.libraryRevision
    store.presentationMode = .folderComparison

    // No explicit query edit accompanies these revisions. The mark subscriber
    // must also defer the hidden workspace rather than starting its own query.
    store.photoMarks.set(.one, enabled: true, for: [charlie])
    store.photoMarks.set(.one, enabled: false, for: [bravo])
    await Task.yield()
    try await Task.sleep(for: .milliseconds(160))
    #expect(!store.isFiltering && store.assets == beforeMarks)
    #expect(store.libraryRevision == markRevision && store.currentAsset?.id == bravo.id)

    store.presentationMode = .overview
    try await wait { !store.isFiltering }
    #expect(store.assets.map(\.filename) == ["03-charlie.jpg", "09-video.mov"])
    store.select(asset: charlie)
    let beforePreferences = store.assets
    let preferenceRevision = store.libraryRevision
    store.presentationMode = .folderComparison

    store.libraryQuery.searchText = "alpha"
    store.libraryQuery.searchText = ""
    store.libraryQuery.sort = .nameDescending
    store.showsVideos = false
    #expect(!store.isFiltering)
    try await Task.sleep(for: .milliseconds(160))
    #expect(store.assets == beforePreferences && store.libraryRevision == preferenceRevision)
    #expect(store.currentAsset?.id == charlie.id && store.selectedURLs == [charlie.url])

    store.presentationMode = .viewer
    #expect(store.isFiltering && store.assets == beforePreferences)
    try await wait { !store.isFiltering }
    #expect(store.assets.map(\.filename) == ["03-charlie.jpg"])
    #expect(store.currentAsset?.id == charlie.id && store.selectedURLs == [charlie.url])
    #expect(store.libraryQuery.searchText.isEmpty && store.libraryQuery.sort == .nameDescending)
    #expect(!store.showsVideos && store.allAssets.contains(where: \.isVideo))
  }

  @Test("진행 중인 지도 GPS 색인은 비교 진입 시 대기를 취소하고 지도 복귀 시 이어서 표시한다")
  func activeMapIndexingStopsUntilMapReturns() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await open(store, fixture: fixture)
    store.select(index: 1)
    let selected = try #require(store.currentAsset)
    let originalAssets = store.assets
    let revision = store.libraryRevision
    let viewport = store.photoMapViewport
    let governor = store.loadingGovernor
    // One occupied shared slot leaves the actual GPS header read queued. This
    // observes an active scan without relying on a large folder or slow disk.
    await governor.update(ImageResourceSnapshot(
      physicalMemory: 16 * 1_024 * 1_024 * 1_024,
      activeProcessorCount: 8, appleSilicon: true, isAppActive: true,
      memoryPressure: .warning, cpuBusyFraction: 0.1))
    let gate = ComparisonWorkspaceGate()
    let block = Task {
      try await governor.value(for: ImageResourceWorkKey(namespace: UUID(), key: 0),
        url: selected.url, priority: .interactivePreview, workload: .metadataHeader) { _ in
        await gate.wait()
        return true
      }
    }
    defer { block.cancel(); Task { await gate.release() } }
    try await wait { await gate.isWaiting }
    store.presentationMode = .map
    try await wait {
      let state = await governor.stateSnapshot()
      return store.isIndexingLocations && state.queuedCount > 0
    }

    store.presentationMode = .folderComparison
    #expect(!store.isFiltering && !store.isIndexingLocations)
    try await wait { (await governor.stateSnapshot()).queuedCount == 0 }
    await gate.release()
    _ = try await block.value
    try await Task.sleep(for: .milliseconds(160))
    #expect(store.assets == originalAssets && store.libraryRevision == revision)
    #expect(store.allAssets.allSatisfy { !$0.hasReadLocation })
    #expect(store.currentAsset == selected && store.selectedURLs == [selected.url])
    #expect(store.photoMapViewport === viewport)

    store.presentationMode = .map
    #expect(store.isFiltering)
    try await wait { !store.isFiltering && !store.isIndexingLocations }
    #expect(store.allAssets.allSatisfy { $0.hasReadLocation })
    #expect(store.mapAssets.compactMap(\.location).count == 2)
    #expect(store.currentAsset?.id == selected.id && store.selectedURLs == [selected.url])
    #expect(store.photoMapViewport === viewport)
  }

  private func open(_ store: AppStore, fixture: Fixture) async throws {
    await store.photoMarks.waitUntilReady()
    store.open(urls: [fixture.folder])
    try await wait { !store.isLoading && !store.isFiltering }
    try #require(store.alert == nil && store.assets.count == (fixture.includesVideo ? 9 : 8))
    store.presentationMode = .overview
  }

  private func wait(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private struct Fixture {
    let folder: URL
    let includesVideo: Bool
    let suite: String
    let defaults: UserDefaults

    init(includesVideo: Bool = false) throws {
      folder = FileManager.default.temporaryDirectory.appendingPathComponent("ComparisonWorkspace-\(UUID())")
      self.includesVideo = includesVideo
      suite = "ComparisonWorkspace.\(UUID())"
      defaults = try #require(UserDefaults(suiteName: suite))
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
        bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
      let image = try #require(context.makeImage())
      for (index, name) in ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"].enumerated() {
        let url = folder.appendingPathComponent(String(format: "%02d-%@.jpg", index + 1, name))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
          UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = index < 2 ? [kCGImagePropertyGPSDictionary: [
          kCGImagePropertyGPSLatitude: 48.8584, kCGImagePropertyGPSLatitudeRef: "N",
          kCGImagePropertyGPSLongitude: 2.2945, kCGImagePropertyGPSLongitudeRef: "E",
        ]] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
      }
      if includesVideo {
        // Enumeration and visibility filtering need only a recognized file;
        // this test never asks AVFoundation to render or inspect this fixture.
        try Data([0]).write(to: folder.appendingPathComponent("09-video.mov"))
      }
    }

    @MainActor func makeStore() -> AppStore {
      AppStore(defaults: defaults, monitorsSystemResources: false, thumbnailDiskCache: nil)
    }

    @MainActor func cleanup(_ store: AppStore) {
      store.presentationMode = .folderComparison
      store.folderComparison.cancelLoads()
      store.photoMarks.flush()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }
  }
}

private actor ComparisonWorkspaceGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false
  var isWaiting: Bool { continuation != nil }

  func wait() async {
    if !released { await withCheckedContinuation { continuation = $0 } }
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
