import Foundation
import Testing

@testable import ImageViewer

@Suite("다중보기 페이지 이동 후 영상·음성 모두 재생")
@MainActor
struct VideoGridPageAutoplayTests {
  @Test("첫 클릭은 현재 화면만 재생하고 두 번째 클릭은 다음 페이지 재생을 켠다")
  func firstRequestIsLocalAndSecondFollowsNavigation() {
    let state = VideoGridPlaybackState()
    let first = [asset("photo.png"), asset("one.mp4"), asset("one.wav")]
    let next = [asset("next.jpg"), asset("two.mov"), asset("two.m4a")]
    state.updateVisibleAssets(first)
    state.playAll()
    #expect(state.playingIDs == Set(first.filter(\.isPlaybackMedia).map(\.id)))
    #expect(!state.followsPages && state.canEnablePageAutoplay)
    state.updateVisibleAssets(next)
    #expect(state.playingIDs.isEmpty && state.audioID == nil)
    #expect(!state.followsPages && !state.canEnablePageAutoplay)

    state.playAll()
    let before = next.map { state.command(for: $0.id) }
    state.playAll()
    #expect(state.followsPages)
    #expect(next.map { state.command(for: $0.id) } == before,
      "Enabling future pages must not restart players already on screen")
    state.updateVisibleAssets(first)
    #expect(state.playingIDs == Set(first.filter(\.isPlaybackMedia).map(\.id)))
    #expect(state.audioID == first[2].id)
    #expect(next.filter(\.isPlaybackMedia).allSatisfy { state.command(for: $0.id).mode == .paused })
  }

  @Test("사진만 있는 페이지도 유지하고 다음 혼합 페이지의 영상·음성만 재생한다")
  func imageOnlyPageDoesNotKeepHiddenPlayersOrLoseIntent() {
    let state = VideoGridPlaybackState()
    let first = [asset("one.mp4"), asset("one.wav")]
    let photos = [asset("photo.png"), asset("photo.dng")]
    let mixed = [photos[0], asset("two.mov"), asset("first.m4a"), asset("second.wav")]
    state.updateVisibleAssets(first)
    state.toggleSelection(first[0].id)
    state.playAll()
    state.playAll()
    state.updateVisibleAssets(photos)
    #expect(state.followsPages && state.playingIDs.isEmpty && state.audioID == nil)
    #expect(state.selectedIDs.isEmpty)
    #expect(first.allSatisfy { state.command(for: $0.id).mode == .paused })
    state.updateVisibleAssets(mixed)
    #expect(state.playingIDs == Set(mixed.filter(\.isPlaybackMedia).map(\.id)))
    #expect(state.audioID == mixed[2].id)
    #expect(mixed.filter { !state.command(for: $0.id).isMuted }.map(\.id) == [mixed[2].id])
    #expect(!state.playingIDs.contains(photos[0].id))
  }

  @Test("세 번째 클릭은 현재 재생을 유지하면서 다음 페이지 자동 재생만 끈다")
  func disablingFollowDoesNotPauseOrRestartCurrentPage() {
    let state = VideoGridPlaybackState()
    let video = asset("one.mp4")
    state.updateVisibleAssets([video])
    state.playAll()
    state.playAll()
    state.toggleSound(video.id)
    let command = state.command(for: video.id)
    state.playAll()
    #expect(!state.followsPages && state.canEnablePageAutoplay)
    #expect(state.command(for: video.id) == command)
    state.updateVisibleAssets([asset("two.mp4")])
    #expect(state.playingIDs.isEmpty && state.audioID == nil)
  }

  @Test("사진만 있는 페이지에서 해제할 수 있고 전체 일시정지는 다음 페이지에도 적용된다")
  func disablingOnPhotoPageAndPauseAllCancelFollow() {
    let state = VideoGridPlaybackState()
    let video = asset("one.mp4")
    state.updateVisibleAssets([video])
    state.playAll()
    state.playAll()
    state.updateVisibleAssets([asset("photo.png")])
    state.playAll()
    #expect(!state.followsPages && !state.canEnablePageAutoplay)
    state.updateVisibleAssets([video])
    #expect(state.playingIDs.isEmpty)
    state.playAll()
    state.playAll()
    state.pauseAll()
    #expect(!state.followsPages && !state.canEnablePageAutoplay)
    #expect(state.command(for: video.id).mode == .paused)
    state.updateVisibleAssets([asset("two.wav")])
    #expect(state.playingIDs.isEmpty && state.audioID == nil)
  }

  @Test("소리 소유자가 화면에 남으면 유지하고 사라지면 첫 음성을 고르며 영상끼리는 음소거한다")
  func pageChangesKeepOnlyOneDeterministicSoundOwner() {
    let state = VideoGridPlaybackState()
    let video = asset("one.mp4")
    let firstAudio = asset("one.wav")
    let secondAudio = asset("two.m4a")
    let otherVideo = asset("two.mov")
    state.updateVisibleAssets([video, firstAudio])
    state.playAll()
    state.playAll()
    state.toggleSound(video.id)
    state.updateVisibleAssets([secondAudio, video, otherVideo])
    #expect(state.audioID == video.id)
    #expect(state.command(for: secondAudio.id).isMuted)
    state.updateVisibleAssets([secondAudio, firstAudio, otherVideo])
    #expect(state.audioID == secondAudio.id)
    #expect(state.command(for: firstAudio.id).isMuted && state.command(for: otherVideo.id).isMuted)
    state.updateVisibleAssets([video, otherVideo])
    #expect(state.playingIDs == [video.id, otherVideo.id] && state.audioID == nil)
    #expect(state.command(for: video.id).isMuted && state.command(for: otherVideo.id).isMuted)
  }

  @Test("재생 종료나 실패 후 두 번째 클릭과 같은 페이지 갱신은 재시도하지 않는다")
  func completionOrFailureDoesNotRearmOrLoopOnTheSamePage() {
    let state = VideoGridPlaybackState()
    let failed = asset("broken.mp4")
    let audio = asset("completed.wav")
    state.updateVisibleAssets([failed, audio])
    state.playAll()
    state.didFinish(failed.id)
    state.didFinish(audio.id)
    #expect(state.playingIDs.isEmpty && state.canEnablePageAutoplay)
    let finishedGeneration = state.generation
    state.playAll()
    #expect(state.followsPages && state.playingIDs.isEmpty)
    state.updateVisibleAssets([failed, audio])
    #expect(state.playingIDs.isEmpty && state.generation == finishedGeneration)
    state.updateVisibleAssets([asset("good.mov")])
    #expect(state.playingIDs == [asset("good.mov").id])
    state.didFinish(failed.id)
    state.nativeAudioPlaybackChanged(audio.id, isPlaying: false, isSoundEnabled: true)
    #expect(state.playingIDs == [asset("good.mov").id] && state.audioID == nil,
      "Late callbacks from the old page must not affect the new page")
  }

  @Test("선택 재생과 초기화는 다음 페이지 재생 의도를 남기지 않는다")
  func selectedPlaybackAndResetAreExplicitBoundaries() {
    let state = VideoGridPlaybackState()
    let video = asset("one.mp4")
    let audio = asset("one.wav")
    state.updateVisibleAssets([video, audio])
    state.playAll()
    state.playAll()
    state.toggleSelection(video.id)
    state.playSelected()
    #expect(state.playingIDs == [video.id] && state.audioID == nil)
    #expect(!state.followsPages && !state.canEnablePageAutoplay)
    state.playAll()
    state.playAll()
    state.reset()
    #expect(!state.followsPages && !state.canEnablePageAutoplay && !state.usesExplicitPlayback)
    #expect(state.playingIDs.isEmpty && state.selectedIDs.isEmpty && state.audioID == nil)
    state.updateVisibleAssets([audio])
    #expect(state.command(for: audio.id).mode == .hover)
  }

  @Test("프레임 재배치나 같은 항목의 메타정보 갱신은 음소거·일시정지 선택을 되살리지 않는다")
  func unchangedPageDoesNotOverrideLocalPlaybackChoices() {
    let state = VideoGridPlaybackState()
    let video = asset("one.mp4")
    let audio = asset("one.wav")
    state.updateVisibleAssets([video, audio])
    state.playAll()
    state.playAll()
    state.togglePlayback(video.id)
    state.nativeAudioSoundChanged(audio.id, isEnabled: false)
    let commands = [video, audio].map { state.command(for: $0.id) }
    state.updateVisibleAssets([audio, video])
    #expect([video, audio].map { state.command(for: $0.id) } == commands)
    #expect(state.followsPages)
  }

  private func asset(_ filename: String) -> ImageAsset {
    ImageAsset(url: URL(fileURLWithPath: "/synthetic-page-autoplay/\(filename)"),
      byteCount: nil, modificationDate: nil)
  }
}
