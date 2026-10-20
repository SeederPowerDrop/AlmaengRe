import AVFoundation
import Combine
import Foundation

/// Hover owns at most one lightweight preview. Explicitly playing tiles may
/// coexist, but audio ownership is exclusive and transferred synchronously.
@MainActor
final class VideoHoverPlaybackCoordinator {
  static let shared = VideoHoverPlaybackCoordinator()
  private weak var owner: VideoTilePlaybackController?
  private weak var audioOwner: VideoTilePlaybackController?

  func claim(_ controller: VideoTilePlaybackController) {
    if owner !== controller { owner?.stop() }
    owner = controller
  }
  func claimAudio(_ controller: VideoTilePlaybackController) {
    if audioOwner !== controller { audioOwner?.setSoundEnabled(false) }
    audioOwner = controller
  }
  func release(_ controller: VideoTilePlaybackController) {
    if owner === controller { owner = nil }
    if audioOwner === controller { audioOwner = nil }
  }
  func releaseHover(_ controller: VideoTilePlaybackController) {
    if owner === controller { owner = nil }
  }
  func owns(_ controller: VideoTilePlaybackController) -> Bool { owner === controller }
}

@MainActor
final class VideoTilePlaybackController: ObservableObject {
  @Published private(set) var playback: VideoPlaybackState?
  @Published private(set) var isSoundEnabled = false

  private let coordinator: VideoHoverPlaybackCoordinator
  private var asset: ImageAsset?
  private var isMultiTile = false
  private var permitsPlayback = false
  private var isPinned = false
  private var explicitSoundChoice: Bool?
  private var desiredPlaying = false
  private var lastCommand = VideoTilePlaybackCommand()
  private var slideshowPlaybackID: UUID?
  private var audioCommandSuppressedAfterSlideshow: VideoTilePlaybackCommand?
  private var monitor: Task<Void, Never>?
  private var documentSubscription: AnyCancellable?
  private var generation = UUID()

  init(coordinator: VideoHoverPlaybackCoordinator = .shared) { self.coordinator = coordinator }

  var acceptsNativeAudioSoundChanges: Bool { asset?.isAudio == true && permitsPlayback }

  var acceptsNativeAudioPlaybackChanges: Bool {
    acceptsNativeAudioSoundChanges && slideshowPlaybackID == nil
  }

  func update(asset: ImageAsset, isMultiTile: Bool, isHovered: Bool,
    allowsPlayback: Bool, appIsActive: Bool,
    command: VideoTilePlaybackCommand = VideoTilePlaybackCommand(),
    slideshowPlaybackID: UUID? = nil
  ) {
    let changedFile = self.asset?.id != asset.id
      || self.asset?.byteCount != asset.byteCount
      || self.asset?.modificationDate != asset.modificationDate
    if changedFile || self.isMultiTile != isMultiTile {
      stop()
      self.isMultiTile = isMultiTile
    }
    self.asset = asset
    let slideshowChanged = self.slideshowPlaybackID != slideshowPlaybackID
    let slideshowStopped = self.slideshowPlaybackID != nil && slideshowPlaybackID == nil
    let commandChanged = lastCommand != command
    let playIntentChanged = lastCommand.mode != command.mode || lastCommand.generation != command.generation
    self.slideshowPlaybackID = slideshowPlaybackID
    lastCommand = command
    if playback?.errorMessage != nil,
      (slideshowChanged && slideshowPlaybackID != nil)
        || (commandChanged && command.mode == .playing) {
      stop()
    }
    let regainingPlayback = !permitsPlayback && allowsPlayback && appIsActive
    permitsPlayback = allowsPlayback && appIsActive
    guard permitsPlayback else {
      // Pausing, rather than disposing a user-started clip, retains its position
      // across fullscreen handoff and application activation changes.
      if isPinned || command.mode != .hover || !isMultiTile || slideshowPlaybackID != nil {
        desiredPlaying = false
        playback?.pause()
      } else { stop() }
      return
    }

    if asset.isAudio {
      coordinator.releaseHover(self)
      // Album playback has its own lifetime. A manual pause from a previous
      // page must not prevent a new album token from starting this audio file.
      if slideshowStopped {
        audioCommandSuppressedAfterSlideshow = command
        desiredPlaying = false
        playback?.pause()
        return
      }
      if slideshowPlaybackID != nil
        || audioCommandSuppressedAfterSlideshow?.generation != command.generation {
        audioCommandSuppressedAfterSlideshow = nil
      }
      desiredPlaying = slideshowPlaybackID != nil
        || (command.mode == .playing && audioCommandSuppressedAfterSlideshow == nil)
      guard desiredPlaying else {
        if command.mode == .hover { stop() }
        else {
          playback?.pause()
          setSoundEnabled(!command.isMuted)
        }
        return
      }
      if playback == nil { start(asset, autoplays: true) }
      setSoundEnabled(slideshowChanged && slideshowPlaybackID != nil ? true : !command.isMuted)
      if playIntentChanged || slideshowChanged || regainingPlayback {
        playback?.resume(completionID: slideshowPlaybackID)
      }
      return
    }

    if isMultiTile {
      if command.mode == .paused {
        desiredPlaying = false
        isPinned = false
        playback?.pause()
        setSoundEnabled(false)
        coordinator.releaseHover(self)
        return
      }
      let explicitlyPlaying = command.mode == .playing || isPinned || slideshowPlaybackID != nil
      guard explicitlyPlaying || isHovered else { stop(); return }
      desiredPlaying = true
      if explicitlyPlaying { coordinator.releaseHover(self) }
      else { coordinator.claim(self) }
      if playback == nil { start(asset, autoplays: true) }
      if command.mode == .playing { setSoundEnabled(!command.isMuted) }
      if commandChanged || slideshowChanged || regainingPlayback { playback?.resume(completionID: slideshowPlaybackID) }
    } else {
      let startsNewPlayback = playback == nil
      if startsNewPlayback { start(asset, autoplays: slideshowPlaybackID != nil) }
      if slideshowStopped {
        desiredPlaying = false
        playback?.pause()
      } else if slideshowPlaybackID != nil {
        desiredPlaying = true
        if slideshowChanged || regainingPlayback { playback?.resume(completionID: slideshowPlaybackID) }
      } else if command.mode != .hover {
        // A partial final grid page can contain just one video. Honor its
        // explicit page command while leaving ordinary single-view controls alone.
        desiredPlaying = command.mode == .playing
        if commandChanged || regainingPlayback || startsNewPlayback {
          setSoundEnabled(desiredPlaying && !command.isMuted)
          if desiredPlaying {
            if playIntentChanged || regainingPlayback || startsNewPlayback { playback?.resume() }
          } else { playback?.pause() }
        }
      }
    }
  }

