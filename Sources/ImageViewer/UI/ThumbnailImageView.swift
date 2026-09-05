import SwiftUI

private struct ThumbnailRequest: Hashable, Sendable {
  let asset: ImageAsset
  let maxPixelSize: Int
  let adjustments: ImageAdjustments
  let prefersHDR: Bool
}

private struct ThumbnailLoadResult {
  let request: ThumbnailRequest
  /// nil이면 현재 요청이 디코딩에 실패했다는 뜻입니다.
  let image: CGImage?
}

/// SwiftUI가 셀 상태를 재사용하더라도 가장 최근 요청만 결과를 기록하게 합니다.
struct LatestRequestGate<Request: Equatable> {
  private var generation: UInt64 = 0
  private var currentRequest: Request?

  init() {}

  mutating func begin(_ request: Request) -> UInt64 {
    generation &+= 1
    currentRequest = request
    return generation
  }

  func accepts(_ candidateGeneration: UInt64, for request: Request) -> Bool {
    generation == candidateGeneration && currentRequest == request
  }
}

/// 목록 셀은 보일 때만 디코딩되고 사라지면 작업이 자동 취소됩니다.
struct ThumbnailImageView: View {
  let asset: ImageAsset
  let thumbnailPipeline: ThumbnailPipeline
  let pipeline: ImagePipeline
  let maxPixelSize: Int
  var adjustments: ImageAdjustments = .identity
  var prefersHDR = false

  @State private var result: ThumbnailLoadResult?
  @State private var requestGate = LatestRequestGate<ThumbnailRequest>()

  private var request: ThumbnailRequest {
    ThumbnailRequest(
      asset: asset,
      maxPixelSize: maxPixelSize,
      adjustments: adjustments,
      prefersHDR: prefersHDR
    )
  }

  var body: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor).opacity(0.32)

      if let result, result.request == request {
        if let image = result.image {
          Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
        } else {
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
        }
      } else {
        ProgressView()
          .controlSize(.small)
      }
    }
    .task(id: request) {
      let requested = request
      let generation = requestGate.begin(requested)
      result = nil

      do {
        if adjustments.isIdentity,
          let quickImage = try? await thumbnailPipeline.thumbnail(
            for: asset, maxPixelSize: maxPixelSize)
        {
          try Task.checkCancellation()
          guard requestGate.accepts(generation, for: requested) else { return }
          result = ThumbnailLoadResult(request: requested, image: quickImage)
          return
        }

        // 자체 포맷이나 조정된 이미지는 Quick Look 대신 앱 디코더로 처리합니다.
        let frame = try await pipeline.renderFrame(
          url: asset.url,
          maxPixelSize: maxPixelSize,
          adjustments: adjustments,
          prefersHDR: prefersHDR
        )
        try Task.checkCancellation()
        guard requestGate.accepts(generation, for: requested) else { return }
        result = ThumbnailLoadResult(request: requested, image: frame.image)
      } catch is CancellationError {
        // 셀이 화면 밖으로 나간 정상적인 취소입니다.
      } catch {
        // 폴더 전환 뒤 늦게 끝난 이전 요청은 새 셀의 실패 상태도 덮지 못합니다.
        guard requestGate.accepts(generation, for: requested) else { return }
        result = ThumbnailLoadResult(request: requested, image: nil)
      }
    }
  }
}
