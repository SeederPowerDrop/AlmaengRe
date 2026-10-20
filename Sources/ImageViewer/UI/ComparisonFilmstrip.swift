import SwiftUI

/// Keep random access and stable file IDs without allocating an enumerated array
/// whenever selection changes. The backing array shares its existing storage.
struct IndexedImageAssets: RandomAccessCollection {
  typealias Index = Int
  typealias Element = (index: Int, asset: ImageAsset)
  private let assets: [ImageAsset]

  init(_ assets: [ImageAsset]) { self.assets = assets }
  var startIndex: Int { assets.startIndex }
  var endIndex: Int { assets.endIndex }
  subscript(position: Int) -> Element { (position, assets[position]) }
}

/// 각 비교 칸의 전체 목록과 현재 위치를 보여 줍니다. 화면에 보이는 셀만 읽습니다.
struct ComparisonFilmstrip: View {
  @ObservedObject var store: AppStore
  @ObservedObject var comparison: FolderComparisonStore
  @ObservedObject var pane: FolderComparisonPane
  let side: FolderComparisonSide
  var compact = false

  private var thumbnailWidth: CGFloat { compact ? 48 : 64 }
  private var thumbnailHeight: CGFloat { compact ? 32 : 44 }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        LazyHStack(spacing: 5) {
          ForEach(IndexedImageAssets(pane.assets), id: \.asset.id) { entry in
            thumbnail(entry.asset, at: entry.index)
              .id(entry.asset.id)
          }
        }
        .viewerPadding(.horizontal, 10)
        .viewerPadding(.vertical, compact ? 3 : 4)
      }
      .onChange(of: pane.currentAsset?.id, initial: true) { _, _ in
        scrollToCurrent(with: proxy)
      }
      .onChange(of: pane.assets) { _, _ in
        // 같은 파일이 선택되어 있어도 재정렬한 목록에서 실제 위치를 다시 찾습니다.
        scrollToCurrent(with: proxy)
      }
    }
    .frame(height: compact ? 62 : 88)
    .background(ViewerTheme.sidebar)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("비교 이미지 썸네일"))
  }

  private func thumbnail(_ asset: ImageAsset, at index: Int) -> some View {
    let isCurrent = pane.currentAsset?.id == asset.id
    return Button {
      comparison.jump(side, number: index + 1)
    } label: {
      VStack(spacing: 3) {
        ThumbnailImageView(asset: asset, thumbnailPipeline: store.thumbnailPipeline,
          pipeline: store.pipeline, maxPixelSize: 160, prefersHDR: store.prefersHDR)
          .frame(width: thumbnailWidth, height: thumbnailHeight)
          .background(ViewerTheme.panel)
          .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        VStack(spacing: 1) {
          Text(verbatim: "\(index + 1)")
            .monospacedDigit()
            .foregroundStyle(isCurrent ? ViewerTheme.accent : Color.secondary)
          if !compact {
            Text(verbatim: asset.filename)
              .foregroundStyle(.primary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        .font(ViewerUIMetrics.font(size: 9, weight: isCurrent ? .medium : .regular))
        .frame(width: thumbnailWidth)
      }
      .viewerPadding(4)
      .background(isCurrent ? ViewerTheme.selection : Color.clear,
        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(isCurrent ? ViewerTheme.accent : Color.clear, lineWidth: 1.5)
      }
      .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    // 버튼만 잠가서 잠긴 칸의 목록도 스크롤하며 확인할 수 있습니다.
    .disabled(pane.isLocked || pane.isLoading)
    .help(asset.filename)
    .accessibilityLabel(Text(verbatim: "\(index + 1) / \(pane.assets.count) · \(asset.filename)"))
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
  }

  private func scrollToCurrent(with proxy: ScrollViewProxy) {
    guard let asset = pane.currentAsset else { return }
    proxy.scrollTo(asset.id, anchor: .center)
  }
}
