import AppKit
import SwiftUI

private struct ViewerPrefetchRequest: Hashable {
  let assets: [ImageAsset]
  let previewPixels: Int
}

struct ViewerCanvas: View {
  @ObservedObject var store: AppStore
  @ObservedObject var shortcuts: ShortcutStore

  @Environment(\.displayScale) private var displayScale
  @GestureState private var liveMagnification: CGFloat = 1
  @GestureState private var livePan: CGSize = .zero
  @State private var controlsVisible = true
  @State private var controlsDismissed = false

  var body: some View {
    VStack(spacing: 0) {
      imageArea
        .environment(\.colorScheme, .dark)
      if !store.isFocusMode {
        Divider()
        BottomControlBar(store: store, shortcuts: shortcuts)
      }
    }
    .onChange(of: store.isFocusMode) { _, _ in
      controlsDismissed = false
      controlsVisible = true
    }
  }

  private func focusImageCanvas() {
    // Clicking a photo ends search-field editing so subsequent Space/arrows
    // control the photo instead of an offscreen or previously active field.
    guard let window = NSApp.keyWindow, window.firstResponder is NSTextView else { return }
    window.makeFirstResponder(nil)
  }

  private var imageArea: some View {
    GeometryReader { geometry in
      let visible = store.visibleAssets
      let columnCount = ViewerGridLayout.columnCount(
        itemCount: visible.count,
        containerSize: geometry.size
      )
      let columns = Array(
        repeating: GridItem(.flexible(minimum: 1), spacing: 3),
        count: columnCount
      )
      let rowCount = max(1, Int(ceil(Double(visible.count) / Double(max(columnCount, 1)))))
      let rowSpacing = CGFloat(max(0, rowCount - 1)) * 3
      let tileHeight = max(1, (geometry.size.height - rowSpacing - 6) / CGFloat(rowCount))
      let tileWidth = max(
        1, (geometry.size.width - 6 - CGFloat(max(0, columnCount - 1)) * 3)
          / CGFloat(max(1, columnCount)))
      let renderPixels = ImageLoadingPolicy.requestedPixels(
        tileSize: store.comparisonLayout.paneSize(in: CGSize(width: tileWidth, height: tileHeight)),
        displayScale: displayScale,
        zoom: store.zoom,
        actualPixels: store.baseScaleMode == .actualPixels,
        itemCount: visible.count,
        physicalMemory: ProcessInfo.processInfo.physicalMemory
      )
      let prefetchRequest = ViewerPrefetchRequest(
        assets: visible, previewPixels: ImageLoadingPolicy.previewPixels(for: renderPixels))
      let canPan = store.canPan
      let usesPrimaryDrag = store.panInteractionMode == .primaryDrag
      let showsTileBoundary = ViewerTileChrome.showsBoundary(itemCount: visible.count)

      ZStack {
        ViewerTheme.canvas

        LazyVGrid(columns: columns, spacing: 3) {
          ForEach(visible) { asset in
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
              effectivePan: CGSize(
                width: store.panOffset.width + (canPan && usesPrimaryDrag ? livePan.width : 0),
                height: store.panOffset.height + (canPan && usesPrimaryDrag ? livePan.height : 0)
              ),
              showsTileBoundary: showsTileBoundary,
              highlightsSelection: ViewerTileChrome.highlightsSelection(
                isCurrent: asset.id == store.currentAsset?.id,
                itemCount: visible.count
              ),
              onPresentationReady: { store.slideshowAssetPresented($0) },
              onExitFocus: store.isFocusMode && asset.id == visible.first?.id
                ? { store.exitFocusMode() } : nil,
              onShowControls: store.isFocusMode && controlsDismissed && asset.id == visible.first?.id
                ? {
                  withAnimation(.easeOut(duration: 0.16)) {
                    controlsDismissed = false
                    controlsVisible = true
                  }
                } : nil
            )
            // GeometryReader는 LazyVGrid 안에서 고유 높이가 없으므로 행 수로
            // 높이를 명시해야 이미지가 캔버스 전체를 채웁니다.
            .frame(height: tileHeight)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
              focusImageCanvas()
              store.toggleImageFocus(on: asset)
            }
            .onTapGesture {
              focusImageCanvas()
              // 활성 이미지를 클릭할 때 비교 중의 배율과 팬 위치가 초기화되지 않게 합니다.
              if asset.id != store.currentAsset?.id { store.select(asset: asset) }
            }
          }
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

        VStack {
          Spacer()
          if store.isFocusMode && controlsVisible && !controlsDismissed {
            BottomControlBar(store: store, shortcuts: shortcuts, onHideControls: {
              // Explicit dismissal survives hover and photo navigation until reopened.
              withAnimation(.easeOut(duration: 0.16)) { controlsDismissed = true }
            })
              .frame(maxWidth: 740)
              .clipShape(RoundedRectangle(cornerRadius: 10))
              .overlay { RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12)) }
              .transition(.opacity)
              .padding(16)
          }
        }

        if let message = store.statusMessage {
          Text(message)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .transition(.opacity)
        }
      }
      .contentShape(Rectangle())
      .task(id: prefetchRequest) {
        store.updateViewerPrefetchSize(prefetchRequest.previewPixels)
      }
      .simultaneousGesture(magnificationGesture)
      .simultaneousGesture(dragGesture(canPan: canPan, usesPrimaryDrag: usesPrimaryDrag))
      .onHover { isInside in
        withAnimation(.easeOut(duration: 0.16)) {
          controlsVisible = isInside
        }
      }
    }
  }

  private var magnificationGesture: some Gesture {
    MagnificationGesture()
      .updating($liveMagnification) { value, state, _ in
        state = value
      }
      .onEnded { value in
        store.updateZoom(with: value)
      }
  }

  private func dragGesture(canPan: Bool, usesPrimaryDrag: Bool) -> some Gesture {
    DragGesture(minimumDistance: 2)
      .updating($livePan) { value, state, _ in
        if canPan, usesPrimaryDrag { state = value.translation }
      }
      .onEnded { value in
        if canPan, usesPrimaryDrag {
          store.updatePan(by: value.translation)
        } else if !canPan, abs(value.translation.width) > 80,
          abs(value.translation.width) > abs(value.translation.height) * 1.4
        {
          store.navigatePage(value.translation.width < 0 ? 1 : -1)
        }
      }
  }
}
