import Combine
import Foundation

struct VideoTilePlaybackCommand: Equatable {
  enum Mode: Equatable { case hover, paused, playing }
  var mode: Mode = .hover
  var isMuted = true
  var generation: UUID? = nil
}

/// Explicit playback belongs to the visible page; an image can share that page
/// without participating. Only one video may own audible playback at a time.
@MainActor
final class VideoGridPlaybackState: ObservableObject {
  @Published private(set) var selectedIDs: Set<URL> = []
  @Published private(set) var playingIDs: Set<URL> = []
  @Published private(set) var audioID: URL?
  @Published private(set) var usesExplicitPlayback = false
  @Published private(set) var generation = UUID()
  private var visibleIDs: Set<URL> = []

  func updateVisibleAssets(_ assets: [ImageAsset]) {
    let ids = Set(assets.filter(\.isVideo).map(\.id))
    guard ids != visibleIDs else { return }
    visibleIDs = ids
    selectedIDs.formIntersection(ids)
    playingIDs.formIntersection(ids)
    if let audioID, !playingIDs.contains(audioID) { self.audioID = nil }
    // A new page starts with lightweight hover previews, never hidden players.
    if playingIDs.isEmpty { usesExplicitPlayback = false }
  }

  func toggleSelection(_ id: URL) {
    guard visibleIDs.contains(id) else { return }
    if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
  }

  func playAll() { play(visibleIDs) }
  func playSelected() { play(selectedIDs.intersection(visibleIDs)) }

  func togglePlayback(_ id: URL) {
    guard visibleIDs.contains(id) else { return }
    usesExplicitPlayback = true
    generation = UUID()
    if !playingIDs.insert(id).inserted {
      playingIDs.remove(id)
      if audioID == id { audioID = nil }
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
    visibleIDs.removeAll()
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
    generation = UUID()
  }
}
