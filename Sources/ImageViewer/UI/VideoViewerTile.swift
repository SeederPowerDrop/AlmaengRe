import AVKit
import SwiftUI

private struct VideoTilePlaybackRequest: Equatable {
  let asset: ImageAsset
  let isMultiTile: Bool
  let isHovered: Bool
  let allowsPlayback: Bool
  let appIsActive: Bool
  let command: VideoTilePlaybackCommand
  let slideshowPlaybackID: UUID?
}

private struct VideoTilePosterInput: Equatable {
  let asset: ImageAsset
  let pixels: Int
}

struct VideoViewerTile: View {
  let asset: ImageAsset
  let itemCount: Int
  let thumbnailPipeline: ThumbnailPipeline
  var posterPixelSize = 768
  let allowsPlayback: Bool
  let onOpenTools: () -> Void
  let onOpenFullScreen: (Double, Bool) -> Void
  var onReady: (ImageAsset) -> Void = { _ in }
  var onDisplayedAssetChange: ((ImageAsset?) -> Void)? = nil
  var photoMarkStore: AppStore? = nil
  var onToggleSelection: (() -> Void)? = nil
  @ObservedObject var gridPlayback = VideoGridPlaybackState()
  var onSelect: () -> Void = {}
  var slideshowPlaybackID: UUID? = nil
  var onSlideshowFinished: (ImageAsset, UUID) -> Void = { _, _ in }
  var onSlideshowFailed: (ImageAsset, UUID) -> Void = { _, _ in }

  @StateObject private var controller = VideoTilePlaybackController()
  @StateObject private var posterLoader = VideoPosterLoader()
  @State private var playbackFailure: (asset: ImageAsset, reason: String)?
  @State private var isHovered = false
  @State private var appIsActive = NSApp.isActive
  @State private var study: VideoStudySession?
  @State private var showsSubtitles = false

  private var isMultiTile: Bool { itemCount > 1 }
  private var posterRequest: VideoTilePosterRequest { VideoTilePosterRequest(asset: asset, maxPixelSize: posterPixelSize) }
  private var poster: CGImage? {
    guard let presentation = posterLoader.presentation,
      presentation.request.hasSameSource(as: posterRequest) else { return nil }
    return presentation.image
  }
  private var posterFailureReason: String? { posterLoader.errorMessage }
  private var retainedPlaybackFailureReason: String? {
    guard let playbackFailure,
      VideoTilePosterRequest(asset: playbackFailure.asset, maxPixelSize: posterPixelSize)
        .hasSameSource(as: posterRequest) else { return nil }
    return playbackFailure.reason
  }
  private var request: VideoTilePlaybackRequest {
    VideoTilePlaybackRequest(asset: asset, isMultiTile: isMultiTile,
      isHovered: isHovered, allowsPlayback: allowsPlayback, appIsActive: appIsActive,
      command: gridPlayback.command(for: asset.id), slideshowPlaybackID: slideshowPlaybackID)
  }

