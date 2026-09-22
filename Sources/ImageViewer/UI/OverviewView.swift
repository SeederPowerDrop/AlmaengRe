import AppKit
import SwiftUI

struct OverviewView: View {
  @ObservedObject var store: AppStore
  @State private var cellFrames: [URL: CGRect] = [:]
  @State private var selectionRectangle: CGRect?
  @State private var dragID: UUID?
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
                OverviewThumbnailCell(store: store, index: index, asset: asset, size: size)
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
              cellFrames = frames
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
      }

      Divider()

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          Image(systemName: "photo")
          Slider(
            value: $store.thumbnailSize,
            in: OverviewThumbnailSizing.range
          )
          .frame(minWidth: 60, maxWidth: 160)
          .accessibilityLabel(L10n.text("썸네일 크기"))
          .accessibilityValue(L10n.format("%.1f pt", Double(store.thumbnailSize)))
          Image(systemName: "photo.fill")
          numberToggle
          Text(L10n.format("%.1f pt", Double(store.thumbnailSize)))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 44, alignment: .trailing)
          Spacer()
          BatchActionsMenu(store: store)

          Button {
            store.presentBatchRename()
          } label: {
            Label(L10n.text("이름 변경"), systemImage: "pencil.line")
          }
          .disabled(!store.canStartBatchOperation)

          Button {
            store.presentBatchExport()
          } label: {
            Label(L10n.text("형식 변환"), systemImage: "photo.on.rectangle.angled")
          }
          .disabled(!store.canStartBatchOperation)

          Text(store.positionDescription)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 10) {
          Image(systemName: "photo")
          Slider(
            value: $store.thumbnailSize,
            in: OverviewThumbnailSizing.range
          )
          .frame(minWidth: 40, maxWidth: 100)
          .accessibilityLabel(L10n.text("썸네일 크기"))
          .accessibilityValue(L10n.format("%.1f pt", Double(store.thumbnailSize)))
          Spacer(minLength: 0)
          numberToggle
          BatchActionsMenu(store: store)
        }
      }
      .font(.system(size: 12))
      .controlSize(.small)
      .padding(.horizontal, 16)
      .frame(height: 48)
      .background(ViewerTheme.panel)
    }
    .background(ViewerTheme.chrome)
    .onChange(of: store.thumbnailSize) { _, _ in cancelMarquee() }
    .onChange(of: store.showsOverviewNumbers) { _, _ in cancelMarquee() }
    .onChange(of: store.libraryRevision) { _, _ in
      cancelMarquee()
      cellFrames = [:]
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
    .onDisappear { cancelMarquee() }
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
      dragID, hits: OverviewMarqueeGeometry.hits(in: selectionRectangle, frames: cellFrames))
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

private struct OverviewCellFramesKey: PreferenceKey {
  static let defaultValue: [URL: CGRect] = [:]
  static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
  }
}
