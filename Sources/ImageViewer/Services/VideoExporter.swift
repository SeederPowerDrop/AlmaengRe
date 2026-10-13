@preconcurrency import AVFoundation
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Each job owns its AVFoundation objects and a private temporary directory.
/// Only completed output is published, with an atomic no-overwrite rename.
actor VideoExporter {
  func extractFrame(from sourceURL: URL, at seconds: Double, to destinationURL: URL) async throws -> VideoFrameResult {
    guard seconds.isFinite, seconds >= 0 else { throw VideoProcessingError.invalidFrameTime }
    return try await extractFrame(from: sourceURL,
      at: CMTime(seconds: seconds, preferredTimescale: 600_000), to: destinationURL)
  }

  /// Passing AVPlayer.currentTime() preserves the selected sample's media time.
  /// Zero tolerance requests a precise frame; actualTime is returned explicitly
  /// rather than guessing a frame number from nominal frame rate.
  func extractFrame(from sourceURL: URL, at time: CMTime, to destinationURL: URL) async throws -> VideoFrameResult {
    try Task.checkCancellation()
    let source = try VideoSourceSnapshot.capture(sourceURL)
    try VideoOutputSafety.validate(source: sourceURL, destination: destinationURL, extension: "png")
    let document = try await VideoDocument.load(url: sourceURL)
    guard !document.hasProtectedContent else { throw VideoProcessingError.protectedContent }
    let seconds = CMTimeGetSeconds(time)
    guard seconds.isFinite, seconds >= 0, seconds < document.durationSeconds else {
      throw VideoProcessingError.invalidFrameTime
    }
    let asset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let operation = VideoFrameOperation(generator: generator)
    let frame = try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        operation.start(at: time) { continuation.resume(with: $0) }
      }
    } onCancel: { operation.cancel() }
    try Task.checkCancellation()
    let staging = try VideoOutputSafety.makeStagingDirectory(for: destinationURL)
    defer { try? FileManager.default.removeItem(at: staging) }
    let temporary = staging.appendingPathComponent("frame.png")
    guard let output = CGImageDestinationCreateWithURL(temporary as CFURL,
      UTType.png.identifier as CFString, 1, nil) else { throw VideoProcessingError.imageWriteFailed }
    CGImageDestinationAddImage(output, frame.image, [
      kCGImagePropertyOrientation: 1,
      kCGImagePropertyPixelWidth: frame.image.width,
      kCGImagePropertyPixelHeight: frame.image.height,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(output) else { throw VideoProcessingError.imageWriteFailed }
    try Task.checkCancellation()
    try source.verify(sourceURL)
    try VideoOutputSafety.validate(source: sourceURL, destination: destinationURL, extension: "png")
    try Task.checkCancellation()
    try VideoOutputSafety.publish(temporary, to: destinationURL)
    return VideoFrameResult(destinationURL: destinationURL, requestedTimeSeconds: seconds,
      actualTimeSeconds: CMTimeGetSeconds(frame.actualTime),
      pixelWidth: frame.image.width, pixelHeight: frame.image.height)
  }

  func export(from sourceURL: URL, range: VideoTimeRange, to destinationURL: URL,
    options: VideoExportOptions = VideoExportOptions(),
    progress: (@Sendable (Double) -> Void)? = nil) async throws -> VideoExportResult {
    try Task.checkCancellation()
    let source = try VideoSourceSnapshot.capture(sourceURL)
    try VideoOutputSafety.validate(source: sourceURL, destination: destinationURL,
      extension: options.container.fileExtension)
    let document = try await VideoDocument.load(url: sourceURL)
    guard !document.hasProtectedContent else { throw VideoProcessingError.protectedContent }
    guard document.isExportable else { throw VideoProcessingError.notExportable }
    try range.validate(durationSeconds: document.durationSeconds)
    try Task.checkCancellation()
    let asset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    guard let session = AVAssetExportSession(asset: asset, presetName: options.preset.avPresetName) else {
      throw VideoProcessingError.unsupportedPreset
    }
    let fileTypes: [AVFileType] = await withCheckedContinuation { continuation in
      session.determineCompatibleFileTypes { continuation.resume(returning: $0) }
    }
    try Task.checkCancellation()
    guard fileTypes.contains(options.container.fileType) else { throw VideoProcessingError.unsupportedContainer }
    let staging = try VideoOutputSafety.makeStagingDirectory(for: destinationURL)
    defer { try? FileManager.default.removeItem(at: staging) }
    let temporary = staging.appendingPathComponent("video." + options.container.fileExtension)
    session.directoryForTemporaryFiles = staging
    session.outputURL = temporary
    session.outputFileType = options.container.fileType
    session.timeRange = range.cmTimeRange
    session.shouldOptimizeForNetworkUse = true
    let operation = VideoExportOperation(session: session)
    progress?(0)
    let monitor = Task {
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(200)) }
        catch { return }
        guard !Task.isCancelled else { return }
        progress?(operation.progress)
      }
    }
    defer { monitor.cancel() }
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        operation.start { continuation.resume(with: $0) }
      }
    } onCancel: { operation.cancel() }
    monitor.cancel()
    await monitor.value
    try Task.checkCancellation()
    let output = try await VideoDocument.load(url: temporary)
    try Task.checkCancellation()
    try source.verify(sourceURL)
    try VideoOutputSafety.validate(source: sourceURL, destination: destinationURL,
      extension: options.container.fileExtension)
    let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
    let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    guard byteCount > 0 else { throw VideoProcessingError.exportFailed }
    try Task.checkCancellation()
    try VideoOutputSafety.publish(temporary, to: destinationURL)
    progress?(1)
    return VideoExportResult(destinationURL: destinationURL, durationSeconds: output.durationSeconds,
      pixelWidth: output.pixelWidth, pixelHeight: output.pixelHeight, byteCount: byteCount)
  }
}

