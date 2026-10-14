import AVFoundation
import Darwin
import Foundation

/// Brief, evidence-based reasons shared by image, thumbnail and video surfaces.
/// Unknown native errors must not be presented as a confirmed codec problem.
enum MediaLoadFailure: String, CaseIterable, Sendable {
  case empty, missing, permission, notDownloaded, unavailable, unsupported
  case unreadableData, noVideoTrack, protectedContent = "protected"
  case invalidVideo, rendering, resource, tooLarge, unknown

  var message: String { Self.text(rawValue) }

  static func text(_ key: String) -> String {
    L10n.text(key, localeIdentifier: L10n.languageIdentifier, table: "MediaLoadFailure")
  }

  /// File checks happen only after a load failure and never block the UI actor.
  /// A cancelled view request is normal navigation and has no error message.
  static func message(for error: Error, url: URL) async -> String? {
    guard !Task.isCancelled, !isCancellation(error) else { return nil }
    let failure = await Task.detached(priority: .utility) {
      Self.sourceFailure(at: url) ?? Self.reason(for: error) ?? .unknown
    }.value
    guard !Task.isCancelled else { return nil }
    return failure.message
  }

  private static func sourceFailure(at url: URL) -> Self? {
    guard url.isFileURL else { return nil }
    // Discard resource values cached on an old asset URL after moves/restoration.
    let freshURL = URL(fileURLWithPath: url.path)
    do {
      let values = try freshURL.resourceValues(forKeys: [
        .fileSizeKey, .isDirectoryKey, .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
      ])
      if values.isUbiquitousItem == true,
        values.ubiquitousItemDownloadingStatus == .notDownloaded { return .notDownloaded }
      if values.isDirectory == true { return .unavailable }
      let accessError = freshURL.path.withCString { path -> Int32? in
        guard Darwin.access(path, R_OK) != 0 else { return nil }
        return errno
      }
      if let accessError {
        // A file can disappear or a volume disconnect after the resource query.
        // Only EACCES/EPERM establish that this is a permission problem.
        return reason(for: NSError(domain: NSPOSIXErrorDomain, code: Int(accessError))) ?? .unavailable
      }
      if values.fileSize == 0 { return .empty }
      return nil
    } catch {
      return reason(for: error) ?? .unavailable
    }
  }

  static func isCancellation(_ error: Error, depth: Int = 0) -> Bool {
    if error is CancellationError { return true }
    guard depth < 8 else { return false }
    let native = error as NSError
    if native.domain == NSCocoaErrorDomain && native.code == CocoaError.userCancelled.rawValue { return true }
    if native.domain == NSURLErrorDomain && native.code == URLError.cancelled.rawValue { return true }
    if native.domain == AVFoundationErrorDomain && native.code == AVError.operationCancelled.rawValue { return true }
    if let underlying = native.userInfo[NSUnderlyingErrorKey] as? Error {
      return isCancellation(underlying, depth: depth + 1)
    }
    return false
  }

  /// Pure classification keeps tests independent of the OS language and files.
  static func reason(for error: Error, depth: Int = 0) -> Self? {
    guard depth < 8 else { return nil }
    if let error = error as? ImagePipelineError {
      switch error {
      case .emptyFile: return .empty
      // ImageIO and AppKit share this fallback for unrecognized AND corrupt data.
      case .unsupported, .decodingFailed: return .unreadableData
      case .renderingFailed: return .rendering
      }
    }
    if let error = error as? BitmapDecoderError {
      switch error {
      case .unsupportedVariant: return .unsupported
      case .invalidHeader, .truncatedData: return .unreadableData
      case .imageTooLarge: return .tooLarge
      case .imageCreationFailed: return .rendering
      }
    }
    if let error = error as? VideoProcessingError {
      switch error {
      case .sourceUnavailable: return .unavailable
      case .noVideoTrack: return .noVideoTrack
      case .invalidDuration, .invalidDimensions: return .invalidVideo
      case .protectedContent: return .protectedContent
      default: break
      }
    }
    if let error = error as? AnimatedImageExportError {
      switch error {
      case .unsupportedSource, .frameDecodingFailed, .incompleteCanvas: return .unreadableData
      default: break
      }
    }
    let native = error as NSError
    // A system wrapper often carries the useful permission/missing-file cause.
    if let underlying = native.userInfo[NSUnderlyingErrorKey] as? Error,
      let reason = reason(for: underlying, depth: depth + 1) { return reason }
    if native.domain == NSCocoaErrorDomain {
      switch native.code {
      case CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue: return .missing
      case CocoaError.fileReadNoPermission.rawValue: return .permission
      case CocoaError.fileReadCorruptFile.rawValue: return .unreadableData
      case CocoaError.fileReadUnknown.rawValue: return .unavailable
      default: break
      }
    }
    if native.domain == NSPOSIXErrorDomain {
      switch native.code {
      case Int(ENOENT), Int(ENOTDIR): return .missing
      case Int(EACCES), Int(EPERM): return .permission
      case Int(EIO), Int(ENXIO), Int(ENODEV), Int(ESTALE): return .unavailable
      case Int(ENOMEM): return .resource
      default: break
      }
    }
    if native.domain == AVFoundationErrorDomain {
      switch native.code {
      case AVError.decoderNotFound.rawValue, AVError.formatUnsupported.rawValue: return .unsupported
      case AVError.contentIsProtected.rawValue, AVError.contentIsNotAuthorized.rawValue: return .protectedContent
      case AVError.noSourceTrack.rawValue: return .noVideoTrack
      case AVError.decodeFailed.rawValue, AVError.invalidSourceMedia.rawValue,
        AVError.fileFormatNotRecognized.rawValue, AVError.fileFailedToParse.rawValue,
        AVError.failedToParse.rawValue, AVError.undecodableMediaData.rawValue: return .unreadableData
      case AVError.outOfMemory.rawValue, AVError.decoderTemporarilyUnavailable.rawValue,
        AVError.deviceInUseByAnotherApplication.rawValue: return .resource
      case AVError.deviceWasDisconnected.rawValue, AVError.deviceNotConnected.rawValue,
        AVError.contentIsUnavailable.rawValue: return .unavailable
      default: break
      }
    }
    return nil
  }
}
