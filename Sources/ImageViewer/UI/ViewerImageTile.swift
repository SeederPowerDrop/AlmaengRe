import SwiftUI

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
  var onDisplayedAssetChange: ((ImageAsset?) -> Void)? = nil
  var onBaseImageSizeChange: (ImageAsset, CGSize) -> Void = { _, _ in }
  var onPanGeometryChange: (ImageAsset, ImagePanGeometry) -> Void = { _, _ in }
  var isPanReference = true
  var onExitFocus: (() -> Void)? = nil
  var onShowControls: (() -> Void)? = nil
  var onOpenMotionTools: ((ImageAsset) -> Void)? = nil
  var photoMarkStore: AppStore? = nil
  var onToggleSelection: (() -> Void)? = nil

  @Environment(\.displayScale) private var displayScale
  @StateObject private var loader = ViewerFrameLoader()

  private struct PresentedImageSize: Equatable {
    let assetID: URL
    let geometry: ImagePanGeometry
    let scaleMode: BaseScaleMode
    let isPanReference: Bool
    let hasDefinitiveSize: Bool
  }

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

        if let presentation = loader.presentation {
          renderedImage(presentation.frame, asset: presentation.request.asset, in: geometry.size)
            .frame(width: geometry.size.width, height: geometry.size.height)
        } else if let errorMessage = loader.errorMessage {
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
          filenameOverlay(frame: loader.presentation?.frame)
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
      .contextMenu {
        if let photoMarkStore {
          // Fast navigation can retain the previous frame while its replacement loads.
          // File actions must refer to the pixels currently shown to the user.
          BatchAssetContextMenu(store: photoMarkStore,
            url: loader.presentation?.request.asset.url ?? asset.url)
        }
      }
      .overlay(alignment: .bottomLeading) {
        if let presentation = loader.presentation, presentation.frame.frameCount > 1,
          ["gif", "png", "apng", "webp"].contains(presentation.request.asset.fileExtension),
          let onOpenMotionTools {
          Button(MotionMediaL10n.text("editor.open")) { onOpenMotionTools(presentation.request.asset) }
            .buttonStyle(.bordered).padding(10).background(.black.opacity(0.65))
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if let shown = loader.presentation?.request.asset, shown.id != asset.id {
          HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text(asset.filename)
              .font(.caption)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .foregroundStyle(.white)
          .padding(.horizontal, 11)
          .padding(.vertical, 8)
          .background(.black.opacity(0.78), in: Capsule())
          .frame(maxWidth: 260, alignment: .trailing)
          .padding(12)
          .help(L10n.text("이미지 로딩"))
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(Text("\(L10n.text("이미지 로딩")): \(asset.filename)"))
          .allowsHitTesting(false)
        }
      }
      .onChange(of: request, initial: true) { _, request in
        load(request)
      }
      .onChange(of: loader.presentation?.request.asset, initial: true) { _, displayedAsset in
        onDisplayedAssetChange?(displayedAsset)
      }
      .onDisappear {
        loader.stop()
        onDisplayedAssetChange?(nil)
      }
    }
  }

  @ViewBuilder
  private func filenameOverlay(frame: RenderedFrame?) -> some View {
    if filenameDisplaySize.isVisible || onExitFocus != nil || photoMarkStore?.isPhotoMarking == true {
      HStack(spacing: 10) {
        if itemCount > 1, let photoMarkStore, photoMarkStore.isPhotoMarking,
          let onToggleSelection {
          PhotoMarkSelectionToggle(asset: asset,
            isSelected: photoMarkStore.selectedURLs.contains(asset.url),
            action: onToggleSelection)
        }
        if let onExitFocus {
          Button(action: onExitFocus) { Image(systemName: "xmark") }
            .buttonStyle(ViewerToolButtonStyle())
            .help("집중 보기 종료 (Esc)")
            .accessibilityLabel("집중 보기 종료 (Esc)")
        }
        if filenameDisplaySize.isVisible {
          Text((loader.presentation?.request.asset ?? asset).filename)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer(minLength: 8)

        if let photoMarkStore, photoMarkStore.isPhotoMarking {
          PhotoMarkCardMenu(store: photoMarkStore, asset: asset)
            .disabled(loader.presentation?.request.asset.id != asset.id)
            .font(.caption)
        }

        if let frame, frame.frameCount > 1 {
          Text("\(frame.frameIndex + 1)/\(frame.frameCount)")
            .monospacedDigit()
        }
        if let onShowControls {
          Button(action: onShowControls) { Image(systemName: "slider.horizontal.3") }
            .buttonStyle(ViewerToolButtonStyle())
            .help("조작창 표시")
            .accessibilityLabel("조작창 표시")
        }
      }
      .font(.system(size: max(12, filenameDisplaySize.fontSize), weight: .semibold))
      // 불투명 검정과 완전한 흰색을 써 밝은 이미지 위에서도 대비를 보장합니다.
      .foregroundStyle(Color.white)
      .padding(.horizontal, max(onExitFocus == nil ? 0 : 6, filenameDisplaySize.horizontalPadding))
      .padding(.vertical, max(onExitFocus == nil ? 0 : 4, filenameDisplaySize.verticalPadding))
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
  private func renderedImage(
    _ renderedFrame: RenderedFrame, asset: ImageAsset, in container: CGSize
  ) -> some View {
    let paneSize = comparisonLayout.paneSize(in: container)
    // 두 영역은 같은 CGImage를 공유합니다. 애니메이션 재생·색상·보정도 일치합니다.
    switch comparisonLayout {
    case .off:
      imagePane(renderedFrame, asset: asset, in: paneSize, mode: interpolationMode, label: nil)
    case .sideBySide:
      HStack(spacing: 0) {
        imagePane(renderedFrame, asset: asset, in: paneSize, mode: .pixelated, label: "기본 확대 · 픽셀 그대로")
        Color.white.opacity(0.2).frame(width: 2)
        imagePane(renderedFrame, asset: asset, in: paneSize, mode: .smooth, label: "고화질 확대 · 부드럽게")
      }
      .frame(width: container.width, height: container.height)
    case .stacked:
      VStack(spacing: 0) {
        imagePane(renderedFrame, asset: asset, in: paneSize, mode: .pixelated, label: "기본 확대 · 픽셀 그대로")
        Color.white.opacity(0.2).frame(height: 2)
        imagePane(renderedFrame, asset: asset, in: paneSize, mode: .smooth, label: "고화질 확대 · 부드럽게")
      }
      .frame(width: container.width, height: container.height)
    }
  }

  private func imagePane(
    _ renderedFrame: RenderedFrame, asset: ImageAsset, in container: CGSize,
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
    let panGeometry = ImagePanGeometry(baseImageSize: baseImageSize, viewportSize: container)

    return ExtendedRangeImageView(
      image: image,
      prefersHDR: prefersHDR,
      interpolationMode: mode
    )
    .frame(width: renderedSize.width, height: renderedSize.height)
    .onChange(of: PresentedImageSize(assetID: asset.id, geometry: panGeometry,
      scaleMode: baseScaleMode,
      isPanReference: isPanReference,
      hasDefinitiveSize: baseScaleMode == .fit || renderedFrame.sourcePixelSize != nil), initial: true) { _, value in
      // A retained preview belongs to its displayed file, not the pending target.
      // Include identity so equally sized consecutive photos also report readiness.
      onBaseImageSizeChange(asset, value.geometry.baseImageSize)
      // A temporary fit-sized RAW preview cannot constrain a saved 1:1 position.
      if value.isPanReference && value.hasDefinitiveSize {
        onPanGeometryChange(asset, value.geometry)
      }
    }
    .offset(panGeometry.constrained(effectivePan, zoom: effectiveZoom))
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
            onExitFocus != nil
              ? max(28, filenameDisplaySize.fontSize * 1.25)
                + max(4, filenameDisplaySize.verticalPadding) * 2
              : filenameDisplaySize.isVisible
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

  private func load(_ request: ViewerFrameRequest) {
    loader.load(request, preview: { [thumbnailPipeline, pipeline] request in
      if request.adjustments.isIdentity {
        do {
          let image = try await thumbnailPipeline.browsingThumbnail(for: request.asset)
          return RenderedFrame(image: image, frameIndex: 0, frameCount: 1, duration: nil)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          // Custom codecs and failed system previews still produce browsing samples.
        }
      }
      // Edited images must retain their crop, rotation and color adjustments.
      return try await pipeline.renderFrame(url: request.asset.url, maxPixelSize: 512,
        adjustments: request.adjustments, prefersHDR: false, priority: .interactivePreview)
    }, render: { [pipeline] request, index in
      try await pipeline.renderFrame(url: request.asset.url, frameIndex: index,
        maxPixelSize: request.maxPixelSize, adjustments: request.adjustments,
        prefersHDR: request.prefersHDR)
    }, onReady: onPresentationReady)
  }
}
