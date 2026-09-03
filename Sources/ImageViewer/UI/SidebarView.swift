import SwiftUI

struct SidebarView: View {
  @ObservedObject var store: AppStore

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 3) {
        Text(store.activeFolderName)
          .font(.headline)
          .lineLimit(1)
        Text("\(store.assets.count)개 이미지")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(Array(store.assets.enumerated()), id: \.element.id) { index, asset in
              Button {
                store.select(index: index)
              } label: {
                VStack(spacing: 4) {
                  ThumbnailImageView(
                    asset: asset,
                    pipeline: store.pipeline,
                    maxPixelSize: 192
                  )
                  .frame(width: 88, height: 68)
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
                    .stroke(
                      index == store.currentIndex ? Color.accentColor : .clear, lineWidth: 1.5)
                }
              }
              .buttonStyle(.plain)
              .id(index)
              .help(asset.filename)
            }
          }
          .padding(8)
        }
        .onChange(of: store.currentIndex) { _, newIndex in
          withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(newIndex, anchor: .center)
          }
        }
      }
    }
    .frame(width: 116)
    .background(.ultraThinMaterial)
  }
}
