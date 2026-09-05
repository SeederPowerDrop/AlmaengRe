import AppKit
import SwiftUI

struct OverviewView: View {
  @ObservedObject var store: AppStore

  private var columns: [GridItem] {
    [
      GridItem(
        .adaptive(minimum: store.thumbnailSize, maximum: store.thumbnailSize * 1.35), spacing: 12)
    ]
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVGrid(columns: columns, spacing: 16) {
            ForEach(Array(store.assets.enumerated()), id: \.element.id) { index, asset in
              VStack(alignment: .leading, spacing: 7) {
                ThumbnailImageView(
                  asset: asset,
                  thumbnailPipeline: store.thumbnailPipeline,
                  pipeline: store.pipeline,
                  maxPixelSize: Int(store.thumbnailSize * 2.2),
                  adjustments: store.adjustments(for: asset)
                )
                .frame(height: store.thumbnailSize)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                  Text("\(index + 1)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(6)
                }

                Text(asset.filename)
                  .font(.caption)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
              .padding(7)
              .background {
                RoundedRectangle(cornerRadius: 11)
                  .fill(
                    index == store.currentIndex
                      ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.035))
              }
              .overlay {
                RoundedRectangle(cornerRadius: 11)
                  .stroke(
                    index == store.currentIndex ? Color.accentColor : Color.white.opacity(0.08),
                    lineWidth: 1.5)
              }
              .contentShape(Rectangle())
              .onTapGesture(count: 2) {
                store.select(index: index)
                store.presentationMode = .viewer
              }
              .onTapGesture {
                store.select(index: index)
              }
              // 폴더를 바꾸면 순번은 반복되므로 파일 URL을 스크롤/뷰 식별자로 씁니다.
              .id(asset.id)
            }
          }
          .padding(18)
        }
        .onChange(of: store.currentIndex) { _, newIndex in
          scrollToCurrent(newIndex, with: proxy)
        }
        .task(id: store.assets.first?.id) {
          await Task.yield()
          scrollToCurrent(store.currentIndex, with: proxy, animated: false)
        }
      }

      Divider()

      HStack(spacing: 12) {
        Image(systemName: "photo")
        Slider(value: $store.thumbnailSize, in: 80...300)
          .frame(maxWidth: 250)
        Image(systemName: "photo.fill")
        Spacer()
        Text(store.positionDescription)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 16)
      .frame(height: 46)
      .background(.ultraThinMaterial)
    }
    .background(Color(nsColor: .underPageBackgroundColor))
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
