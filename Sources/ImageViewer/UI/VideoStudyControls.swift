import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Study controls share a per-video session with the dedicated fullscreen player.
/// They do not own a player, decode images, or start playback when opened.
struct VideoStudyControls: View {
  @ObservedObject var session: VideoStudySession
  @State private var showsSubtitles = false

  var body: some View {
    HStack(spacing: 8) {
      Menu {
        Picker(MotionMediaL10n.text("study.speed"), selection: $session.playbackRate) {
          ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4], id: \.self) { rate in
            Text(rate.formatted(.number.precision(.fractionLength(0...2))) + "×").tag(rate)
          }
        }
      } label: {
        Text(session.playbackRate.formatted(.number.precision(.fractionLength(0...2))) + "×")
          .monospacedDigit().viewerFrame(minWidth: 36, minHeight: 28)
      }
      .menuStyle(.borderlessButton).fixedSize()
      .help(MotionMediaL10n.text("study.speed"))
      .accessibilityLabel(MotionMediaL10n.text("study.speed"))
      .accessibilityValue(String(session.playbackRate))
      .accessibilityIdentifier("video.study.speed")
      Button { showsSubtitles.toggle() } label: {
        Label(MotionMediaL10n.text("study.subtitles"), systemImage: "captions.bubble")
          .viewerFrame(minHeight: 28)
      }
      .buttonStyle(.borderless)
      .accessibilityIdentifier("video.study.subtitles")
      .popover(isPresented: $showsSubtitles) {
        VideoSubtitleSettings(session: session)
      }
    }
    .font(ViewerUIMetrics.font(size: 13, weight: .medium))
    .task { SubtitleFontCatalog.shared.prepare() }
  }
}

struct VideoSubtitleSettings: View {
  @ObservedObject var session: VideoStudySession
  @Environment(\.colorScheme) private var colorScheme

  // Explicit opaque colors also reset the white foreground inherited from the
  // video header. Material/vibrancy must never blend these controls with video.
  private var background: Color { Color(white: colorScheme == .dark ? 0.14 : 0.97) }
  private var foreground: Color { Color(white: colorScheme == .dark ? 0.95 : 0.10) }
  private var card: Color { Color(white: colorScheme == .dark ? 0.20 : 1) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text(MotionMediaL10n.text("study.dual")).font(ViewerUIMetrics.font(size: 17, weight: .semibold))
        Text(MotionMediaL10n.text("study.formats"))
          .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
        Text(MotionMediaL10n.text("study.automaticHint"))
          .font(ViewerUIMetrics.font(size: 12)).foregroundStyle(.secondary)
        HStack(alignment: .top, spacing: 14) {
          VideoSubtitleSlotSettings(slot: session.primary, sidecars: session.sidecarURLs,
            title: MotionMediaL10n.text("study.primary"))
            .viewerPadding(12).background(card, in: RoundedRectangle(cornerRadius: 10))
          VideoSubtitleSlotSettings(slot: session.secondary, sidecars: session.sidecarURLs,
            title: MotionMediaL10n.text("study.secondary"))
            .viewerPadding(12).background(card, in: RoundedRectangle(cornerRadius: 10))
        }
        if session.isDiscovering { ProgressView().controlSize(.small) }
        if let error = session.sidecarErrorMessage {
          Text(error).font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
        }
        Text(MotionMediaL10n.text("study.sessionHint"))
          .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
      }
      .viewerPadding(20)
    }
    .viewerFrame(width: 660, height: 580)
    .foregroundStyle(foreground)
    .background(background)
    .buttonStyle(.bordered)
    .accessibilityIdentifier("video.subtitle.settings")
    .task { await session.discoverSidecars() }
  }
}

