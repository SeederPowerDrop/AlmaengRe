import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// The sheet owns a captured source (including archive leases). Every export is
/// a separate file; changing the gallery selection cannot retarget a running job.
struct MotionMediaEditor: View {
  let asset: ImageAsset
  let pipeline: ImagePipeline
  var preparePhotoMarks: @MainActor () async throws -> PhotoMarkExportContext = { .disabled }
  @Environment(\.dismiss) private var dismiss
  @StateObject private var playback = VideoPlaybackState()
  @State private var animation: AnimatedImageDocument?
  @State private var animationFrame: CGImage?
  @State private var frameIndex = 0
  @State private var animationPlaying = false
  @State private var displayedFrameIndex: Int?
  @State private var firstFrame = 1
  @State private var lastFrame = 1
  @State private var startSeconds = 0.0
  @State private var endSeconds = 0.0
  @State private var animationFormat: AnimatedImageExportFormat = .gif
  @State private var videoContainer: VideoContainer = .mp4
  @State private var videoPreset: VideoExportPreset = .highestQuality
  @State private var resizeMode = 0
  @State private var longestEdge = 1280
  @State private var percent = 50.0
  @State private var frameStride = 1
  @State private var errorMessage: String?
  @State private var progress = 0.0
  @State private var isWorking = false
  @State private var outputURL: URL?
  @State private var outputSummary: String?
  @State private var operation: Task<Void, Never>?
  private let animationExporter = AnimatedImageExporter()
  private let videoExporter = VideoExporter()
  private struct AnimationPreviewRequest: Hashable {
    let index: Int
    let playing: Bool
    let count: Int
  }

