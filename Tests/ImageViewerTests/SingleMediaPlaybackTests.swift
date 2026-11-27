import Foundation
import Testing
@testable import ImageViewer

@Suite("한 장 보기의 지연 무음 재생", .serialized)
@MainActor
struct SingleMediaPlaybackTests {
  private func asset(_ name: String) -> ImageAsset {
    ImageAsset(url: URL(fileURLWithPath: "/single-media/" + name), byteCount: 100, modificationDate: nil)
  }

  @Test("소리 버튼의 두 번째 누름은 사진을 지나 다음 영상·음성에도 유지되고 세 번째는 무음으로 돌아간다",
    arguments: [false, true])
  func sessionSoundCyclesAndFollowsFiles(autoplay: Bool) async throws {
    let state = VideoGridPlaybackState()
    let video = asset("first.mp4"), audio = asset("next.wav"), photo = asset("still.jpg")
    defer { state.reset() }
    state.updateVisibleAssets([video], singleAutoplay: autoplay)
    #expect(state.soundMode(for: video.id) == .muted)
    state.cycleSound(video.id)
    #expect(state.soundMode(for: video.id) == .currentFile)
    #expect(!state.soundSession.isEnabled && !state.command(for: video.id).isMuted)
    state.updateVisibleAssets([audio], singleAutoplay: autoplay)
    #expect(state.command(for: audio.id).isMuted)
    state.cycleSound(audio.id)
    state.cycleSound(audio.id)
    #expect(state.soundMode(for: audio.id) == .session && state.soundSession.isEnabled)
    state.didFinish(audio.id)
    #expect(state.playingIDs.isEmpty && state.soundSession.isEnabled)
    state.updateVisibleAssets([photo], singleAutoplay: autoplay)
    #expect(state.audioID == nil && state.playingIDs.isEmpty && state.soundSession.isEnabled)
    state.updateVisibleAssets([video], singleAutoplay: autoplay)
    if autoplay {
      try await waitUntil { state.playingIDs == [video.id] }
    } else {
      try await Task.sleep(for: .milliseconds(200))
      #expect(state.playingIDs.isEmpty, "Sound persistence must not enable autoplay")
      state.togglePlayback(video.id)
    }
    #expect(!state.command(for: video.id).isMuted)
    state.togglePlayback(video.id)
    #expect(state.playingIDs.isEmpty && state.soundSession.isEnabled)
    state.togglePlayback(video.id)
    #expect(!state.command(for: video.id).isMuted)
    state.cycleSound(video.id)
    #expect(state.soundMode(for: video.id) == .muted && !state.soundSession.isEnabled)
    #expect(state.command(for: video.id).isMuted)
    state.updateVisibleAssets([audio], singleAutoplay: autoplay)
    #expect(state.command(for: audio.id).isMuted)
  }

  @Test("소리 유지는 화면·폴더 플레이어 리셋을 지나 공유되지만 앱을 다시 만들면 기본 무음이다")
  func sessionSoundOutlivesPlayersButIsNotSaved() throws {
    let name = "SessionSound.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    let video = asset("one.mp4"), audio = asset("next.wav")
    let viewer = store.videoGridPlayback
    viewer.updateVisibleAssets([video], singleAutoplay: false)
    viewer.cycleSound(video.id)
    viewer.cycleSound(video.id)
    viewer.pauseAll()
    viewer.reset()
    #expect(store.mediaSoundSession.isEnabled && viewer.audioID == nil)
    let inline = VideoGridPlaybackState(soundSession: store.mediaSoundSession)
    inline.updateVisibleAssets([audio], singleAutoplay: false)
    #expect(inline.soundMode(for: audio.id) == .session && !inline.command(for: audio.id).isMuted)
    #expect(inline.playingIDs.isEmpty)
    inline.reset()
    let relaunched = AppStore(defaults: defaults, monitorsSystemResources: false)
    relaunched.videoGridPlayback.updateVisibleAssets([audio], singleAutoplay: false)
    #expect(!relaunched.mediaSoundSession.isEnabled)
    #expect(relaunched.videoGridPlayback.command(for: audio.id).isMuted)
  }

