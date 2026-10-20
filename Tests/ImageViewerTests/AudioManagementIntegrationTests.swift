import Foundation
import Testing

@testable import ImageViewer

@Suite("사진·영상·음성 관리 통합", .serialized)
@MainActor
struct AudioManagementIntegrationTests {
  @Test("기존 표시 설정은 영상과 음성을 함께 숨기고 오디오 종류 필터와 직접 열기가 동작한다")
  func visibilityFilterAndExternalOpen() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { store.saveSessionNow(); fixture.remove() }
    store.open(urls: [fixture.folder])
    try await ready(store)
    #expect(store.allAssets.count == 3 && store.assets.count == 3)
    store.libraryQuery.mediaKind = .audio
    try await ready(store)
    #expect(store.assets.map(\.filename) == ["recording.wav"])
    store.libraryQuery.mediaKind = .all
    store.showsVideos = false
    try await ready(store)
    #expect(store.assets.map(\.filename) == ["photo.png"])
    #expect(store.allAssets.count == 3)
    #expect(store.openExternally(urls: [fixture.audio]))
    try await ready(store)
    #expect(store.showsVideos && store.currentAsset?.isAudio == true)
    #expect(store.presentationMode == .viewer && store.imagesPerPage == 1 && store.isFocusMode)
    #expect(store.assets.count == 3)
  }

  @Test("음성도 분류하며 개별 재생은 소리를 소유하고 이미지 편집·내보내기는 열지 않는다")
  func classificationAndExplicitPlayback() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { store.saveSessionNow(); fixture.remove() }
    store.open(urls: [fixture.folder])
    try await ready(store)
    let candidate = store.assets.first { $0.isAudio }
    let audio = try #require(candidate)
    store.select(asset: audio)
    store.togglePhotoMarking()
    store.togglePhotoMark(.one)
    #expect(store.photoMarks.marks(for: audio) == [.one])
    #expect(!store.canExportBatchImages() && !store.canOpenMotionMedia)
    store.presentMotionMedia(audio)
    #expect(store.motionMediaAsset == nil)
    store.presentationMode = .overview
    store.setImagesPerPage(6)
    store.openAudioForPlayback(audio)
    #expect(store.presentationMode == .viewer && store.imagesPerPage == 1)
    #expect(store.currentAsset == audio && !store.canPan)
    #expect(store.videoGridPlayback.playingIDs == [audio.id])
    #expect(store.videoGridPlayback.audioID == audio.id)
    #expect(!store.videoGridPlayback.command(for: audio.id).isMuted)
    store.openAudioForPlayback(audio)
    #expect(store.videoGridPlayback.playingIDs == [audio.id])
    store.videoGridPlayback.pauseAll()
  }

  @Test("음성 앨범은 이미지 간격 대신 실제 재생 완료를 기다리고 실패하면 일시정지한다")
  func audioAlbumUsesPlaybackCompletion() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { store.pauseSlideshow(); store.saveSessionNow(); fixture.remove() }
    store.open(urls: [fixture.folder])
    try await ready(store)
    store.libraryQuery.mediaKind = .audio
    try await ready(store)
    let audio = try #require(store.currentAsset)
    #expect(audio.isAudio && store.canStartSlideshow)
    store.slideshowInterval = 1
    store.slideshowRepeats = false
    store.toggleSlideshow()
    let token = try #require(store.slideshowVideoPlaybackID)
    store.slideshowAssetPresented(audio)
    try await Task.sleep(for: .milliseconds(1_100))
    #expect(store.isSlideshowPlaying && store.slideshowVideoPlaybackID == token)
    store.slideshowVideoFinished(audio, playbackID: token)
    #expect(!store.isSlideshowPlaying)
    store.toggleSlideshow()
    let nextToken = try #require(store.slideshowVideoPlaybackID)
    store.slideshowVideoFailed(audio, playbackID: nextToken)
    #expect(!store.isSlideshowPlaying)
  }

  private func ready(_ store: AppStore) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while store.isLoading || store.isFiltering || store.isIndexingLocations || !store.photoMarks.isReady {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private struct Fixture {
    let folder: URL
    let audio: URL
    let defaults: UserDefaults
    let suite = "AudioManagementTests.\(UUID())"
    init() throws {
      folder = FileManager.default.temporaryDirectory.appendingPathComponent("audio-management-\(UUID())", isDirectory: true)
      audio = folder.appendingPathComponent("recording.wav")
      defaults = UserDefaults(suiteName: suite)!
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      // Listing/marking is independent of decoding. Playback is covered with
      // real generated PCM files in AudioPlaybackTests.
      for name in ["recording.wav", "movie.mp4", "photo.png"] {
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent(name))
      }
    }
    @MainActor func makeStore() -> AppStore {
      AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: folder.appendingPathComponent("marks.sqlite"))
    }
    func remove() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }
  }
}
