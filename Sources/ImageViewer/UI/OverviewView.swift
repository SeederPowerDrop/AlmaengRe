import AppKit
import SwiftUI

struct OverviewView: View {
  @ObservedObject var store: AppStore
  @State private var cellFrames = OverviewCellFrameCache()
  @State private var selectionRectangle: CGRect?
  @State private var dragID: UUID?
  @State private var isAdjustingThumbnailSize = false
  @State private var footerWidth: CGFloat = 0
  @GestureState private var isDragging = false
  @Namespace private var contentSpace

  private func columns(for size: CGFloat) -> [GridItem] {
    [
      GridItem(
        .adaptive(minimum: size + 14, maximum: (size + 14) * 1.35), spacing: 12)
    ]
  }

  var body: some View {
    VStack(spacing: 0) {
      GeometryReader { geometry in
        // 최대 크기를 골라도 사이드바/정보 패널 사이의 좁은 공간을 넘지 않습니다.
        let size = min(store.thumbnailSize, max(1, geometry.size.width - 50))
        ScrollViewReader { proxy in
          ScrollView {
            LazyVGrid(columns: columns(for: size), spacing: 16) {
              ForEach(Array(store.assets.enumerated()), id: \.element.id) { index, asset in
                OverviewThumbnailCell(store: store, index: index, asset: asset, size: size,
                  isAdjustingSize: isAdjustingThumbnailSize)
                  .background {
                    GeometryReader { cell in
                      Color.clear.preference(
                        key: OverviewCellFramesKey.self,
                        value: [asset.id: cell.frame(in: .named(contentSpace))])
                    }
                  }
                  .id(asset.id)
              }
            }
            .padding(18)
            .frame(minHeight: geometry.size.height, alignment: .top)
            .contentShape(Rectangle())
            .coordinateSpace(name: contentSpace)
            .simultaneousGesture(marqueeGesture)
            .overlay(alignment: .topLeading) {
              if let rectangle = selectionRectangle {
                Rectangle()
                  .fill(ViewerTheme.selection)
                  .overlay { Rectangle().stroke(ViewerTheme.accent, lineWidth: 1) }
                  .frame(width: rectangle.width, height: rectangle.height)
                  .offset(x: rectangle.minX, y: rectangle.minY)
                  .allowsHitTesting(false)
                  .accessibilityHidden(true)
              }
            }
            .onPreferenceChange(OverviewCellFramesKey.self) { frames in
              cellFrames.frames = frames
              updateMarqueeSelection()
            }
          }
          .onChange(of: store.currentIndex) { _, newIndex in
            guard dragID == nil else { return }
            scrollToCurrent(newIndex, with: proxy)
          }
          .task(id: store.assets.first?.id) {
            await Task.yield()
            scrollToCurrent(store.currentIndex, with: proxy, animated: false)
          }
          .onChange(of: geometry.size) { _, _ in cancelMarquee() }
        }
        .onChange(of: OverviewGridNavigation.columnCount(
          width: geometry.size.width, thumbnailSize: store.thumbnailSize), initial: true) { _, count in
          store.overviewColumnCount = count
        }
      }

      Divider()

      OverviewFooterLayout {
        overviewControls
        ViewThatFits(in: .horizontal) {
          BatchQuickActionsView(store: store)
          BatchQuickActionsView(store: store, layout: .icons)
          BatchQuickActionsView(store: store, layout: .twoRows)
        }
      }
      .background {
        GeometryReader { geometry in
          Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in
            footerWidth = width
          }
        }
      }
      .font(.system(size: 12))
      .controlSize(.small)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity)
      .background(ViewerTheme.panelGradient)
    }
    .background(ViewerTheme.chromeGradient)
    .onChange(of: store.thumbnailSize) { _, _ in cancelMarquee() }
    .onChange(of: store.showsOverviewNumbers) { _, _ in cancelMarquee() }
    .onChange(of: store.libraryRevision) { _, _ in
      cancelMarquee()
      cellFrames.frames.removeAll(keepingCapacity: true)
    }
    .onChange(of: store.overviewSelectionSession?.id) { _, sessionID in
      if sessionID == nil { selectionRectangle = nil }
    }
    .onChange(of: isDragging) { _, dragging in
      if !dragging {
        // 정상 mouse-up의 onEnded가 먼저 완료하도록 양보한 뒤 취소된 제스처만 복구합니다.
        Task { @MainActor in
          await Task.yield()
          if !isDragging { cancelMarquee(); dragID = nil }
        }
      }
    }
    .onDisappear {
      cancelMarquee()
      isAdjustingThumbnailSize = false
    }
  }

  private var overviewControls: some View {
    HStack(spacing: 8) {
      Image(systemName: "photo")
        .accessibilityHidden(true)
      // Keep one control and a stable track while the grid and footer are remeasured.
      // Replacing ViewThatFits candidates during a drag loses native slider tracking.
      Slider(value: $store.thumbnailSize, in: OverviewThumbnailSizing.range) { editing in
        isAdjustingThumbnailSize = editing
      }
        // Only the available pane width changes the track, never its current value.
        .frame(width: min(140, max(40, footerWidth - 100)))
        .accessibilityLabel(L10n.text("썸네일 크기"))
        .accessibilityValue(L10n.format("%.1f pt", Double(store.thumbnailSize)))
        .accessibilityIdentifier("overview.thumbnailSize")
      numberToggle
      if footerWidth >= 360 {
        Text(L10n.format("%.1f pt", Double(store.thumbnailSize)))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 60, alignment: .trailing)
      }
      Spacer(minLength: 0)
      if footerWidth >= 360 {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) {
            BatchActionsMenu(store: store)
            Text(store.positionDescription)
              .font(.system(size: 11, weight: .medium))
              .monospacedDigit()
              .foregroundStyle(.secondary)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(ViewerTheme.controlFill, in: RoundedRectangle(cornerRadius: 5))
              .fixedSize()
          }
          BatchActionsMenu(store: store, compact: true)
        }
      } else {
        BatchActionsMenu(store: store, compact: true)
      }
    }
  }

  private var numberToggle: some View {
    Toggle(isOn: $store.showsOverviewNumbers) {
      Label("몽땅보기 번호 표시", systemImage: "number")
    }
    .toggleStyle(.button)
    .labelStyle(.iconOnly)
    .help("몽땅보기 번호 표시")
  }

  private var marqueeGesture: some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .named(contentSpace))
      .updating($isDragging) { _, active, _ in active = true }
      .onChanged { value in
        if dragID == nil { dragID = store.beginOverviewSelection(modifiers: NSEvent.modifierFlags) }
        // Esc 뒤에도 mouse-up 전까지 같은 드래그를 다시 시작하지 않습니다.
        guard let dragID, store.overviewSelectionSession?.id == dragID else { return }
        selectionRectangle = OverviewMarqueeGeometry.rectangle(from: value.startLocation, to: value.location)
        updateMarqueeSelection()
      }
      .onEnded { _ in
        if let dragID { store.finishOverviewSelection(dragID) }
        dragID = nil
        selectionRectangle = nil
      }
  }

  private func updateMarqueeSelection() {
    guard let dragID, let selectionRectangle else { return }
    store.updateOverviewSelection(
      dragID, hits: OverviewMarqueeGeometry.hits(in: selectionRectangle, frames: cellFrames.frames))
  }

  private func cancelMarquee() {
    if let dragID { store.cancelOverviewSelection(dragID) }
    selectionRectangle = nil
  }

  private func scrollToCurrent(
    _ index: Int,
    with proxy: ScrollViewProxy,
    animated: Bool = true
  ) {
    guard store.assets.indices.contains(index) else { return }
    let target = store.assets[index].id

    if animated {
      withAnimation(.easeOut(duration: 0.2)) {
        proxy.scrollTo(target, anchor: .center)
      }
    } else {
      proxy.scrollTo(target, anchor: .center)
    }
  }
}

