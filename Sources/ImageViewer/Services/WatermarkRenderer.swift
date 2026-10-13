import CoreGraphics
import CoreImage
import CoreText
import Darwin
import Foundation
import ImageIO

/// The bounded alpha raster lets preview move an overlay without compositing the
/// photograph again during each pointer event. Layout uses original-image pixels.
struct WatermarkRenderResult: Sendable {
  let image: CGImage
  let layout: WatermarkLayout?
  let watermarkImage: CGImage?
}

/// Shared by export and preview. Only a bounded set of small EXIF strings is cached;
/// source pixels, logo bitmaps, and full-size output images are never cached here.
actor WatermarkRenderer {
  static let metadataCacheLimit = 32
  static let maximumOverlayDimension = 4_096

  private struct SourceKey: Hashable, Sendable {
    let url: URL
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
  }

  private var metadataCache: [SourceKey: [WatermarkMetadataField: String]] = [:]
  private var metadataOrder: [SourceKey] = []
  private(set) var metadataLoadCount = 0
  var metadataCacheEntryCount: Int { metadataCache.count }

  private lazy var context = CIContext(options: [
    .cacheIntermediates: false, .workingFormat: CIFormat.RGBAh.rawValue,
    .name: "ImageViewer Watermark",
  ])

  /// Receives already-oriented, adjusted, resized pixels. Canvas expansion moves
  /// these pixels without scaling them and preserves their RGB color space.
  func render(image: CGImage, sourceURL: URL, options: WatermarkOptions) throws -> CGImage {
    try renderResult(image: image, sourceURL: sourceURL, options: options).image
  }

  func renderResult(image: CGImage, sourceURL: URL,
    options: WatermarkOptions) throws -> WatermarkRenderResult {
    try Task.checkCancellation()
    try options.validate()
    let unchanged = WatermarkRenderResult(image: image, layout: nil, watermarkImage: nil)
    guard options.isEnabled, options.hasContent, options.opacity > 0 else { return unchanged }
    var lines = options.text.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    if !options.metadataFields.isEmpty {
      let values: [WatermarkMetadataField: String]
      if options.metadataFields == [.filename] {
        _ = try Self.sourceKey(sourceURL)
        values = [.filename: Self.clean(sourceURL.lastPathComponent) ?? sourceURL.lastPathComponent]
      } else {
        values = try metadataValues(sourceURL: sourceURL)
      }
      for field in WatermarkMetadataField.allCases where options.metadataFields.contains(field) {
        if let value = values[field] { lines.append("\(field.title): \(value)") }
      }
    }
    try Task.checkCancellation()
    guard !lines.isEmpty || options.logoURL != nil else { return unchanged }
    let overlay = try Self.makeOverlay(canvasWidth: image.width, canvasHeight: image.height,
      lines: lines, options: options)
    try Task.checkCancellation()
    let layout = overlay.layout
    let canvas = layout.canvasBounds
    let outputRect = CGRect(origin: .zero, size: canvas.size)
    // Convert top-left layout coordinates to Core Image's bottom-left coordinates.
    // Integral canvas bounds make this an exact translation of source pixels.
    let source = CIImage(cgImage: image).transformed(by: CGAffineTransform(
      translationX: -canvas.minX, y: canvas.maxY - CGFloat(image.height)))
    let mark = CIImage(cgImage: overlay.image)
      .transformed(by: CGAffineTransform(scaleX: layout.effectiveRect.width / CGFloat(overlay.image.width),
        y: layout.effectiveRect.height / CGFloat(overlay.image.height)))
      .transformed(by: CGAffineTransform(translationX: layout.effectiveRect.minX - canvas.minX,
        y: canvas.maxY - layout.effectiveRect.maxY))
    let transparent = CIImage(color: .clear).cropped(to: outputRect)
    let composite = mark.composited(over: source).composited(over: transparent)
    // Keep the source profile and floating-point headroom. Drawing the whole photo
    // into an 8-bit sRGB bitmap here would clip HDR and desaturate wide-gamut pixels.
    let sourceSpace = image.colorSpace
    let colorSpace: CGColorSpace
    if let sourceSpace, sourceSpace.model == .rgb {
      colorSpace = sourceSpace
    } else {
      colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    }
    let format: CIFormat = image.bitsPerComponent > 8 ? .RGBAh : .RGBA8
    guard let output = context.createCGImage(composite, from: outputRect,
      format: format, colorSpace: colorSpace)
    else { throw WatermarkError.renderFailed }
    try Task.checkCancellation()
    return WatermarkRenderResult(image: output, layout: layout, watermarkImage: overlay.image)
  }

  /// Metadata is inspected without decoding an image. Settings-only preview changes
  /// reuse the snapshot until the file's identity, size, modification, or change time changes.
  func metadataValues(sourceURL: URL) throws -> [WatermarkMetadataField: String] {
    try Task.checkCancellation()
    let access = sourceURL.startAccessingSecurityScopedResource()
    defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
    let key = try Self.sourceKey(sourceURL)
    if let cached = metadataCache[key] { return cached }
    let values = try Self.readMetadata(sourceURL: sourceURL)
    try Task.checkCancellation()
    // Do not retain an obsolete snapshot if the source changed while it was read.
    guard key == (try Self.sourceKey(sourceURL)) else { throw WatermarkError.sourceMetadataUnreadable }
    metadataLoadCount += 1
    for old in metadataOrder where old.url == key.url { metadataCache.removeValue(forKey: old) }
    metadataOrder.removeAll { $0.url == key.url }
    while metadataOrder.count >= Self.metadataCacheLimit {
      metadataCache.removeValue(forKey: metadataOrder.removeFirst())
    }
    metadataOrder.append(key)
    metadataCache[key] = values
    return values
  }

  private nonisolated static func sourceKey(_ url: URL) throws -> SourceKey {
    guard url.isFileURL else { throw WatermarkError.sourceMetadataUnreadable }
    var info = stat()
    let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
    let status = resolved.withUnsafeFileSystemRepresentation { pointer -> Int32 in
      guard let pointer else { return -1 }
      return Darwin.lstat(pointer, &info)
    }
    guard status == 0 else { throw WatermarkError.sourceMetadataUnreadable }
    return SourceKey(url: url.standardizedFileURL, device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
      size: Int64(info.st_size), modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
      changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
  }

  private nonisolated static func readMetadata(sourceURL: URL) throws -> [WatermarkMetadataField: String] {
    var values: [WatermarkMetadataField: String] = [:]
    values[.filename] = clean(sourceURL.lastPathComponent)
    let readOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, readOptions),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
      // The app also decodes formats such as QOI through its own codecs. Their
      // filename remains usable; EXIF unavailable through ImageIO is simply absent.
      return values
    }
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    values[.captureDate] = clean(exif[kCGImagePropertyExifDateTimeOriginal])
      ?? clean(exif[kCGImagePropertyExifDateTimeDigitized]) ?? clean(tiff[kCGImagePropertyTIFFDateTime])
    values[.cameraMake] = clean(tiff[kCGImagePropertyTIFFMake])
    values[.cameraModel] = clean(tiff[kCGImagePropertyTIFFModel])
    values[.lens] = clean(exif[kCGImagePropertyExifLensModel])
    if let exposure = positiveNumber(exif[kCGImagePropertyExifExposureTime]) {
      let denominator = 1 / exposure
      if denominator >= 2, abs(denominator - denominator.rounded()) / denominator < 0.01 {
        values[.shutterSpeed] = "1/\(Int(denominator.rounded())) s"
      } else {
        values[.shutterSpeed] = "\(String(format: "%.4g", locale: Locale(identifier: "en_US_POSIX"), exposure)) s"
      }
    }
    if let aperture = positiveNumber(exif[kCGImagePropertyExifFNumber]) {
      values[.aperture] = "f/\(decimal(aperture))"
    }
    if let iso = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber],
      let first = iso.first, let value = positiveNumber(first) {
      values[.iso] = decimal(value)
    } else if let iso = positiveNumber(exif[kCGImagePropertyExifISOSpeedRatings]) {
      values[.iso] = decimal(iso)
    }
    if let focalLength = positiveNumber(exif[kCGImagePropertyExifFocalLength]) {
      values[.focalLength] = "\(decimal(focalLength)) mm"
    }
    return values
  }

  private nonisolated static func positiveNumber(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber else { return nil }
    let result = number.doubleValue
    return result.isFinite && result >= 0.000_000_001 && result < 1_000_000_000 ? result : nil
  }

  private nonisolated static func decimal(_ value: Double) -> String {
    String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
      .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
  }

  private nonisolated static func clean(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let cleaned = string.components(separatedBy: .controlCharacters).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? nil : String(cleaned.prefix(256))
  }

  private struct Overlay {
    let image: CGImage
    let layout: WatermarkLayout
  }

  private struct TextLine {
    let line: CTLine
    let width: CGFloat
    let left: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let height: CGFloat
  }

  /// CoreText and the logo are rasterized only into the bounded watermark block.
  /// Font size depends on the original resized image, never on how many metadata
  /// fields are selected. A taller block must fit or explicitly expand the canvas.
  private nonisolated static func makeOverlay(canvasWidth: Int, canvasHeight: Int,
    lines: [String], options: WatermarkOptions) throws -> Overlay {
    let fontSize = CGFloat(canvasWidth) * options.sizeFraction / 8
    let font = CTFontCreateWithName(options.fontPostScriptName as CFString, fontSize, nil)
    let white = options.textColor == .white
    let textColor = CGColor(gray: white ? 1 : 0, alpha: 1)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor,
    ]
    let padding = fontSize * (options.readability == .none ? 0.125 : 0.375)
    let inset = CGFloat(min(canvasWidth, canvasHeight)) * options.marginFraction
    let wrapWidth = max(1, CGFloat(canvasWidth) - inset * 2 - padding * 2)
    let textLines = try wrappedLines(lines, attributes: attributes, font: font, width: wrapWidth)
    let textWidth = textLines.map(\.width).max() ?? 0
    let textHeight = textLines.reduce(CGFloat.zero) { $0 + $1.height }
    let logoBound = CGFloat(canvasWidth) * options.sizeFraction
    var logo: CGImage?
    if let logoURL = options.logoURL {
      logo = try downsampleLogo(url: logoURL,
        maximumPixelSize: min(maximumOverlayDimension, max(1, Int(ceil(logoBound)))))
    }
    try Task.checkCancellation()
    var logoWidth: CGFloat = 0
    var logoHeight: CGFloat = 0
    if let logo {
      let scale = logoBound / CGFloat(max(logo.width, logo.height))
      logoWidth = CGFloat(logo.width) * scale
      logoHeight = CGFloat(logo.height) * scale
    }
    let gap = logo != nil && !textLines.isEmpty ? fontSize * 0.3125 : 0
    // Integer block bounds avoid rescaling ordinary-size text when a newly added
    // line changes only the fractional typographic width or height of its block.
    let naturalWidth = max(1, ceil(max(textWidth, logoWidth) + padding * 2))
    let naturalHeight = max(1, ceil(logoHeight + gap + textHeight + padding * 2))
    let layout = try WatermarkLayout.make(
      originalSize: CGSize(width: canvasWidth, height: canvasHeight),
      overlaySize: CGSize(width: naturalWidth, height: naturalHeight),
      position: options.position, marginFraction: options.marginFraction,
      customPosition: options.customPosition, expandsCanvas: options.expandsCanvas)
    try Task.checkCancellation()
    // Validate placement/expanded allocation before allocating the overlay. The
    // bounded raster may be magnified for very large photos, but its layout and
    // physical font size remain unchanged.
    let rasterScale = min(1, CGFloat(maximumOverlayDimension) / max(naturalWidth, naturalHeight))
    let pixelWidth = max(1, min(maximumOverlayDimension, Int(ceil(naturalWidth * rasterScale))))
    let pixelHeight = max(1, min(maximumOverlayDimension, Int(ceil(naturalHeight * rasterScale))))
    guard let bitmap = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw WatermarkError.renderFailed }
    bitmap.scaleBy(x: CGFloat(pixelWidth) / naturalWidth, y: CGFloat(pixelHeight) / naturalHeight)
    // Group opacity applies once, including overlap between background and glyphs.
    bitmap.setAlpha(options.opacity)
    bitmap.beginTransparencyLayer(auxiliaryInfo: nil)
    if options.readability == .background {
      bitmap.setFillColor(CGColor(gray: white ? 0 : 1, alpha: 0.72))
      bitmap.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: naturalWidth, height: naturalHeight),
        cornerWidth: fontSize * 0.25, cornerHeight: fontSize * 0.25, transform: nil))
      bitmap.fillPath()
    }
    if let logo {
      bitmap.interpolationQuality = .high
      bitmap.draw(logo, in: CGRect(x: (naturalWidth - logoWidth) / 2,
        y: padding + textHeight + gap, width: logoWidth, height: logoHeight))
    }
    bitmap.saveGState()
    if options.readability == .shadow {
      bitmap.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.046875),
        blur: fontSize * 0.125, color: CGColor(gray: white ? 0 : 1, alpha: 0.9))
    }
    var lineTop = padding + textHeight
    for measure in textLines {
      try Task.checkCancellation()
      bitmap.textPosition = CGPoint(x: (naturalWidth - measure.width) / 2 - measure.left,
        y: lineTop - measure.height + measure.descent)
      CTLineDraw(measure.line, bitmap)
      lineTop -= measure.height
    }
    bitmap.restoreGState()
    bitmap.endTransparencyLayer()
    guard let output = bitmap.makeImage() else { throw WatermarkError.renderFailed }
    return Overlay(image: output, layout: layout)
  }

  private nonisolated static func wrappedLines(_ paragraphs: [String],
    attributes: [NSAttributedString.Key: Any], font: CTFont, width: CGFloat
  ) throws -> [TextLine] {
    let fontHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    var result: [TextLine] = []
    for paragraph in paragraphs {
      let text = paragraph as NSString
      let attributed = NSAttributedString(string: paragraph, attributes: attributes)
      let typesetter = CTTypesetterCreateWithAttributedString(attributed as CFAttributedString)
      var start = 0
      while start < text.length {
        try Task.checkCancellation()
        var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
        if count == 0 {
          count = max(1, text.rangeOfComposedCharacterSequence(at: start).length)
        }
        count = min(count, text.length - start)
        var measure = measureLine(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)),
          fontHeight: fontHeight)
        // Typographic wrapping omits italic overhang. Back up by a complete
        // character until the actual glyph bounds also fit, without shrinking.
        while measure.width > width, count > 1 {
          let last = text.rangeOfComposedCharacterSequence(at: start + count - 1)
          let shorterCount = last.location - start
          guard shorterCount > 0 else { break }
          count = shorterCount
          measure = measureLine(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)),
            fontHeight: fontHeight)
        }
        result.append(measure)
        start += count
      }
    }
    return result
  }

  private nonisolated static func measureLine(_ line: CTLine, fontHeight: CGFloat) -> TextLine {
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    let pathBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let bounds = pathBounds.isNull ? CGRect.zero : pathBounds
    let left = min(0, bounds.minX)
    ascent = max(ascent + leading, bounds.maxY)
    descent = max(descent, -bounds.minY)
    return TextLine(line: line, width: max(advance, bounds.maxX) - left,
      left: left, ascent: ascent, descent: descent,
      height: max(fontHeight, ascent + descent) * 1.12)
  }

  /// The decoder applies orientation and preserves alpha. No full logo-sized bitmap
  /// is requested, and even unusually large output canvases cap the logo allocation.
  nonisolated static func downsampleLogo(url: URL, maximumPixelSize: Int) throws -> CGImage {
    try Task.checkCancellation()
    guard url.isFileURL else { throw WatermarkError.logoUnreadable }
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    guard let source = CGImageSourceCreateWithURL(url as CFURL,
      [kCGImageSourceShouldCache: false] as CFDictionary),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(1, min(maximumOverlayDimension, maximumPixelSize)),
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary)
    else { throw WatermarkError.logoUnreadable }
    try Task.checkCancellation()
    return image
  }

}
