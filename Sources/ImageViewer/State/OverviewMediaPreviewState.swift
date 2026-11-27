import Combine
import Foundation

/// One hover target and at most one decoder for the entire overview. Idle
/// thumbnails own no player, metadata scan, waveform analysis or animation.
@MainActor
final class OverviewMediaPreviewState: ObservableObject {
  @Published private(set) var asset: ImageAsset?
  @Published private(set) var playback: VideoPlaybackState?
  @Published private(set) var errorMessage: String?
  @Published private(set) var isEnabled = false
  private var generation = UUID()
  private var dwell: Task<Void, Never>?
  private var monitor: Task<Void, Never>?
  private var observations: Set<AnyCancellable> = []

  deinit { dwell?.cancel(); monitor?.cancel() }

  func setEnabled(_ enabled: Bool) {
    guard isEnabled != enabled else { return }
    isEnabled = enabled
    if !enabled { stop() }
  }

  func owns(_ candidate: ImageAsset) -> Bool {
    guard let asset else { return false }
    return VideoTilePosterRequest(asset: asset, maxPixelSize: 256)
      .hasSameSource(as: VideoTilePosterRequest(asset: candidate, maxPixelSize: 256))
  }

  func hover(_ candidate: ImageAsset, isInside: Bool) {
    if isInside { request(candidate, delay: .milliseconds(150)) }
    else { end(candidate) }
  }

  /// The same action is available to keyboard and accessibility users.
  func toggle(_ candidate: ImageAsset) {
    if owns(candidate), playback != nil { stop() }
    else { request(candidate, delay: .zero, startsImmediately: true) }
  }

  func end(_ candidate: ImageAsset) {
    if owns(candidate) { stop() }
  }

  func retain(in assets: [ImageAsset]) {
    guard asset != nil else { return }
    if !assets.contains(where: owns) { stop() }
  }

  func stop() {
    generation = UUID()
    dwell?.cancel(); dwell = nil
    monitor?.cancel(); monitor = nil
    observations.removeAll()
    playback?.player.isMuted = true
    playback?.stop()
    playback = nil
    asset = nil
    errorMessage = nil
  }

  private func request(_ candidate: ImageAsset, delay: Duration, startsImmediately: Bool = false) {
    guard isEnabled, candidate.isPlaybackMedia,
      !owns(candidate) || (startsImmediately && playback == nil) else { return }
    stop()
    asset = candidate
    let token = generation
    dwell = Task { [weak self] in
      do { try await Task.sleep(for: delay) } catch { return }
      guard let self, !Task.isCancelled, self.isEnabled,
        self.generation == token, self.owns(candidate) else { return }
      self.dwell = nil
      self.start(candidate, token: token)
    }
  }

  private func start(_ candidate: ImageAsset, token: UUID) {
    let state = VideoPlaybackState()
    // Overview audio preview is deliberately audible; video preview is always
    // muted. Neither changes the viewer's independent session sound choice.
    state.player.isMuted = !candidate.isAudio
    playback = state
    state.$document.compactMap { $0 }.sink { [weak self, weak state] _ in
      Task { @MainActor [weak self, weak state] in
        guard let self, let state, self.generation == token, self.isEnabled,
          self.playback === state, state.player.currentItem != nil else { return }
        state.player.isMuted = !candidate.isAudio
        state.resume()
      }
    }.store(in: &observations)
    state.$completedPlaybackCount.dropFirst().sink { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.generation == token else { return }
        self.stop()
      }
    }.store(in: &observations)
    state.$errorMessage.compactMap { $0 }.sink { [weak self] message in
      Task { @MainActor [weak self] in
        guard let self, self.generation == token else { return }
        self.stop()
        self.asset = candidate
        self.errorMessage = message
      }
    }.store(in: &observations)
    monitor = Task { await state.monitor(candidate) }
  }
}