  var body: some View {
    VStack(spacing: 0) {
      ViewThatFits(in: .horizontal) {
        fullHeader
        compactHeader
      }
      .buttonStyle(.borderless)
      .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.white).background(.black)
      // The presentation belongs to the tile, so changing header variants while
      // resizing does not discard an open subtitle settings panel.
      .popover(isPresented: $showsSubtitles) {
        if let study { VideoSubtitleSettings(session: study) }
      }

      ZStack {
        posterSurface
          .contentShape(Rectangle())
          .onTapGesture(count: 2, perform: openFullScreen)
          .onTapGesture(perform: onSelect)
        if let playback = controller.playback {
          VideoTilePlayerSurface(playback: playback, isMultiTile: isMultiTile,
            isAudio: asset.isAudio,
            isInteractive: allowsPlayback && appIsActive,
            isSoundEnabled: controller.isSoundEnabled,
            onToggleSound: {
              controller.noteExplicitSoundChoice(gridPlayback.audioID != asset.id)
              gridPlayback.toggleSound(asset.id)
            },
            onOpenFullScreen: openFullScreen,
            onSelect: onSelect,
            onAudioToggle: {
              if slideshowPlaybackID != nil { playback.togglePlayback() }
              else { gridPlayback.togglePlayback(asset.id) }
            },
            onAudioPlaybackChange: { playing, soundEnabled in
              // A child onChange may still carry its previous interaction or
              // album values. Consult the controller's current lifetime and
              // reject a rate event superseded by a later native action.
              guard controller.acceptsNativeAudioPlaybackChanges,
                let current = controller.playback, current === playback,
                playing == (current.player.rate != 0) else { return }
              gridPlayback.nativeAudioPlaybackChanged(asset.id,
                isPlaying: playing, isSoundEnabled: soundEnabled)
            },
            onAudioSoundChange: { enabled in
              guard controller.acceptsNativeAudioSoundChanges,
                let current = controller.playback, current === playback,
                enabled == !current.player.isMuted else { return }
              gridPlayback.nativeAudioSoundChanged(asset.id, isEnabled: enabled)
            },
            onEnded: { completedSlideshowID in
              gridPlayback.didFinish(asset.id)
              if let completedSlideshowID { onSlideshowFinished(asset, completedSlideshowID) }
            },
            onFailed: { reason in
              playbackFailure = (asset, reason)
              gridPlayback.didFinish(asset.id)
              if let slideshowPlaybackID { onSlideshowFailed(asset, slideshowPlaybackID) }
            },
            onReady: {
              if retainedPlaybackFailureReason != nil { playbackFailure = nil }
              onReady(asset)
              onDisplayedAssetChange?(asset)
            })
        } else if let reason = retainedPlaybackFailureReason {
          // Hover releases its player when the pointer leaves. Keep the reason
          // on this asset even when a successfully cached poster is still shown.
          failureNotice(title: MotionMediaL10n.text(asset.isAudio ? "audio.unavailable" : "video.unavailable"), reason: reason)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .viewerPadding(16)
            .allowsHitTesting(false)
            .accessibilityIdentifier("video.failure.retained")
        }
        if isMultiTile && !asset.isAudio && controller.playback == nil && posterFailureReason == nil
          && retainedPlaybackFailureReason == nil && !gridPlayback.usesExplicitPlayback {
          VStack {
            Spacer()
            Label(MotionMediaL10n.text("video.preview.hover"), systemImage: "play.fill")
              .font(ViewerUIMetrics.font(.caption)).lineLimit(1)
              .viewerPadding(.horizontal, 9).viewerPadding(.vertical, 6)
              .background(.black.opacity(0.65), in: Capsule())
              .viewerPadding(10)
          }
          .foregroundStyle(.white)
          .allowsHitTesting(false)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
    }
    .background(.black)
    .contextMenu {
      if let photoMarkStore { BatchAssetContextMenu(store: photoMarkStore, url: asset.url) }
    }
    .overlay {
      if isMultiTile && (photoMarkStore?.isPhotoMarking == true
        ? photoMarkStore?.selectedURLs.contains(asset.url) == true
        : gridPlayback.selectedIDs.contains(asset.id)) {
        Rectangle().stroke(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
      }
    }
    .onHover { isHovered = $0 }
    .onChange(of: request, initial: true) { old, request in
      if request.asset.isAudio, request.slideshowPlaybackID != nil,
        request.allowsPlayback, request.appIsActive,
        old.slideshowPlaybackID != request.slideshowPlaybackID || controller.playback == nil {
        gridPlayback.nativeAudioSoundChanged(asset.id, isEnabled: true)
      }
      controller.update(asset: request.asset, isMultiTile: request.isMultiTile,
        isHovered: request.isHovered, allowsPlayback: request.allowsPlayback,
        appIsActive: request.appIsActive, command: request.command,
        slideshowPlaybackID: request.slideshowPlaybackID)
    }
    .onChange(of: VideoTilePosterInput(asset: asset, pixels: posterRequest.maxPixelSize), initial: true) { old, _ in
      let previous = VideoTilePosterRequest(asset: old.asset, maxPixelSize: old.pixels)
      if !previous.hasSameSource(as: posterRequest) {
        playbackFailure = nil
        study = asset.isAudio ? nil : VideoStudySession.session(for: asset.url)
      } else if study == nil, !asset.isAudio {
        study = VideoStudySession.session(for: asset.url)
      }
      loadPoster()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      updateApplicationActivity(true)
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
      updateApplicationActivity(false)
    }
    .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
      updateApplicationActivity(false)
    }
    .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
      updateApplicationActivity(NSApp.isActive)
    }
    .onAppear {
      appIsActive = NSApp.isActive
      loadPoster()
    }
    .onDisappear {
      controller.stop()
      posterLoader.stop()
      isHovered = false
      onDisplayedAssetChange?(nil)
    }
  }

