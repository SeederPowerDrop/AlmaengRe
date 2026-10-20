import SwiftUI

struct ThumbnailRequest: Hashable, Sendable {
  let asset: ImageAsset
  let maxPixelSize: Int
  let adjustments: ImageAdjustments
  let prefersHDR: Bool
  var prefersPreciseImage = false

  /// 크기만 바뀌면 이전 미리보기를 유지합니다. 다른 폴더/수정본은 재사용하지 않습니다.
  func hasSameContent(as other: Self) -> Bool {
    // Location/EXIF/mark enrichment changes library filtering and labels, not
    // image pixels. Match the full source version and archive member instead of
    // ImageAsset's display-metadata fields so those updates keep accepted State.
    asset.url == other.asset.url && asset.byteCount == other.asset.byteCount
      && asset.modificationDate == other.asset.modificationDate
      && asset.archiveOrigin == other.asset.archiveOrigin
      && adjustments == other.adjustments && prefersHDR == other.prefersHDR
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.hasSameContent(as: rhs) && lhs.maxPixelSize == rhs.maxPixelSize
      && lhs.prefersPreciseImage == rhs.prefersPreciseImage
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(asset.url)
    hasher.combine(asset.byteCount)
    hasher.combine(asset.modificationDate)
    hasher.combine(asset.archiveOrigin)
    hasher.combine(adjustments)
    hasher.combine(prefersHDR)
    hasher.combine(maxPixelSize)
    hasher.combine(prefersPreciseImage)
  }

  var needsPreciseImage: Bool {
    guard prefersPreciseImage && maxPixelSize >= 512 else { return false }
    // The RAW thumbnail path already supplies an adequately sized embedded image
    // or decodes the source. Decoding the same sensor data again for every grid
    // cell adds work without improving its unedited SDR thumbnail.
    return !ImageFormatRegistry.cameraRAWExtensions.contains(asset.fileExtension)
      || !adjustments.isIdentity || prefersHDR
  }
}

/// A display-size change may adopt an already accepted final bitmap, but cannot
/// promote a quick/SDR/unedited image into a newly precise, HDR or edited result.
enum ThumbnailFinalBitmapReuse {
  static func canAdopt(previous: ThumbnailRequest, current: ThumbnailRequest,
    pixelWidth: Int, pixelHeight: Int, previousIsFinal: Bool) -> Bool {
    guard previousIsFinal, previous.hasSameContent(as: current),
      pixelWidth > 0, pixelHeight > 0,
      max(pixelWidth, pixelHeight) >= current.maxPixelSize else { return false }
    return !current.needsPreciseImage || previous.needsPreciseImage
  }
}

private struct ThumbnailLoadIdentity: Hashable {
  let request: ThumbnailRequest
  let defersLoading: Bool
  let prefersCompactPreview: Bool
}

private struct ThumbnailRefinementIdentity: Hashable {
  let request: ThumbnailRequest
  let isDeferred: Bool
  let hasFirstBitmap: Bool
  let overviewQuietRevision: UInt64?
}

private struct ThumbnailLoadResult {
  let request: ThumbnailRequest
  /// nil이면 현재 요청이 디코딩에 실패했다는 뜻입니다.
  let image: CGImage?
  var errorMessage: String? = nil
  var isFinal = false
}

/// The accepted bitmap was assigned to SwiftUI State. This is not compositor
/// presentation or screen-paint timing; opt-in callers may measure display work separately.
struct ThumbnailBitmapStateEvent: Sendable {
  let assetURL: URL
  let requestStartedUptime: Double
  let appliedUptime: Double
  let pixelWidth: Int
  let pixelHeight: Int
  let isRefinement: Bool
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
  var defersLoading = false
  var prefersCompactPreview = false
  var defersRefinement = false
  var overviewRefinementGate: OverviewRefinementGate? = nil

