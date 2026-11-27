@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class VideoPlaybackState: ObservableObject {
  let player = AVPlayer()
  @Published private(set) var document: VideoDocument?
  @Published private(set) var errorMessage: String?
  @Published private(set) var currentSeconds = 0.0
  @Published private(set) var isPlaying = false
  private(set) var hasStartedCurrentItem = false
  @Published private(set) var isSoundEnabled = false
  @Published private(set) var completedPlaybackCount = 0
  private(set) var completedSlideshowID: UUID?
  @Published private(set) var isSeeking = false
  @Published private(set) var canStepForward = false
  @Published private(set) var canStepBackward = false
  @Published private(set) var study: VideoStudySession?
  private var rateSubscription: AnyCancellable?
  private var endSubscription: AnyCancellable?
  private var failureSubscription: AnyCancellable?
  private var audioOutputSubscription: AnyCancellable?
  private var audioRateSubscription: AnyCancellable?
  private var itemStatusSubscription: AnyCancellable?
  private var playerStatusSubscription: AnyCancellable?
  private var positionObserver: Any?
  private var positionObserverInterval: Double?
  private var monitorLifetime: VideoPlaybackMonitorLifetime?
  private var generation = UUID()
  private var seekToken = UUID()
  private var playWhenSeekCompletes = false
  private var hasReachedEnd = false

  /// Owned by a SwiftUI task: changing files or leaving the view cancels this
  /// monitor, pauses audio and releases the old player item and its decode work.
  func monitor(_ asset: ImageAsset) async {
    // A cancelled task may first reach the main actor after a newer monitor.
    // It must not tear down the newer item's state before noticing cancellation.
    guard !Task.isCancelled else { return }
    stop()
    errorMessage = nil
    if asset.isAudio {
      player.defaultRate = 1
    } else {
      let session = VideoStudySession.session(for: asset.url)
      study = session
      rateSubscription = session.$playbackRate.removeDuplicates().sink { [weak self] rate in
        guard let self else { return }
        let supportedRate = rate.isFinite ? Float(min(4, max(0.25, rate))) : 1
        // Native AVKit controls call play(), which also respects defaultRate.
        self.player.defaultRate = supportedRate
        if self.player.rate != 0, !self.isSeeking { self.player.rate = supportedRate }
      }
    }
    let token = UUID()
    generation = token
    defer { if generation == token { stop() } }
    do {
      let info = try await VideoDocument.load(url: asset.url, allowsAudioOnly: asset.isAudio)
      try Task.checkCancellation()
      guard generation == token else { return }
      guard info.isPlayable else {
        if info.hasProtectedContent { throw VideoProcessingError.protectedContent }
        throw ImagePipelineError.unsupported(asset.url)
      }
      document = info
      let item = AVPlayerItem(url: asset.url)
      // Preserve speech pitch while changing speed, using AVFoundation's
      // time-domain algorithm for interactive playback.
      item.audioTimePitchAlgorithm = .timeDomain
      player.replaceCurrentItem(with: item)
      observeAudioOutput(item, token: token)
      observeCompletion(completionID: nil)
      observeFailure(item, token: token)
      study?.prepareAutomaticSubtitles()
      let lifetime = VideoPlaybackMonitorLifetime()
      monitorLifetime = lifetime
      observeProgress(item, token: token, lifetime: lifetime)
      try await lifetime.wait()
    } catch is CancellationError {
      // Leaving the view is normal cancellation, not a playback failure.
    } catch {
      guard !Task.isCancelled, generation == token else { return }
      let reason = await MediaLoadFailure.message(for: error, url: asset.url)
      guard !Task.isCancelled, generation == token else { return }
      errorMessage = reason
    }
  }

  func togglePlayback() {
    guard !isSeeking else { return }
    if player.rate != 0 { pause() }
    else { resume() }
  }

  func resume(completionID: UUID? = nil) {
    guard !isSeeking, player.currentItem != nil else { return }
    observeCompletion(completionID: completionID)
    synchronizeCurrentTime()
    if hasReachedEnd || document.map({ currentSeconds >= $0.durationSeconds - 0.001 }) == true {
      seek(0, resumePlayback: true)
    } else {
      player.play()
      synchronizePlayingState()
    }
  }

  func pause() {
    playWhenSeekCompletes = false
    player.pause()
    if isPlaying { isPlaying = false }
    synchronizeCurrentTime()
  }

  func seek(_ seconds: Double) {
    seek(seconds, resumePlayback: false)
  }

  /// Continue a preview in the dedicated player without losing its position.
  func play(from seconds: Double) {
    seek(seconds, resumePlayback: true)
  }

  private func seek(_ seconds: Double, resumePlayback: Bool) {
    guard let document, let item = player.currentItem, seconds.isFinite else { return }
    pause()
    hasReachedEnd = false
    let time = min(document.durationSeconds, max(0, seconds))
    let currentGeneration = generation
    let itemIdentity = ObjectIdentifier(item)
    let token = UUID()
    seekToken = token
    if !isSeeking { isSeeking = true }
    playWhenSeekCompletes = resumePlayback
    updateSteppingAvailability()
    if currentSeconds != time { currentSeconds = time }
    player.seek(to: CMTime(seconds: time, preferredTimescale: 600_000),
      toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
      Task { @MainActor [weak self] in
        guard let self, let item = self.player.currentItem,
          self.generation == currentGeneration, self.seekToken == token,
          ObjectIdentifier(item) == itemIdentity else { return }
        self.isSeeking = false
        self.synchronizeCurrentTime()
        self.updateSteppingAvailability()
        let resume = finished && self.playWhenSeekCompletes
        self.playWhenSeekCompletes = false
        if resume {
          self.player.play()
          self.synchronizePlayingState()
        }
      }
    }
  }

  func step(_ count: Int) {
    guard !isSeeking,
      (count > 0 && canStepForward) || (count < 0 && canStepBackward) else { return }
    pause()
    player.currentItem?.step(byCount: count)
    synchronizeCurrentTime()
  }

  func stop() {
    hasStartedCurrentItem = false
    generation = UUID()
    monitorLifetime?.finish(.success(()))
    monitorLifetime = nil
    if let positionObserver { player.removeTimeObserver(positionObserver) }
    positionObserver = nil
    positionObserverInterval = nil
    itemStatusSubscription?.cancel(); itemStatusSubscription = nil
    playerStatusSubscription?.cancel(); playerStatusSubscription = nil
    seekToken = UUID()
    hasReachedEnd = false
    if isSeeking { isSeeking = false }
    pause()
    player.currentItem?.cancelPendingSeeks()
    player.replaceCurrentItem(with: nil)
    rateSubscription?.cancel()
    rateSubscription = nil
    endSubscription?.cancel()
    endSubscription = nil
    failureSubscription?.cancel()
    failureSubscription = nil
    audioOutputSubscription?.cancel()
    audioOutputSubscription = nil
    audioRateSubscription?.cancel()
    audioRateSubscription = nil
    if isSoundEnabled { isSoundEnabled = false }
    if study != nil { study = nil }
    if document != nil { document = nil }
    if currentSeconds != 0 { currentSeconds = 0 }
    if canStepForward { canStepForward = false }
    if canStepBackward { canStepBackward = false }
  }

  private func observeCompletion(completionID: UUID?) {
    guard let item = player.currentItem else { return }
    let token = generation
    endSubscription = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self, self.generation == token, self.player.currentItem === item,
            !self.isSeeking else { return }
          self.synchronizeCurrentTime()
          // Ignore an EOF already queued for a play cycle that has since sought
          // backwards. Each observer also captures the originating album token.
          guard let document = self.document,
            self.currentSeconds >= document.durationSeconds - max(0.05, 1 / max(1, document.nominalFrameRate)) else { return }
          self.isPlaying = false
          self.hasReachedEnd = true
          self.completedSlideshowID = completionID
          self.completedPlaybackCount += 1
        }
      }
  }

  private func observeFailure(_ item: AVPlayerItem, token: UUID) {
    failureSubscription = NotificationCenter.default.publisher(
      for: .AVPlayerItemFailedToPlayToEndTime, object: item)
      .sink { [weak self, weak item] notification in
        let reportedError = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        Task { @MainActor [weak self, weak item] in
          guard let self, let item, self.generation == token,
            self.player.currentItem === item else { return }
          let error = reportedError ?? item.error ?? self.player.error ?? AVError(.unknown)
          guard !MediaLoadFailure.isCancellation(error) else { return }
          self.monitorLifetime?.finish(.failure(error))
          self.pause()
        }
      }
  }

  private func observeAudioOutput(_ item: AVPlayerItem, token: UUID) {
    // Keep one observer per loaded item, outside SwiftUI body updates. A
    // deferred delivery avoids mutating the grid during its own view update;
    // read the current value rather than an already superseded KVO event.
    // Volume zero remains a volume choice, not an extra mute command: moving
    // the native slider up must restore sound unless another tile took over.
    audioOutputSubscription = player.publisher(for: \.isMuted)
      .receive(on: RunLoop.main)
      .sink { [weak self, weak item] _ in
        guard let self, let item, self.generation == token,
          self.player.currentItem === item else { return }
        let enabled = !self.player.isMuted
        if self.isSoundEnabled != enabled { self.isSoundEnabled = enabled }
      }
    // Observe native pause/play actions independently of position updates.
    audioRateSubscription = player.publisher(for: \.rate)
      .receive(on: RunLoop.main)
      .sink { [weak self, weak item] _ in
        guard let self, let item, self.generation == token,
          self.player.currentItem === item else { return }
        self.synchronizePlayingState()
        self.observePosition(item, token: token)
      }
  }

  private func observeProgress(_ item: AVPlayerItem, token: UUID,
    lifetime: VideoPlaybackMonitorLifetime) {
    observePosition(item, token: token)
    // Stepping capabilities are fixed once the item is ready. Status events
    // also report decode failures without a timer polling paused players.
    itemStatusSubscription = item.publisher(for: \.status)
      .receive(on: RunLoop.main).sink { [weak self, weak item] _ in
        guard let self, let item, self.generation == token,
          self.player.currentItem === item else { return }
        self.updateSteppingAvailability()
        if item.status == .failed { lifetime.finish(.failure(item.error ?? AVError(.unknown))) }
      }
    playerStatusSubscription = player.publisher(for: \.status)
      .receive(on: RunLoop.main).sink { [weak self, weak item] _ in
        guard let self, let item, self.generation == token,
          self.player.currentItem === item else { return }
        if self.player.status == .failed {
          lifetime.finish(.failure(item.error ?? self.player.error ?? AVError(.unknown)))
        }
      }
  }

  private func observePosition(_ item: AVPlayerItem, token: UUID) {
    // AVPlayer intervals use media time. Keep the previous ~60ms wall-clock
    // cadence at slow/fast speeds; a paused item's clock does not tick.
    let rate = Double(abs(player.rate))
    let interval = 0.06 * (rate.isFinite && rate > 0 ? rate : 1)
    guard positionObserverInterval != interval else { return }
    if let positionObserver { player.removeTimeObserver(positionObserver) }
    positionObserverInterval = interval
    positionObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: interval, preferredTimescale: 60_000),
      queue: .main) { [weak self, weak item] _ in
      MainActor.assumeIsolated {
        guard let self, let item, self.generation == token,
          self.player.currentItem === item else { return }
        if !self.isSeeking { self.synchronizeCurrentTime() }
        self.synchronizePlayingState()
      }
    }
  }

  private func synchronizePlayingState() {
    let playing = player.rate != 0
    if playing, player.currentItem != nil { hasStartedCurrentItem = true }
    if isPlaying != playing { isPlaying = playing }
  }

  private func synchronizeCurrentTime() {
    guard let document else { return }
    let seconds = player.currentTime().seconds
    let actual = seconds.isFinite ? min(document.durationSeconds, max(0, seconds)) : 0
    // @Published emits even for an identical value. Paused videos must not
    // invalidate the SwiftUI hierarchy on every 60ms monitoring tick.
    if currentSeconds != actual { currentSeconds = actual }
  }

  private func updateSteppingAvailability() {
    guard !isSeeking, let document, document.pixelWidth > 0,
      let item = player.currentItem, item.status == .readyToPlay else {
      if canStepForward { canStepForward = false }
      if canStepBackward { canStepBackward = false }
      return
    }
    let forward = item.canStepForward
    let backward = item.canStepBackward
    if canStepForward != forward { canStepForward = forward }
    if canStepBackward != backward { canStepBackward = backward }
  }
}
