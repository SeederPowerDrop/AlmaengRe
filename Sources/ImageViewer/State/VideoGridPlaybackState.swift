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
  let soundSession: MediaSoundSession
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
  private var visiblePlaybackIDs: [URL] = []
  private var visibleAudioIDs: [URL] = []
  private var hasSessionSoundFocus = true
  private var soundSessionSubscription: AnyCancellable?
  private var singleAutoplay: Bool?
  private var pendingSingleAutoplay: Task<Void, Never>?

  init(soundSession: MediaSoundSession = MediaSoundSession()) {
    self.soundSession = soundSession
    soundSessionSubscription = soundSession.$isEnabled.dropFirst().sink { [weak self] enabled in
      guard let self else { return }
      self.objectWillChange.send()
      if enabled {
        let candidate = self.singleAutoplay != nil ? self.visiblePlaybackIDs.first
          : self.visiblePlaybackIDs.first { self.playingIDs.contains($0) }
        if self.hasSessionSoundFocus, let id = candidate {
          self.audioID = id
        }
      } else { self.audioID = nil }
    }
  }

  deinit { pendingSingleAutoplay?.cancel() }

  /// A short dwell avoids starting clips merely passed during rapid browsing.
  /// nil preserves the multi-view hover/page-follow policy.
  func updateVisibleAssets(_ assets: [ImageAsset], singleAutoplay: Bool? = nil) {
    visiblePlaybackIDs = assets.filter(\.isPlaybackMedia).map(\.id)
    let ids = Set(visiblePlaybackIDs)
    visibleAudioIDs = assets.filter(\.isAudio).map(\.id)
    guard ids != visibleIDs || self.singleAutoplay != singleAutoplay else { return }
    cancelPendingSingleAutoplay()
    let wasSingle = self.singleAutoplay != nil
    self.singleAutoplay = singleAutoplay
    visibleIDs = ids
    selectedIDs.formIntersection(ids)
    if let singleAutoplay {
      followsPages = false
      canEnablePageAutoplay = false
      playingIDs.removeAll()
      audioID = preferredSessionSoundID
      usesExplicitPlayback = true
      generation = UUID()
      if singleAutoplay, ids.count == 1, let id = ids.first {
        pendingSingleAutoplay = Task { [weak self] in
          do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
          guard let self, !Task.isCancelled, self.visibleIDs == [id],
            self.singleAutoplay == true else { return }
          self.pendingSingleAutoplay = nil
          self.playingIDs = [id]
          self.generation = UUID()
        }
      }
      return
    }
    if wasSingle {
      playingIDs.removeAll()
      audioID = nil
      usesExplicitPlayback = false
    }
    if followsPages {
      // Replace, rather than accumulate, the requested players. An image-only
      // page retains the follow intent without keeping hidden media alive.
      playingIDs = ids
      if let audioID, !ids.contains(audioID) { self.audioID = nil }
      if audioID == nil { audioID = visibleAudioIDs.first }
      if audioID == nil { audioID = preferredSessionSoundID }
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
    cancelPendingSingleAutoplay()
    usesExplicitPlayback = true
    generation = UUID()
    if !playingIDs.insert(id).inserted {
      playingIDs.remove(id)
      if singleAutoplay == nil, audioID == id { audioID = nil }
    } else if singleAutoplay == nil, visibleAudioIDs.contains(id) {
      audioID = id
    } else if soundSession.isEnabled, hasSessionSoundFocus {
      audioID = id
    }
  }

  /// Native audio controls can pause/resume independently of the tile button.
  /// Synchronize only actual transitions so programmatic starts do not steal
  /// the single sound owner from another explicitly selected media item.
  func nativeAudioPlaybackChanged(_ id: URL, isPlaying: Bool, isSoundEnabled: Bool) {
    guard visibleIDs.contains(id), playingIDs.contains(id) != isPlaying else { return }
    cancelPendingSingleAutoplay()
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
    guard visibleAudioIDs.contains(id) || (singleAutoplay != nil && visibleIDs.contains(id)) else { return }
    if isEnabled {
      if audioID != id { audioID = id }
    } else if audioID == id {
      // A native mute choice must survive hover and other view
      // updates. Muting the old owner must never clear a newer audio owner.
      soundSession.setEnabled(false)
      audioID = nil
    }
  }

  func toggleSound(_ id: URL) {
    guard visibleIDs.contains(id) else { return }
    cancelPendingSingleAutoplay()
    usesExplicitPlayback = true
    playingIDs.insert(id)
    if audioID == id {
      soundSession.setEnabled(false)
      audioID = nil
    } else { audioID = id }
    generation = UUID()
  }

  func soundMode(for id: URL) -> MediaSoundMode {
    soundSession.isEnabled ? .session : audioID == id ? .currentFile : .muted
  }

  /// One click enables this file; the next keeps sound across navigation.
  /// A third click mutes immediately and ends that session-wide choice.
  func cycleSound(_ id: URL) {
    guard visibleIDs.contains(id) else { return }
    cancelPendingSingleAutoplay()
    switch soundMode(for: id) {
    case .muted:
      usesExplicitPlayback = true
      playingIDs.insert(id)
      audioID = id
      generation = UUID()
    case .currentFile: soundSession.setEnabled(true)
    case .session:
      soundSession.setEnabled(false)
      audioID = nil
    }
  }

  /// In A/B, only the active pane inherits session sound. This never starts a
  /// paused item or changes the autoplay preference.
  func setSessionSoundFocus(_ focused: Bool) {
    guard hasSessionSoundFocus != focused else { return }
    hasSessionSoundFocus = focused
    if soundSession.isEnabled {
      audioID = singleAutoplay != nil ? preferredSessionSoundID
        : visiblePlaybackIDs.first { focused && playingIDs.contains($0) }
    }
  }

  func pauseAll() {
    cancelPendingSingleAutoplay()
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
    cancelPendingSingleAutoplay()
    singleAutoplay = nil
    followsPages = false
    canEnablePageAutoplay = false
    visibleIDs.removeAll()
    visiblePlaybackIDs.removeAll()
    visibleAudioIDs.removeAll()
    selectedIDs.removeAll()
    playingIDs.removeAll()
    audioID = nil
    usesExplicitPlayback = false
    generation = UUID()
    // View teardown and folder changes end players, not the app's sound choice.
  }

  func command(for id: URL) -> VideoTilePlaybackCommand {
    VideoTilePlaybackCommand(mode: playingIDs.contains(id) ? .playing
      : (usesExplicitPlayback ? .paused : .hover), isMuted: audioID != id,
      generation: generation)
  }

  func cancelPendingSingleAutoplay() {
    pendingSingleAutoplay?.cancel()
    pendingSingleAutoplay = nil
  }

  private func play(_ ids: Set<URL>) {
    guard !ids.isEmpty else { return }
    usesExplicitPlayback = true
    playingIDs = ids
    if let audioID, !ids.contains(audioID) { self.audioID = nil }
    if audioID == nil { audioID = visibleAudioIDs.first { ids.contains($0) } }
    if audioID == nil, soundSession.isEnabled, hasSessionSoundFocus {
      audioID = visiblePlaybackIDs.first { ids.contains($0) }
    }
    generation = UUID()
  }

  private var preferredSessionSoundID: URL? {
    soundSession.isEnabled && hasSessionSoundFocus ? visiblePlaybackIDs.first : nil
  }
}
