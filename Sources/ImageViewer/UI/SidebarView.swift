import AppKit
import SwiftUI

/// 폴더의 이미지를 창 가장자리에 세로 또는 가로로 보여 주는 썸네일 패널입니다.
struct SidebarView: View {
  @ObservedObject var store: AppStore
  let placement: ThumbnailPanelPlacement
  var panelWidth: CGFloat = 220

  var body: some View {
    Group {
      if placement.isHorizontal {
        horizontalPanel
      } else {
        verticalPanel
      }
    }
    .background(ViewerTheme.sidebar)
  }

  private var verticalPanel: some View {
    VStack(spacing: 0) {
      folderHeader
        .padding(.horizontal, 14)
        .padding(.vertical, 15)

      Divider()

      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          LazyVStack(spacing: 4) {
            thumbnailCells(width: 64, height: 52)
          }
          .padding(8)
        }
        .onChange(of: store.currentIndex) { _, newIndex in
          scrollToCurrent(newIndex, with: proxy)
        }
        .task(id: store.assets.first?.id) {
          await Task.yield()
          scrollToCurrent(store.currentIndex, with: proxy, animated: false)
        }
      }
    }
    .frame(width: panelWidth)
  }

  private var horizontalPanel: some View {
    HStack(spacing: 0) {
      folderHeader
        .frame(width: 160, alignment: .leading)
        .padding(.horizontal, 14)

      Divider()

      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          LazyHStack(spacing: 6) {
            thumbnailCells(width: 88, height: 58)
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
        }
        .onChange(of: store.currentIndex) { _, newIndex in
          scrollToCurrent(newIndex, with: proxy)
        }
        .task(id: store.assets.first?.id) {
          await Task.yield()
          scrollToCurrent(store.currentIndex, with: proxy, animated: false)
        }
      }
    }
    .frame(height: 112)
  }

  private var folderHeader: some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: "folder")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.top, 1)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(store.activeFolderName)
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(1)
          .truncationMode(.middle)
          .help(store.activeFolderName)
        Text(L10n.format("%d개 이미지", store.assets.count))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .monospacedDigit()
        if store.selectedURLs.count > 1 {
          Text(L10n.format("%d개 선택", store.selectedURLs.count))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ViewerTheme.accent)
            .monospacedDigit()
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
    ForEach(Array(store.assets.enumerated()), id: \.element.id) { index, asset in
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
                .font(.system(size: 10, weight: isCurrent ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: width, alignment: .leading)
            }
          } else {
            HStack(spacing: 10) {
              thumbnail(asset: asset, width: width, height: height, isSelected: isSelected)
              VStack(alignment: .leading, spacing: 5) {
                Text(asset.filename)
                  .font(.system(size: 11, weight: isCurrent ? .semibold : .medium))
                  .foregroundStyle(.primary)
                  .lineLimit(1)
                  .truncationMode(.middle)
                Text(verbatim: "\(asset.fileExtension.uppercased()) · \(asset.formattedFileSize)")
                  .font(.system(size: 10))
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                Text(verbatim: "\(index + 1)")
                  .font(.system(size: 10).monospacedDigit())
                  .foregroundStyle(.tertiary)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        .padding(7)
        .background {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected || isCurrent ? ViewerTheme.selection : Color.clear)
        }
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(isCurrent ? ViewerTheme.accent.opacity(0.65) : Color.clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      .buttonStyle(.plain)
      .contextMenu {
        BatchAssetContextMenu(store: store, index: index)
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
      maxPixelSize: 192
    )
    .frame(width: width, height: height)
    .background(ViewerTheme.panel, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .strokeBorder(ViewerTheme.separator, lineWidth: 0.5)
    }
    .overlay(alignment: .topTrailing) {
      if isSelected && store.selectedURLs.count > 1 {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 13))
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, ViewerTheme.accent)
          .padding(3)
          .accessibilityHidden(true)
      }
    }
  }

  private func scrollToCurrent(
    _ index: Int,
    with proxy: ScrollViewProxy,
    animated: Bool = true
  ) {
    guard store.assets.indices.contains(index) else { return }
    let target = store.assets[index].id

    if animated {
      withAnimation(.easeOut(duration: 0.15)) {
        proxy.scrollTo(target, anchor: .center)
      }
    } else {
      proxy.scrollTo(target, anchor: .center)
    }
  }
}
