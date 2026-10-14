import SwiftUI

/// A dedicated playback row sits above navigation and zoom, with full-size targets.
struct VideoGridPlaybackControls: View {
  @ObservedObject var state: VideoGridPlaybackState
  let visibleAssets: [ImageAsset]

  private var videos: [ImageAsset] { visibleAssets.filter(\.isVideo) }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        playAllButton
        playSelectedButton
        pauseButton
      }
      .fixedSize(horizontal: true, vertical: false)
      VStack(spacing: 10) {
        playAllButton
        HStack(spacing: 10) {
          playSelectedButton
          pauseButton
        }
        .fixedSize(horizontal: true, vertical: false)
      }
      // Long translated labels must keep their full-size targets even when the
      // folder sidebar leaves too little room for the two-button second row.
      VStack(spacing: 10) {
        playAllButton
        playSelectedButton
        pauseButton
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(ViewerTheme.chromeGradient)
    .disabled(videos.isEmpty)
    .accessibilityElement(children: .contain)
    .onChange(of: visibleAssets, initial: true) { _, assets in state.updateVisibleAssets(assets) }
  }

  private var playAllButton: some View {
    Button { state.playAll() } label: {
      actionLabel("grid.playAll", systemImage: "play.rectangle.on.rectangle.fill")
    }
    .buttonStyle(ViewerActionButtonStyle(prominent: true))
    .accessibilityIdentifier("video.grid.playAll")
  }

  private var playSelectedButton: some View {
    Button { state.playSelected() } label: {
      Label(MediaPlaybackL10n.format("grid.playSelected", state.selectedIDs.count), systemImage: "checkmark.rectangle.stack")
        .font(.system(size: 14, weight: .semibold))
        .frame(minHeight: 42)
        .fixedSize()
    }
    .buttonStyle(ViewerActionButtonStyle())
    .disabled(state.selectedIDs.isEmpty)
    .accessibilityIdentifier("video.grid.playSelected")
  }

  private var pauseButton: some View {
    Button { state.pauseAll() } label: {
      actionLabel("grid.pauseAll", systemImage: "pause.fill")
    }
    .buttonStyle(ViewerActionButtonStyle())
    .accessibilityIdentifier("video.grid.pauseAll")
  }

  private func actionLabel(_ key: String, systemImage: String) -> some View {
    Label(MediaPlaybackL10n.text(key), systemImage: systemImage)
      .font(.system(size: 14, weight: .semibold))
      .frame(minHeight: 42)
      .fixedSize()
  }
}
