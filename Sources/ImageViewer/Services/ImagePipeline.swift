import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

enum ImagePipelineError: LocalizedError {
  case unsupported(URL)
  case decodingFailed(URL)
  case renderingFailed(URL)

  var errorDescription: String? {
    switch self {
    case .unsupported(let url):
      L10n.format("지원 코덱으로 ‘%@’을 열 수 없습니다.", url.lastPathComponent)
    case .decodingFailed(let url):
      L10n.format("‘%@’의 이미지 데이터를 읽지 못했습니다.", url.lastPathComponent)
    case .renderingFailed(let url):
      L10n.format("‘%@’을 화면용 이미지로 만들지 못했습니다.", url.lastPathComponent)
    }
  }
}

/// Swift 동시성 경계에서 CGImage를 안전하게 전달하기 위한 불변 결과입니다.
struct RenderedFrame: @unchecked Sendable {
  let image: CGImage
  let frameIndex: Int
  let frameCount: Int
  let duration: TimeInterval?
  let sourcePixelSize: CGSize?

  init(image: CGImage, frameIndex: Int, frameCount: Int, duration: TimeInterval?,
    sourcePixelSize: CGSize? = nil)
  {
    self.image = image
    self.frameIndex = frameIndex
    self.frameCount = frameCount
    self.duration = duration
    self.sourcePixelSize = sourcePixelSize
  }
}

private final class ImageSourceBox: NSObject {
  let source: CGImageSource

  init(_ source: CGImageSource) {
    self.source = source
  }
}

private struct FrameCacheKey: Hashable, Sendable {
  let file: ImageFileVersion
  let frameIndex: Int
  let pixelSize: Int?
  let adjustments: ImageAdjustments
  let prefersHDR: Bool
  let generation: UInt64

  var needsSerialDecoder: Bool {
    // Full-size exports, RAW, TIFF, floating point and custom decoders may need
    // a full-size workspace even when their resulting thumbnail is small.
    guard pixelSize != nil else { return true }
    return !["jpg", "jpeg", "png", "heic", "heif", "hif", "webp", "gif", "avif", "jxl", "bmp"]
      .contains(file.url.pathExtension.lowercased())
  }
}