  private var isReady: Bool { asset.isVideo ? playback.document != nil : animation != nil }
  private var resize: BatchResizeOptions {
    switch resizeMode {
    case 1: .longestEdge(longestEdge)
    case 2: .percentage(percent)
    default: .original
    }
  }
  private var validRange: Bool {
    if let document = playback.document {
      return (try? VideoTimeRange(start: startSeconds, end: endSeconds)
        .validate(durationSeconds: document.durationSeconds)) != nil
    }
    guard let animation else { return false }
    return firstFrame >= 1 && lastFrame >= firstFrame && lastFrame <= animation.frameCount
      && frameStride > 0 && (try? resize.dimensions(width: animation.width, height: animation.height)) != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label(MotionMediaL10n.text("editor.title"), systemImage: "film.stack")
          .font(.title3.weight(.semibold))
        Spacer()
        Text(asset.filename).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
      }
      preview.frame(minHeight: 210, idealHeight: 290, maxHeight: 340)
        .background(.black, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
      playbackControls
        .disabled(!isReady || isWorking)
      Divider()
      exportOptions.disabled(!isReady || isWorking)
      Text(MotionMediaL10n.text(asset.isVideo ? "video.exportHint" : "animation.exportHint"))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let error = errorMessage ?? playback.errorMessage {
        Text(error).font(.caption).foregroundStyle(.red)
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      }
      if isWorking {
        HStack {
          ProgressView(value: progress).frame(maxWidth: .infinity)
          Button(MotionMediaL10n.text("cancel")) { operation?.cancel() }
        }
      } else if let outputURL {
        HStack {
          Text(outputSummary ?? outputURL.lastPathComponent)
            .font(.caption).lineLimit(2).textSelection(.enabled)
          Spacer()
          Button(MotionMediaL10n.text("showInFinder")) {
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
          }
          Button(BatchActionsL10n.text("share.menu")) {
            FileSharingService.shared.share(urls: [outputURL])
          }
        }
      }
      HStack {
        Button(MotionMediaL10n.text("close")) { dismiss() }
          .keyboardShortcut(.cancelAction).disabled(isWorking)
        Spacer()
        Button(MotionMediaL10n.text("frame.extract")) { extractFrame() }
          .disabled(!isReady || isWorking || (asset.isVideo
            ? playback.isSeeking || playback.currentSeconds >= (playback.document?.durationSeconds ?? 0)
            : displayedFrameIndex != frameIndex))
        Button(MotionMediaL10n.text("range.export")) { exportRange() }
          .buttonStyle(.borderedProminent).disabled(!isReady || isWorking || !validRange)
      }
    }
    .padding(20).frame(width: 840)
    .frame(minHeight: 670, idealHeight: 730)
    .interactiveDismissDisabled(isWorking)
    .task {
      if asset.isVideo {
        await playback.monitor(asset)
      } else {
        do {
          let document = try await animationExporter.inspect(url: asset.url)
          try Task.checkCancellation()
          animation = document
          lastFrame = document.frameCount
          animationFormat = document.sourceTypeIdentifier == "public.png" ? .apng : .gif
        } catch {
          let reason = await MediaLoadFailure.message(for: error, url: asset.url)
          guard !Task.isCancelled else { return }
          errorMessage = reason
        }
      }
    }
    .onChange(of: playback.document) { _, document in
      if let document { endSeconds = document.durationSeconds }
    }
    .task(id: AnimationPreviewRequest(index: frameIndex, playing: animationPlaying,
      count: animation?.frameCount ?? 0)) {
      // Hold each successfully decoded frame before advancing. A slow decoder
      // must not be cancelled by a timer on every frame of a large animation.
      let index = frameIndex
      await loadAnimationFrame()
      guard !Task.isCancelled, animationPlaying, let animation,
        displayedFrameIndex == index, frameIndex == index else { return }
      do { try await Task.sleep(for: .seconds(animation.frames[index].duration)) }
      catch { return }
      guard !Task.isCancelled, animationPlaying, frameIndex == index else { return }
      frameIndex = (index + 1) % animation.frameCount
    }
    .onDisappear {
      operation?.cancel()
      animationPlaying = false
      playback.stop()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
      playback.pause()
      animationPlaying = false
    }
    .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
      playback.pause()
      animationPlaying = false
    }
  }

  @ViewBuilder private var preview: some View {
    if asset.isVideo {
      StudyVideoPlayerView(playback: playback, isInteractive: !isWorking)
    } else if let animationFrame {
      Image(decorative: animationFrame, scale: 1)
        .resizable().interpolation(.high).scaledToFit()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var playbackControls: some View {
    HStack(spacing: 12) {
      Button {
        if asset.isVideo { playback.step(-1) }
        else { animationPlaying = false; frameIndex = max(0, frameIndex - 1) }
      } label: { Image(systemName: "backward.frame.fill") }
      .help(MotionMediaL10n.text("frame.previous"))
      .accessibilityLabel(MotionMediaL10n.text("frame.previous"))
      .disabled(asset.isVideo ? !playback.canStepBackward : frameIndex == 0)
      Button {
        if asset.isVideo { playback.togglePlayback() } else { animationPlaying.toggle() }
      } label: {
        Image(systemName: (asset.isVideo ? playback.isPlaying : animationPlaying) ? "pause.fill" : "play.fill")
      }
      .help(MotionMediaL10n.text("playPause"))
      .accessibilityLabel(MotionMediaL10n.text("playPause"))
      Button {
        if asset.isVideo { playback.step(1) }
        else { animationPlaying = false; frameIndex = min((animation?.frameCount ?? 1) - 1, frameIndex + 1) }
      } label: { Image(systemName: "forward.frame.fill") }
      .help(MotionMediaL10n.text("frame.next"))
      .accessibilityLabel(MotionMediaL10n.text("frame.next"))
      .disabled(asset.isVideo ? !playback.canStepForward : frameIndex >= (animation?.frameCount ?? 1) - 1)
      if asset.isVideo {
        if let study = playback.study { VideoStudyControls(session: study) }
        Slider(value: Binding(get: { playback.currentSeconds }, set: { playback.seek($0) }),
          in: 0...max(0.001, playback.document?.durationSeconds ?? 0))
          .accessibilityLabel(MotionMediaL10n.text("position"))
        Text(String(format: "%.3f / %.3f s", playback.currentSeconds, playback.document?.durationSeconds ?? 0))
          .font(.caption.monospacedDigit()).frame(minWidth: 132)
      } else {
        Slider(value: Binding(get: { Double(frameIndex) }, set: { animationPlaying = false; frameIndex = Int($0) }),
          in: 0...Double(max(1, (animation?.frameCount ?? 1) - 1)), step: 1)
          .disabled((animation?.frameCount ?? 1) <= 1)
          .accessibilityLabel(MotionMediaL10n.text("position"))
        Text(MotionMediaL10n.format("frame.position", frameIndex + 1, animation?.frameCount ?? 0))
          .font(.caption.monospacedDigit()).frame(minWidth: 100)
      }
    }
  }

  private var exportOptions: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(MotionMediaL10n.text("range.title")).font(.headline)
        Spacer()
        Button(MotionMediaL10n.text("range.startHere")) {
          animationPlaying = false; playback.pause()
          if asset.isVideo { startSeconds = playback.currentSeconds }
          else { firstFrame = frameIndex + 1 }
        }
        .disabled(asset.isVideo && playback.isSeeking)
        Button(MotionMediaL10n.text("range.endHere")) {
          animationPlaying = false; playback.pause()
          if asset.isVideo { endSeconds = playback.currentSeconds }
          else { lastFrame = frameIndex + 1 }
        }
        .disabled(asset.isVideo && playback.isSeeking)
        Button(MotionMediaL10n.text("range.all")) {
          firstFrame = 1; lastFrame = animation?.frameCount ?? 1
          startSeconds = 0; endSeconds = playback.document?.durationSeconds ?? 0
        }
      }
      HStack {
        if asset.isVideo {
          Text(MotionMediaL10n.text("range.startSeconds"))
          TextField("", value: $startSeconds, format: .number.precision(.fractionLength(0...6)))
            .frame(width: 90).accessibilityLabel(MotionMediaL10n.text("range.startSeconds"))
          Text(MotionMediaL10n.text("range.endSeconds"))
          TextField("", value: $endSeconds, format: .number.precision(.fractionLength(0...6)))
            .frame(width: 90).accessibilityLabel(MotionMediaL10n.text("range.endSeconds"))
        } else {
          Text(MotionMediaL10n.text("range.firstFrame"))
          TextField("", value: $firstFrame, format: .number.grouping(.never))
            .frame(width: 75).accessibilityLabel(MotionMediaL10n.text("range.firstFrame"))
          Text(MotionMediaL10n.text("range.lastFrame"))
          TextField("", value: $lastFrame, format: .number.grouping(.never))
            .frame(width: 75).accessibilityLabel(MotionMediaL10n.text("range.lastFrame"))
        }
        Spacer()
        Button(MotionMediaL10n.text("compress.preset")) {
          if asset.isVideo { videoPreset = .hd720; videoContainer = .mp4 }
          else { resizeMode = 2; percent = 50; frameStride = 2 }
        }
      }
      HStack {
        if asset.isVideo {
          Picker(MotionMediaL10n.text("format"), selection: $videoContainer) {
            ForEach(VideoContainer.allCases) { Text($0.rawValue.uppercased()).tag($0) }
          }.frame(width: 170)
          Picker(MotionMediaL10n.text("quality"), selection: $videoPreset) {
            ForEach(VideoExportPreset.allCases) {
              Text(MotionMediaL10n.text("preset." + $0.rawValue)).tag($0)
            }
          }.frame(width: 290)
        } else {
          Picker(MotionMediaL10n.text("format"), selection: $animationFormat) {
            ForEach(AnimatedImageExportFormat.available) { Text($0.title).tag($0) }
          }.frame(width: 150)
          Picker(MotionMediaL10n.text("size"), selection: $resizeMode) {
            Text(MotionMediaL10n.text("size.original")).tag(0)
            Text(MotionMediaL10n.text("size.longestEdge")).tag(1)
            Text(MotionMediaL10n.text("size.percent")).tag(2)
          }.frame(width: 210)
          if resizeMode == 1 {
            TextField("px", value: $longestEdge, format: .number.grouping(.never)).frame(width: 70)
              .accessibilityLabel(MotionMediaL10n.text("size.longestEdge"))
          } else if resizeMode == 2 {
            TextField("%", value: $percent, format: .number).frame(width: 55)
              .accessibilityLabel(MotionMediaL10n.text("size.percent"))
            Text("%")
          }
          Picker(MotionMediaL10n.text("frames.keep"), selection: $frameStride) {
            Text(MotionMediaL10n.text("frames.all")).tag(1)
            Text(MotionMediaL10n.text("frames.every2")).tag(2)
            Text(MotionMediaL10n.text("frames.every3")).tag(3)
            Text(MotionMediaL10n.text("frames.every4")).tag(4)
          }.frame(width: 220)
        }
        Spacer(minLength: 0)
      }
    }
    .textFieldStyle(.roundedBorder)
  }

  private func loadAnimationFrame() async {
    guard !asset.isVideo, let animation, animation.frames.indices.contains(frameIndex) else { return }
    let index = frameIndex
    do {
      let rendered = try await pipeline.renderFrame(url: asset.url, frameIndex: index,
        maxPixelSize: 1280, adjustments: .identity, prefersHDR: false)
      try Task.checkCancellation()
      guard index == frameIndex else { return }
      animationFrame = rendered.image
      displayedFrameIndex = index
    } catch {
      let reason = await MediaLoadFailure.message(for: error, url: asset.url)
      guard !Task.isCancelled, index == frameIndex else { return }
      errorMessage = reason
    }
  }

  private func destination(extension suffix: String, descriptor: String) -> URL? {
    let panel = NSSavePanel()
    panel.title = MotionMediaL10n.text("saveCopy")
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = asset.url.deletingPathExtension().lastPathComponent + descriptor + "." + suffix
    if let type = UTType(filenameExtension: suffix) { panel.allowedContentTypes = [type] }
    return panel.runModal() == .OK ? panel.url : nil
  }

  private func extractFrame() {
    animationPlaying = false; playback.pause()
    let time = playback.player.currentTime()
    let index = frameIndex
    guard let destination = destination(extension: "png", descriptor: "-frame") else { return }
    beginOperation {
      if asset.isVideo {
        _ = try await videoExporter.extractFrame(from: asset.url, at: time, to: destination)
      } else {
        _ = try await animationExporter.extractFrame(sourceURL: asset.url,
          destinationURL: destination, frameIndex: index)
      }
      return destination
    }
  }

  private func exportRange() {
    guard validRange else { return }
    animationPlaying = false; playback.pause()
    let suffix = asset.isVideo ? videoContainer.fileExtension : animationFormat.fileExtension
    guard let destination = destination(extension: suffix, descriptor: "-clip") else { return }
    let videoOptions = VideoExportOptions(container: videoContainer, preset: videoPreset)
    let range = VideoTimeRange(start: startSeconds, end: endSeconds)
    let imageOptions = AnimatedImageExportOptions(frameRange: (firstFrame - 1)...(lastFrame - 1),
      resize: resize, frameStride: frameStride)
    let format = animationFormat
    beginOperation {
      if asset.isVideo {
        _ = try await videoExporter.export(from: asset.url, range: range, to: destination,
          options: videoOptions) { value in Task { @MainActor in progress = value } }
      } else {
        _ = try await animationExporter.export(sourceURL: asset.url,
          destinationURL: destination, format: format, options: imageOptions) { complete, count in
          Task { @MainActor in progress = Double(complete) / Double(max(1, count)) }
        }
      }
      return destination
    }
  }

  private func beginOperation(_ action: @escaping @MainActor () async throws -> URL) {
    guard !isWorking else { return }
    isWorking = true; progress = 0; errorMessage = nil; outputURL = nil; outputSummary = nil
    operation = Task { @MainActor in
      defer { isWorking = false; operation = nil }
      do {
        let classifications = try await preparePhotoMarks()
        try Task.checkCancellation()
        let result = try await action()
        outputURL = result
        try await classifications.commit([BatchExportItem(sourceURL: asset.url, destinationURL: result)])
        let bytes = (try? result.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        outputSummary = MotionMediaL10n.format("saved", result.lastPathComponent,
          ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
      } catch is CancellationError { errorMessage = MotionMediaL10n.text("cancelled") }
      catch { errorMessage = error.localizedDescription }
    }
  }
}
