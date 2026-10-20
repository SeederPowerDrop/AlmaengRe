import AppKit
import SwiftUI

private struct ViewerPrefetchRequest: Hashable {
  let assets: [ImageAsset]
  let previewPixels: Int
}

struct ViewerCanvas: View {
  @ObservedObject var store: AppStore
  @ObservedObject var shortcuts: ShortcutStore
  @ObservedObject private var panState: ViewerPanState
  @ObservedObject private var frameLayout: ViewerFrameLayoutStore
  @ObservedObject private var videoPlayback: VideoGridPlaybackState

  @Environment(\.displayScale) private var displayScale
  @GestureState private var liveMagnification: CGFloat = 1
  @GestureState private var isDragging = false
  @State private var lastDragTranslation: CGSize = .zero
  @State private var hasDragTranslation = false
  @State private var controlsVisible = true
  @State private var controlsDismissed = false

  init(store: AppStore, shortcuts: ShortcutStore) {
    self.store = store
    self.shortcuts = shortcuts
    panState = store.viewerPan
    frameLayout = store.frameLayout
    videoPlayback = store.videoGridPlayback
  }

  var body: some View {
    VStack(spacing: 0) {
      if frameLayout.isEditing && store.visibleAssets.count > 1 {
        ViewerFrameEditingBar(layout: frameLayout, count: store.visibleAssets.count)
      }
      imageArea
        .environment(\.colorScheme, .dark)
      if !store.isFocusMode {
        Divider()
        if showsVideoControls {
          videoControls
          Divider()
        }
        BottomControlBar(store: store, shortcuts: shortcuts)
      }
    }
    .onChange(of: store.isFocusMode) { _, _ in
      controlsDismissed = false
      controlsVisible = true
    }
    .onChange(of: frameLayout.isEditing) { _, editing in
      if editing { store.pauseSlideshow() }
    }
    .onAppear {
      store.beginTrackingViewerPresentation()
      store.videoGridPlayback.updateVisibleAssets(store.visibleAssets)
    }
    .onChange(of: store.visibleAssets) { _, assets in store.videoGridPlayback.updateVisibleAssets(assets) }
    .onDisappear {
      store.endTrackingViewerPresentation()
      store.videoGridPlayback.reset()
    }
  }

  private var showsVideoControls: Bool {
    // Keep the active toggle reachable on photo-only and partial final pages.
    videoPlayback.followsPages ||
      (store.visibleAssets.count > 1 && store.visibleAssets.contains(where: \.isPlaybackMedia))
  }

  private var videoControls: some View {
    VideoGridPlaybackControls(state: store.videoGridPlayback, visibleAssets: store.visibleAssets)
      .disabled(!store.allowsVideoPlayback)
  }

  private func focusImageCanvas() {
    // Clicking a photo ends search-field editing so subsequent Space/arrows
    // control the photo instead of an offscreen or previously active field.
    guard let window = NSApp.keyWindow, window.firstResponder is NSTextView else { return }
    window.makeFirstResponder(nil)
  }

  private func selectAsset(_ asset: ImageAsset, modifiers: NSEvent.ModifierFlags) {
    focusImageCanvas()
    guard let index = store.assets.firstIndex(where: { $0.id == asset.id }) else { return }
    // Clicking an already sole-selected item preserves the zoom and pan. A
    // modifier click, or a plain click within a group, still changes selection.
    if modifiers.intersection([.command, .shift]).isEmpty,
      store.currentAsset?.id == asset.id, store.selectedURLs == [asset.url] { return }
    store.selectForBatch(index: index, modifiers: modifiers)
  }