  private func loadPoster() {
    posterLoader.load(posterRequest, preview: { [thumbnailPipeline] request in
      try await thumbnailPipeline.browsingThumbnail(for: request.asset, maxPixelSize: request.maxPixelSize)
    }, render: { [thumbnailPipeline] request in
      try await thumbnailPipeline.thumbnail(for: request.asset, maxPixelSize: request.maxPixelSize,
        waitsForStableVisibility: true)
    }, onReady: onReady, onDisplayedAssetChange: onDisplayedAssetChange)
  }

  private func updateApplicationActivity(_ active: Bool) {
    // Update the playback lifetime in the notification callback itself. Waiting
    // for SwiftUI's next layout can misclassify an automatic pause as a native
    // control action and discard the user's intended playback state.
    appIsActive = active
    controller.update(asset: asset, isMultiTile: isMultiTile,
      isHovered: isHovered, allowsPlayback: allowsPlayback,
      appIsActive: active, command: gridPlayback.command(for: asset.id),
      slideshowPlaybackID: slideshowPlaybackID)
  }

  private var fullHeader: some View {
    HStack(spacing: 10) {
      if isMultiTile {
        if let photoMarkStore, photoMarkStore.isPhotoMarking, let onToggleSelection {
          PhotoMarkSelectionToggle(asset: asset,
            isSelected: photoMarkStore.selectedURLs.contains(asset.url),
            action: onToggleSelection)
        }
        Button { gridPlayback.toggleSelection(asset.id) } label: {
          Image(systemName: playbackSelectionSymbol)
        }
        .help(MediaPlaybackL10n.text("grid.select"))
        .accessibilityLabel(MediaPlaybackL10n.text("grid.select") + " " + asset.filename)
        .accessibilityIdentifier("video.select.\(asset.id.absoluteString)")
        .foregroundStyle(gridPlayback.selectedIDs.contains(asset.id) ? Color.accentColor : .white)
        if !asset.isAudio { playButton }
      }
      HStack(spacing: 6) {
        Image(systemName: asset.isAudio ? "waveform" : "film").fixedSize()
          .accessibilityHidden(true)
        Text(asset.filename).lineLimit(1).truncationMode(.middle)
      }
      .foregroundStyle(.white)
      .viewerFrame(minWidth: 60, idealWidth: 160, maxWidth: .infinity, alignment: .leading)
      .help(asset.filename)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(asset.filename)
      if let photoMarkStore, photoMarkStore.isPhotoMarking {
        PhotoMarkCardMenu(store: photoMarkStore, asset: asset)
      }
      if let study, !asset.isAudio {
        VideoTileStudyActions(session: study, showsSubtitles: $showsSubtitles)
          .disabled(!allowsPlayback)
      }
      if !asset.isAudio {
        Button(action: openFullScreen) {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .help(MotionMediaL10n.text("video.fullscreen"))
        .accessibilityLabel(MotionMediaL10n.text("video.fullscreen"))
        .disabled(!allowsPlayback)
        Button(action: onOpenTools) { Image(systemName: "film.stack") }
          .help(MotionMediaL10n.text("editor.open"))
          .accessibilityLabel(MotionMediaL10n.text("editor.open"))
          .disabled(!allowsPlayback)
      }
    }
    .viewerPadding(10)
    .accessibilityIdentifier("video.header.full")
  }

  private var compactHeader: some View {
    HStack(spacing: 6) {
      if isMultiTile && !asset.isAudio { playButton }
      Text(asset.filename)
        .foregroundStyle(.white)
        .lineLimit(1).truncationMode(.middle)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .help(asset.filename)
      if !asset.isAudio || isMultiTile || photoMarkStore?.isPhotoMarking == true {
        Menu {
          if isMultiTile {
            Toggle(MediaPlaybackL10n.text("grid.select"), isOn: Binding(
              get: { gridPlayback.selectedIDs.contains(asset.id) },
              set: { _ in gridPlayback.toggleSelection(asset.id) }))
            if let photoMarkStore, photoMarkStore.isPhotoMarking, let onToggleSelection {
              Toggle(PhotoMarkL10n.format("selection.accessibilityFormat", asset.filename), isOn: Binding(
                get: { photoMarkStore.selectedURLs.contains(asset.url) },
                set: { _ in onToggleSelection() }))
            }
            Divider()
          }
          if let photoMarkStore, photoMarkStore.isPhotoMarking {
            PhotoMarkCardMenu(store: photoMarkStore, asset: asset, inMenu: true)
          }
          if let study, !asset.isAudio {
            VideoTileStudyActions(session: study, showsSubtitles: $showsSubtitles, inMenu: true)
              .disabled(!allowsPlayback)
            Divider()
          }
          if !asset.isAudio {
            Button(action: openFullScreen) {
              Label(MotionMediaL10n.text("video.fullscreen"),
                systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(!allowsPlayback)
            Button(action: onOpenTools) {
              Label(MotionMediaL10n.text("editor.open"), systemImage: "film.stack")
            }
            .disabled(!allowsPlayback)
          }
        } label: {
          Image(systemName: "ellipsis.circle").viewerFrame(width: 18, height: 28)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(FrameLayoutL10n.text("video.more"))
        .accessibilityLabel(FrameLayoutL10n.text("video.more"))
        .accessibilityIdentifier("video.header.more")
      }
    }
    .viewerPadding(.horizontal, 6).viewerPadding(.vertical, 4)
    .accessibilityIdentifier("video.header.compact")
  }

  private var playButton: some View {
    Button { gridPlayback.togglePlayback(asset.id) } label: {
      Image(systemName: gridPlayback.playingIDs.contains(asset.id) ? "pause.fill" : "play.fill")
        .viewerFrame(width: 16, height: 28)
    }
    .disabled(!allowsPlayback)
    .help(MediaPlaybackL10n.text(gridPlayback.playingIDs.contains(asset.id) ? "grid.pause" : "grid.play"))
    .accessibilityLabel(MediaPlaybackL10n.text(gridPlayback.playingIDs.contains(asset.id) ? "grid.pause" : "grid.play") + " " + asset.filename)
    .accessibilityIdentifier("video.play.\(asset.id.absoluteString)")
    .fixedSize()
  }

  private var posterSurface: some View {
    Color.black.overlay {
      if asset.isAudio && retainedPlaybackFailureReason == nil && controller.playback?.errorMessage == nil {
        GeometryReader { geometry in
          VStack(spacing: 16) {
            if geometry.size.height >= ViewerUIMetrics.scale(140) {
              Image(systemName: "waveform").font(ViewerUIMetrics.font(size: 42))
                .foregroundStyle(.white.opacity(0.65))
            }
            audioPlayButton
            if geometry.size.height >= ViewerUIMetrics.scale(190) {
              Text(MotionMediaL10n.text("audio.ready"))
                .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
            }
          }
          .viewerPadding(16)
          .frame(width: geometry.size.width, height: geometry.size.height)
        }
      } else if let poster {
        Image(decorative: poster, scale: 1).resizable().scaledToFit()
      } else if let posterFailureReason {
        // A missing first-frame preview does not mean playback will fail.
        // Leave hover, play and full-screen actions available for this tile.
        if retainedPlaybackFailureReason == nil && controller.playback?.errorMessage == nil {
          failureNotice(title: MediaLoadFailure.text("preview.title"), reason: posterFailureReason)
        }
      } else if retainedPlaybackFailureReason == nil {
        ProgressView().controlSize(.small)
      }
    }
  }

  private var audioPlayButton: some View {
    AudioPlaybackButton(isPlaying: gridPlayback.playingIDs.contains(asset.id),
      isEnabled: allowsPlayback) { gridPlayback.togglePlayback(asset.id) }
  }

  private func failureNotice(title: String, reason: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: asset.isAudio ? "waveform" : "film").font(ViewerUIMetrics.font(.title2))
      Text(title).font(ViewerUIMetrics.font(.callout).weight(.semibold)).lineLimit(2)
      Text(reason).font(ViewerUIMetrics.font(.caption)).lineLimit(3)
    }
    .multilineTextAlignment(.center)
    .foregroundStyle(.white.opacity(0.75))
    .viewerFrame(maxWidth: 360)
    .viewerPadding(16)
    .help(reason)
    .accessibilityElement(children: .combine)
  }

  private var playbackSelectionSymbol: String {
    let selected = gridPlayback.selectedIDs.contains(asset.id)
    if photoMarkStore?.isPhotoMarking == true {
      return selected ? "play.rectangle.fill" : "play.rectangle"
    }
    return selected ? "checkmark.circle.fill" : "circle"
  }

  private func openFullScreen() {
    guard allowsPlayback, !asset.isAudio else { return }
    let position = controller.pauseForFullScreen()
    onOpenFullScreen(position.seconds, position.isMuted)
  }
}

/// A compact fallback keeps long translations and narrow multi-view frames
/// usable without removing the explicit audio play/pause action.
private struct AudioPlaybackButton: View {
  let isPlaying: Bool
  let isEnabled: Bool
  let action: () -> Void
  private var title: String { MotionMediaL10n.text(isPlaying ? "audio.pause" : "audio.play") }
  private var symbol: String { isPlaying ? "pause.fill" : "play.fill" }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      Button(action: action) {
        Label(title, systemImage: symbol)
          .font(ViewerUIMetrics.font(.callout).weight(.semibold))
          .fixedSize(horizontal: true, vertical: false)
          .viewerPadding(.horizontal, 12).viewerPadding(.vertical, 8)
      }
      .fixedSize()
      Button(action: action) {
        Image(systemName: symbol)
          .font(ViewerUIMetrics.font(.callout).weight(.semibold))
          .viewerFrame(width: 32, height: 32)
      }
    }
    .buttonStyle(.borderedProminent)
    .disabled(!isEnabled)
    .help(title)
    .accessibilityLabel(title)
    .accessibilityIdentifier("audio.play")
  }
}