  @State private var result: ThumbnailLoadResult?
  /// 몽땅보기 번호 배치에만 사용합니다. 크기 알림 때문에 추가 디코딩하지 않습니다.
  var onDisplayedImageSizeChange: ((CGSize?) -> Void)?
  var onBitmapStateApplied: (@MainActor (ThumbnailBitmapStateEvent) -> Void)? = nil
  @State private var requestGate = LatestRequestGate<ThumbnailRequest>()
  @State private var refinementGate = LatestRequestGate<ThumbnailRequest>()

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
          failurePlaceholder(message: result.errorMessage)
        }
      } else {
        ProgressView()
          .controlSize(.small)
      }
    }
    .background {
      if onBitmapStateApplied != nil {
        OverviewBitmapPresentationProbe(asset: asset, size: displayedImageSize)
          .allowsHitTesting(false)
      }
    }
    .onChange(of: displayedImageSize, initial: true) { _, size in
      onDisplayedImageSizeChange?(size)
    }
    .onChange(of: onDisplayedImageSizeChange != nil) { _, isEnabled in
      if isEnabled { onDisplayedImageSizeChange?(displayedImageSize) }
    }
    .onDisappear {
      requestGate.invalidate()
      refinementGate.invalidate()
      result = nil
    }
    .task(id: ThumbnailLoadIdentity(request: request, defersLoading: defersLoading,
      prefersCompactPreview: prefersCompactPreview)) {
      await loadInitialImage()
    }
    .task(id: ThumbnailRefinementIdentity(request: request,
      isDeferred: defersLoading || defersRefinement,
      hasFirstBitmap: displayedImageSize != nil,
      overviewQuietRevision: overviewRefinementGate?.quietRevision)) {
      await refineOverviewImage()
    }
  }

  private func loadInitialImage() async {
    guard !Task.isCancelled else { return }
    // Size drags keep their displayed pixels and do not admit transient decodes.
    guard !defersLoading else { requestGate.invalidate(); return }
    let requested = request
    let generation = requestGate.begin(requested)
    // Occlusion and a size-drag pause preserve accepted State. Exposing that
    // same overview request needs no second actor/cache round trip; its quiet
    // task still performs any missing display-size refinement below.
    if prefersCompactPreview, let result, result.request == requested, result.image != nil { return }
    if adoptExistingFinalImage(for: requested) { return }
    let started = onBitmapStateApplied == nil ? nil : ProcessInfo.processInfo.systemUptime
    if result?.request.hasSameContent(as: requested) != true { result = nil }
    do {
      if requested.asset.byteCount == 0 {
        throw ImagePipelineError.emptyFile(requested.asset.url)
      }
      if requested.adjustments.isIdentity {
        do {
          if let cached = await thumbnailPipeline.cachedPreview(for: requested.asset,
            maxPixelSize: requested.maxPixelSize, prefersCompact: prefersCompactPreview) {
            try Task.checkCancellation()
            guard requestGate.accepts(generation, for: requested) else { return }
            applyImage(cached, for: requested, started: started, isRefinement: false,
              isFinal: !requested.needsPreciseImage
                && max(cached.width, cached.height) >= requested.maxPixelSize)
            if prefersCompactPreview || (!requested.needsPreciseImage
              && max(cached.width, cached.height) >= requested.maxPixelSize) { return }
          }
          let quickImage: CGImage
          if prefersCompactPreview {
            quickImage = try await thumbnailPipeline.browsingThumbnail(
              for: requested.asset, maxPixelSize: min(256, requested.maxPixelSize),
              preciseRAWFallbackPixelSize: !requested.needsPreciseImage
                && !requested.prefersHDR
                && ImageFormatRegistry.cameraRAWExtensions.contains(requested.asset.fileExtension)
                ? min(1_024, requested.maxPixelSize) : nil)
          } else {
            quickImage = try await thumbnailPipeline.thumbnail(for: requested.asset,
              maxPixelSize: requested.maxPixelSize, waitsForStableVisibility: true)
          }
          try Task.checkCancellation()
          guard requestGate.accepts(generation, for: requested) else { return }
          applyImage(quickImage, for: requested, started: started, isRefinement: false,
            isFinal: !requested.needsPreciseImage
              && (!prefersCompactPreview || max(quickImage.width, quickImage.height) >= requested.maxPixelSize))
          if prefersCompactPreview || !requested.needsPreciseImage { return }
          try await Task.sleep(for: .milliseconds(90))
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          try Task.checkCancellation()
        }
      }
      let frame = try await pipeline.renderFrame(url: requested.asset.url,
        maxPixelSize: prefersCompactPreview ? min(256, requested.maxPixelSize) : requested.maxPixelSize,
        adjustments: requested.adjustments, prefersHDR: requested.prefersHDR)
      try Task.checkCancellation()
      guard requestGate.accepts(generation, for: requested) else { return }
      applyImage(frame.image, for: requested, started: started, isRefinement: false,
        isFinal: !prefersCompactPreview || requested.maxPixelSize <= 256)
    } catch is CancellationError {
      // Leaving the viewport cancels normal work; keep any accepted bitmap.
    } catch {
      guard !Task.isCancelled, requestGate.accepts(generation, for: requested) else { return }
      if result?.request.hasSameContent(as: requested) != true || result?.image == nil {
        let message = await MediaLoadFailure.message(for: error, url: requested.asset.url)
        guard !Task.isCancelled, requestGate.accepts(generation, for: requested), let message else { return }
        if result?.request.hasSameContent(as: requested) != true || result?.image == nil {
          result = ThumbnailLoadResult(request: requested, image: nil, errorMessage: message)
        }
      }
    }
  }

  private func refineOverviewImage() async {
    guard prefersCompactPreview, !Task.isCancelled else { return }
    let requested = request
    guard !defersLoading, !defersRefinement,
      overviewRefinementGate?.allowsRefinement(for: requested.asset.url) != false
      else { refinementGate.invalidate(); return }
    // Either SwiftUI task can resume first after a size change. Both must adopt
    // an adequate final bitmap before admitting another render/cache request.
    if adoptExistingFinalImage(for: requested) { return }
    guard displayedImageSize != nil,
      !(result?.request == requested && result?.isFinal == true), !Task.isCancelled else { return }
    let generation = refinementGate.begin(requested)
    let motionGeneration = overviewRefinementGate?.motionGeneration
    let started = onBitmapStateApplied == nil ? nil : ProcessInfo.processInfo.systemUptime
    do {
      let image: CGImage
      if requested.adjustments.isIdentity && !requested.needsPreciseImage {
        image = try await thumbnailPipeline.thumbnail(for: requested.asset,
          maxPixelSize: requested.maxPixelSize, waitsForStableVisibility: true)
      } else {
        // The compact bitmap already supplies first pixels. Go directly to the
        // final edited/HDR/precise frame instead of decoding an intermediate one.
        image = try await pipeline.renderFrame(url: requested.asset.url,
          maxPixelSize: requested.maxPixelSize, adjustments: requested.adjustments,
          prefersHDR: requested.prefersHDR).image
      }
      try Task.checkCancellation()
      guard refinementGate.accepts(generation, for: requested) else { return }
      if let overviewRefinementGate, let motionGeneration {
        guard overviewRefinementGate.allowsRefinement(for: requested.asset.url, since: motionGeneration) else { return }
      }
      applyImage(image, for: requested, started: started, isRefinement: true, isFinal: true)
    } catch {
      // A failed/cancelled refinement never replaces usable first pixels.
    }
  }

  private func adoptExistingFinalImage(for requested: ThumbnailRequest) -> Bool {
    guard prefersCompactPreview, let result, result.request != requested, let image = result.image,
      ThumbnailFinalBitmapReuse.canAdopt(previous: result.request, current: requested,
        pixelWidth: image.width, pixelHeight: image.height, previousIsFinal: result.isFinal)
      else { return false }
    self.result = ThumbnailLoadResult(request: requested, image: image, isFinal: true)
    return true
  }

  private func applyImage(_ image: CGImage, for requested: ThumbnailRequest,
    started: Double?, isRefinement: Bool, isFinal: Bool) {
    if !isFinal, result?.request == requested, result?.isFinal == true { return }
    result = ThumbnailLoadResult(request: requested, image: image, isFinal: isFinal)
    if let onBitmapStateApplied, let started {
      onBitmapStateApplied(ThumbnailBitmapStateEvent(assetURL: requested.asset.url,
        requestStartedUptime: started, appliedUptime: ProcessInfo.processInfo.systemUptime,
        pixelWidth: image.width, pixelHeight: image.height, isRefinement: isRefinement))
    }
  }

  private func failurePlaceholder(message: String?) -> some View {
    let reason = message ?? L10n.text("이미지를 표시할 수 없음")
    return GeometryReader { geometry in
      VStack(spacing: geometry.size.height < 64 ? 2 : 6) {
        if geometry.size.height >= 64 {
          Image(systemName: "exclamationmark.triangle")
            .font(ViewerUIMetrics.font(.body))
            .accessibilityHidden(true)
        }
        Text(reason)
          .font(ViewerUIMetrics.font(.caption2))
          .multilineTextAlignment(.center)
          .lineLimit(geometry.size.height < 64 ? 2 : 3)
          .fixedSize(horizontal: false, vertical: false)
      }
      .foregroundStyle(.secondary)
      .viewerPadding(geometry.size.height < 64 ? 3 : 8)
      .frame(width: geometry.size.width, height: geometry.size.height)
      .help(reason)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(reason)
    }
  }
}
