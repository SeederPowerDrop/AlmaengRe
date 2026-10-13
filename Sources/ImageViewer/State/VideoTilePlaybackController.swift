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
  private var monitor: Task<Void, Never>?
  private var documentSubscription: AnyCancellable?
  private var generation = UUID()

  init(coordinator: VideoHoverPlaybackCoordinator = .shared) { self.coordinator = coordinator }

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
      if playback == nil { start(asset, autoplays: slideshowPlaybackID != nil) }
      if slideshowStopped {
        desiredPlaying = false
        playback?.pause()
      } else if slideshowPlaybackID != nil {
        desiredPlaying = true
        if slideshowChanged || regainingPlayback { playback?.resume(completionID: slideshowPlaybackID) }
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
    playback?.player.isMuted = !enabled
    if enabled { playback?.player.volume = 1 }
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
