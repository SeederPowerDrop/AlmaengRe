import CoreGraphics
import CoreImage
import Darwin
import Foundation
import ImageIO

/// This actor confines ImageIO objects and encodes one composited frame at a time.
/// All writes go to a sibling temporary file; only finalized results are published.
actor AnimatedImageExporter {
  private lazy var resizeContext = CIContext(options: [
    .cacheIntermediates: false, .highQualityDownsample: true,
    .name: "ImageViewer Animation Export",
  ])

  func inspect(url: URL) throws -> AnimatedImageDocument {
    try Task.checkCancellation()
    return try metadata(source: open(url), url: url)
  }

  func extractFrame(sourceURL: URL, destinationURL: URL, frameIndex: Int,
    resize: BatchResizeOptions = .original) throws -> URL
  {
    try Task.checkCancellation()
    try validateDestination(source: sourceURL, destination: destinationURL, extensions: ["png"])
    let original = try FileSnapshot(sourceURL)
    let source = try open(sourceURL)
    let document = try metadata(source: source, url: sourceURL)
    guard document.frames.indices.contains(frameIndex) else { throw AnimatedImageExportError.invalidFrameRange }
    _ = try resize.dimensions(width: document.width, height: document.height)
    let temporary = try makeTemporaryFile(in: destinationURL.deletingLastPathComponent())
    defer { try? FileManager.default.removeItem(at: temporary) }
    try autoreleasepool {
      guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL,
        "public.png" as CFString, 1, nil) else { throw AnimatedImageExportError.encodingFailed }
      let image = try frame(source, index: frameIndex, document: document, resize: resize)
      CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
      try Task.checkCancellation()
      guard CGImageDestinationFinalize(destination) else { throw AnimatedImageExportError.encodingFailed }
    }
    try publish(temporary, to: destinationURL, source: sourceURL, original: original, extensions: ["png"])
    return destinationURL
  }

  func export(sourceURL: URL, destinationURL: URL, format: AnimatedImageExportFormat,
    options: AnimatedImageExportOptions,
    progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> AnimatedImageExportResult
  {
    try Task.checkCancellation()
    try validateDestination(source: sourceURL, destination: destinationURL, extensions: format.acceptedExtensions)
    guard AnimatedImageExportFormat.available.contains(format) else { throw AnimatedImageExportError.encodingFailed }
    let original = try FileSnapshot(sourceURL)
    let source = try open(sourceURL)
    let document = try metadata(source: source, url: sourceURL)
    let selected = try options.selectedFrames(in: document)
    let size = try options.resize.dimensions(width: document.width, height: document.height)
    let temporary = try makeTemporaryFile(in: destinationURL.deletingLastPathComponent())
    defer { try? FileManager.default.removeItem(at: temporary) }
    try autoreleasepool {
      guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL,
        format.typeIdentifier as CFString, selected.count, nil)
      else { throw AnimatedImageExportError.encodingFailed }
      // Both ImageIO writers accept its normalized total play count. Do not
      // substitute the GIF file's raw repeat count (which excludes play one).
      // A GIF with no looping extension plays once; avoid an encoder's default
      // infinite loop when converting such a source to APNG.
      let loopCount = document.loopCount ?? 1
      let loopDictionary = format == .gif ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
      let loopKey = format == .gif ? kCGImagePropertyGIFLoopCount : kCGImagePropertyAPNGLoopCount
      CGImageDestinationSetProperties(destination, [loopDictionary: [loopKey: loopCount]] as CFDictionary)
      progress(0, selected.count)
      for (offset, selectedFrame) in selected.enumerated() {
        try Task.checkCancellation()
        try autoreleasepool {
          let image = try frame(source, index: selectedFrame.index, document: document, resize: options.resize)
          let dictionary = format == .gif ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
          let delay = format == .gif ? kCGImagePropertyGIFDelayTime : kCGImagePropertyAPNGDelayTime
          let unclamped = format == .gif ? kCGImagePropertyGIFUnclampedDelayTime : kCGImagePropertyAPNGUnclampedDelayTime
          // Full composited canvases must not inherit source disposal/blend/offset
          // properties: the encoder chooses disposal for these complete images.
          let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 1,
            dictionary: [delay: selectedFrame.duration, unclamped: selectedFrame.duration],
          ]
          CGImageDestinationAddImage(destination, image, properties as CFDictionary)
          CGImageSourceRemoveCacheAtIndex(source, selectedFrame.index)
        }
        progress(offset + 1, selected.count)
      }
      try Task.checkCancellation()
      guard CGImageDestinationFinalize(destination) else { throw AnimatedImageExportError.encodingFailed }
    }
    try publish(temporary, to: destinationURL, source: sourceURL, original: original,
      extensions: format.acceptedExtensions)
    return AnimatedImageExportResult(destinationURL: destinationURL,
      sourceFrameIndices: selected.map(\.index),
      totalDuration: selected.reduce(0) { $0 + $1.duration }, width: size.width, height: size.height)
  }

  private func open(_ url: URL) throws -> CGImageSource {
    guard url.isFileURL,
      let source = CGImageSourceCreateWithURL(url as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary),
      let identifier = CGImageSourceGetType(source) as String?,
      ["com.compuserve.gif", "public.png", "public.apng", "org.webmproject.webp"].contains(identifier),
      CGImageSourceGetCount(source) > 0
    else { throw AnimatedImageExportError.unsupportedSource }
    return source
  }

  nonisolated private func metadata(source: CGImageSource, url: URL) throws -> AnimatedImageDocument {
    let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
    let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    let type = CGImageSourceGetType(source)! as String
    let keys = animationKeys(type)
    let animation = properties[keys.dictionary] as? [CFString: Any] ?? [:]
    let firstAnimation = first[keys.dictionary] as? [CFString: Any] ?? [:]
    // Extract Sendable scalars before using fallback autoclosures. Capturing an
    // ImageIO [CFString: Any] dictionary in actor-isolated ?? closures can make
    // Swift 6 treat subsequent dictionary reads as unsafe transfers.
    let animationWidth = integer(animation[keys.width])
    let firstAnimationWidth = integer(firstAnimation[keys.width])
    let sourceWidth = integer(properties[kCGImagePropertyPixelWidth])
    let firstWidth = integer(first[kCGImagePropertyPixelWidth])
    let animationHeight = integer(animation[keys.height])
    let firstAnimationHeight = integer(firstAnimation[keys.height])
    let sourceHeight = integer(properties[kCGImagePropertyPixelHeight])
    let firstHeight = integer(first[kCGImagePropertyPixelHeight])
    let animationLoop = integer(animation[keys.loop])
    let firstAnimationLoop = integer(firstAnimation[keys.loop])
    let width = animationWidth ?? firstAnimationWidth ?? sourceWidth ?? firstWidth ?? 0
    let height = animationHeight ?? firstAnimationHeight ?? sourceHeight ?? firstHeight ?? 0
    let loop = animationLoop ?? firstAnimationLoop
    // The GIF decoder already converts finite NETSCAPE repeats to total plays;
    // APNG/WebP also expose total plays. Preserve that shared ImageIO meaning.
    guard width > 0, height > 0 else { throw AnimatedImageExportError.unsupportedSource }
    var elapsed: TimeInterval = 0
    var frames: [AnimatedImageFrame] = []
    for index in 0..<CGImageSourceGetCount(source) {
      try Task.checkCancellation()
      let duration: TimeInterval = autoreleasepool {
        let frameKeys = animationKeys(type)
        let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let nested = frame[frameKeys.dictionary] as? [CFString: Any] ?? [:]
        let unclamped = (nested[frameKeys.unclamped] as? NSNumber)?.doubleValue
        let clamped = (nested[frameKeys.delay] as? NSNumber)?.doubleValue
        let raw = unclamped ?? clamped ?? 0.1
        // Keep the source timing, including unclamped short frame delays.
        // Only malformed or missing delays use the conventional 100ms fallback.
        return raw.isFinite && raw > 0 ? raw : 0.1
      }
      guard (elapsed + duration).isFinite else { throw AnimatedImageExportError.unsupportedSource }
      frames.append(AnimatedImageFrame(index: index, duration: duration, startTime: elapsed))
      elapsed += duration
    }
    return AnimatedImageDocument(sourceURL: url, sourceTypeIdentifier: type,
      width: width, height: height, frames: frames, loopCount: loop.flatMap { $0 >= 0 ? $0 : nil })
  }

  private func frame(_ source: CGImageSource, index: Int, document: AnimatedImageDocument,
    resize: BatchResizeOptions) throws -> CGImage
  {
    try Task.checkCancellation()
    // ImageIO resolves prior partial frames and their disposal/blending when
    // requesting an indexed frame. Drawing it again over a prior canvas would
    // corrupt transparency. Validate that the decoder produced the whole canvas.
    guard let image = CGImageSourceCreateImageAtIndex(source, index,
      [kCGImageSourceShouldCache: false] as CFDictionary)
    else { throw AnimatedImageExportError.frameDecodingFailed(index) }
    guard image.width == document.width, image.height == document.height else {
      throw AnimatedImageExportError.incompleteCanvas
    }
    let size = try resize.dimensions(width: image.width, height: image.height)
    guard size.width != image.width || size.height != image.height else { return image }
    let scaleX = Double(size.width) / Double(image.width)
    let scaleY = Double(size.height) / Double(image.height)
    let resized = CIImage(cgImage: image).applyingFilter("CILanczosScaleTransform", parameters: [
      kCIInputScaleKey: scaleY, kCIInputAspectRatioKey: scaleX / scaleY,
    ])
    guard let output = resizeContext.createCGImage(resized,
      from: CGRect(x: 0, y: 0, width: size.width, height: size.height), format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    else { throw AnimatedImageExportError.encodingFailed }
    return output
  }

  nonisolated private func animationKeys(_ type: String) -> (dictionary: CFString, delay: CFString,
    unclamped: CFString, loop: CFString, width: CFString, height: CFString)
  {
    switch type {
    case "com.compuserve.gif":
      (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFDelayTime,
        kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFLoopCount,
        kCGImagePropertyGIFCanvasPixelWidth, kCGImagePropertyGIFCanvasPixelHeight)
    case "org.webmproject.webp":
      (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPDelayTime,
        kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPLoopCount,
        kCGImagePropertyWebPCanvasPixelWidth, kCGImagePropertyWebPCanvasPixelHeight)
    default:
      (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGDelayTime,
        kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGLoopCount,
        kCGImagePropertyAPNGCanvasPixelWidth, kCGImagePropertyAPNGCanvasPixelHeight)
    }
  }

  nonisolated private func integer(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

  private func validateDestination(source: URL, destination: URL, extensions: Set<String>) throws {
    guard source.isFileURL, destination.isFileURL else { throw AnimatedImageExportError.invalidDestination }
    let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath()
    let destinationPath = destination.standardizedFileURL.resolvingSymlinksInPath()
    if sourcePath == destinationPath || ((try? FileSnapshot(source))?.sameFile(as: try? FileSnapshot(destination)) == true) {
      throw AnimatedImageExportError.sourceOverwrite
    }
    let folder = destination.deletingLastPathComponent()
    let filename = destination.lastPathComponent
    guard extensions.contains(destination.pathExtension.lowercased()),
      !filename.contains("\0"), filename.utf8.count <= 255,
      (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    else { throw AnimatedImageExportError.invalidDestination }
    let canonical = filename.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .precomposedStringWithCanonicalMapping
    let conflict = try FileManager.default.contentsOfDirectory(atPath: folder.path).contains {
      $0.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .precomposedStringWithCanonicalMapping == canonical
    }
    guard !conflict else { throw AnimatedImageExportError.destinationExists }
  }

  private func makeTemporaryFile(in folder: URL) throws -> URL {
    var path = Array(folder.appendingPathComponent(".imageviewer-animation-XXXXXX").path.utf8CString)
    let descriptor = mkstemp(&path)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    close(descriptor)
    return URL(fileURLWithPath: path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
  }

  private func publish(_ temporary: URL, to destination: URL, source: URL,
    original: FileSnapshot, extensions: Set<String>) throws
  {
    try Task.checkCancellation()
    guard (try? FileSnapshot(source)) == original else { throw AnimatedImageExportError.sourceChanged }
    try validateDestination(source: source, destination: destination, extensions: extensions)
    guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
      if errno == EEXIST { throw AnimatedImageExportError.destinationExists }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private struct FileSnapshot: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let seconds: Int
    let nanoseconds: Int
    init(_ url: URL) throws {
      var info = stat()
      // Swift imports `stat` as both a struct and a C function. Resolve links
      // explicitly and use the unambiguous lstat entry point on the real file.
      let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
      let status = resolvedURL.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return Darwin.lstat(path, &info)
      }
      guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
      device = UInt64(bitPattern: Int64(info.st_dev))
      inode = UInt64(info.st_ino)
      size = Int64(info.st_size)
      seconds = Int(info.st_mtimespec.tv_sec)
      nanoseconds = Int(info.st_mtimespec.tv_nsec)
    }
    func sameFile(as other: FileSnapshot?) -> Bool {
      guard let other else { return false }
      return device == other.device && inode == other.inode
    }
  }
}