private struct VideoSubtitleSlotSettings: View {
  @ObservedObject var slot: VideoSubtitleSlot
  let sidecars: [URL]
  let title: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle(title, isOn: $slot.isEnabled).font(ViewerUIMetrics.font(.headline))
        .accessibilityIdentifier("video.subtitle.\(slot.id).enabled")
      HStack {
        Menu {
          Button(MotionMediaL10n.text("study.open"), action: chooseFile)
          if !sidecars.isEmpty {
            Divider()
            ForEach(sidecars, id: \.self) { url in
              Button(url.lastPathComponent) { slot.load(url: url) }
            }
          }
        } label: {
          Label(MotionMediaL10n.text("study.choose"), systemImage: "folder")
        }
        .accessibilityIdentifier("video.subtitle.\(slot.id).open")
        Button { slot.remove() } label: { Image(systemName: "trash") }
          .help(MotionMediaL10n.text("study.remove"))
          .accessibilityLabel(MotionMediaL10n.text("study.remove"))
          .disabled(slot.sourceURL == nil && !slot.isLoading)
      }
      Text(slot.sourceURL?.lastPathComponent ?? MotionMediaL10n.text("study.none"))
        .font(ViewerUIMetrics.font(.caption)).lineLimit(2).truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
      if slot.isLoading { ProgressView().controlSize(.small) }
      if let error = slot.errorMessage {
        Text(error).font(ViewerUIMetrics.font(.caption)).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let document = slot.document, document.tracks.count > 1 {
        Picker(MotionMediaL10n.text("study.track"), selection: $slot.trackID) {
          ForEach(document.tracks, id: \.id) { track in
            Text(track.name).tag(Optional(track.id))
          }
        }
      }
      Divider()
      Text(MotionMediaL10n.text("study.sync")).font(ViewerUIMetrics.font(.subheadline).weight(.medium))
      HStack(spacing: 5) {
        Button { slot.offsetSeconds -= 0.1 } label: { Image(systemName: "minus") }
          .accessibilityLabel(MotionMediaL10n.text("study.earlier"))
        TextField("", value: $slot.offsetSeconds,
          format: .number.precision(.fractionLength(1...3)))
          .textFieldStyle(.roundedBorder).viewerFrame(minWidth: 54)
          .accessibilityLabel(title + " " + MotionMediaL10n.text("study.sync"))
        Text("s").foregroundStyle(.secondary)
        Button { slot.offsetSeconds += 0.1 } label: { Image(systemName: "plus") }
          .accessibilityLabel(MotionMediaL10n.text("study.later"))
        Button { slot.offsetSeconds = 0 } label: { Image(systemName: "arrow.counterclockwise") }
          .help(MotionMediaL10n.text("study.reset"))
          .accessibilityLabel(MotionMediaL10n.text("study.reset"))
      }
      Text(MotionMediaL10n.text("study.syncHint")).font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
      HStack(spacing: 8) {
        Text(MotionMediaL10n.text("study.font"))
        SubtitleFontPicker(selection: $slot.fontName,
          accessibilityID: "video.subtitle.\(slot.id).font")
          .viewerFrame(height: 26)
      }
      HStack {
        Text(MotionMediaL10n.text("study.size"))
        Slider(value: $slot.fontSize, in: 12...96, step: 1)
          .accessibilityLabel(title + " " + MotionMediaL10n.text("study.size"))
        Text(Int(slot.fontSize).formatted()).monospacedDigit().viewerFrame(width: 26)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(MotionMediaL10n.text("study.horizontal"))
        Slider(value: $slot.horizontalPosition, in: 0...1)
          .accessibilityLabel(title + " " + MotionMediaL10n.text("study.horizontal"))
        Text(MotionMediaL10n.text("study.vertical"))
        Slider(value: $slot.verticalPosition, in: 0...1)
          .accessibilityLabel(title + " " + MotionMediaL10n.text("study.vertical"))
      }
      Button(MotionMediaL10n.text("study.resetStyle")) {
        slot.fontName = ""
        slot.fontSize = 24
        slot.horizontalPosition = 0.5
        slot.verticalPosition = slot.id == .primary ? 0.84 : 0.72
      }
    }
    .font(ViewerUIMetrics.font(size: 13))
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private func chooseFile() {
    let panel = NSOpenPanel()
    panel.title = title
    panel.message = MotionMediaL10n.text("study.formats")
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = ["srt", "vtt", "smi", "sami"].compactMap { UTType(filenameExtension: $0) }
    // AVPlayer remains paused when the panel moves focus out of fullscreen.
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      slot.load(url: url)
    }
  }
}

struct StudyVideoPlayerView: View {
  @ObservedObject var playback: VideoPlaybackState
  var isInteractive = true
  var onDoubleClick: (() -> Void)? = nil

  var body: some View {
    NativeVideoPlayerView(player: playback.player, isInteractive: isInteractive,
      onDoubleClick: onDoubleClick, showsFullScreenToggleButton: false)
      .overlay {
        if let session = playback.study, let document = playback.document {
          VideoSubtitleOverlay(session: session, seconds: playback.currentSeconds,
            videoSize: document.pixelSize)
        }
      }
  }
}

struct VideoSubtitleOverlay: View {
  @ObservedObject var session: VideoStudySession
  let seconds: Double
  let videoSize: CGSize

  var body: some View {
    GeometryReader { geometry in
      let rect = Self.videoRect(size: videoSize, in: geometry.size)
      ZStack {
        VideoSubtitleLine(slot: session.primary, seconds: seconds)
        VideoSubtitleLine(slot: session.secondary, seconds: seconds)
      }
      .frame(width: rect.width, height: rect.height)
      .position(x: rect.midX, y: rect.midY)
    }
    .allowsHitTesting(false)
  }

  static func videoRect(size: CGSize, in bounds: CGSize) -> CGRect {
    guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
    let scale = min(bounds.width / size.width, bounds.height / size.height)
    let fitted = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2,
      width: fitted.width, height: fitted.height)
  }
}

private struct VideoSubtitleLine: View {
  @ObservedObject var slot: VideoSubtitleSlot
  let seconds: Double

  var body: some View {
    if let text = slot.text(at: seconds), !text.isEmpty {
      SubtitlePlacement(horizontal: slot.horizontalPosition, vertical: slot.verticalPosition) {
        Text(text)
          .font(slot.fontName.isEmpty ? .system(size: slot.fontSize, weight: .medium)
            : .custom(slot.fontName, size: slot.fontSize))
          .multilineTextAlignment(.center)
          .foregroundStyle(.white)
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 4))
          .accessibilityIdentifier("video.subtitle.\(slot.id).text")
      }
    }
  }
}

/// Use measured text bounds so either axis can move the subtitle without putting
/// it beyond the fitted video rectangle, including portrait videos/letterboxing.
private struct SubtitlePlacement: Layout {
  let horizontal: Double
  let vertical: Double

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for view in subviews {
      let available = CGSize(width: max(0, bounds.width - 16), height: max(0, bounds.height - 16))
      let size = view.sizeThatFits(ProposedViewSize(width: available.width, height: nil))
      let fitted = CGSize(width: min(available.width, size.width), height: min(available.height, size.height))
      let x = bounds.minX + 8 + (available.width - fitted.width) * min(1, max(0, horizontal))
      let y = bounds.minY + 8 + (available.height - fitted.height) * min(1, max(0, vertical))
      view.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
        proposal: ProposedViewSize(width: fitted.width, height: fitted.height))
    }
  }
}
