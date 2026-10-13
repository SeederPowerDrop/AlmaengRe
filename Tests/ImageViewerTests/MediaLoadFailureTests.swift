import AVFoundation
import Darwin
import Foundation
import Testing
@testable import ImageViewer

struct MediaLoadFailureTests {
  @Test("Fresh source facts distinguish empty, missing and restored files", arguments: ["png", "DNG", "mp4"])
  func sourceFacts(suffix: String) async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("failure-\(UUID()).\(suffix)")
    defer { try? FileManager.default.removeItem(at: url) }
    let error = ImagePipelineError.unsupported(url)
    try Data().write(to: url)
    #expect(await MediaLoadFailure.message(for: error, url: url) == MediaLoadFailure.empty.message)
    try FileManager.default.removeItem(at: url)
    #expect(await MediaLoadFailure.message(for: error, url: url) == MediaLoadFailure.missing.message)
    try Data("nonempty, undecodable data".utf8).write(to: url)
    #expect(await MediaLoadFailure.message(for: error, url: url) == MediaLoadFailure.unreadableData.message)
    let unknown = NSError(domain: "TestFailure", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Raw implementation detail must not leak into the caption"])
    #expect(await MediaLoadFailure.message(for: unknown, url: url) == MediaLoadFailure.unknown.message)
  }

  @Test("Nested system errors preserve the specific cause")
  func nestedErrors() {
    let permission = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue)
    let wrapper = NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue,
      userInfo: [NSUnderlyingErrorKey: permission])
    #expect(MediaLoadFailure.reason(for: wrapper) == .permission)
    #expect(MediaLoadFailure.reason(for: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))) == .missing)
    #expect(MediaLoadFailure.reason(for: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))) == .unavailable)
    #expect(MediaLoadFailure.reason(for: NSError(domain: NSPOSIXErrorDomain, code: Int.max)) == nil)
  }

  @Test("Unreadable file permissions are distinguished from undecodable data")
  func unreadableFile() async throws {
    guard geteuid() != 0 else { return }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("failure-permission-\(UUID()).png")
    try Data("nonempty".utf8).write(to: url)
    defer {
      _ = chmod(url.path, 0o600)
      try? FileManager.default.removeItem(at: url)
    }
    #expect(chmod(url.path, 0) == 0)
    #expect(await MediaLoadFailure.message(for: ImagePipelineError.unsupported(url), url: url)
      == MediaLoadFailure.permission.message)
  }

  @Test("Only definite codec errors are described as unsupported")
  func codecAndMediaFailures() {
    #expect(MediaLoadFailure.reason(for: AVError(.decoderNotFound)) == .unsupported)
    #expect(MediaLoadFailure.reason(for: AVError(.fileFormatNotRecognized)) == .unreadableData)
    #expect(MediaLoadFailure.reason(for: AVError(.contentIsProtected)) == .protectedContent)
    #expect(MediaLoadFailure.reason(for: AVError(.decoderTemporarilyUnavailable)) == .resource)
    #expect(MediaLoadFailure.reason(for: VideoProcessingError.noVideoTrack) == .noVideoTrack)
    #expect(MediaLoadFailure.reason(for: VideoProcessingError.invalidDuration) == .invalidVideo)
    #expect(MediaLoadFailure.reason(for: BitmapDecoderError.imageTooLarge) == .tooLarge)
    #expect(MediaLoadFailure.reason(for: AnimatedImageExportError.frameDecodingFailed(2)) == .unreadableData)
    #expect(MediaLoadFailure.reason(for: AnimatedImageExportError.unsupportedSource) == .unreadableData)
    #expect(MediaLoadFailure.reason(for: ImagePipelineError.renderingFailed(URL(fileURLWithPath: "/unused"))) == .rendering)
  }

  @Test("Cancellation never turns navigation into a missing-file error")
  func cancellation() async {
    let url = URL(fileURLWithPath: "/missing-\(UUID()).png")
    let wrapped = NSError(domain: "Wrapper", code: 0,
      userInfo: [NSUnderlyingErrorKey: URLError(.cancelled)])
    #expect(await MediaLoadFailure.message(for: CancellationError(), url: url) == nil)
    #expect(await MediaLoadFailure.message(for: AVError(.operationCancelled), url: url) == nil)
    #expect(await MediaLoadFailure.message(for: wrapped, url: url) == nil)
  }

  @Test("All supported languages contain short failure reasons")
  func translations() {
    for locale in L10n.supportedLocalizations {
      for key in MediaLoadFailure.allCases.map(\.rawValue) + ["preview.title"] {
        let value = L10n.text(key, localeIdentifier: locale, table: "MediaLoadFailure")
        #expect(value != key && !value.isEmpty)
      }
    }
  }
}
