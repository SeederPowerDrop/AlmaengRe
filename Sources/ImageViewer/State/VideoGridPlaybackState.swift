import Combine
import Foundation

struct VideoTilePlaybackCommand: Equatable {
  enum Mode: Equatable { case hover, paused, playing }
  var mode: Mode = .hover
  var isMuted = true
  var generation: UUID? = nil
}

/// Players belong only to the visible page. The optional page-follow intent
/// starts its media after navigation; images never participate in playback.
/// Only one video or audio item may own audible playback at a time.
@MainActor
final class VideoGridPlaybackState: ObservableObject {
  @Published private(set) var selectedIDs: Set<URL> = []
  @Published private(set) var playingIDs: Set<URL> = []
  @Published private(set) var audioID: URL?
  @Published private(set) var usesExplicitPlayback = false
  @Published private(set) var followsPages = false
  // Record the user's first all-play request separately from player status.
  // Completion or failure must not turn the next button press into a retry.
  @Published private(set) var canEnablePageAutoplay = false
  @Published private(set) var generation = UUID()
  private var visibleIDs: Set<URL> = []
  private var visibleAudioIDs: [URL] = []

  func updateVisibleAssets(_ assets: [ImageAsset]) {
    let ids = Set(assets.filter(\.isPlaybackMedia).map(\.id))
    visibleAudioIDs = assets.filter(\.isAudio).map(\.id)
    guard ids != visibleIDs else { return }
    visibleIDs = ids
    selectedIDs.formIntersection(ids)
    if followsPages {
      // Replace, rather than accumulate, the requested players. An image-only
      // page retains the follow intent without keeping hidden media alive.
      playingIDs = ids
      if let audioID, !ids.contains(audioID) { self.audioID = nil }
      if audioID == nil { audioID = visibleAudioIDs.first }
      usesExplicitPlayback = true
      canEnablePageAutoplay = !ids.isEmpty
      generation = UUID()
      return
    }
    canEnablePageAutoplay = false
    playingIDs.formIntersection(ids)
    if let audioID, !playingIDs.contains(audioID) { self.audioID = nil }
    // A new page starts with lightweight hover previews, never hidden players.
    if playingIDs.isEmpty { usesExplicitPlayback = false }
  }

  func toggleSelection(_ id: URL) {
    guard visibleIDs.contains(id) else { return }
    if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
  }

  func playAll() {
    if followsPages {
      // Turning off page-follow leaves this page's playback untouched.
      followsPages = false
      canEnablePageAutoplay = !visibleIDs.isEmpty
      return
    }
    guard !visibleIDs.isEmpty else { return }
    if canEnablePageAutoplay {
      followsPages = true
      return
    }
    play(visibleIDs)
    canEnablePageAutoplay = true
  }

  func playSelected() {
    let ids = selectedIDs.intersection(visibleIDs)
    guard !ids.isEmpty else { return }
    followsPages = false
    canEnablePageAutoplay = false
    play(ids)
  }

  func togglePlayback(_ id: URL) {
    guard visibleIDs.contains(id) else { return }
    usesExplicitPlayback = true
    generation = UUID()
    if !playingIDs.insert(id).inserted {
      playingIDs.remove(id)
      if audioID == id { audioID = nil }
    } else if visibleAudioIDs.contains(id) {
      audioID = id
    }
  }

  /// Native audio controls can pause/resume independently of the tile button.
  /// Synchronize only actual transitions so programmatic starts do not steal
  /// the single sound owner from another explicitly selected media item.
  func nativeAudioPlaybackChanged(_ id: URL, isPlaying: Bool, isSoundEnabled: Bool) {
    guard visibleIDs.contains(id), playingIDs.contains(id) != isPlaying else { return }
    usesExplicitPlayback = true
    if isPlaying {
      playingIDs.insert(id)
    } else {
      playingIDs.remove(id)
    }
    // Native pause/resume preserves the user's actual mute and volume choice.
    // The central explicit play button has its separate audible-start policy.
    if isSoundEnabled { audioID = id }
    else if audioID == id { audioID = nil }
    generation = UUID()
  }

  func nativeAudioSoundChanged(_ id: URL, isEnabled: Bool) {
    guard visibleAudioIDs.contains(id) else { return }
    if isEnabled {
      if audioID != id { audioID = id }
    } else if audioID == id {
      // A native mute choice must survive hover and other view
      // updates. Muting the old owner must never clear a newer audio owner.
      audioID = nil
    }
  }

  func toggleSound(_ id: URL) {
    guard visibleIDs.contains(id) else { return }
    usesExplicitPlayback = true
    playingIDs.insert(id)
    audioID = audioID == id ? nil : id
    generation = UUID()
  }

  func pauseAll() {
    followsPages = false
    canEnablePageAutoplay = false
    usesExplicitPlayback = true
    playingIDs.removeAll()
    audioID = nil
    generation = UUID()
  }

  func didFinish(_ id: URL) {
    guard playingIDs.contains(id) else { return }
    playingIDs.remove(id)
    if audioID == id { audioID = nil }
  }

  func reset() {
    followsPages = false
    canEnablePageAutoplay = false
    visibleIDs.removeAll()
    visibleAudioIDs.removeAll()
    selectedIDs.removeAll()
    playingIDs.removeAll()
    audioID = nil
    usesExplicitPlayback = false
    generation = UUID()
  }

  func command(for id: URL) -> VideoTilePlaybackCommand {
    VideoTilePlaybackCommand(mode: playingIDs.contains(id) ? .playing
      : (usesExplicitPlayback ? .paused : .hover), isMuted: audioID != id,
      generation: generation)
  }

  private func play(_ ids: Set<URL>) {
    guard !ids.isEmpty else { return }
    usesExplicitPlayback = true
    playingIDs = ids
    if let audioID, !ids.contains(audioID) { self.audioID = nil }
    if audioID == nil { audioID = visibleAudioIDs.first { ids.contains($0) } }
    generation = UUID()
  }
}