  @Test("비교의 소리 유지는 활성 칸만 따르고 이전 칸의 늦은 음소거는 새 소리를 끄지 않는다")
  func sessionSoundFollowsComparisonFocusAndNativeMute() {
    let session = MediaSoundSession()
    let first = VideoGridPlaybackState(soundSession: session)
    let second = VideoGridPlaybackState(soundSession: session)
    let video = asset("first.mp4"), audio = asset("second.wav")
    second.setSessionSoundFocus(false)
    first.updateVisibleAssets([video], singleAutoplay: false)
    second.updateVisibleAssets([audio], singleAutoplay: false)
    first.cycleSound(video.id)
    first.cycleSound(video.id)
    #expect(!first.command(for: video.id).isMuted && second.command(for: audio.id).isMuted)
    first.setSessionSoundFocus(false)
    second.setSessionSoundFocus(true)
    #expect(first.command(for: video.id).isMuted && !second.command(for: audio.id).isMuted)
    #expect(second.playingIDs.isEmpty)
    first.nativeAudioSoundChanged(video.id, isEnabled: false)
    #expect(session.isEnabled && !second.command(for: audio.id).isMuted)
    second.nativeAudioSoundChanged(audio.id, isEnabled: false)
    #expect(!session.isEnabled && second.command(for: audio.id).isMuted)
    first.updateVisibleAssets([audio], singleAutoplay: false)
    #expect(first.command(for: audio.id).isMuted)
  }

  @Test("한 장 보기의 소리 유지는 다중보기 선택 재생과 다음 페이지에서도 한 항목에만 적용된다")
  func sessionSoundFollowsSelectedGridPlayback() {
    let state = VideoGridPlaybackState()
    let first = asset("first.mp4"), second = asset("second.mp4"), next = asset("next.mp4")
    state.updateVisibleAssets([first], singleAutoplay: false)
    state.cycleSound(first.id)
    state.cycleSound(first.id)
    state.updateVisibleAssets([first, second])
    state.toggleSelection(second.id)
    state.playSelected()
    #expect(state.playingIDs == [second.id] && state.audioID == second.id)
    #expect(state.command(for: first.id).isMuted && !state.command(for: second.id).isMuted)
    state.playAll()
    state.playAll()
    state.updateVisibleAssets([first, next])
    #expect(state.playingIDs == [first.id, next.id] && state.audioID == first.id)
    #expect(state.command(for: next.id).isMuted)
    state.reset()
  }

  @Test("소리 유지 선택과 해제는 일시 정지한 파일을 재개하거나 플레이어를 다시 로드하지 않는다")
  func pinningAndMutingSoundPreservePause() {
    let state = VideoGridPlaybackState(), video = asset("paused.mp4")
    state.updateVisibleAssets([video], singleAutoplay: false)
    state.cycleSound(video.id)
    state.togglePlayback(video.id)
    let pausedCommand = state.command(for: video.id)
    state.cycleSound(video.id)
    #expect(state.soundSession.isEnabled && state.command(for: video.id) == pausedCommand)
    state.cycleSound(video.id)
    #expect(!state.soundSession.isEnabled && state.playingIDs.isEmpty)
    #expect(state.command(for: video.id).mode == .paused && state.command(for: video.id).isMuted)
    state.reset()
  }

  @Test("같은 파일에 잠깐 머문 뒤 한 번만 무음 재생하고 메타데이터 갱신은 정지를 되돌리지 않는다")
  func autoplayWaitsAndPreservesManualPause() async throws {
    let state = VideoGridPlaybackState(), video = asset("one.mp4")
    defer { state.reset() }
    state.updateVisibleAssets([video], singleAutoplay: true)
    #expect(state.command(for: video.id).mode == .paused)
    try await Task.sleep(for: .milliseconds(80))
    #expect(state.playingIDs.isEmpty)
    try await waitUntil { state.playingIDs == [video.id] }
    #expect(state.playingIDs == [video.id] && state.audioID == nil)
    state.togglePlayback(video.id)
    var enriched = video
    enriched.hasReadLocation = true
    state.updateVisibleAssets([enriched], singleAutoplay: true)
    try await Task.sleep(for: .milliseconds(200))
    #expect(state.playingIDs.isEmpty)
  }