/// A small worker pool keeps multi-image pages moving without spawning a decoder
/// per file. The scheduler prioritizes visible work and shares identical requests.
actor ImagePipeline {
  private let workers = (0..<4).map { _ in ImageDecoder() }
  private let largeImageDecoder = ImageDecoder()
  private let metadataDecoder = ImageDecoder()
  private let governor: ImageResourceGovernor
  private let renderNamespace = UUID()
  private let metadataNamespace = UUID()
  private let cacheClientID = UUID()
  private var cache = ImageCostCache<FrameCacheKey, RenderedFrame>(costLimit: 0)
  private var generation: UInt64 = 0
  private var resourceRevision: UInt64 = 0
  private var registeredCacheClient = false

  init(maxConcurrentDecodes: Int? = nil, governor: ImageResourceGovernor? = nil) {
    self.governor = governor ?? ImageResourceGovernor(
      mode: maxConcurrentDecodes == nil ? .comfortable : .priority,
      maximumConcurrentLoadsOverride: maxConcurrentDecodes)
  }

  func metadata(for url: URL) async throws -> ImageMetadata {
    try Task.checkCancellation()
    let decoder = metadataDecoder
    return try await governor.value(
      for: ImageResourceWorkKey(namespace: metadataNamespace, key: ImageFileVersion(url: url)),
      url: url
    ) { _ in
      try await decoder.metadata(for: url)
    }
  }

  func renderFrame(
    url: URL,
    frameIndex: Int = 0,
    maxPixelSize: Int?,
    adjustments: ImageAdjustments,
    prefersHDR: Bool,
    priority: ImageWorkPriority = .visible
  ) async throws -> RenderedFrame {
    try Task.checkCancellation()
    await registerCacheClientIfNeeded()
    let key = FrameCacheKey(
      file: ImageFileVersion(url: url), frameIndex: max(0, frameIndex),
      pixelSize: maxPixelSize.map(ImageLoadingPolicy.pixelBucket),
      adjustments: adjustments, prefersHDR: prefersHDR, generation: generation)
    if let frame = cache.value(for: key) { return frame }

    let workers = workers
    let largeImageDecoder = largeImageDecoder
    let frame = try await governor.value(
      for: ImageResourceWorkKey(namespace: renderNamespace, key: key), url: url, priority: priority
    ) { slot in
      let decoder = key.needsSerialDecoder ? largeImageDecoder : workers[slot]
      return try await decoder.renderFrame(
        url: key.file.url, frameIndex: key.frameIndex, maxPixelSize: key.pixelSize,
        adjustments: key.adjustments, prefersHDR: key.prefersHDR,
        hdrFallback: key.needsSerialDecoder ? nil : largeImageDecoder)
    }
    try Task.checkCancellation()
    if key.pixelSize != nil, key.generation == generation {
      cache.insert(frame, for: key, cost: frame.image.bytesPerRow * frame.image.height)
    }
    return frame
  }

  func prefetch(urls: [URL], maxPixelSize: Int, prefersHDR: Bool) async {
    guard let first = urls.first else { return }
    let limits = await governor.limits(for: first)
    guard limits.permitsSpeculation else { return }
    for url in urls.prefix(limits.prefetchCount) {
      guard !Task.isCancelled else { return }
      _ = try? await renderFrame(url: url, maxPixelSize: maxPixelSize,
        adjustments: .identity, prefersHDR: prefersHDR, priority: .prefetch)
    }
  }

  func purgeCaches() async {
    generation &+= 1
    cache.removeAll()
    await clearDecoderCaches()
  }

  private func registerCacheClientIfNeeded() async {
    guard !registeredCacheClient else { return }
    registeredCacheClient = true
    await governor.registerCacheClient(id: cacheClientID) { [weak self] update in
      await self?.applyResourceLimits(update)
    }
  }

  private func applyResourceLimits(_ update: ImageResourceUpdate) async {
    guard update.revision >= resourceRevision else { return }
    resourceRevision = update.revision
    let smaller = update.limits.renderCacheBytes < cache.costLimit
    cache.costLimit = update.limits.renderCacheBytes
    if smaller {
      generation &+= 1
      cache.removeAll()
      await clearDecoderCaches()
    }
  }

  private func clearDecoderCaches() async {
    for decoder in workers { await decoder.purgeCaches() }
    await largeImageDecoder.purgeCaches()
    await metadataDecoder.purgeCaches()
  }
}

