import Foundation
import Testing

@testable import ImageViewer

@Suite("혼합 폴더의 다중보기 페이지 재생 통합", .serialized)
@MainActor
struct VideoGridPageAutoplayIntegrationTests {
  @Test("수동 페이지 이동은 사진 순서를 보존하며 화면의 영상·음성만 재생한다")
  func manualNavigationThroughMixedAndImageOnlyPages() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.store
    try await fixture.open()
    let orderedIDs = store.assets.map(\.id)
    let first = store.visibleAssets
    try #require(first.count == 3 && !first[0].isPlaybackMedia && first[1].isVideo && first[2].isAudio)
    let grid = store.videoGridPlayback
    grid.updateVisibleAssets(first)
    grid.playAll()
    grid.playAll()
    #expect(store.currentIndex == 0 && store.pageStartIndex == 0 && !store.isSlideshowPlaying)

    store.navigatePage(1)
    grid.updateVisibleAssets(store.visibleAssets) // ViewerCanvas' actual observer boundary.
    #expect(store.pageStartIndex == 3 && store.visibleAssets.allSatisfy { !$0.isPlaybackMedia })
    #expect(grid.playingIDs.isEmpty && grid.audioID == nil && grid.followsPages)
    store.navigatePage(1)
    grid.updateVisibleAssets(store.visibleAssets)
    #expect(store.pageStartIndex == 6)
    #expect(grid.playingIDs == Set(store.visibleAssets.map(\.id)))
    #expect(grid.audioID == store.visibleAssets.first?.id)
    #expect(first.filter(\.isPlaybackMedia).allSatisfy { grid.command(for: $0.id).mode == .paused })
    store.navigatePage(-1)
    grid.updateVisibleAssets(store.visibleAssets)
    #expect(grid.playingIDs.isEmpty && grid.followsPages)
    store.navigatePage(-1)
    grid.updateVisibleAssets(store.visibleAssets)
    #expect(grid.playingIDs == Set(first.filter(\.isPlaybackMedia).map(\.id)))
    #expect(store.assets.map(\.id) == orderedIDs && store.photoMarks.marksByAssetID.isEmpty)
    #expect(!store.isSlideshowPlaying && store.imagesPerPage == 3)
  }

  @Test("폴더·모드·표시 전환은 이전 페이지의 자동 재생 설정을 끈다", arguments: Boundary.allCases)
  func leavingMultiviewCancelsPageFollow(_ boundary: Boundary) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.store
    try await fixture.open()
    let grid = store.videoGridPlayback
    grid.updateVisibleAssets(store.visibleAssets)
    grid.playAll()
    grid.playAll()
    try #require(grid.followsPages && !grid.playingIDs.isEmpty)
    switch boundary {
    case .folder: store.open(urls: [fixture.folder])
    case .externalFile:
      #expect(store.openExternally(urls: [fixture.folder.appendingPathComponent("00-photo.qoi")]))
    case .overview: store.presentationMode = .overview
    case .map: store.presentationMode = .map
    case .comparison: store.presentationMode = .folderComparison
    case .slideshow:
      store.toggleSlideshow()
      #expect(store.isSlideshowPlaying)
    case .singleView: store.setImagesPerPage(1)
    case .hideMedia: store.showsVideos = false
    }
    #expect(!grid.followsPages && !grid.canEnablePageAutoplay)
    #expect(grid.playingIDs.isEmpty && grid.audioID == nil)
    try await fixture.ready()
    // A late Canvas update must not re-enable follow after the mode boundary.
    grid.updateVisibleAssets(store.visibleAssets)
    #expect(!grid.followsPages && grid.playingIDs.isEmpty)
  }

  enum Boundary: String, CaseIterable, Sendable {
    case folder, externalFile, overview, map, comparison, slideshow, singleView, hideMedia
  }

  @MainActor private struct Fixture {
    let root: URL
    let folder: URL
    let suite = "VideoGridPageAutoplayIntegration.\(UUID())"
    let defaults: UserDefaults
    let store: AppStore

    init() throws {
      defaults = try #require(UserDefaults(suiteName: suite))
      root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
      folder = root.appendingPathComponent("Media", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let qoi = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
        0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
      for filename in ["00-photo.qoi", "01-video.mp4", "02-audio.wav",
        "03-photo.qoi", "04-photo.qoi", "05-photo.qoi",
        "06-audio.m4a", "07-video.mov", "08-audio.wav"] {
        // File identity/navigation are independent of codec success. Native
        // playback and corrupt-file handling have real-media controller tests.
        try (filename.hasSuffix(".qoi") ? qoi : Data("Synthetic media".utf8))
          .write(to: folder.appendingPathComponent(filename))
      }
      store = AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: root.appendingPathComponent("marks.sqlite"))
    }

    func open() async throws {
      await store.photoMarks.waitUntilReady()
      store.open(urls: [folder])
      try await ready()
      try #require(store.assets.count == 9 && store.alert == nil)
      store.setImagesPerPage(3)
      store.wrapsNavigation = false
    }

    func ready() async throws {
      let deadline = ContinuousClock.now + .seconds(10)
      while store.isLoading || store.isFiltering || store.isIndexingLocations {
        try #require(ContinuousClock.now < deadline, "Page playback fixture did not finish loading")
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    func cleanup() {
      store.pauseSlideshow()
      store.videoGridPlayback.reset()
      store.folderComparison.cancelLoads()
      store.photoMarks.flush()
      store.saveSessionNow()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