  /// A sound click is an explicit playback action. Keep it playing when the
  /// pointer crosses the overlay or leaves the tile, and recover from EOF.
  func toggleSound() {
    guard isMultiTile, permitsPlayback, let playback,
      playback.document?.hasAudio == true else { return }
    isPinned = true
    coordinator.releaseHover(self)
    explicitSoundChoice = !isSoundEnabled
    setSoundEnabled(!isSoundEnabled)
    desiredPlaying = true
    playback.resume()
  }

  func setSoundEnabled(_ enabled: Bool) {
    if enabled { coordinator.claimAudio(self) }
    if isSoundEnabled != enabled { isSoundEnabled = enabled }
    if playback?.player.isMuted != !enabled { playback?.player.isMuted = !enabled }
    if enabled, asset?.isAudio != true, (playback?.player.volume ?? 0) == 0 { playback?.player.volume = 1 }
  }

  /// Ordinary fullscreen playback is audible by default. The automatic mute of
  /// a hover preview is not a user's mute choice for the dedicated player.
  func pauseForFullScreen() -> (seconds: Double, isMuted: Bool) {
    guard let playback else { return (0, false) }
    playback.pause()
    return (playback.currentSeconds,
      isMultiTile ? explicitSoundChoice == false : playback.player.isMuted)
  }

  func noteExplicitSoundChoice(_ enabled: Bool) { explicitSoundChoice = enabled }

  func stop() {
    generation = UUID()
    monitor?.cancel()
    monitor = nil
    documentSubscription?.cancel()
    documentSubscription = nil
    playback?.player.isMuted = true
    playback?.stop()
    playback = nil
    isPinned = false
    explicitSoundChoice = nil
    desiredPlaying = false
    audioCommandSuppressedAfterSlideshow = nil
    if isSoundEnabled { isSoundEnabled = false }
    coordinator.release(self)
  }

  private func start(_ asset: ImageAsset, autoplays: Bool) {
    let state = VideoPlaybackState()
    state.player.isMuted = isMultiTile && !isSoundEnabled
    desiredPlaying = autoplays
    let token = UUID()
    generation = token
    playback = state
    documentSubscription = state.$document.sink { [weak self, weak state] document in
      guard document != nil else { return }
      // Metadata is published just before AVPlayerItem installation.
      Task { @MainActor [weak self, weak state] in
        guard let self, let state, self.generation == token,
          self.permitsPlayback, self.desiredPlaying,
          self.playback === state, state.player.currentItem != nil else { return }
        state.resume(completionID: self.slideshowPlaybackID)
      }
    }
    monitor = Task { [weak self, state] in
      guard !Task.isCancelled else { return }
      await state.monitor(asset)
      guard let self, self.generation == token else { return }
      self.monitor = nil
    }
  }
}
