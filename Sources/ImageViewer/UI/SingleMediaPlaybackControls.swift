import SwiftUI

struct SingleMediaPlaybackControls: View {
  @ObservedObject var state: VideoGridPlaybackState
  let asset: ImageAsset
  @Binding var autoplay: Bool
  var isEnabled = true
  var showsShortcutHint = true
  var onSoundInteraction: () -> Void = {}

  private var playing: Bool { state.playingIDs.contains(asset.id) }
  private var soundMode: MediaSoundMode { state.soundMode(for: asset.id) }

  var body: some View {
    VStack(spacing: 6) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) { autoplayToggle; playbackButton; soundButton }
          .fixedSize(horizontal: true, vertical: false)
        VStack(spacing: 8) {
          autoplayToggle
          HStack(spacing: 12) { playbackButton; soundButton }
        }
        .fixedSize(horizontal: true, vertical: false)
        VStack(spacing: 8) { autoplayToggle; playbackButton; soundButton }
          .fixedSize(horizontal: true, vertical: false)
      }
      if showsShortcutHint {
        Text(MediaPlaybackL10n.text("single.shortcutHint"))
        .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      }
    }
    .viewerFrame(maxWidth: .infinity)
    .viewerPadding(.horizontal, 16).viewerPadding(.vertical, 8)
    .background(ViewerTheme.chromeGradient)
    .disabled(!isEnabled)
    .accessibilityIdentifier("media.single.controls")
  }

  private var autoplayToggle: some View {
    Toggle(MediaPlaybackL10n.text("single.autoplay"), isOn: $autoplay)
      .toggleStyle(.switch).fixedSize()
      .help(MediaPlaybackL10n.text("single.autoplay.help"))
      .accessibilityIdentifier("media.single.autoplay")
  }

  private var playbackButton: some View {
    Button { state.togglePlayback(asset.id) } label: {
      Label(MediaPlaybackL10n.text(playing ? "grid.pause" : "grid.play"),
        systemImage: playing ? "pause.fill" : "play.fill")
        .font(ViewerUIMetrics.font(size: 14, weight: .semibold))
        .viewerFrame(minHeight: 34).fixedSize()
    }
    .buttonStyle(ViewerActionButtonStyle(prominent: true))
    .accessibilityIdentifier("media.single.play")
  }

  private var soundButton: some View {
    Button {
      onSoundInteraction()
      state.cycleSound(asset.id)
    } label: {
      Label(MediaPlaybackL10n.text(soundMode.buttonTitleKey), systemImage: soundMode.symbol)
        .font(ViewerUIMetrics.font(size: 14, weight: .semibold))
        .viewerFrame(minHeight: 34).fixedSize()
    }
    .buttonStyle(ViewerActionButtonStyle(prominent: soundMode == .session))
    .help(MediaPlaybackL10n.text("single.sound.help"))
    .accessibilityValue(MediaPlaybackL10n.text(soundMode.valueKey))
    .accessibilityAddTraits(soundMode == .session ? .isSelected : [])
    .accessibilityIdentifier("media.single.sound")
  }
}

private extension MediaSoundMode {
  var buttonTitleKey: String {
    switch self {
    case .muted: "single.unmute"
    case .currentFile: "single.keepSound"
    case .session: "single.sessionSound"
    }
  }
  var valueKey: String {
    switch self {
    case .muted: "single.sound.muted"
    case .currentFile: "single.sound.current"
    case .session: "single.sessionSound"
    }
  }
  var symbol: String {
    switch self {
    case .muted: "speaker.slash.fill"
    case .currentFile: "speaker.wave.2.fill"
    case .session: "speaker.wave.2.circle.fill"
    }
  }
}

/// Settings and the main viewer share the same persisted preference.
struct SingleMediaPlaybackOptions: View {
  @Binding var autoplay: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(MediaPlaybackL10n.text("single.setting"))
        .fixedSize(horizontal: false, vertical: true)
      Picker(MediaPlaybackL10n.text("single.setting"), selection: $autoplay) {
        Text(MediaPlaybackL10n.text("single.automatic")).tag(true)
        Text(MediaPlaybackL10n.text("single.manual")).tag(false)
      }
      .labelsHidden()
      .frame(maxWidth: .infinity)
      .accessibilityIdentifier("settings.mediaPlayback")
      Text(MediaPlaybackL10n.text("single.autoplay.help"))
        .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
