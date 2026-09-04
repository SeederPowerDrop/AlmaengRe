import SwiftUI

private struct ViewerFrameRequest: Hashable {
  let url: URL
  let maxPixelSize: Int
  let adjustments: ImageAdjustments
  let prefersHDR: Bool
}

/// 한 타일이 정지 이미지와 GIF/APNG/WebP 같은 다중 프레임 이미지를 모두 재생합니다.
struct ViewerImageTile: View {
  let asset: ImageAsset
  let thumbnailPipeline: ThumbnailPipeline
  let pipeline: ImagePipeline
  let adjustments: ImageAdjustments
  let prefersHDR: Bool
  let baseScaleMode: BaseScaleMode
  let committedZoom: CGFloat
  let effectiveZoom: CGFloat
  let effectivePan: CGSize
  let showsTileBoundary: Bool
  let highlightsSelection: Bool

  @State private var frame: RenderedFrame?
  @State private var errorMessage: String?

  var body: some View {
    GeometryReader { geometry in
      let maxPixelSize = requestedPixelSize(for: geometry.size)
      let request = ViewerFrameRequest(
        url: asset.url,
        maxPixelSize: maxPixelSize,
        adjustments: adjustments,
        prefersHDR: prefersHDR
      )

      ZStack {
        Color.black

        if let frame {
          renderedImage(frame.image, in: geometry.size)
        } else if let errorMessage {
          ContentUnavailableView(
            "이미지를 표시할 수 없음",
            systemImage: "exclamationmark.triangle",
            description: Text(errorMessage)
          )
          .padding()
        } else {
          ProgressView()
            .controlSize(.large)
        }

        VStack {
          HStack {
            Text(asset.filename)
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer()
            if let frame, frame.frameCount > 1 {
              Text("\(frame.frameIndex + 1)/\(frame.frameCount)")
                .monospacedDigit()
            }
          }
          .font(.caption)
          .foregroundStyle(.white.opacity(0.82))
          .padding(.horizontal, 9)
          .padding(.vertical, 6)
          .background(.black.opacity(0.45))
          Spacer()
        }
      }
      .overlay {
        // 단일 이미지는 캔버스와 자연스럽게 이어지게 하고, 다중 보기에서만
        // 타일 구분선과 현재 이미지의 선택 강조를 그립니다.
        if showsTileBoundary {
          Rectangle()
            .stroke(
              highlightsSelection ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.08),
              lineWidth: highlightsSelection ? 2 : 1)
        }
      }
      .clipped()
      .task(id: request) {
        await loadAndPlay(request: request)
      }
    }
  }

  @ViewBuilder
  private func renderedImage(_ image: CGImage, in container: CGSize) -> some View {
    let pixelSize = CGSize(width: image.width, height: image.height)
    let availableWidth = max(container.width - 2, 1)
    let availableHeight = max(container.height - 2, 1)
    let backingScale = NSScreen.main?.backingScaleFactor ?? 2

    let baseScale: CGFloat =
      switch baseScaleMode {
      case .fit:
        min(availableWidth / max(pixelSize.width, 1), availableHeight / max(pixelSize.height, 1))
      case .actualPixels:
        1 / backingScale
      }

    let renderedSize = CGSize(
      width: pixelSize.width * baseScale * effectiveZoom,
      height: pixelSize.height * baseScale * effectiveZoom
    )

    ExtendedRangeImageView(image: image, prefersHDR: prefersHDR)
      .frame(width: renderedSize.width, height: renderedSize.height)
      .offset(effectivePan)
  }

  private func requestedPixelSize(for tileSize: CGSize) -> Int {
    let backingScale = NSScreen.main?.backingScaleFactor ?? 2
    if baseScaleMode == .actualPixels {
      // 8K 미리보기 상한은 단일 CGImage가 수 GB로 커지는 것을 막습니다.
      return 8_192
    }
    let points = max(tileSize.width, tileSize.height)
    return min(8_192, max(512, Int(points * backingScale * max(1, committedZoom) * 1.2)))
  }

  private func loadAndPlay(request: ViewerFrameRequest) async {
    frame = nil
    errorMessage = nil
    var frameIndex = 0

    // Quick Look의 캐시 이미지를 먼저 보여 주고, 아래의 정밀 렌더가 끝나는 즉시
    // 색상 관리/HDR 결과로 교체해 큰 RAW에서도 빈 화면 시간을 줄입니다.
    var previewTask: Task<Void, Never>?
    if request.adjustments.isIdentity {
      previewTask = Task { @MainActor in
        guard
          let image = try? await thumbnailPipeline.thumbnail(
            for: request.url,
            maxPixelSize: min(2_048, request.maxPixelSize)
          ),
          !Task.isCancelled,
          frame == nil
        else {
          return
        }
        frame = RenderedFrame(image: image, frameIndex: 0, frameCount: 1, duration: nil)
      }
    }
    defer { previewTask?.cancel() }

    do {
      while !Task.isCancelled {
        let rendered = try await pipeline.renderFrame(
          url: request.url,
          frameIndex: frameIndex,
          maxPixelSize: request.maxPixelSize,
          adjustments: request.adjustments,
          prefersHDR: request.prefersHDR
        )
        try Task.checkCancellation()
        frame = rendered

        guard rendered.frameCount > 1 else { return }
        try await Task.sleep(for: .seconds(rendered.duration ?? 0.1))
        frameIndex = (frameIndex + 1) % rendered.frameCount
      }
    } catch is CancellationError {
      // 다른 파일이나 확대 단계로 전환한 정상적인 취소입니다.
    } catch {
      // 정밀 렌더만 실패하고 Quick Look 미리보기가 남아 있다면 그것이라도 유지합니다.
      if frame == nil {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
    }
  }
}