/// The lock orders start against cancellation, including cancellation in the gap
/// immediately before exportAsynchronously. AVFoundation supports cancelExport
/// from a different thread; the session is otherwise configured before wrapping.
private final class VideoExportOperation: @unchecked Sendable {
  private let session: AVAssetExportSession
  private let lock = NSLock()
  private var isCancelled = false
  var progress: Double { Double(session.progress) }

  init(session: AVAssetExportSession) { self.session = session }

  func start(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    lock.lock()
    guard !isCancelled else { lock.unlock(); completion(.failure(CancellationError())); return }
    session.exportAsynchronously { [self] in
      switch session.status {
      case .completed: completion(.success(()))
      case .cancelled: completion(.failure(CancellationError()))
      default: completion(.failure(session.error ?? VideoProcessingError.exportFailed))
      }
    }
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    session.cancelExport()
    lock.unlock()
  }
}

/// CGImage is immutable after AVFoundation produces it. Ownership is retained
/// across the callback so writing the PNG does not depend on callback lifetime.
private struct GeneratedVideoFrame: @unchecked Sendable {
  let image: CGImage
  let actualTime: CMTime
}

private final class VideoFrameOperation: @unchecked Sendable {
  private let generator: AVAssetImageGenerator
  private let lock = NSLock()
  private var isCancelled = false

  init(generator: AVAssetImageGenerator) { self.generator = generator }

  func start(at time: CMTime,
    completion: @escaping @Sendable (Result<GeneratedVideoFrame, Error>) -> Void) {
    lock.lock()
    guard !isCancelled else { lock.unlock(); completion(.failure(CancellationError())); return }
    generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, actualTime, result, error in
      switch result {
      case .succeeded:
        if let image { completion(.success(GeneratedVideoFrame(image: image, actualTime: actualTime))) }
        else { completion(.failure(VideoProcessingError.frameGenerationFailed)) }
      case .cancelled: completion(.failure(CancellationError()))
      default: completion(.failure(error ?? VideoProcessingError.frameGenerationFailed))
      }
    }
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    generator.cancelAllCGImageGeneration()
    lock.unlock()
  }
}

private struct VideoSourceSnapshot: Equatable, Sendable {
  let device: Int32
  let inode: UInt64
  let size: Int64
  let modifiedSeconds: Int
  let modifiedNanoseconds: Int
  let changedSeconds: Int
  let changedNanoseconds: Int

  static func capture(_ url: URL) throws -> Self {
    guard url.isFileURL else { throw VideoProcessingError.sourceUnavailable }
    var info = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return fstatat(AT_FDCWD, path, &info, 0)
    }
    guard result == 0, info.st_mode & S_IFMT == S_IFREG else { throw VideoProcessingError.sourceUnavailable }
    return Self(device: info.st_dev, inode: UInt64(info.st_ino), size: info.st_size,
      modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
      changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
  }

  func verify(_ url: URL) throws {
    guard let current = try? Self.capture(url), current == self else { throw VideoProcessingError.sourceChanged }
  }
}

private enum VideoOutputSafety {
  static func validate(source: URL, destination: URL, extension expectedExtension: String) throws {
    guard source.isFileURL, destination.isFileURL else { throw VideoProcessingError.invalidDestination }
    let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath()
    let destinationPath = destination.standardizedFileURL.resolvingSymlinksInPath()
    if pathKey(sourcePath.path) == pathKey(destinationPath.path) { throw VideoProcessingError.sourceOverwrite }
    if let first = try? VideoSourceSnapshot.capture(source),
      let second = try? VideoSourceSnapshot.capture(destination),
      first.device == second.device, first.inode == second.inode { throw VideoProcessingError.sourceOverwrite }
    let filename = destination.lastPathComponent
    let folder = destination.deletingLastPathComponent()
    guard destination.pathExtension.lowercased() == expectedExtension,
      filename.utf8.count <= 255, !filename.contains("\0"), !filename.hasPrefix("."),
      (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
      throw VideoProcessingError.invalidDestination
    }
    // Includes broken links, folders, case variants and Unicode aliases.
    let existing = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    guard !existing.contains(where: { pathKey($0) == pathKey(filename) }) else {
      throw VideoProcessingError.destinationExists
    }
  }

  static func makeStagingDirectory(for destination: URL) throws -> URL {
    let template = destination.deletingLastPathComponent().appendingPathComponent(".almaeng-video-XXXXXX").path
    var buffer = Array(template.utf8CString)
    guard mkdtemp(&buffer) != nil else { throw posixError() }
    return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
  }

  static func publish(_ temporary: URL, to destination: URL) throws {
    guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
      if errno == EEXIST { throw VideoProcessingError.destinationExists }
      throw posixError()
    }
  }

  private static func pathKey(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive,
      locale: Locale(identifier: "en_US_POSIX"))
  }

  private static func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
