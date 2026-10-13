import SwiftUI

/// During a drag only the overlay's position changes. No bitmap decoding, text
/// layout, or full-photo compositing is scheduled for individual pointer events.
struct WatermarkPlacementPreview: View {
  let source: CGImage
  let result: WatermarkRenderResult?
  let proposedPosition: WatermarkPoint?
  let isEnabled: Bool
  let onDrop: (WatermarkPoint, Bool) -> Void
  @GestureState private var dragOffset = CGSize.zero

  var body: some View {
    GeometryReader { geometry in
      let originalSize = CGSize(width: source.width, height: source.height)
      let originalRect = CGRect(origin: .zero, size: originalSize)
      let layout = result?.layout
      let mapping = WatermarkPreviewGeometry(originalSize: originalSize,
        canvasBounds: layout?.canvasBounds ?? originalRect, stageSize: geometry.size)
      let photoRect = mapping.stageRect(for: originalRect)
      let canvasRect = mapping.stageRect(for: mapping.canvasBounds)
      ZStack(alignment: .topLeading) {
        Color.black.opacity(0.92)
        Rectangle().fill(Color.gray.opacity(0.2))
          .overlay(Rectangle().stroke(Color.white.opacity(0.3), lineWidth: 1))
          .frame(width: canvasRect.width, height: canvasRect.height)
          .position(x: canvasRect.midX, y: canvasRect.midY)
        // The border identifies the original photo even when the output expands.
        Image(decorative: source, scale: 1).resizable()
          .frame(width: photoRect.width, height: photoRect.height)
          .position(x: photoRect.midX, y: photoRect.midY)
        if let layout, let watermarkImage = result?.watermarkImage, isEnabled {
          let rect = proposedPosition.map {
            WatermarkPreviewGeometry.rect(center: $0, overlaySize: layout.effectiveRect.size,
              originalSize: originalSize)
          } ?? layout.effectiveRect
          let markRect = mapping.stageRect(for: rect)
          Image(decorative: watermarkImage, scale: 1).resizable()
            .frame(width: markRect.width, height: markRect.height)
            .overlay(Rectangle().stroke(Color.accentColor.opacity(0.9),
              style: StrokeStyle(lineWidth: 1, dash: [5, 3])))
            .contentShape(Rectangle())
            .position(x: markRect.midX + dragOffset.width, y: markRect.midY + dragOffset.height)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("watermarkStage"))
              .updating($dragOffset) { value, state, _ in state = value.translation }
              .onEnded { drag in
                let point = mapping.movedPosition(rect: rect, translation: drag.translation)
                let proposed = WatermarkPreviewGeometry.rect(center: point,
                  overlaySize: rect.size, originalSize: originalSize)
                onDrop(point, !originalRect.contains(proposed))
              })
            .accessibilityLabel(WatermarkL10n.text("drag.help"))
            .help(WatermarkL10n.text("drag.help"))
        }
      }
      .coordinateSpace(name: "watermarkStage")
      .clipShape(RoundedRectangle(cornerRadius: 10))
    }
  }
}
