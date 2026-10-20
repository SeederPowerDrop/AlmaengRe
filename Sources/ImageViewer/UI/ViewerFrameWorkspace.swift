import AppKit
import SwiftUI

/// Geometry moves around stable source slots. Reordering never rebinds a
/// decoded photo or a running video to a different slot's state.
struct ViewerFrameWorkspace<Content: View>: View {
  @ObservedObject var layout: ViewerFrameLayoutStore
  let count: Int
  let content: (Int, CGSize) -> Content
  @Environment(\.layoutDirection) private var textDirection
  @State private var movingSlot: Int?
  @State private var moveLocation: CGPoint?
  @State private var targetSlot: Int?
  @State private var resizeStart: ViewerFrameLayoutConfiguration?
  @State private var resizeSize: CGSize?
  @State private var resizeCount: Int?
  @State private var activeDivider: String?

  init(layout: ViewerFrameLayoutStore, count: Int,
    @ViewBuilder content: @escaping (Int, CGSize) -> Content) {
    self.layout = layout
    self.count = count
    self.content = content
  }

  private var editing: Bool { layout.isEditing && count > 1 }
  private var headerHeight: CGFloat { editing ? ViewerUIMetrics.scale(28) : 0 }

  var body: some View {
    GeometryReader { proxy in
      let geometry = layout.geometry(for: count, in: proxy.size)
      ZStack(alignment: .topLeading) {
        ForEach(geometry.frames, id: \.slot) { frame in
          VStack(spacing: 0) {
            if editing { moveHandle(slot: frame.slot, geometry: geometry) }
            content(frame.slot, CGSize(width: frame.rect.width,
              height: max(1, frame.rect.height - headerHeight)))
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .allowsHitTesting(!editing)
          }
          .environment(\.layoutDirection, textDirection)
          .frame(width: frame.rect.width, height: frame.rect.height)
          .clipped()
          .overlay {
            if editing {
              Rectangle().stroke(targetSlot == frame.slot ? Color.accentColor : .white.opacity(0.2),
                lineWidth: targetSlot == frame.slot ? 3 : 1)
                .allowsHitTesting(false)
            }
          }
          .opacity(movingSlot == frame.slot ? 0.65 : 1)
          .position(x: frame.rect.midX, y: frame.rect.midY)
          .accessibilityIdentifier("viewer.frame.\(frame.slot)")
        }

        if editing {
          ForEach(geometry.dividers, id: \.id) { divider in
            dividerHandle(divider, size: proxy.size)
          }
        }
        if let movingSlot, let moveLocation {
          Label("\(movingSlot + 1)", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
            .font(ViewerUIMetrics.font(size: 13, weight: .semibold))
            .viewerPadding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .position(x: min(max(moveLocation.x, 30), max(30, proxy.size.width - 30)),
              y: min(max(moveLocation.y, 20), max(20, proxy.size.height - 20)))
            .allowsHitTesting(false)
        }
      }
      // Frame positions have physical meaning; changing the UI language must
      // not mirror or reorder the user's photographs.
      .environment(\.layoutDirection, .leftToRight)
      .frame(width: proxy.size.width, height: proxy.size.height)
      .coordinateSpace(name: "viewerFrameWorkspace")
      .onChange(of: count) { _, _ in clearGesture() }
      .onChange(of: editing) { _, _ in clearGesture() }
      .onDisappear { clearGesture() }
    }
  }

  private func moveHandle(slot: Int, geometry: ViewerFrameLayoutGeometry) -> some View {
    HStack(spacing: 6) {
      HStack(spacing: 5) {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
        Text(verbatim: "\(slot + 1)").monospacedDigit()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .help(FrameLayoutL10n.text("move.help"))
      .accessibilityLabel(FrameLayoutL10n.format("move.accessibility", slot + 1))
      .accessibilityIdentifier("viewer.frame.move.\(slot)")
      .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("viewerFrameWorkspace"))
        .onChanged { value in
          movingSlot = slot
          moveLocation = value.location
          targetSlot = geometry.frames.first { $0.slot != slot && $0.rect.contains(value.location) }?.slot
        }
        .onEnded { value in
          let target = geometry.frames.first { $0.slot != slot && $0.rect.contains(value.location) }?.slot
          if let target { withAnimation(.easeOut(duration: 0.16)) { layout.swap(slot, with: target, count: count) } }
          clearGesture()
        })
      Menu {
        ForEach((0..<count).filter { $0 != slot }, id: \.self) { other in
          Button(FrameLayoutL10n.format("swap.with", other + 1)) {
            withAnimation(.easeOut(duration: 0.16)) { layout.swap(slot, with: other, count: count) }
          }
        }
      } label: { Image(systemName: "ellipsis") }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      .accessibilityLabel(FrameLayoutL10n.format("move.accessibility", slot + 1))
      .accessibilityIdentifier("viewer.frame.moveMenu.\(slot)")
    }
    .font(ViewerUIMetrics.font(size: 11, weight: .semibold))
    .foregroundStyle(.white)
    .viewerPadding(.horizontal, 9)
    .frame(height: headerHeight)
    .background(Color.accentColor.opacity(0.28))
    .onHover { inside in
      if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
    }
  }

