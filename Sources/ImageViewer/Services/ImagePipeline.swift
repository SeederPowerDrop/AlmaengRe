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
    case .unsupported(let url): "지원 코덱으로 ‘\(url.lastPathComponent)’을 열 수 없습니다."
    case .decodingFailed(let url): "‘\(url.lastPathComponent)’의 이미지 데이터를 읽지 못했습니다."
    case .renderingFailed(let url): "‘\(url.lastPathComponent)’을 화면용 이미지로 만들지 못했습니다."
    }
  }
}

/// Swift 동시성 경계에서 CGImage를 안전하게 전달하기 위한 불변 결과입니다.
struct RenderedFrame: @unchecked Sendable {
  let image: CGImage
  let frameIndex: Int
  let frameCount: Int
  let duration: TimeInterval?
}

private final class RenderedFrameBox: NSObject {
  let frame: RenderedFrame

  init(_ frame: RenderedFrame) {
    self.frame = frame
  }
}

private final class ImageSourceBox: NSObject {
  let source: CGImageSource

  init(_ source: CGImageSource) {
    self.source = source
  }
}

/// 디코딩, 축소, 색상 변환과 필터를 한 직렬 파이프라인에서 처리합니다.
///
/// 화면에는 뷰 크기에 필요한 픽셀만 만들고, 원본 크기 이미지는 내보낼 때만
/// 렌더링합니다. NSCache는 압박이 생기면 자동으로 항목을 버립니다.
actor ImagePipeline {
  private let renderedCache = NSCache<NSString, RenderedFrameBox>()
  private let sourceCache = NSCache<NSURL, ImageSourceBox>()
  private let context: CIContext
  private let softwareContext: CIContext

  init() {
    let physicalMemory = ProcessInfo.processInfo.physicalMemory
    let cacheBytes = min(
      UInt64(768 * 1_024 * 1_024), max(UInt64(256 * 1_024 * 1_024), physicalMemory / 16))
    renderedCache.totalCostLimit = Int(cacheBytes)
    renderedCache.countLimit = 192
    sourceCache.countLimit = 24

    context = CIContext(options: [
      .cacheIntermediates: false,
      .highQualityDownsample: true,
      .name: "ImageViewer Core Image Pipeline",
    ])
    softwareContext = CIContext(options: [
      .useSoftwareRenderer: true,
      .cacheIntermediates: false,
      .highQualityDownsample: true,
      .name: "ImageViewer CPU Fallback",
    ])
  }

  func metadata(for url: URL) throws -> ImageMetadata {
    if let source = imageSource(for: url) {
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
      return ImageMetadata(
        pixelWidth: number(properties?[kCGImagePropertyPixelWidth]),
        pixelHeight: number(properties?[kCGImagePropertyPixelHeight]),
        frameCount: max(1, CGImageSourceGetCount(source)),
        bitDepth: optionalNumber(properties?[kCGImagePropertyDepth]),
        colorModel: properties?[kCGImagePropertyColorModel] as? String,
        profileName: properties?[kCGImagePropertyProfileName] as? String,
        typeIdentifier: CGImageSourceGetType(source) as String?
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
    frameIndex requestedFrameIndex: Int = 0,
    maxPixelSize: Int?,
    adjustments: ImageAdjustments,
    prefersHDR: Bool
  ) throws -> RenderedFrame {
    try Task.checkCancellation()

    let source = imageSource(for: url)
    let frameCount = max(1, source.map(CGImageSourceGetCount) ?? 1)
    let frameIndex = min(max(0, requestedFrameIndex), frameCount - 1)
    let pixelBucket = maxPixelSize.map(Self.pixelBucket) ?? 0
    let key = cacheKey(
      url: url,
      frameIndex: frameIndex,
      pixelBucket: pixelBucket,
      adjustments: adjustments,
      prefersHDR: prefersHDR
    )

    if let cached = renderedCache.object(forKey: key) {
      return cached.frame
    }

    let input: CIImage
    var directlyDecodedBitmap: CGImage?
    if frameCount == 1,
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
    } else if let source,
      let frameImage = makeImageIOFrame(
        source: source,
        frameIndex: frameIndex,
        maxPixelSize: pixelBucket == 0 ? nil : pixelBucket
      )
    {
      input = CIImage(cgImage: frameImage)
    } else {
      let bitmap = try decodeCustomOrAppKit(url: url)
      directlyDecodedBitmap = bitmap
      input = CIImage(cgImage: bitmap)
    }

    // 자체 디코더가 이미 목표 크기의 표준 비트맵을 만들었고 보정도 없다면
    // 불필요한 GPU 왕복 없이 그대로 표시·저장합니다.
    if let bitmap = directlyDecodedBitmap,
      adjustments.isIdentity,
      pixelBucket == 0 || max(bitmap.width, bitmap.height) <= pixelBucket
    {
      let frame = RenderedFrame(
        image: bitmap,
        frameIndex: 0,
        frameCount: 1,
        duration: nil
      )
      renderedCache.setObject(
        RenderedFrameBox(frame),
        forKey: key,
        cost: bitmap.bytesPerRow * bitmap.height
      )
      return frame
    }

    try Task.checkCancellation()
    var image = downsample(input, maxPixelSize: pixelBucket == 0 ? nil : pixelBucket)
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

    let duration = source.flatMap {
      animationDuration(source: $0, frameIndex: frameIndex, frameCount: frameCount)
    }
    let frame = RenderedFrame(
      image: rendered,
      frameIndex: frameIndex,
      frameCount: frameCount,
      duration: duration
    )
    let cost = rendered.bytesPerRow * rendered.height
    renderedCache.setObject(RenderedFrameBox(frame), forKey: key, cost: cost)
    return frame
  }

  func prefetch(urls: [URL], maxPixelSize: Int, prefersHDR: Bool) {
    for url in urls {
      guard !Task.isCancelled else { return }
      _ = try? renderFrame(
        url: url,
        maxPixelSize: maxPixelSize,
        adjustments: .identity,
        prefersHDR: prefersHDR
      )
    }
  }

  func purgeCaches() {
    renderedCache.removeAllObjects()
    sourceCache.removeAllObjects()
    context.clearCaches()
    softwareContext.clearCaches()
  }

  private func imageSource(for url: URL) -> CGImageSource? {
    if let cached = sourceCache.object(forKey: url as NSURL) {
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

    sourceCache.setObject(ImageSourceBox(source), forKey: url as NSURL)
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
      options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
    }
    return CGImageSourceCreateThumbnailAtIndex(source, frameIndex, options as CFDictionary)
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

  private func applying(_ adjustments: ImageAdjustments, to input: CIImage) -> CIImage {
    var image = input

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

    switch adjustments.normalizedQuarterTurns {
    case 1: image = image.oriented(.right)
    case 2: image = image.oriented(.down)
    case 3: image = image.oriented(.left)
    default: break
    }

    return image
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

  private func cacheKey(
    url: URL,
    frameIndex: Int,
    pixelBucket: Int,
    adjustments: ImageAdjustments,
    prefersHDR: Bool
  ) -> NSString {
    let value = [
      url.path,
      String(frameIndex),
      String(pixelBucket),
      String(format: "%.4f", adjustments.brightness),
      String(format: "%.4f", adjustments.contrast),
      String(format: "%.4f", adjustments.saturation),
      String(format: "%.4f", adjustments.highlights),
      adjustments.isInverted ? "1" : "0",
      String(adjustments.normalizedQuarterTurns),
      prefersHDR ? "hdr" : "sdr",
    ].joined(separator: "|")
    return value as NSString
  }

  private static func pixelBucket(_ value: Int) -> Int {
    let clamped = max(64, value)
    return ((clamped + 255) / 256) * 256
  }

  private func number(_ value: Any?) -> Int {
    (value as? NSNumber)?.intValue ?? 0
  }

  private func optionalNumber(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue
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
