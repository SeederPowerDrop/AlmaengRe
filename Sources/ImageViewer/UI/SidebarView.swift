import AppKit
import SwiftUI

/// 폴더의 이미지를 창 가장자리에 세로 또는 가로로 보여 주는 썸네일 패널입니다.
struct SidebarView: View {
  @ObservedObject var store: AppStore
  let placement: ThumbnailPanelPlacement
  var panelWidth: CGFloat = 220
  @StateObject private var visibilityGate: OverviewRefinementGate
  @State private var appliedScrollRequest: SidebarScrollRequest?
  private let observesNativeWindowVisibility: Bool
  private let onBitmapStateApplied: (@MainActor (ThumbnailBitmapStateEvent) -> Void)?

  init(store: AppStore, placement: ThumbnailPanelPlacement, panelWidth: CGFloat = 220,
    visibilityGate: OverviewRefinementGate = OverviewRefinementGate(),
    observesNativeWindowVisibility: Bool = true,
    onBitmapStateApplied: (@MainActor (ThumbnailBitmapStateEvent) -> Void)? = nil) {
    self.store = store
    self.placement = placement
    self.panelWidth = panelWidth
    _visibilityGate = StateObject(wrappedValue: visibilityGate)
    self.observesNativeWindowVisibility = observesNativeWindowVisibility
    self.onBitmapStateApplied = onBitmapStateApplied
  }

  private var focusScrollRequest: SidebarScrollRequest {
    SidebarScrollRequest(focus: OverviewFocusScrollRequest(collectionRevision: store.assetOrderRevision,
      assetID: store.currentAsset?.id), placement: placement)
  }

  var body: some View {
    Group {
      if placement.isHorizontal {
        horizontalPanel
      } else {
        verticalPanel
      }
    }
    .background(ViewerTheme.sidebar)
    .background(alignment: .topLeading) {
      // One panel-level native bridge also sees fully covered inactive windows.
      // Individual rows retain their bitmap and existing quality path on return.
      if observesNativeWindowVisibility {
        OverviewScrollMotionObserver(gate: visibilityGate)
          .frame(width: 0, height: 0)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .onChange(of: placement) { _, _ in appliedScrollRequest = nil }
    .onDisappear {
      appliedScrollRequest = nil
      visibilityGate.stop()
    }
  }

  private var verticalPanel: some View {
    VStack(spacing: 0) {
      folderHeader
        .viewerPadding(.horizontal, 14)
        .viewerPadding(.vertical, 15)
        .background(ViewerTheme.chromeGradient)

      Divider()

      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          LazyVStack(spacing: 4) {
            thumbnailCells(width: 64, height: 52)
          }
          .viewerPadding(8)
        }
        .task(id: focusScrollRequest) { await revealCurrent(with: proxy) }
      }
    }
    .frame(width: panelWidth)
  }