private struct VideoTileStudyActions: View {
  @ObservedObject var session: VideoStudySession
  @Binding var showsSubtitles: Bool
  var inMenu = false

  var body: some View {
    Group {
      if inMenu {
        speedMenu
        subtitlesButton
      } else {
        HStack(spacing: 8) {
          speedMenu
          subtitlesButton
        }
        .fixedSize()
      }
    }
    .font(ViewerUIMetrics.font(size: 13, weight: .medium))
    .task { SubtitleFontCatalog.shared.prepare() }
  }

  private var speedMenu: some View {
    Menu {
      Picker(MotionMediaL10n.text("study.speed"), selection: $session.playbackRate) {
        ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4], id: \.self) { rate in
          Text(rate.formatted(.number.precision(.fractionLength(0...2))) + "×").tag(rate)
        }
      }
    } label: {
      if inMenu {
        Text(MotionMediaL10n.text("study.speed"))
      } else {
        Text(session.playbackRate.formatted(.number.precision(.fractionLength(0...2))) + "×")
          .monospacedDigit().viewerFrame(minWidth: 36, minHeight: 28)
      }
    }
    .menuStyle(.borderlessButton).fixedSize()
    .help(MotionMediaL10n.text("study.speed"))
    .accessibilityLabel(MotionMediaL10n.text("study.speed"))
    .accessibilityValue(String(session.playbackRate))
    .accessibilityIdentifier("video.study.speed")
  }

  private var subtitlesButton: some View {
    Button { showsSubtitles.toggle() } label: {
      Label(MotionMediaL10n.text("study.subtitles"), systemImage: "captions.bubble")
        .lineLimit(1).viewerFrame(minHeight: inMenu ? nil : 28)
    }
    .buttonStyle(.borderless)
    .accessibilityIdentifier("video.study.subtitles")
  }
}

