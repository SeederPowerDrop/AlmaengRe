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
  @State private var poster: CGImage?
  @State private var posterFailureReason: String?
  @State private var posterRequestID = UUID()
  @State private var playbackFailure: (asset: ImageAsset, reason: String)?
  @State private var isHovered = false
  @State private var appIsActive = NSApp.isActive
  @State private var study: VideoStudySession?

  private var isMultiTile: Bool { itemCount > 1 }
  private var retainedPlaybackFailureReason: String? {
    playbackFailure?.asset == asset ? playbackFailure?.reason : nil
  }
  private var request: VideoTilePlaybackRequest {
    VideoTilePlaybackRequest(asset: asset, isMultiTile: isMultiTile,
      isHovered: isHovered, allowsPlayback: allowsPlayback, appIsActive: appIsActive,
      command: gridPlayback.command(for: asset.id), slideshowPlaybackID: slideshowPlaybackID)
  }

  var body: some View {
    VStack(spacing: 0) {
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
          Button { gridPlayback.togglePlayback(asset.id) } label: {
            Image(systemName: gridPlayback.playingIDs.contains(asset.id) ? "pause.fill" : "play.fill")
          }
          .disabled(!allowsPlayback)
          .help(MediaPlaybackL10n.text(gridPlayback.playingIDs.contains(asset.id) ? "grid.pause" : "grid.play"))
          .accessibilityLabel(MediaPlaybackL10n.text(gridPlayback.playingIDs.contains(asset.id) ? "grid.pause" : "grid.play") + " " + asset.filename)
          .accessibilityIdentifier("video.play.\(asset.id.absoluteString)")
        }
        Label(asset.filename, systemImage: "film")
          .lineLimit(1).truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let photoMarkStore, photoMarkStore.isPhotoMarking {
          PhotoMarkCardMenu(store: photoMarkStore, asset: asset)
        }
        if let study {
          VideoStudyControls(session: study).disabled(!allowsPlayback)
        }
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
      .buttonStyle(.borderless)
      .font(.caption).foregroundStyle(.white).padding(10).background(.black)

      ZStack {
        posterSurface
          .contentShape(Rectangle())
          .onTapGesture(count: 2, perform: openFullScreen)
          .onTapGesture(perform: onSelect)
        if let playback = controller.playback {
          VideoTilePlayerSurface(playback: playback, isMultiTile: isMultiTile,
            isInteractive: allowsPlayback && appIsActive,
            isSoundEnabled: controller.isSoundEnabled,
            onToggleSound: {
              controller.noteExplicitSoundChoice(gridPlayback.audioID != asset.id)
              gridPlayback.toggleSound(asset.id)
            },
            onOpenFullScreen: openFullScreen,
            onSelect: onSelect,
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
              if playbackFailure?.asset == asset { playbackFailure = nil }
              onReady(asset)
              onDisplayedAssetChange?(asset)
            })
        } else if let reason = retainedPlaybackFailureReason {
          // Hover releases its player when the pointer leaves. Keep the reason
          // on this asset even when a successfully cached poster is still shown.
          failureNotice(title: MotionMediaL10n.text("video.unavailable"), reason: reason)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .padding(16)
            .allowsHitTesting(false)
            .accessibilityIdentifier("video.failure.retained")
        }
        if isMultiTile && controller.playback == nil && posterFailureReason == nil
          && retainedPlaybackFailureReason == nil && !gridPlayback.usesExplicitPlayback {
          VStack {
            Spacer()
            Label(MotionMediaL10n.text("video.preview.hover"), systemImage: "play.fill")
              .font(.caption).lineLimit(1)
              .padding(.horizontal, 9).padding(.vertical, 6)
              .background(.black.opacity(0.65), in: Capsule())
              .padding(10)
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
    .onChange(of: request, initial: true) { _, request in
      controller.update(asset: request.asset, isMultiTile: request.isMultiTile,
        isHovered: request.isHovered, allowsPlayback: request.allowsPlayback,
        appIsActive: request.appIsActive, command: request.command,
        slideshowPlaybackID: request.slideshowPlaybackID)
    }
    .task(id: asset) {
      study = VideoStudySession.session(for: asset.url)
      onDisplayedAssetChange?(nil)
      let requestID = UUID()
      posterRequestID = requestID
      poster = nil
      posterFailureReason = nil
      playbackFailure = nil
      do {
        let image = try await thumbnailPipeline.browsingThumbnail(for: asset,
          maxPixelSize: min(1_024, max(256, posterPixelSize)))
        try Task.checkCancellation()
        guard posterRequestID == requestID else { return }
        poster = image
        onReady(asset)
        onDisplayedAssetChange?(asset)
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, posterRequestID == requestID else { return }
        let reason = await MediaLoadFailure.message(for: error, url: asset.url)
        guard !Task.isCancelled, posterRequestID == requestID else { return }
        posterFailureReason = reason
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      appIsActive = true
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
      appIsActive = false
    }
    .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
      appIsActive = false
    }
    .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
      appIsActive = NSApp.isActive
    }
    .onAppear { appIsActive = NSApp.isActive }
    .onDisappear {
      controller.stop()
      isHovered = false
      onDisplayedAssetChange?(nil)
    }
  }

  private var posterSurface: some View {
    Color.black.overlay {
      if let poster {
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

  private func failureNotice(title: String, reason: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: "film").font(.title2)
      Text(title).font(.callout.weight(.semibold)).lineLimit(2)
      Text(reason).font(.caption).lineLimit(3)
    }
    .multilineTextAlignment(.center)
    .foregroundStyle(.white.opacity(0.75))
    .frame(maxWidth: 360)
    .padding(16)
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
    guard allowsPlayback else { return }
    let position = controller.pauseForFullScreen()
    onOpenFullScreen(position.seconds, position.isMuted)
  }
}

private struct VideoTilePlayerSurface: View {
  @ObservedObject var playback: VideoPlaybackState
  let isMultiTile: Bool
  let isInteractive: Bool
  let isSoundEnabled: Bool
  let onToggleSound: () -> Void
  let onOpenFullScreen: () -> Void
  let onSelect: () -> Void
  let onEnded: (UUID?) -> Void
  let onFailed: (String) -> Void
  let onReady: () -> Void

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      if let error = playback.errorMessage {
        ContentUnavailableView(MotionMediaL10n.text("video.unavailable"),
          systemImage: "film", description: Text(error))
          .environment(\.colorScheme, .dark)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.black)
          .accessibilityIdentifier("video.failure.current")
      } else if playback.document != nil {
        if isMultiTile {
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
      if isMultiTile {
        Button(action: onToggleSound) {
          Image(systemName: isSoundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 32, height: 32)
            .foregroundStyle(.white)
            .background(.black.opacity(0.7), in: Circle())
        }
        .buttonStyle(.plain)
        .help(MotionMediaL10n.text(isSoundEnabled ? "video.preview.mute" : "video.preview.unmute"))
        .accessibilityLabel(MotionMediaL10n.text(isSoundEnabled ? "video.preview.mute" : "video.preview.unmute"))
        .accessibilityIdentifier("video.preview.sound")
        .disabled(!isInteractive || playback.document?.hasAudio != true)
        .padding(10)
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
  }
}
