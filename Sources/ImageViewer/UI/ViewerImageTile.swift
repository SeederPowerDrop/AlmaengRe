import SwiftUI

private struct ViewerFrameRequest: Hashable, Sendable {
  let asset: ImageAsset
  let maxPixelSize: Int
  let adjustments: ImageAdjustments
  let prefersHDR: Bool
}

/// 한 타일이 정지 이미지와 GIF/APNG/WebP 같은 다중 프레임 이미지를 모두 재생합니다.
struct ViewerImageTile: View {
  let asset: ImageAsset
  let itemCount: Int
  let thumbnailPipeline: ThumbnailPipeline
  let pipeline: ImagePipeline
  let adjustments: ImageAdjustments
  let prefersHDR: Bool
  let interpolationMode: ImageInterpolationMode
  let comparisonLayout: MagnificationComparisonLayout
  let filenameDisplaySize: FilenameDisplaySize
  let baseScaleMode: BaseScaleMode
  let committedZoom: CGFloat
  let effectiveZoom: CGFloat
  let effectivePan: CGSize
  let showsTileBoundary: Bool
  let highlightsSelection: Bool
  var onPresentationReady: (ImageAsset) -> Void = { _ in }
  var onBaseImageSizeChange: (CGSize) -> Void = { _ in }

  @Environment(\.displayScale) private var displayScale
  @State private var frame: RenderedFrame?
  @State private var frameAsset: ImageAsset?
  @State private var errorMessage: String?
  @State private var activeRequest: ViewerFrameRequest?
  @State private var requestGate = LatestRequestGate<ViewerFrameRequest>()

