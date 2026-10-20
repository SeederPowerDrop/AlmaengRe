import SwiftUI

/// A dedicated playback row sits above navigation and zoom, with full-size targets.
struct VideoGridPlaybackControls: View {
  @ObservedObject var state: VideoGridPlaybackState
  let visibleAssets: [ImageAsset]

  private var videos: [ImageAsset] { visibleAssets.filter(\.isPlaybackMedia) }

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
    .viewerFrame(maxWidth: .infinity)
    .viewerPadding(.horizontal, 16)
    .viewerPadding(.vertical, 10)
    .background(ViewerTheme.chromeGradient)
    .accessibilityElement(children: .contain)
    .onChange(of: visibleAssets, initial: true) { _, assets in state.updateVisibleAssets(assets) }
  }

  private var playAllButton: some View {
    Button { state.playAll() } label: {
      actionLabel(playAllKey, systemImage: state.followsPages
        ? "checkmark.circle.fill" : "play.rectangle.on.rectangle.fill")
    }
    .buttonStyle(ViewerActionButtonStyle(prominent: true))
    .disabled(videos.isEmpty && !state.followsPages)
    .help(MediaPlaybackL10n.text(playAllKey + ".help"))
    .accessibilityAddTraits(state.followsPages ? .isSelected : [])
    .accessibilityIdentifier("video.grid.playAll")
  }

  private var playAllKey: String {
    state.followsPages ? "grid.pageAutoplayOn"
      : state.canEnablePageAutoplay ? "grid.playNextPages" : "grid.playAll"
  }

  private var playSelectedButton: some View {
    Button { state.playSelected() } label: {
      Label(MediaPlaybackL10n.format("grid.playSelected", state.selectedIDs.count), systemImage: "checkmark.rectangle.stack")
        .font(ViewerUIMetrics.font(size: 14, weight: .semibold))
        .viewerFrame(minHeight: 42)
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
    .disabled(videos.isEmpty && !state.followsPages)
    .accessibilityIdentifier("video.grid.pauseAll")
  }

  private func actionLabel(_ key: String, systemImage: String) -> some View {
    Label(MediaPlaybackL10n.text(key), systemImage: systemImage)
      .font(ViewerUIMetrics.font(size: 14, weight: .semibold))
      .viewerFrame(minHeight: 42)
      .fixedSize()
  }
}
