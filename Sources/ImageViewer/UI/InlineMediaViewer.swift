import AppKit
import SwiftUI

/// A map selection or comparison pane owns only its current visible player.
/// Reuse the main viewer's dwell policy, session sound and bounded poster cache.
struct InlineMediaViewer: View {
  @ObservedObject var store: AppStore
  let asset: ImageAsset
  let allowsPlayback: Bool
  var hasSoundFocus = true
  var onSelect: () -> Void = {}
  var onDisplayedAssetChange: ((ImageAsset?) -> Void)?
  @StateObject private var playback: VideoGridPlaybackState

  init(store: AppStore, asset: ImageAsset, allowsPlayback: Bool, hasSoundFocus: Bool = true,
    onSelect: @escaping () -> Void = {}, onDisplayedAssetChange: ((ImageAsset?) -> Void)? = nil) {
    self.store = store
    self.asset = asset
    self.allowsPlayback = allowsPlayback
    self.hasSoundFocus = hasSoundFocus
    self.onSelect = onSelect
    self.onDisplayedAssetChange = onDisplayedAssetChange
    _playback = StateObject(wrappedValue: VideoGridPlaybackState(soundSession: store.mediaSoundSession))
  }

  var body: some View {
    GeometryReader { geometry in
    VStack(spacing: 0) {
      VideoViewerTile(asset: asset, itemCount: 1,
        thumbnailPipeline: store.thumbnailPipeline,
        allowsPlayback: allowsPlayback,
        onOpenTools: {}, allowsEditingTools: false,
        onOpenFullScreen: { seconds, muted in
          store.openVideoFullScreen(asset, at: seconds, isMuted: muted)
        },
        onDisplayedAssetChange: onDisplayedAssetChange,
        gridPlayback: playback, tracksSinglePlayback: true, onSelect: onSelect,
        usesCompactPlaybackControls: geometry.size.height < 220)
      if geometry.size.height >= 220 {
        SingleMediaPlaybackControls(state: playback, asset: asset,
        autoplay: $store.automaticallyPlaysSingleMedia,
        isEnabled: allowsPlayback, showsShortcutHint: false, onSoundInteraction: onSelect)
      }
    }
    }
    .onChange(of: asset, initial: true) { _, _ in updatePlayback() }
    .onChange(of: store.automaticallyPlaysSingleMedia) { _, _ in updatePlayback() }
    .onChange(of: hasSoundFocus) { _, focused in playback.setSessionSoundFocus(focused) }
    .onChange(of: allowsPlayback, initial: true) { _, allowed in
      if !allowed { playback.cancelPendingSingleAutoplay() }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
      playback.cancelPendingSingleAutoplay()
    }
    .onDisappear { playback.reset() }
  }

  private func updatePlayback() {
    playback.setSessionSoundFocus(hasSoundFocus)
    playback.updateVisibleAssets([asset], singleAutoplay: store.automaticallyPlaysSingleMedia)
    if !allowsPlayback { playback.cancelPendingSingleAutoplay() }
  }
}
