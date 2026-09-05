import SwiftUI

/// 폴더의 이미지를 창 가장자리에 세로 또는 가로로 보여 주는 썸네일 패널입니다.
struct SidebarView: View {
  @ObservedObject var store: AppStore
  let placement: ThumbnailPanelPlacement

  var body: some View {
    Group {
      if placement.isHorizontal {
        horizontalPanel
      } else {
        verticalPanel
      }
    }
    .background(.ultraThinMaterial)
  }

  private var verticalPanel: some View {
    VStack(spacing: 0) {
      folderHeader
        .padding(12)

      Divider()

      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          LazyVStack(spacing: 8) {
            thumbnailCells(width: 88, height: 68)
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
    .frame(width: 116)
  }

  private var horizontalPanel: some View {
    HStack(spacing: 0) {
      folderHeader
        .frame(width: 132, alignment: .leading)
        .padding(.horizontal, 12)

      Divider()

      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          LazyHStack(spacing: 8) {
            thumbnailCells(width: 82, height: 58)
          }
          .padding(.horizontal, 9)
          .padding(.vertical, 7)
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
    .frame(height: 102)
  }

  private var folderHeader: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(store.activeFolderName)
        .font(.headline)
        .lineLimit(1)
      Text("\(store.assets.count)개 이미지")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func thumbnailCells(width: CGFloat, height: CGFloat) -> some View {
    ForEach(Array(store.assets.enumerated()), id: \.element.id) { index, asset in
      Button {
        store.select(index: index)
      } label: {
        VStack(spacing: 4) {
          ThumbnailImageView(
            asset: asset,
            thumbnailPipeline: store.thumbnailPipeline,
            pipeline: store.pipeline,
            maxPixelSize: 192
          )
          .frame(width: width, height: height)
          .clipShape(RoundedRectangle(cornerRadius: 5))

          Text("\(index + 1)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(5)
        .background {
          RoundedRectangle(cornerRadius: 8)
            .fill(index == store.currentIndex ? Color.accentColor.opacity(0.25) : .clear)
        }
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(index == store.currentIndex ? Color.accentColor : .clear, lineWidth: 1.5)
        }
      }
      .buttonStyle(.plain)
      // 목록 순번은 새 폴더에서도 다시 0부터 시작합니다. 실제 파일 URL을 써야
      // 같은 순번에 있던 이전 폴더의 썸네일 상태가 재사용되지 않습니다.
      .id(asset.id)
      .help(asset.filename)
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