  private var imageArea: some View {
    GeometryReader { geometry in
      let visible = store.visibleAssets
      let configuration = frameLayout.configuration(for: visible.count)
      let frames = configuration.geometry(in: geometry.size)
      let columnCount = configuration.rows.map { $0.slots.count }.max() ?? 1
      let renderPixels = frames.frames.map {
        requestedRenderPixels(tileSize: $0.rect.size, itemCount: visible.count)
      }.max() ?? 768
      let prefetchRequest = ViewerPrefetchRequest(
        assets: visible, previewPixels: ImageLoadingPolicy.previewPixels(for: renderPixels))
      let canPan = store.canPan
      let usesPrimaryDrag = store.panInteractionMode == .primaryDrag
      let showsTileBoundary = ViewerTileChrome.showsBoundary(itemCount: visible.count)

      ZStack {
        ViewerTheme.canvas

        ViewerFrameWorkspace(layout: frameLayout, count: visible.count) { slot, tileSize in
            let asset = visible[slot]
            let renderPixels = requestedRenderPixels(tileSize: tileSize, itemCount: visible.count)
            Group {
            if asset.isPlaybackMedia {
              VideoViewerTile(asset: asset, itemCount: visible.count,
                thumbnailPipeline: store.thumbnailPipeline, posterPixelSize: renderPixels,
                allowsPlayback: store.allowsVideoPlayback,
                onOpenTools: { store.presentMotionMedia(asset) },
                onOpenFullScreen: { seconds, isMuted in
                  store.openVideoFullScreen(asset, at: seconds, isMuted: isMuted)
                },
                onReady: { store.slideshowAssetPresented($0) },
                onDisplayedAssetChange: {
                  store.recordPresentedAsset($0, slot: slot, requestedAsset: asset)
                },
                photoMarkStore: store,
                onToggleSelection: { selectAsset(asset, modifiers: .command) },
                gridPlayback: store.videoGridPlayback,
                onSelect: {
                  selectAsset(asset, modifiers: NSEvent.modifierFlags)
                },
                slideshowPlaybackID: store.slideshowVideoPlaybackID,
                onSlideshowFinished: { store.slideshowVideoFinished($0, playbackID: $1) },
                onSlideshowFailed: { store.slideshowVideoFailed($0, playbackID: $1) })
            } else {
            ViewerImageTile(
              asset: asset,
              itemCount: visible.count,
              thumbnailPipeline: store.thumbnailPipeline,
              pipeline: store.pipeline,
              adjustments: store.adjustments(for: asset),
              prefersHDR: store.prefersHDR,
              interpolationMode: store.imageInterpolationMode,
              comparisonLayout: store.comparisonLayout,
              filenameDisplaySize: store.filenameDisplaySize,
              baseScaleMode: store.baseScaleMode,
              committedZoom: store.zoom,
              effectiveZoom: store.zoom * liveMagnification,
              effectivePan: panState.offset,
              showsTileBoundary: showsTileBoundary,
              highlightsSelection: ViewerTileChrome.highlightsSelection(
                isCurrent: store.selectedURLs.contains(asset.url),
                itemCount: visible.count
              ),
              onPresentationReady: { store.slideshowAssetPresented($0) },
              onDisplayedAssetChange: { displayedAsset in
                store.recordPresentedAsset(displayedAsset, slot: slot, requestedAsset: asset)
                if let displayedAsset { store.recordRecentlyViewed(displayedAsset) }
              },
              onPanGeometryChange: { store.updateViewerPanGeometry($1, for: $0) },
              isPanReference: asset.id == store.currentAsset?.id,
              onExitFocus: store.isFocusMode && asset.id == visible.first?.id
                ? { store.exitFocusMode() } : nil,
              onShowControls: store.isFocusMode && controlsDismissed && asset.id == visible.first?.id
                ? {
                  withAnimation(.easeOut(duration: 0.16)) {
                    controlsDismissed = false
                    controlsVisible = true
                  }
                } : nil,
              onOpenMotionTools: { store.presentMotionMedia($0) },
              photoMarkStore: store,
              onToggleSelection: { selectAsset(asset, modifiers: .command) }
            )
            }
            }
            .frame(width: tileSize.width, height: tileSize.height)
            .contentShape(Rectangle())
            .gesture(TapGesture(count: 2).onEnded {
              focusImageCanvas()
              store.toggleImageFocus(on: asset)
            }, including: asset.isPlaybackMedia ? .subviews : .all)
            .gesture(TapGesture().onEnded {
              selectAsset(asset, modifiers: NSEvent.modifierFlags)
            }, including: asset.isPlaybackMedia ? .subviews : .all)
        }
        .id(store.assetOrderRevision)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

        VStack {
          Spacer()
          if store.isFocusMode && controlsVisible && !controlsDismissed {
            VStack(spacing: 8) {
              if showsVideoControls {
                videoControls
                  .clipShape(RoundedRectangle(cornerRadius: 12))
                  .overlay { RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12)) }
              }
              BottomControlBar(store: store, shortcuts: shortcuts, onHideControls: {
                // Explicit dismissal survives hover and photo navigation until reopened.
                withAnimation(.easeOut(duration: 0.16)) { controlsDismissed = true }
              })
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12)) }
            }
              .frame(maxWidth: 780)
              .transition(.opacity)
              .viewerPadding(16)
          }
        }

        if let message = store.statusMessage {
          Text(message)
            .viewerPadding(.horizontal, 14)
            .viewerPadding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .transition(.opacity)
        }
      }
      .contentShape(Rectangle())
      .onChange(of: columnCount, initial: true) { _, count in
        store.viewerColumnCount = count
      }
      .onChange(of: geometry.size, initial: true) { _, size in
        store.viewerViewportSize = size
      }
      .task(id: prefetchRequest) {
        store.updateViewerPrefetchSize(prefetchRequest.previewPixels)
      }
      // Disable canvas gestures for video without disabling the tile's buttons.
      // `.none` also suppresses pointer gestures throughout the subview hierarchy.
      .simultaneousGesture(magnificationGesture, including: visible.contains(where: \.isPlaybackMedia) ? .subviews : .all)
      .simultaneousGesture(dragGesture(canPan: canPan, usesPrimaryDrag: usesPrimaryDrag),
        including: visible.contains(where: \.isPlaybackMedia) ? .subviews : .all)
      .onChange(of: isDragging) { _, dragging in
        if !dragging { lastDragTranslation = .zero; hasDragTranslation = false }
      }
      .onHover { isInside in
        withAnimation(.easeOut(duration: 0.16)) {
          controlsVisible = isInside
        }
      }
    }
  }

  private func requestedRenderPixels(tileSize: CGSize, itemCount: Int) -> Int {
    let pixels = ImageLoadingPolicy.requestedPixels(
      tileSize: store.comparisonLayout.paneSize(in: tileSize), displayScale: displayScale,
      zoom: store.zoom, actualPixels: store.baseScaleMode == .actualPixels,
      itemCount: itemCount, physicalMemory: ProcessInfo.processInfo.physicalMemory)
    // Divider movement should not issue a new video-poster request for every pixel.
    return max(128, Int(ceil(Double(pixels) / 128)) * 128)
  }

  private var magnificationGesture: some Gesture {
    MagnificationGesture()
      .updating($liveMagnification) { value, state, _ in
        guard !frameLayout.isEditing else { return }
        state = value
      }
      .onEnded { value in
        guard !frameLayout.isEditing else { return }
        store.updateZoom(with: value)
      }
  }

  private func dragGesture(canPan: Bool, usesPrimaryDrag: Bool) -> some Gesture {
    DragGesture(minimumDistance: 2)
      .updating($isDragging) { _, state, _ in state = true }
      .onChanged { value in
        guard !frameLayout.isEditing else { return }
        let delta = CGSize(width: value.translation.width - lastDragTranslation.width,
          height: value.translation.height - lastDragTranslation.height)
        lastDragTranslation = value.translation
        hasDragTranslation = true
        // Commit bounded deltas while dragging, so reversing at an edge responds immediately.
        if canPan, usesPrimaryDrag { store.updatePan(by: delta) }
      }
      .onEnded { value in
        guard !frameLayout.isEditing else {
          lastDragTranslation = .zero
          hasDragTranslation = false
          return
        }
        if canPan, usesPrimaryDrag, hasDragTranslation {
          store.updatePan(by: CGSize(width: value.translation.width - lastDragTranslation.width,
            height: value.translation.height - lastDragTranslation.height))
        }
        lastDragTranslation = .zero
        hasDragTranslation = false
        if !canPan, abs(value.translation.width) > 80,
          abs(value.translation.width) > abs(value.translation.height) * 1.4
        {
          store.navigatePage(value.translation.width < 0 ? 1 : -1)
        }
      }
  }
}
