import SwiftUI

private struct ThumbnailRequest: Hashable {
  let url: URL
  let maxPixelSize: Int
  let adjustments: ImageAdjustments
  let prefersHDR: Bool
}

/// 목록 셀은 보일 때만 디코딩되고 사라지면 작업이 자동 취소됩니다.
struct ThumbnailImageView: View {
  let asset: ImageAsset
  let pipeline: ImagePipeline
  let maxPixelSize: Int
  var adjustments: ImageAdjustments = .identity
  var prefersHDR = false

  @State private var image: CGImage?
  @State private var failed = false

  private var request: ThumbnailRequest {
    ThumbnailRequest(
      url: asset.url,
      maxPixelSize: maxPixelSize,
      adjustments: adjustments,
      prefersHDR: prefersHDR
    )
  }

  var body: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor).opacity(0.32)

      if let image {
        Image(decorative: image, scale: 1)
          .resizable()
          .interpolation(.high)
          .antialiased(true)
          .aspectRatio(contentMode: .fit)
      } else if failed {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
      } else {
        ProgressView()
          .controlSize(.small)
      }
    }
    .task(id: request) {
      failed = false
      do {
        let frame = try await pipeline.renderFrame(
          url: asset.url,
          maxPixelSize: maxPixelSize,
          adjustments: adjustments,
          prefersHDR: prefersHDR
        )
        try Task.checkCancellation()
        image = frame.image
      } catch is CancellationError {
        // 셀이 화면 밖으로 나간 정상적인 취소입니다.
      } catch {
        image = nil
        failed = true
      }
    }
  }
}