private struct VideoTilePlayerSurface: View {
  @ObservedObject var playback: VideoPlaybackState
  let isMultiTile: Bool
  let isAudio: Bool
  let isInteractive: Bool
  let isSoundEnabled: Bool
  let onToggleSound: () -> Void
  let onOpenFullScreen: () -> Void
  let onSelect: () -> Void
  let onAudioToggle: () -> Void
  let onAudioPlaybackChange: (Bool, Bool) -> Void
  let onAudioSoundChange: (Bool) -> Void
  let onEnded: (UUID?) -> Void
  let onFailed: (String) -> Void
  let onReady: () -> Void

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      if let error = playback.errorMessage {
        ContentUnavailableView(MotionMediaL10n.text(isAudio ? "audio.unavailable" : "video.unavailable"),
          systemImage: isAudio ? "waveform" : "film", description: Text(error))
          .environment(\.colorScheme, .dark)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.black)
          .accessibilityIdentifier("video.failure.current")
      } else if playback.document != nil {
        if isAudio {
          GeometryReader { geometry in
            VStack(spacing: 8) {
              VStack(spacing: 12) {
                if geometry.size.height >= ViewerUIMetrics.scale(210) {
                  Image(systemName: "waveform").font(ViewerUIMetrics.font(size: 42))
                    .foregroundStyle(.white.opacity(0.65))
                }
                audioPlayButton
              }
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              NativeVideoPlayerView(player: playback.player, isInteractive: isInteractive,
                showsFullScreenToggleButton: false, keepsControlsVisibleWhenInactive: true)
                .viewerFrame(height: 64)
                .accessibilityIdentifier("audio.nativePlayer")
            }
            .viewerPadding(12)
            .frame(width: geometry.size.width, height: geometry.size.height)
          }
          .background(.black)
        } else if isMultiTile {
          // The SwiftUI surface owns grid gestures. A native event monitor
          // would also catch double-clicks on the overlaid sound button.
          StudyVideoPlayerView(playback: playback, isInteractive: false)
            .allowsHitTesting(false)
          Color.clear.contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onOpenFullScreen)
            .onTapGesture(perform: onSelect)
        } else {
          StudyVideoPlayerView(playback: playback, isInteractive: isInteractive,
            onDoubleClick: onOpenFullScreen)
        }
      }
      if isMultiTile && !isAudio {
        Button(action: onToggleSound) {
          Image(systemName: isSoundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
            .font(ViewerUIMetrics.font(size: 14, weight: .semibold))
            .viewerFrame(width: 32, height: 32)
            .foregroundStyle(.white)
            .background(.black.opacity(0.7), in: Circle())
        }
        .buttonStyle(.plain)
        .help(MotionMediaL10n.text(isSoundEnabled ? "video.preview.mute" : "video.preview.unmute"))
        .accessibilityLabel(MotionMediaL10n.text(isSoundEnabled ? "video.preview.mute" : "video.preview.unmute"))
        .accessibilityIdentifier("video.preview.sound")
        .disabled(!isInteractive || playback.document?.hasAudio != true)
        .viewerPadding(10)
      }
    }
    .onChange(of: playback.completedPlaybackCount) { old, new in
      if new > old { onEnded(playback.completedSlideshowID) }
    }
    .onChange(of: playback.errorMessage, initial: true) { _, error in
      if let error { onFailed(error) }
    }
    .onChange(of: playback.document, initial: true) { _, document in
      if document != nil { onReady() }
    }
    .onChange(of: playback.isPlaying) { _, playing in
      if isAudio && isInteractive {
        onAudioPlaybackChange(playing, !playback.player.isMuted)
      }
    }
    .onChange(of: playback.isSoundEnabled) { _, enabled in
      if isAudio && isInteractive { onAudioSoundChange(enabled) }
    }
  }

  private var audioPlayButton: some View {
    AudioPlaybackButton(isPlaying: playback.isPlaying, isEnabled: isInteractive, action: onAudioToggle)
  }
}