  private func dividerHandle(_ divider: ViewerFrameLayoutDivider, size: CGSize) -> some View {
    let vertical = divider.axis == .vertical
    return RoundedRectangle(cornerRadius: 2)
      .fill(activeDivider == divider.id ? Color.accentColor : .white.opacity(0.25))
      .overlay {
        Capsule().fill(.white.opacity(0.7))
          .frame(width: vertical ? 2 : min(30, divider.rect.width),
            height: vertical ? min(30, divider.rect.height) : 2)
      }
      .contentShape(Rectangle())
      .frame(width: divider.rect.width, height: divider.rect.height)
      .position(x: divider.rect.midX, y: divider.rect.midY)
      .help(FrameLayoutL10n.text(vertical ? "resize.columns" : "resize.rows"))
      .accessibilityLabel(FrameLayoutL10n.text(vertical ? "resize.columns" : "resize.rows"))
      .accessibilityIdentifier("viewer.frame.divider.\(divider.id)")
      .accessibilityAdjustableAction { direction in
        let delta: CGFloat = direction == .increment ? 24 : -24
        let initial = layout.configuration(for: count)
        layout.commit(initial.resizing(divider,
          translation: CGSize(width: vertical ? delta : 0, height: vertical ? 0 : delta), in: size), count: count)
      }
      .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("viewerFrameWorkspace"))
        .onChanged { value in
          if resizeStart == nil {
            resizeStart = layout.configuration(for: count)
            resizeSize = size
            resizeCount = count
            activeDivider = divider.id
          }
          guard let resizeStart, let resizeSize else { return }
          layout.set(resizeStart.resizing(divider, translation: value.translation, in: resizeSize),
            for: count, persist: false)
        }
        .onEnded { value in
          if let resizeStart, let resizeSize {
            layout.commit(resizeStart.resizing(divider, translation: value.translation, in: resizeSize), count: count)
          }
          clearGesture()
        })
      .onHover { inside in
        if inside { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set() }
        else { NSCursor.arrow.set() }
      }
  }

  private func clearGesture() {
    // Escape or a view/count change can finish a pointer gesture before its
    // onEnded callback. Keep the last size the user actually saw.
    if let resizeCount, resizeStart != nil {
      layout.commit(layout.configuration(for: resizeCount), count: resizeCount)
    }
    movingSlot = nil
    moveLocation = nil
    targetSlot = nil
    resizeStart = nil
    resizeSize = nil
    resizeCount = nil
    activeDivider = nil
    NSCursor.arrow.set()
  }
}

struct ViewerFrameEditingBar: View {
  @ObservedObject var layout: ViewerFrameLayoutStore
  let count: Int

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "rectangle.3.group")
        .foregroundStyle(Color.accentColor)
      Text(FrameLayoutL10n.text("editing.help"))
        .font(ViewerUIMetrics.font(.caption))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button(FrameLayoutL10n.text("done")) { layout.isEditing = false }
        .buttonStyle(.borderedProminent)
        .fixedSize()
        .accessibilityIdentifier("viewer.frame.done")
    }
    .viewerPadding(.horizontal, 14).viewerPadding(.vertical, 8)
    .background(ViewerTheme.chromeGradient)
    .accessibilityIdentifier("viewer.frame.editingBar")
  }
}
