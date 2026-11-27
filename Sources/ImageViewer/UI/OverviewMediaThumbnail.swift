import SwiftUI

/// The accepted thumbnail stays underneath the preview, including while the
/// native video surface is waiting for its first frame.
struct OverviewMediaThumbnail<Poster: View>: View {
  let asset: ImageAsset
  @ObservedObject var preview: OverviewMediaPreviewState
  var pointSize: CGFloat = 180
  @ViewBuilder let poster: () -> Poster

  private var ownsPreview: Bool { preview.owns(asset) }
  private var hasPlayer: Bool { ownsPreview && preview.playback != nil }
  private var controlSide: CGFloat { min(32, max(16, pointSize * 0.38)) }
  private var help: String {
    if ownsPreview, let error = preview.errorMessage { return error }
    return MediaPlaybackL10n.text(asset.isAudio ? "overview.audio.preview.help" : "overview.video.preview.help")
  }

  var body: some View {
    poster()
      .overlay {
        if ownsPreview, let playback = preview.playback {
          OverviewActiveMediaSurface(asset: asset, playback: playback)
            .allowsHitTesting(false)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        Button { preview.toggle(asset) } label: {
          Image(systemName: hasPlayer ? "stop.fill" : "play.fill")
            .font(ViewerUIMetrics.font(size: min(14, max(9, controlSide * 0.5)), weight: .semibold))
            .viewerFrame(width: controlSide, height: controlSide)
            .foregroundStyle(.white)
            .background(.black.opacity(0.78), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { preview.hover(asset, isInside: $0) }
        .help(help)
        .disabled(!preview.isEnabled)
        .accessibilityLabel(MediaPlaybackL10n.text(hasPlayer ? "overview.preview.stop" : "overview.preview.play"))
        .accessibilityIdentifier("overview.media.preview.\(asset.sessionID)")
        .viewerPadding(min(6, controlSide * 0.15))
      }
      .onChange(of: VideoTilePosterRequest(asset: asset, maxPixelSize: 256)) { old, new in
        if !old.hasSameSource(as: new) { preview.end(old.asset) }
      }
      .onDisappear { preview.end(asset) }
  }
}

private struct OverviewActiveMediaSurface: View {
  let asset: ImageAsset
  @ObservedObject var playback: VideoPlaybackState

  var body: some View {
    if asset.isAudio {
      OverviewAudioArtwork(fileExtension: asset.fileExtension, isPlaying: playback.isPlaying)
    } else {
      NativeVideoPlayerView(player: playback.player, isInteractive: false,
        showsFullScreenToggleButton: false, waitsForFirstVideoFrame: true)
        .accessibilityHidden(true)
    }
  }
}

/// Format and a large audio symbol identify even a silent/stopped file without
/// reading its contents. Only the one playing card gets an animated indicator.
struct OverviewAudioArtwork: View {
  let fileExtension: String
  var isPlaying = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      let side = min(geometry.size.width, geometry.size.height)
      VStack(spacing: max(4, side * 0.035)) {
        Group {
          if isPlaying && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 15)) { timeline in
              AudioPlaybackIndicator(phase: timeline.date.timeIntervalSinceReferenceDate)
            }
          } else {
            Image(systemName: "waveform")
              .font(ViewerUIMetrics.font(size: max(12, min(52, side * 0.28)), weight: .semibold))
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
        .frame(width: side * 0.62, height: side * 0.33)
        .foregroundStyle(Color(red: 0.65, green: 0.84, blue: 1))
        .accessibilityHidden(true)
        if side >= 64 {
          Text(fileExtension.uppercased())
            .font(ViewerUIMetrics.font(size: max(13, min(32, side * 0.19)), weight: .bold, design: .rounded))
            .lineLimit(1).minimumScaleFactor(0.5)
        }
        if side >= 110 {
          Text(MediaPlaybackL10n.text("overview.audio.file"))
            .font(ViewerUIMetrics.font(.caption))
            .lineLimit(1).minimumScaleFactor(0.5)
            .foregroundStyle(.white.opacity(0.8))
        }
      }
      .padding(.horizontal, max(6, side * 0.08))
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .foregroundStyle(.white)
    .background(LinearGradient(colors: [Color(red: 0.10, green: 0.20, blue: 0.36),
      Color(red: 0.16, green: 0.12, blue: 0.30)], startPoint: .topLeading, endPoint: .bottomTrailing))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(MediaPlaybackL10n.text("overview.audio.file") + " " + fileExtension.uppercased())
  }
}

/// A playback activity indicator, not a measured amplitude trace. No audio
/// samples are decoded for visualization; the timeline exists only while playing.
struct AudioPlaybackIndicator: View {
  let phase: TimeInterval

  var body: some View {
    Canvas { context, size in
      let count = 11
      let step = size.width / CGFloat(count)
      let width = max(2, step * 0.5)
      for index in 0..<count {
        let motion = (sin(phase * 6 + Double(index) * 0.73) + 1) / 2
        let height = max(3, size.height * (0.18 + 0.82 * motion))
        let rect = CGRect(x: CGFloat(index) * step + (step - width) / 2,
          y: (size.height - height) / 2, width: width, height: height)
        context.fill(Path(roundedRect: rect, cornerRadius: width / 2),
          with: .color(Color(red: 0.65, green: 0.84, blue: 1)))
      }
    }
  }
}
