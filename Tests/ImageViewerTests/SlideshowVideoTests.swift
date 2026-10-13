import Foundation
import Testing

@testable import ImageViewer

@Suite("영상과 사진을 함께 재생하는 전자 앨범")
@MainActor
struct SlideshowVideoTests {
  @Test("영상 전용 앨범은 한 영상부터 재생하고 끝나면 멈춘다")
  func videoOnly() async throws {
    let fixture = try Fixture(names: ["01.mp4"])
    defer { fixture.remove() }
    let store = try await fixture.open()
    defer { store.pauseSlideshow() }
    store.slideshowRepeats = false
    #expect(store.canStartSlideshow)
    store.toggleSlideshow()
    let asset = try #require(store.currentAsset)
    let playbackID = try #require(store.slideshowVideoPlaybackID)
    #expect(store.isSlideshowPlaying && store.isFocusMode && store.imagesPerPage == 1)
    store.slideshowVideoFinished(asset, playbackID: playbackID)
    #expect(!store.isSlideshowPlaying && store.slideshowVideoPlaybackID == nil)
    #expect(store.currentAsset == asset)
  }

  @Test("사진 간격과 준비된 포스터는 영상을 중간에 넘기지 않는다")
  func videosWaitForPlaybackEnd() async throws {
    let fixture = try Fixture(names: ["01.mp4", "02.qoi", "03.mov"])
    defer { fixture.remove() }
    let store = try await fixture.open()
    defer { store.pauseSlideshow() }
    store.slideshowInterval = 1
    store.slideshowRepeats = false
    store.toggleSlideshow()
    let video = try #require(store.currentAsset)
    let playbackID = try #require(store.slideshowVideoPlaybackID)
    store.slideshowAssetPresented(video)
    try await Task.sleep(for: .milliseconds(1150))
    #expect(store.currentIndex == 0 && store.isSlideshowPlaying)
    #expect(store.slideshowVideoPlaybackID == playbackID)
    store.slideshowVideoFinished(video, playbackID: playbackID)
    #expect(store.currentIndex == 1 && store.slideshowVideoPlaybackID == nil)
    let photo = try #require(store.currentAsset)
    #expect(!photo.isVideo)
    store.slideshowAssetPresented(photo)
    try await waitUntil { store.currentIndex == 2 }
    let lastVideo = try #require(store.currentAsset)
    let lastID = try #require(store.slideshowVideoPlaybackID)
    // The previous player's delayed completion must not end the new video.
    store.slideshowVideoFinished(video, playbackID: playbackID)
    #expect(store.currentIndex == 2 && store.isSlideshowPlaying)
    store.slideshowVideoFinished(lastVideo, playbackID: lastID)
    #expect(!store.isSlideshowPlaying)
  }

  @Test("한 영상 반복은 매번 새 재생 ID를 발급하고 중복 완료를 무시한다")
  func repeatingOneVideo() async throws {
    let fixture = try Fixture(names: ["01.mp4"])
    defer { fixture.remove() }
    let store = try await fixture.open()
    defer { store.pauseSlideshow() }
    store.toggleSlideshow()
    let video = try #require(store.currentAsset)
    let firstID = try #require(store.slideshowVideoPlaybackID)
    store.slideshowVideoFinished(video, playbackID: firstID)
    let secondID = try #require(store.slideshowVideoPlaybackID)
    #expect(firstID != secondID && store.currentIndex == 0 && store.isSlideshowPlaying)
    store.slideshowVideoFinished(video, playbackID: firstID)
    #expect(store.slideshowVideoPlaybackID == secondID)
    store.slideshowVideoFinished(video, playbackID: secondID)
    #expect(store.slideshowVideoPlaybackID != secondID)
  }

  @Test("수동 탐색과 일시정지·재개 후에는 오래된 영상 결과를 무시한다")
  func staleEventsAfterNavigationAndPause() async throws {
    let fixture = try Fixture(names: ["01.mp4", "02.mp4"])
    defer { fixture.remove() }
    let store = try await fixture.open()
    defer { store.pauseSlideshow() }
    store.toggleSlideshow()
    let first = try #require(store.currentAsset)
    let firstID = try #require(store.slideshowVideoPlaybackID)
    store.navigatePage(1)
    let second = try #require(store.currentAsset)
    let secondID = try #require(store.slideshowVideoPlaybackID)
    #expect(secondID != firstID)
    store.slideshowVideoFinished(first, playbackID: firstID)
    store.slideshowVideoFailed(first, playbackID: firstID)
    #expect(store.currentIndex == 1 && store.isSlideshowPlaying)
    store.pauseSlideshow()
    #expect(store.slideshowVideoPlaybackID == nil)
    store.toggleSlideshow()
    let resumedID = try #require(store.slideshowVideoPlaybackID)
    #expect(resumedID != secondID)
    store.slideshowVideoFinished(second, playbackID: secondID)
    store.slideshowVideoFailed(second, playbackID: secondID)
    #expect(store.currentIndex == 1 && store.isSlideshowPlaying)
    store.slideshowVideoFinished(second, playbackID: resumedID)
    #expect(store.currentIndex == 0 && store.isSlideshowPlaying)
  }

  @Test("재생 실패는 앨범을 일시정지하고 다중 보기 복귀는 재생 ID를 해제한다")
  func failureAndExit() async throws {
    let fixture = try Fixture(names: ["01.mp4", "02.mp4"])
    defer { fixture.remove() }
    let store = try await fixture.open()
    defer { store.pauseSlideshow() }
    store.toggleSlideshow()
    let video = try #require(store.currentAsset)
    let playbackID = try #require(store.slideshowVideoPlaybackID)
    store.slideshowVideoFailed(video, playbackID: playbackID)
    #expect(!store.isSlideshowPlaying && store.slideshowVideoPlaybackID == nil)
    store.toggleSlideshow()
    #expect(store.slideshowVideoPlaybackID != nil)
    store.setImagesPerPage(4)
    #expect(!store.isSlideshowPlaying && store.slideshowVideoPlaybackID == nil)
    store.toggleSlideshow()
    store.exitFocusMode()
    #expect(!store.isSlideshowPlaying && store.slideshowVideoPlaybackID == nil)
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !predicate() {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  @MainActor private struct Fixture {
    let folder: URL
    let suite = "SlideshowVideoTests.\(UUID())"

    init(names: [String]) throws {
      folder = FileManager.default.temporaryDirectory.appendingPathComponent("slideshow-video-\(UUID())")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let photo = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 2, 0, 0, 0, 1, 3, 0,
        0xfe, 255, 0, 0, 0xfe, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 1])
      for name in names {
        // Playback itself is tested by VideoTilePlaybackController tests. These
        // files exercise the library and slideshow's timing/event ownership.
        try (name.hasSuffix(".qoi") ? photo : Data("Synthetic video".utf8))
          .write(to: folder.appendingPathComponent(name))
      }
    }

    func open() async throws -> AppStore {
      let defaults = try #require(UserDefaults(suiteName: suite))
      let store = AppStore(defaults: defaults, monitorsSystemResources: false)
      store.showsVideos = true
      store.open(urls: [folder])
      let deadline = ContinuousClock.now + .seconds(8)
      while store.isLoading || store.isFiltering {
        try #require(ContinuousClock.now < deadline)
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(!store.assets.isEmpty && store.alert == nil)
      return store
    }

    func remove() {
      UserDefaults.standard.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }
  }
}