  private var horizontalPanel: some View {
    HStack(spacing: 0) {
      folderHeader
        .frame(width: 160, alignment: .leading)
        .viewerPadding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(ViewerTheme.chromeGradient)

      Divider()

      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          LazyHStack(spacing: 6) {
            thumbnailCells(width: 88, height: 58)
          }
          .viewerPadding(.horizontal, 10)
          .viewerPadding(.vertical, 8)
        }
        .task(id: focusScrollRequest) { await revealCurrent(with: proxy) }
      }
    }
    .frame(height: 112)
  }

  private var folderHeader: some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: "folder")
        .font(ViewerUIMetrics.font(size: 17, weight: .medium))
        .foregroundStyle(ViewerTheme.accent.opacity(0.85))
        .viewerPadding(.top, 1)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(store.activeFolderName)
          .font(ViewerUIMetrics.font(size: 12, weight: .semibold))
          .lineLimit(1)
          .truncationMode(.middle)
          .help(store.activeFolderName)
        Text(MotionMediaL10n.format("items.count", store.assets.count))
          .font(ViewerUIMetrics.font(size: 11))
          .foregroundStyle(.secondary)
          .monospacedDigit()
        if store.selectedURLs.count > 1 {
          Text(L10n.format("%d개 선택", store.selectedURLs.count))
            .font(ViewerUIMetrics.font(size: 11, weight: .medium))
            .foregroundStyle(ViewerTheme.accent)
            .monospacedDigit()
            .viewerPadding(.horizontal, 6)
            .viewerPadding(.vertical, 2)
            .background(ViewerTheme.selection, in: RoundedRectangle(cornerRadius: 4))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      BatchActionsMenu(store: store, compact: true)
        .controlSize(.small)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func thumbnailCells(width: CGFloat, height: CGFloat) -> some View {
    ForEach(OverviewIndexedAssets(store.assets), id: \.element.id) { index, asset in
      let isSelected = store.selectedURLs.contains(asset.url)
      let isCurrent = store.currentIndex == index
      Button {
        store.selectForBatch(index: index, modifiers: NSEvent.modifierFlags)
      } label: {
        Group {
          if placement.isHorizontal {
            VStack(alignment: .leading, spacing: 6) {
              thumbnail(asset: asset, width: width, height: height, isSelected: isSelected)
              Text(asset.filename)
                .font(ViewerUIMetrics.font(size: 10, weight: isCurrent ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: width, alignment: .leading)
            }
          } else {
            HStack(spacing: 10) {
              thumbnail(asset: asset, width: width, height: height, isSelected: isSelected)
              VStack(alignment: .leading, spacing: 5) {
                Text(asset.filename)
                  .font(ViewerUIMetrics.font(size: 11, weight: isCurrent ? .semibold : .medium))
                  .foregroundStyle(.primary)
                  .lineLimit(1)
                  .truncationMode(.middle)
                Text(verbatim: "\(asset.fileExtension.uppercased()) · \(asset.formattedFileSize)")
                  .font(ViewerUIMetrics.font(size: 10))
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                Text(verbatim: "\(index + 1)")
                  .font(ViewerUIMetrics.font(size: 10).monospacedDigit())
                  .foregroundStyle(.tertiary)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        .viewerPadding(7)
        .modifier(SidebarThumbnailRowSurface(isSelected: isSelected, isCurrent: isCurrent))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      .buttonStyle(.plain)
      .contextMenu {
        BatchAssetContextMenu(store: store, url: asset.url)
      }
      .accessibilityLabel(asset.filename)
      .accessibilityValue(L10n.text(isSelected ? "선택됨" : "선택 안 됨"))
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      // 목록 순번은 새 폴더에서도 다시 0부터 시작합니다. 실제 파일 URL을 써야
      // 같은 순번에 있던 이전 폴더의 썸네일 상태가 재사용되지 않습니다.
      .id(asset.id)
      .help(asset.filename)
    }
  }

  private func thumbnail(
    asset: ImageAsset, width: CGFloat, height: CGFloat, isSelected: Bool
  ) -> some View {
    ThumbnailImageView(
      asset: asset,
      thumbnailPipeline: store.thumbnailPipeline,
      pipeline: store.pipeline,
      maxPixelSize: 192,
      defersLoading: visibilityGate.isWindowSuppressed,
      onBitmapStateApplied: onBitmapStateApplied
    )
    .frame(width: width, height: height)
    .background(ViewerTheme.panel, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .strokeBorder(ViewerTheme.controlBorder, lineWidth: 0.5)
        .allowsHitTesting(false)
    }
    .overlay(alignment: .topTrailing) {
      if isSelected && store.selectedURLs.count > 1 {
        Image(systemName: "checkmark.circle.fill")
          .font(ViewerUIMetrics.font(size: 13))
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, ViewerTheme.accent)
          .viewerPadding(3)
          .accessibilityHidden(true)
      }
    }
  }

  private func revealCurrent(with proxy: ScrollViewProxy) async {
    let request = focusScrollRequest
    await Task.yield()
    guard !Task.isCancelled, focusScrollRequest == request,
      appliedScrollRequest != request, let target = request.focus.assetID else { return }
    let animated = appliedScrollRequest?.focus.collectionRevision == request.focus.collectionRevision
      && appliedScrollRequest?.placement == request.placement
    appliedScrollRequest = request
    if animated {
      withAnimation(.easeOut(duration: 0.15)) {
        proxy.scrollTo(target, anchor: .center)
      }
    } else {
      var transaction = Transaction(animation: nil)
      transaction.disablesAnimations = true
      withTransaction(transaction) { proxy.scrollTo(target, anchor: .center) }
    }
  }
}

private struct SidebarScrollRequest: Equatable {
  let focus: OverviewFocusScrollRequest
  let placement: ThumbnailPanelPlacement
}

/// 행의 호버 상태는 셀 안에 두어 커서 이동으로 전체 사진 목록을 갱신하지 않습니다.
private struct SidebarThumbnailRowSurface: ViewModifier {
  let isSelected: Bool
  let isCurrent: Bool
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .background {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(ViewerTheme.panelGradient)
          .opacity(isSelected || isCurrent ? 1 : isHovered ? 0.6 : 0)
          .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(isSelected || isCurrent ? ViewerTheme.selection : Color.clear)
          }
      }
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(
            isCurrent ? ViewerTheme.selectionBorder
              : isSelected ? ViewerTheme.selectionBorder.opacity(0.45)
              : ViewerTheme.controlBorder.opacity(isHovered ? 0.7 : 0), lineWidth: 1)
          .allowsHitTesting(false)
      }
      .onHover { isHovered = $0 }
  }
}