  var body: some View {
    GeometryReader { geometry in
      let maxPixelSize = requestedPixelSize(for: geometry.size)
      let request = ViewerFrameRequest(
        asset: asset,
        maxPixelSize: maxPixelSize,
        adjustments: adjustments,
        prefersHDR: prefersHDR
      )

      ZStack {
        ViewerTheme.canvas

        if let frame, frameAsset == asset {
          renderedImage(frame, in: geometry.size)
            .frame(width: geometry.size.width, height: geometry.size.height)
        } else if let errorMessage, activeRequest == request {
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

        VStack(spacing: 0) {
          filenameOverlay(frame: frameAsset == asset ? frame : nil)
          Spacer(minLength: 0)
        }
      }
      // Enlarged pixels must not expand the ZStack's own clipping boundary.
      .frame(width: geometry.size.width, height: geometry.size.height)
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
      .onDisappear {
        requestGate.invalidate()
        activeRequest = nil
        frame = nil
        frameAsset = nil
        errorMessage = nil
      }
    }
  }

  @ViewBuilder
  private func filenameOverlay(frame: RenderedFrame?) -> some View {
    if filenameDisplaySize.isVisible {
      HStack(spacing: 10) {
        Text(asset.filename)
          .lineLimit(1)
          .truncationMode(.middle)

        Spacer(minLength: 8)

        if let frame, frame.frameCount > 1 {
          Text("\(frame.frameIndex + 1)/\(frame.frameCount)")
            .monospacedDigit()
        }
      }
      .font(.system(size: filenameDisplaySize.fontSize, weight: .semibold))
      // 불투명 검정과 완전한 흰색을 써 밝은 이미지 위에서도 대비를 보장합니다.
      .foregroundStyle(Color.white)
      .padding(.horizontal, filenameDisplaySize.horizontalPadding)
      .padding(.vertical, filenameDisplaySize.verticalPadding)
      .frame(maxWidth: .infinity)
      .background(Color.black)
    } else if let frame, frame.frameCount > 1 {
      // 파일명을 숨겨도 애니메이션 재생 위치는 작은 배지로 유지합니다.
      HStack {
        Spacer()
        Text("\(frame.frameIndex + 1)/\(frame.frameCount)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(Color.white)
          .padding(.horizontal, 7)
          .padding(.vertical, 4)
          .background(Color.black, in: RoundedRectangle(cornerRadius: 5))
          .padding(6)
      }
    }
  }

  @ViewBuilder
  private func renderedImage(_ renderedFrame: RenderedFrame, in container: CGSize) -> some View {
    let paneSize = comparisonLayout.paneSize(in: container)
    // 두 영역은 같은 CGImage를 공유합니다. 애니메이션 재생·색상·보정도 일치합니다.
    switch comparisonLayout {
    case .off:
      imagePane(renderedFrame, in: paneSize, mode: interpolationMode, label: nil)
    case .sideBySide:
      HStack(spacing: 0) {
        imagePane(renderedFrame, in: paneSize, mode: .pixelated, label: "기본 확대 · 픽셀 그대로")
        Color.white.opacity(0.2).frame(width: 2)
        imagePane(renderedFrame, in: paneSize, mode: .smooth, label: "고화질 확대 · 부드럽게")
      }
      .frame(width: container.width, height: container.height)
    case .stacked:
      VStack(spacing: 0) {
        imagePane(renderedFrame, in: paneSize, mode: .pixelated, label: "기본 확대 · 픽셀 그대로")
        Color.white.opacity(0.2).frame(height: 2)
        imagePane(renderedFrame, in: paneSize, mode: .smooth, label: "고화질 확대 · 부드럽게")
      }
      .frame(width: container.width, height: container.height)
    }
  }

  private func imagePane(
    _ renderedFrame: RenderedFrame, in container: CGSize,
    mode: ImageInterpolationMode, label: String?
  ) -> some View {
    let image = renderedFrame.image
    let pixelSize = CGSize(width: image.width, height: image.height)
    let displayPixelSize =
      baseScaleMode == .actualPixels
      ? renderedFrame.sourcePixelSize ?? pixelSize : pixelSize
    let availableWidth = max(container.width - 2, 1)
    let availableHeight = max(container.height - 2, 1)

    let baseScale: CGFloat =
      switch baseScaleMode {
      case .fit:
        min(availableWidth / max(pixelSize.width, 1), availableHeight / max(pixelSize.height, 1))
      case .actualPixels:
        // 원본의 실제 치수로 100% 크기를 유지하고 제한된 비트맵은 표시용으로만 씁니다.
        // 아직 원본 치수가 없는 빠른 미리보기는 화면 맞춤으로 먼저 표시합니다.
        renderedFrame.sourcePixelSize != nil
          ? 1 / max(1, displayScale)
          : min(
            availableWidth / max(pixelSize.width, 1), availableHeight / max(pixelSize.height, 1))
      }

    let baseImageSize = CGSize(
      width: displayPixelSize.width * baseScale,
      height: displayPixelSize.height * baseScale
    )
    let renderedSize = CGSize(
      width: baseImageSize.width * effectiveZoom,
      height: baseImageSize.height * effectiveZoom
    )

    return ExtendedRangeImageView(
      image: image,
      prefersHDR: prefersHDR,
      interpolationMode: mode
    )
    .frame(width: renderedSize.width, height: renderedSize.height)
    .onChange(of: baseImageSize, initial: true) { _, size in
      onBaseImageSizeChange(size)
    }
    .offset(effectivePan)
    // 각 칸에서 클리핑해야 확대된 한쪽 이미지가 다른 쪽을 덮지 않습니다.
    .frame(width: container.width, height: container.height)
    .clipped()
    .overlay(alignment: .topLeading) {
      if let label {
        Text(L10n.text(label))
          .font(.caption.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.65)
          .foregroundStyle(.white)
          .padding(6)
          .background(.black)
          .padding(6)
          // 파일명과 하단 조작부가 비교 설명을 가리지 않도록 위쪽에 여백을 둡니다.
          .padding(
            .top,
            filenameDisplaySize.isVisible
              ? filenameDisplaySize.fontSize + filenameDisplaySize.verticalPadding * 2 : 0)
      }
    }
  }

  private func requestedPixelSize(for tileSize: CGSize) -> Int {
    ImageLoadingPolicy.requestedPixels(
      tileSize: comparisonLayout.paneSize(in: tileSize),
      displayScale: displayScale,
      zoom: committedZoom,
      actualPixels: baseScaleMode == .actualPixels,
      itemCount: itemCount,
      physicalMemory: ProcessInfo.processInfo.physicalMemory
    )
  }

  private func loadAndPlay(request: ViewerFrameRequest) async {
    guard !Task.isCancelled else { return }
    let previousRequest = activeRequest
    let generation = requestGate.begin(request)
    activeRequest = request
    if frameAsset != request.asset {
      frame = nil
      frameAsset = nil
    }
    errorMessage = nil
    var frameIndex = 0
    let isResizing =
      frame != nil
      && previousRequest?.asset == request.asset
      && previousRequest?.maxPixelSize != request.maxPixelSize
      && previousRequest?.adjustments == request.adjustments
      && previousRequest?.prefersHDR == request.prefersHDR
    let isAdjusting = previousRequest?.asset == request.asset
      && previousRequest?.adjustments != request.adjustments

    // Quick Look의 캐시 이미지를 먼저 보여 주고, 아래의 정밀 렌더가 끝나는 즉시
    // 색상 관리/HDR 결과로 교체해 큰 RAW에서도 빈 화면 시간을 줄입니다.
    let previewTask: Task<Void, Never>?
    if request.adjustments.isIdentity, frame == nil {
      previewTask = Task { @MainActor in
        guard
          let image = try? await thumbnailPipeline.thumbnail(
            for: request.asset,
            maxPixelSize: ImageLoadingPolicy.previewPixels(for: request.maxPixelSize)
          ),
          !Task.isCancelled,
          requestGate.accepts(generation, for: request),
          frame == nil
        else {
          return
        }
        frame = RenderedFrame(image: image, frameIndex: 0, frameCount: 1, duration: nil)
        frameAsset = request.asset
        onPresentationReady(request.asset)
      }
    } else {
      previewTask = nil
    }
    defer { previewTask?.cancel() }

    await withTaskCancellationHandler {
      do {
        // 창 크기를 바꾸는 동안 이미 보이는 이미지를 유지하고 마지막 크기만 디코딩합니다.
        if isResizing { try await Task.sleep(for: .milliseconds(60)) }
        // Slider updates cancel intermediate requests while the last good frame
        // stays visible. The final value still receives a full-quality render.
        if isAdjusting { try await Task.sleep(for: .milliseconds(90)) }
        while !Task.isCancelled {
          let rendered = try await pipeline.renderFrame(
            url: request.asset.url,
            frameIndex: frameIndex,
            maxPixelSize: request.maxPixelSize,
            adjustments: request.adjustments,
            prefersHDR: request.prefersHDR
          )
          try Task.checkCancellation()
          guard requestGate.accepts(generation, for: request) else { return }
          frame = rendered
          frameAsset = request.asset
          onPresentationReady(request.asset)

          guard rendered.frameCount > 1 else { return }
          try await Task.sleep(for: .seconds(rendered.duration ?? 0.1))
          frameIndex = (frameIndex + 1) % rendered.frameCount
        }
      } catch is CancellationError {
        // 다른 파일이나 확대 단계로 전환한 정상적인 취소입니다.
      } catch {
        guard !Task.isCancelled, requestGate.accepts(generation, for: request) else { return }
        // 정밀 렌더만 실패하고 Quick Look 미리보기가 남아 있다면 그것이라도 유지합니다.
        if frame == nil {
          errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        // 손상된 한 파일 때문에 전자 앨범 전체가 멈추지 않도록 오류도 표시 시간에 포함합니다.
        onPresentationReady(request.asset)
      }
    } onCancel: {
      // 정밀 디코더의 반환을 기다리지 않고 화면 밖 Quick Look 요청도 즉시 취소합니다.
      previewTask?.cancel()
    }
  }
}