/// Wrap the action row without removing/recreating the slider during layout changes.
private struct OverviewFooterLayout: Layout {
  private let horizontalSpacing: CGFloat = 12
  private let verticalSpacing: CGFloat = 8

  private func sizes(width: CGFloat, subviews: Subviews) -> (controls: CGSize, actions: CGSize, wraps: Bool) {
    let controls = subviews[0].sizeThatFits(.unspecified)
    let actions = subviews[1].sizeThatFits(.unspecified)
    let wraps = controls.width + horizontalSpacing + actions.width > width
    if wraps {
      let proposal = ProposedViewSize(width: width, height: nil)
      return (subviews[0].sizeThatFits(proposal), subviews[1].sizeThatFits(proposal), true)
    }
    return (
      subviews[0].sizeThatFits(ProposedViewSize(width: width - actions.width - horizontalSpacing, height: nil)),
      actions, false)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let idealWidth = subviews[0].sizeThatFits(.unspecified).width
      + horizontalSpacing + subviews[1].sizeThatFits(.unspecified).width
    let width = proposal.width ?? idealWidth
    let measured = sizes(width: width, subviews: subviews)
    return CGSize(width: width, height: measured.wraps
      ? measured.controls.height + verticalSpacing + measured.actions.height
      : max(measured.controls.height, measured.actions.height))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let measured = sizes(width: bounds.width, subviews: subviews)
    subviews[0].place(
      at: CGPoint(x: bounds.minX, y: measured.wraps ? bounds.minY : bounds.midY - measured.controls.height / 2),
      anchor: .topLeading, proposal: ProposedViewSize(measured.controls))
    subviews[1].place(
      at: CGPoint(x: bounds.maxX, y: measured.wraps
        ? bounds.minY + measured.controls.height + verticalSpacing : bounds.midY - measured.actions.height / 2),
      anchor: .topTrailing, proposal: ProposedViewSize(measured.actions))
  }
}

/// Hit-test geometry is not display state. Keep the latest positions for the
/// marquee without invalidating the whole grid whenever a cell finishes loading
/// or moves during scrolling/resizing. The visible selection rectangle stays in State.
@MainActor
private final class OverviewCellFrameCache {
  var frames: [URL: CGRect] = [:]
}

private struct OverviewCellFramesKey: PreferenceKey {
  static let defaultValue: [URL: CGRect] = [:]
  static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
  }
}