  @Test("빠른 탐색·비활성화·리셋은 이전 자동 재생을 취소한다")
  func abandonedRequestsNeverStart() async throws {
    let state = VideoGridPlaybackState(), first = asset("one.mp4"), next = asset("two.wav")
    state.updateVisibleAssets([first], singleAutoplay: true)
    state.updateVisibleAssets([next], singleAutoplay: true)
    try await waitUntil { state.playingIDs == [next.id] }
    #expect(state.playingIDs == [next.id] && state.audioID == nil)
    state.updateVisibleAssets([first], singleAutoplay: true)
    state.cancelPendingSingleAutoplay()
    try await Task.sleep(for: .milliseconds(200))
    #expect(state.playingIDs.isEmpty)
    state.updateVisibleAssets([next], singleAutoplay: true)
    state.reset()
    try await Task.sleep(for: .milliseconds(200))
    #expect(state.playingIDs.isEmpty && state.audioID == nil)
  }

  @Test("수동 재생은 무음이며 소리 선택은 정지·재개에 유지되고 새 파일에서는 초기화된다")
  func manualPlaybackAndSoundAreIndependent() async throws {
    let state = VideoGridPlaybackState(), audio = asset("one.wav"), video = asset("two.mp4")
    defer { state.reset() }
    state.updateVisibleAssets([audio], singleAutoplay: false)
    try await Task.sleep(for: .milliseconds(200))
    #expect(state.playingIDs.isEmpty)
    state.togglePlayback(audio.id)
    #expect(state.playingIDs == [audio.id] && state.audioID == nil)
    state.toggleSound(audio.id)
    state.togglePlayback(audio.id)
    #expect(state.playingIDs.isEmpty && state.audioID == audio.id)
    state.togglePlayback(audio.id)
    #expect(state.playingIDs == [audio.id] && state.audioID == audio.id)
    state.updateVisibleAssets([video], singleAutoplay: false)
    #expect(state.playingIDs.isEmpty && state.audioID == nil)
    state.nativeAudioSoundChanged(video.id, isEnabled: true)
    #expect(state.audioID == video.id)
  }

  @Test("수동 조작과 설정 변경은 예약을 취소하고 자동 재생은 무음으로 다시 시작한다")
  func manualActionsAndPreferenceChangesCancelTimer() async throws {
    let state = VideoGridPlaybackState(), video = asset("one.mp4")
    defer { state.reset() }
    state.updateVisibleAssets([video], singleAutoplay: true)
    state.togglePlayback(video.id)
    state.togglePlayback(video.id)
    try await Task.sleep(for: .milliseconds(200))
    #expect(state.playingIDs.isEmpty)
    state.updateVisibleAssets([video], singleAutoplay: false)
    state.toggleSound(video.id)
    state.updateVisibleAssets([video], singleAutoplay: true)
    #expect(state.audioID == nil && state.playingIDs.isEmpty)
    try await waitUntil { state.playingIDs == [video.id] }
    #expect(state.playingIDs == [video.id] && state.audioID == nil)
    state.updateVisibleAssets([video], singleAutoplay: false)
    #expect(state.playingIDs.isEmpty)
  }

  @Test("설정은 재실행에 유지되고 다른 설정 저장소에 영향을 주지 않는다")
  func preferencePersists() throws {
    let name = "SingleMediaPreferences.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let first = AppStore(defaults: defaults, monitorsSystemResources: false)
    #expect(first.automaticallyPlaysSingleMedia)
    first.automaticallyPlaysSingleMedia = false
    let next = AppStore(defaults: defaults, monitorsSystemResources: false)
    #expect(!next.automaticallyPlaysSingleMedia)
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(predicate())
  }
}