/// Each scheduler slot owns a decoder. Synchronous codec calls never run on the UI actor.
private actor ImageDecoder {
  private let sourceCache = NSCache<NSString, ImageSourceBox>()
  private var existingContext: CIContext?
  private var context: CIContext {
    if let existingContext { return existingContext }
    let context = CIContext(options: [
      .cacheIntermediates: false,
      .highQualityDownsample: true,
      .name: "ImageViewer Core Image Decoder",
    ])
    existingContext = context
    return context
  }
  private var existingSoftwareContext: CIContext?
  private var softwareContext: CIContext {
    if let existingSoftwareContext { return existingSoftwareContext }
    let context = CIContext(options: [
      .useSoftwareRenderer: true,
      .cacheIntermediates: false,
      .highQualityDownsample: true,
      .name: "ImageViewer CPU Fallback",
    ])
    existingSoftwareContext = context
    return context
  }

  init() {
    sourceCache.countLimit = 2
  }

  func metadata(for url: URL) throws -> ImageMetadata {
    try Task.checkCancellation()
    return try autoreleasepool { try readMetadata(for: url) }
  }

  private func readMetadata(for url: URL) throws -> ImageMetadata {
    if let source = imageSource(for: url) {
      let properties =
        CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
      let exif = dictionary(properties[kCGImagePropertyExifDictionary])
      let tiff = dictionary(properties[kCGImagePropertyTIFFDictionary])
      let gps = dictionary(properties[kCGImagePropertyGPSDictionary])
      let capturedAt: String?
      if let originalDate = text(exif[kCGImagePropertyExifDateTimeOriginal]) {
        capturedAt = originalDate
      } else {
        capturedAt = text(tiff[kCGImagePropertyTIFFDateTime])
      }
      return ImageMetadata(
        pixelWidth: number(properties[kCGImagePropertyPixelWidth]),
        pixelHeight: number(properties[kCGImagePropertyPixelHeight]),
        frameCount: max(1, CGImageSourceGetCount(source)),
        bitDepth: optionalNumber(properties[kCGImagePropertyDepth]),
        colorModel: text(properties[kCGImagePropertyColorModel]),
        profileName: text(properties[kCGImagePropertyProfileName]),
        typeIdentifier: CGImageSourceGetType(source) as String?,
        orientation: optionalNumber(properties[kCGImagePropertyOrientation]),
        hasAlpha: optionalBool(properties[kCGImagePropertyHasAlpha]),
        dpiWidth: optionalDouble(properties[kCGImagePropertyDPIWidth]),
        dpiHeight: optionalDouble(properties[kCGImagePropertyDPIHeight]),
        cameraMake: text(tiff[kCGImagePropertyTIFFMake]),
        cameraModel: text(tiff[kCGImagePropertyTIFFModel]),
        lensModel: text(exif[kCGImagePropertyExifLensModel]),
        imageDescription: text(tiff[kCGImagePropertyTIFFImageDescription]),
        copyright: text(tiff[kCGImagePropertyTIFFCopyright]),
        software: text(tiff[kCGImagePropertyTIFFSoftware]),
        artist: text(tiff[kCGImagePropertyTIFFArtist]),
        capturedAt: capturedAt,
        exposureTime: optionalDouble(exif[kCGImagePropertyExifExposureTime]),
        aperture: optionalDouble(exif[kCGImagePropertyExifFNumber]),
        iso: isoValue(exif[kCGImagePropertyExifISOSpeedRatings]),
        focalLength: optionalDouble(exif[kCGImagePropertyExifFocalLength]),
        location: imageLocation(from: gps)
      )
    }

    let image = try decodeCustomOrAppKit(url: url)
    return ImageMetadata(
      pixelWidth: image.width,
      pixelHeight: image.height,
      frameCount: 1,
      bitDepth: image.bitsPerComponent,
      colorModel: image.colorSpace?.model.description,
      profileName: image.colorSpace?.name as String?,
      typeIdentifier: nil
    )
  }

  func renderFrame(
    url: URL,
    frameIndex: Int,
    maxPixelSize: Int?,
    adjustments: ImageAdjustments,
    prefersHDR: Bool,
    hdrFallback: ImageDecoder? = nil
  ) async throws -> RenderedFrame {
    try Task.checkCancellation()
    // Gain-map JPEG and high-bit HEIC/AVIF can require a full HDR workspace too.
    // Inspect before decoding and route them through the single large-image actor.
    if let hdrFallback, let source = imageSource(for: url),
      shouldPreserveHDR(source: source, url: url)
    {
      return try await hdrFallback.renderFrame(url: url, frameIndex: frameIndex,
        maxPixelSize: maxPixelSize, adjustments: adjustments, prefersHDR: prefersHDR)
    }
    return try autoreleasepool {
      try decodeFrame(url: url, frameIndex: frameIndex, maxPixelSize: maxPixelSize,
        adjustments: adjustments, prefersHDR: prefersHDR)
    }
  }

  private func decodeFrame(
    url: URL,
    frameIndex requestedFrameIndex: Int,
    maxPixelSize: Int?,
    adjustments: ImageAdjustments,
    prefersHDR: Bool
  ) throws -> RenderedFrame {
    try Task.checkCancellation()
    let source = imageSource(for: url)
    let frameCount = max(1, source.map(CGImageSourceGetCount) ?? 1)
    let frameIndex = min(max(0, requestedFrameIndex), frameCount - 1)
    let pixelBucket = maxPixelSize ?? 0
    let preservesHDRSource = source.map { shouldPreserveHDR(source: $0, url: url) } ?? true
    var sourcePixelSize: CGSize?
    if let source,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, frameIndex, nil) as? [CFString: Any]
    {
      let width = number(properties[kCGImagePropertyPixelWidth])
      let height = number(properties[kCGImagePropertyPixelHeight])
      if width > 0, height > 0 {
        let swapsAxes = (5...8).contains(number(properties[kCGImagePropertyOrientation]))
        sourcePixelSize = CGSize(width: swapsAxes ? height : width, height: swapsAxes ? width : height)
      }
    }
    let decodePixels = cropDecodePixelSize(
      requestedPixels: maxPixelSize, sourceSize: sourcePixelSize, adjustments: adjustments)

    let input: CIImage
    var directlyDecodedBitmap: CGImage?
    var shouldDecodeWithImageIO = frameCount > 1
    if !shouldDecodeWithImageIO, pixelBucket > 0, source != nil {
      shouldDecodeWithImageIO = !preservesHDRSource
    }
    if let source,
      shouldDecodeWithImageIO,
      let frameImage = makeImageIOFrame(
        source: source,
        frameIndex: frameIndex,
        maxPixelSize: decodePixels
      )
    {
      // 화면 크기가 정해진 SDR 이미지는 Image I/O 단계에서 먼저 축소합니다.
      // 수천만 화소 JPEG/RAW를 온전히 디코딩한 뒤 줄이는 비용을 피하는 핵심 경로입니다.
      input = CIImage(cgImage: frameImage)
      if !preservesHDRSource { directlyDecodedBitmap = frameImage }
    } else if frameCount == 1,
      let directImage = CIImage(
        contentsOf: url,
        options: [
          .applyOrientationProperty: true,
          .expandToHDR: prefersHDR,
          .cacheImmediately: false,
        ]
      )
    {
      input = directImage
    } else {
      let bitmap = try decodeCustomOrAppKit(url: url)
      directlyDecodedBitmap = bitmap
      input = CIImage(cgImage: bitmap)
    }

    if sourcePixelSize == nil { sourcePixelSize = input.extent.size }
    if adjustments.normalizedQuarterTurns.isMultiple(of: 2) == false, let size = sourcePixelSize {
      sourcePixelSize = CGSize(width: size.height, height: size.width)
    }
    if let crop = adjustments.effectiveCrop, let size = sourcePixelSize {
      sourcePixelSize = crop.pixelRect(in: size).size
    }

    // A decoded SDR bitmap already carries its ICC profile. Core Animation performs
    // display color management; an identity edit needs no extra GPU/P3/half-float copy.
    if let bitmap = directlyDecodedBitmap,
      adjustments.isIdentity,
      pixelBucket == 0 || max(bitmap.width, bitmap.height) <= pixelBucket
    {
      try Task.checkCancellation()
      return RenderedFrame(
        image: bitmap,
        frameIndex: frameIndex,
        frameCount: frameCount,
        duration: source.flatMap {
          animationDuration(source: $0, frameIndex: frameIndex, frameCount: frameCount)
        },
        sourcePixelSize: sourcePixelSize
      )
    }

    try Task.checkCancellation()
    // 원본 좌표에서 회전·자르기를 먼저 적용해야 작은 선택 영역도 화면 크기를 채웁니다.
    var image = applyingGeometry(adjustments, to: input)
    image = downsample(image, maxPixelSize: maxPixelSize)
    image = applying(adjustments, to: image)

    let extent = image.extent.integral
    guard !extent.isEmpty, extent.width.isFinite, extent.height.isFinite else {
      throw ImagePipelineError.decodingFailed(url)
    }

    let outputColorSpace =
      prefersHDR
      ? CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
      : CGColorSpace(name: CGColorSpace.displayP3)!
    let outputFormat: CIFormat = prefersHDR ? .RGBAh : .RGBA8

    let colorManagedImage = context.createCGImage(
      image,
      from: extent,
      format: outputFormat,
      colorSpace: outputColorSpace
    )
    // 일부 매우 작은 이미지나 비표준 비트맵은 강제 출력 색공간 변환을
    // 거부할 수 있습니다. 그 경우 Core Image가 고른 원본 호환 형식으로 재시도합니다.
    let compatibleImage =
      colorManagedImage
      ?? context.createCGImage(image, from: extent)
      ?? softwareContext.createCGImage(
        image,
        from: extent,
        format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
      )
      ?? softwareContext.createCGImage(image, from: extent)
    guard let rendered = compatibleImage else {
      throw ImagePipelineError.renderingFailed(url)
    }

    let duration: TimeInterval?
    if let source {
      duration = animationDuration(
        source: source, frameIndex: frameIndex, frameCount: frameCount)
    } else {
      duration = nil
    }
    let frame = RenderedFrame(
      image: rendered,
      frameIndex: frameIndex,
      frameCount: frameCount,
      duration: duration,
      sourcePixelSize: sourcePixelSize
    )
    try Task.checkCancellation()
    return frame
  }

  func purgeCaches() {
    sourceCache.removeAllObjects()
    existingContext?.clearCaches()
    existingSoftwareContext?.clearCaches()
  }

  private func imageSource(for url: URL) -> CGImageSource? {
    let key = ImageFileVersion(url: url).encoded
    if let cached = sourceCache.object(forKey: key) {
      return cached.source
    }

    guard
      let source = CGImageSourceCreateWithURL(
        url as CFURL,
        [
          kCGImageSourceShouldCache: false
        ] as CFDictionary)
    else {
      return nil
    }

    sourceCache.setObject(ImageSourceBox(source), forKey: key)
    return source
  }

  private func makeImageIOFrame(
    source: CGImageSource,
    frameIndex: Int,
    maxPixelSize: Int?
  ) -> CGImage? {
    var options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceShouldAllowFloat: true,
    ]
    if let maxPixelSize {
      let properties =
        CGImageSourceCopyPropertiesAtIndex(source, frameIndex, nil) as? [CFString: Any]
      let sourceMaximumDimension = max(
        number(properties?[kCGImagePropertyPixelWidth]),
        number(properties?[kCGImagePropertyPixelHeight])
      )
      // Image I/O는 원본보다 큰 썸네일 상한을 오류로 기록합니다. 작은 이미지에는
      // 원본 치수를 상한으로 써 불필요한 업스케일과 로그 잡음을 함께 피합니다.
      options[kCGImageSourceThumbnailMaxPixelSize] =
        sourceMaximumDimension > 0 ? min(maxPixelSize, sourceMaximumDimension) : maxPixelSize
    }
    return CGImageSourceCreateThumbnailAtIndex(source, frameIndex, options as CFDictionary)
  }

  private func shouldPreserveHDR(source: CGImageSource, url: URL) -> Bool {
    let extensionName = url.pathExtension.lowercased()
    if extensionName == "hdr" || extensionName == "exr" {
      return true
    }

    if CGImageSourceCopyAuxiliaryDataInfoAtIndex(
      source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
    {
      return true
    }

    if #available(macOS 15.0, *),
      CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
    {
      return true
    }

    let wideDynamicRangeContainers: Set<String> = ["avif", "heic", "heif", "hif", "jxl"]
    guard wideDynamicRangeContainers.contains(extensionName),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
      return false
    }
    return number(properties[kCGImagePropertyDepth]) > 8
  }

  private func decodeCustomOrAppKit(url: URL) throws -> CGImage {
    switch url.pathExtension.lowercased() {
    case "qoi":
      return try QOIDecoder.decode(url: url)
    case "pcx":
      return try PCXDecoder.decode(url: url)
    default:
      // NSImage는 SVG/PDF 계열처럼 Image I/O가 직접 노출하지 않는 벡터 표현을
      // AppKit 플러그인으로 읽을 수 있어 마지막 폴백으로 사용합니다.
      guard let image = NSImage(contentsOf: url) else {
        throw ImagePipelineError.unsupported(url)
      }
      var proposedRect = CGRect(origin: .zero, size: image.size)
      guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
      else {
        throw ImagePipelineError.decodingFailed(url)
      }
      return cgImage
    }
  }

  private func downsample(_ image: CIImage, maxPixelSize: Int?) -> CIImage {
    guard let maxPixelSize, maxPixelSize > 0 else { return image }
    let maximumDimension = max(image.extent.width, image.extent.height)
    guard maximumDimension > CGFloat(maxPixelSize) else { return image }

    let scale = CGFloat(maxPixelSize) / maximumDimension
    return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
  }

  private func cropDecodePixelSize(
    requestedPixels: Int?, sourceSize: CGSize?, adjustments: ImageAdjustments
  ) -> Int? {
    guard let requestedPixels, let crop = adjustments.effectiveCrop else { return requestedPixels }
    let retainedFraction: Double
    if var size = sourceSize, size.width > 0, size.height > 0 {
      if !adjustments.normalizedQuarterTurns.isMultiple(of: 2) {
        size = CGSize(width: size.height, height: size.width)
      }
      let retained = crop.pixelRect(in: size).size
      retainedFraction = max(retained.width, retained.height) / max(size.width, size.height)
    } else {
      retainedFraction = max(crop.width, crop.height)
    }
    // A small crop must not force every thumbnail through an unbounded full decode.
    // Keep the existing 8K ceiling and allow at most four times the requested edge.
    let multiplier = min(4, max(1, 1 / max(retainedFraction, 0.000_001)))
    return min(8_192, max(requestedPixels, Int(ceil(Double(requestedPixels) * multiplier))))
  }

  private func applyingGeometry(_ adjustments: ImageAdjustments, to input: CIImage) -> CIImage {
    var image = input
    switch adjustments.normalizedQuarterTurns {
    case 1: image = image.oriented(.right)
    case 2: image = image.oriented(.down)
    case 3: image = image.oriented(.left)
    default: break
    }
    if let crop = adjustments.effectiveCrop {
      image = image.cropped(to: crop.coreImageRect(in: image.extent))
    }
    let extent = image.extent
    if extent.origin != .zero {
      image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }
    return image
  }

  private func applying(_ adjustments: ImageAdjustments, to input: CIImage) -> CIImage {
    guard !adjustments.isIdentity else { return input }
    var image = input

    let noise = adjustmentValue(adjustments.noiseReduction, range: 0...1)
    if noise > 0 {
      let extent = image.extent
      let filter = CIFilter.noiseReduction()
      filter.inputImage = image.clampedToExtent()
      filter.noiseLevel = Float(noise * 0.1)
      filter.sharpness = 0
      if let output = filter.outputImage { image = output.cropped(to: extent) }
    }

    let exposure = adjustmentValue(adjustments.exposure, range: -4...4)
    if exposure != 0 {
      let filter = CIFilter.exposureAdjust()
      filter.inputImage = image
      filter.ev = Float(exposure)
      if let output = filter.outputImage { image = output }
    }

    let temperature = adjustmentValue(adjustments.temperature, range: -100...100)
    if temperature != 0 {
      let filter = CIFilter.temperatureAndTint()
      filter.inputImage = image
      filter.neutral = CIVector(x: 6_500, y: 0)
      // Lower target white-point temperatures add warmth; this is a relative control,
      // not a claim to recover the camera's original Kelvin white-balance setting.
      filter.targetNeutral = CIVector(x: 6_500 - temperature * 30, y: 0)
      if let output = filter.outputImage { image = output }
    }

    let hue = adjustmentValue(adjustments.hue, range: -180...180)
    if hue != 0 {
      let filter = CIFilter.hueAdjust()
      filter.inputImage = image
      filter.angle = Float(hue * .pi / 180)
      if let output = filter.outputImage { image = output }
    }

    let vibrance = adjustmentValue(adjustments.vibrance, range: -1...1)
    if vibrance != 0 {
      let filter = CIFilter.vibrance()
      filter.inputImage = image
      filter.amount = Float(vibrance)
      if let output = filter.outputImage { image = output }
    }

    if adjustments.brightness != 0 || adjustments.contrast != 1 || adjustments.saturation != 1 {
      let controls = CIFilter.colorControls()
      controls.inputImage = image
      controls.brightness = Float(adjustments.brightness)
      controls.contrast = Float(adjustments.contrast)
      controls.saturation = Float(adjustments.saturation)
      if let output = controls.outputImage { image = output }
    }

    if adjustments.highlights != 0 {
      let highlights = CIFilter.highlightShadowAdjust()
      highlights.inputImage = image
      highlights.highlightAmount = Float(max(0, min(2, 1 + adjustments.highlights)))
      if let output = highlights.outputImage { image = output }
    }

    if adjustments.isInverted {
      let invert = CIFilter.colorInvert()
      invert.inputImage = image
      if let output = invert.outputImage { image = output }
    }

    let sharpness = adjustmentValue(adjustments.sharpness, range: 0...2)
    if sharpness > 0 {
      let extent = image.extent
      let filter = CIFilter.sharpenLuminance()
      filter.inputImage = image.clampedToExtent()
      filter.sharpness = Float(sharpness)
      if let output = filter.outputImage { image = output.cropped(to: extent) }
    }

    return image
  }

  private func adjustmentValue(_ value: Double, range: ClosedRange<Double>) -> Double {
    value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : 0
  }

  private func animationDuration(
    source: CGImageSource,
    frameIndex: Int,
    frameCount: Int
  ) -> TimeInterval? {
    guard frameCount > 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, frameIndex, nil)
        as? [AnyHashable: Any]
    else {
      return nil
    }

    let unclamped = findDelay(in: properties, keyContains: "UnclampedDelayTime")
    let regular = findDelay(in: properties, keyContains: "DelayTime")
    let value = unclamped ?? regular ?? 0.1
    return max(0.02, value)
  }

  private func findDelay(in value: Any, keyContains needle: String) -> TimeInterval? {
    guard let dictionary = value as? [AnyHashable: Any] else { return nil }

    for (key, nestedValue) in dictionary {
      let keyName = String(describing: key)
      if keyName.localizedCaseInsensitiveContains(needle),
        let number = nestedValue as? NSNumber
      {
        return number.doubleValue
      }
    }

    for nestedValue in dictionary.values {
      if let found = findDelay(in: nestedValue, keyContains: needle) {
        return found
      }
    }
    return nil
  }

  private func number(_ value: Any?) -> Int {
    (value as? NSNumber)?.intValue ?? 0
  }

  private func optionalNumber(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue
  }

  private func optionalDouble(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
  }

  private func optionalBool(_ value: Any?) -> Bool? {
    (value as? NSNumber)?.boolValue
  }

  private func text(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func dictionary(_ value: Any?) -> [CFString: Any] {
    value as? [CFString: Any] ?? [:]
  }

  private func isoValue(_ value: Any?) -> Int? {
    if let number = value as? NSNumber {
      return number.intValue
    }
    if let values = value as? [NSNumber] {
      return values.first?.intValue
    }
    if let values = value as? [Any], let first = values.first {
      return optionalNumber(first)
    }
    return nil
  }

  private func imageLocation(from gps: [CFString: Any]) -> ImageLocation? {
    guard var latitude = optionalDouble(gps[kCGImagePropertyGPSLatitude]),
      var longitude = optionalDouble(gps[kCGImagePropertyGPSLongitude])
    else {
      return nil
    }

    switch text(gps[kCGImagePropertyGPSLatitudeRef])?.uppercased() {
    case "S": latitude = -abs(latitude)
    case "N": latitude = abs(latitude)
    default: break
    }
    switch text(gps[kCGImagePropertyGPSLongitudeRef])?.uppercased() {
    case "W": longitude = -abs(longitude)
    case "E": longitude = abs(longitude)
    default: break
    }

    guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
      return nil
    }

    var altitude = optionalDouble(gps[kCGImagePropertyGPSAltitude])
    if optionalNumber(gps[kCGImagePropertyGPSAltitudeRef]) == 1, let value = altitude {
      altitude = -abs(value)
    }

    return ImageLocation(
      latitude: latitude,
      longitude: longitude,
      altitude: altitude,
      direction: optionalDouble(gps[kCGImagePropertyGPSImgDirection])
    )
  }
}

extension CGColorSpaceModel {
  fileprivate var description: String {
    switch self {
    case .unknown: "Unknown"
    case .monochrome: "Monochrome"
    case .rgb: "RGB"
    case .cmyk: "CMYK"
    case .lab: "Lab"
    case .deviceN: "Device N"
    case .indexed: "Indexed"
    case .pattern: "Pattern"
    case .XYZ: "XYZ"
    @unknown default: "Unknown"
    }
  }
}
