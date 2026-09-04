import SwiftUI

struct ViewerCanvas: View {
  @ObservedObject var store: AppStore

  @GestureState private var liveMagnification: CGFloat = 1
  @GestureState private var livePan: CGSize = .zero
  @State private var controlsVisible = true

  var body: some View {
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
      let canPan = store.canPan
      let usesPrimaryDrag = store.panInteractionMode == .primaryDrag
      let showsTileBoundary = ViewerTileChrome.showsBoundary(itemCount: visible.count)

      ZStack {
        Color.black

        LazyVGrid(columns: columns, spacing: 3) {
          ForEach(visible) { asset in
            ViewerImageTile(
              asset: asset,
              thumbnailPipeline: store.thumbnailPipeline,
              pipeline: store.pipeline,
              adjustments: store.adjustments(for: asset),
              prefersHDR: store.prefersHDR,
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
              )
            )
            // GeometryReader는 LazyVGrid 안에서 고유 높이가 없으므로 행 수로
            // 높이를 명시해야 이미지가 캔버스 전체를 채웁니다.
            .frame(height: tileHeight)
            .contentShape(Rectangle())
            .onTapGesture {
              store.select(asset: asset)
            }
          }
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

        VStack {
          Spacer()
          if controlsVisible || !store.isFocusMode {
            BottomControlBar(store: store)
              .transition(.opacity.combined(with: .move(edge: .bottom)))
              .padding(.bottom, 18)
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
