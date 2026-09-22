import SwiftUI

struct ThumbnailRequest: Hashable, Sendable {
  let asset: ImageAsset
  let maxPixelSize: Int
  let adjustments: ImageAdjustments
  let prefersHDR: Bool
  var prefersPreciseImage = false

  /// 크기만 바뀌면 이전 미리보기를 유지합니다. 다른 폴더/수정본은 재사용하지 않습니다.
  func hasSameContent(as other: Self) -> Bool {
    asset == other.asset && adjustments == other.adjustments && prefersHDR == other.prefersHDR
  }

  var needsPreciseImage: Bool { prefersPreciseImage && maxPixelSize >= 512 }
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

  mutating func invalidate() {
    generation &+= 1
    currentRequest = nil
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
  var prefersPreciseImage = false

  @State private var result: ThumbnailLoadResult?
  /// 몽땅보기 번호 배치에만 사용합니다. 크기 알림 때문에 추가 디코딩하지 않습니다.
  var onDisplayedImageSizeChange: ((CGSize?) -> Void)?
  @State private var requestGate = LatestRequestGate<ThumbnailRequest>()

  private var request: ThumbnailRequest {
    ThumbnailRequest(
      asset: asset,
      maxPixelSize: ((min(4_096, max(96, maxPixelSize)) + 127) / 128) * 128,
      adjustments: adjustments,
      prefersHDR: prefersHDR,
      prefersPreciseImage: prefersPreciseImage
    )
  }

  private var displayedImageSize: CGSize? {
    guard let result, result.request.hasSameContent(as: request), let image = result.image else {
      return nil
    }
    return CGSize(width: image.width, height: image.height)
  }

  var body: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor).opacity(0.32)

      if let result, result.request.hasSameContent(as: request),
        result.image != nil || result.request == request
      {
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
    .onChange(of: displayedImageSize, initial: true) { _, size in
      onDisplayedImageSizeChange?(size)
    }
    .onDisappear {
      requestGate.invalidate()
      result = nil
    }
    .task(id: request) {
      guard !Task.isCancelled else { return }
      let requested = request
      let generation = requestGate.begin(requested)
      if result?.request.hasSameContent(as: requested) != true {
        result = nil
      }

      do {
        if requested.adjustments.isIdentity {
          do {
            let quickImage = try await thumbnailPipeline.thumbnail(
              for: requested.asset, maxPixelSize: requested.maxPixelSize)
            try Task.checkCancellation()
            guard requestGate.accepts(generation, for: requested) else { return }
            result = ThumbnailLoadResult(request: requested, image: quickImage)
            if !requested.needsPreciseImage { return }
            // 큰 몽땅보기는 빠른 미리보기 뒤에 원본 기반 결과로 보강합니다.
            // 슬라이더를 계속 움직이는 동안 무거운 디코딩이 쌓이지 않게 기다립니다.
            try await Task.sleep(for: .milliseconds(90))
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            // 취소된 Quick Look 요청 때문에 더 무거운 원본 디코딩을 시작하지 않습니다.
            try Task.checkCancellation()
          }
        }

        // 자체 포맷/조정 이미지와 큰 몽땅보기는 원본 기반 디코딩을 사용합니다.
        try Task.checkCancellation()
        let frame = try await pipeline.renderFrame(
          url: requested.asset.url,
          maxPixelSize: requested.maxPixelSize,
          adjustments: requested.adjustments,
          prefersHDR: requested.prefersHDR
        )
        try Task.checkCancellation()
        guard !Task.isCancelled, requestGate.accepts(generation, for: requested) else { return }
        result = ThumbnailLoadResult(request: requested, image: frame.image)
      } catch is CancellationError {
        // 셀이 화면 밖으로 나간 정상적인 취소입니다.
      } catch {
        // 폴더 전환 뒤 늦게 끝난 이전 요청은 새 셀의 실패 상태도 덮지 못합니다.
        guard !Task.isCancelled, requestGate.accepts(generation, for: requested) else { return }
        // 정밀 디코딩만 실패했다면 이미 표시한 빠른 미리보기는 유지합니다.
        if result?.request.hasSameContent(as: requested) != true || result?.image == nil {
          result = ThumbnailLoadResult(request: requested, image: nil)
        }
      }
    }
  }
}
