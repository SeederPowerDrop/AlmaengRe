import Foundation
import ImageIO

struct AnimatedImageFrame: Equatable, Sendable, Identifiable {
  let index: Int
  let duration: TimeInterval
  let startTime: TimeInterval
  var id: Int { index }
}

/// Frame metadata only; no decoded pixels are retained by the document.
struct AnimatedImageDocument: Sendable, Identifiable {
  let sourceURL: URL
  let sourceTypeIdentifier: String
  let width: Int
  let height: Int
  let frames: [AnimatedImageFrame]
  /// ImageIO's total play count, including the initial play: 0 means forever,
  /// a positive value is the total number of complete plays, and nil means the
  /// source did not specify a value (exported as one play). This is NOT the raw
  /// GIF NETSCAPE repeat field: a finite value of 2 means 3 plays in ImageIO.
  let loopCount: Int?

  var id: URL { sourceURL }
  var frameCount: Int { frames.count }
  var totalDuration: TimeInterval { frames.last.map { $0.startTime + $0.duration } ?? 0 }
  var isAnimated: Bool { frameCount > 1 }
}

enum AnimatedImageExportFormat: String, CaseIterable, Identifiable, Sendable {
  case gif, apng
  var id: Self { self }
  var title: String { self == .gif ? "GIF" : "APNG" }
  var fileExtension: String { self == .gif ? "gif" : "png" }
  var typeIdentifier: String { self == .gif ? "com.compuserve.gif" : "public.png" }
  var acceptedExtensions: Set<String> { self == .gif ? ["gif"] : ["png", "apng"] }
  static var available: [Self] {
    let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
    return allCases.filter { identifiers.contains($0.typeIdentifier) }
  }
}

struct AnimatedImageExportOptions: Sendable {
  /// Zero-based inclusive bounds, validated against the source at export time.
  var frameRange: ClosedRange<Int>
  var resize: BatchResizeOptions = .original
  var frameStride: Int = 1
  var maximumFramesPerSecond: Double? = nil

  /// Skipped frame durations are added to the preceding retained frame, so
  /// reducing frame count preserves the duration of the selected interval.
  func selectedFrames(in document: AnimatedImageDocument) throws -> [AnimatedImageFrame] {
    guard frameRange.lowerBound >= 0, frameRange.upperBound < document.frameCount,
      frameStride >= 1 else { throw AnimatedImageExportError.invalidFrameRange }
    if let fps = maximumFramesPerSecond, !fps.isFinite || fps <= 0 {
      throw AnimatedImageExportError.invalidFrameRate
    }
    _ = try resize.dimensions(width: document.width, height: document.height)
    let minimumDuration = maximumFramesPerSecond.map { 1 / $0 } ?? 0
    guard minimumDuration.isFinite else { throw AnimatedImageExportError.invalidFrameRate }
    var selected: [AnimatedImageFrame] = []
    var heldIndex = frameRange.lowerBound
    var heldDuration: TimeInterval = 0
    var outputTime: TimeInterval = 0
    for index in frameRange {
      try Task.checkCancellation()
      if index != frameRange.lowerBound,
        (index - frameRange.lowerBound).isMultiple(of: frameStride),
        heldDuration + 1e-9 >= minimumDuration
      {
        selected.append(AnimatedImageFrame(index: heldIndex,
          duration: heldDuration, startTime: outputTime))
        outputTime += heldDuration
        heldIndex = index
        heldDuration = 0
      }
      heldDuration += document.frames[index].duration
    }
    selected.append(AnimatedImageFrame(index: heldIndex, duration: heldDuration, startTime: outputTime))
    return selected
  }
}

struct AnimatedImageExportResult: Sendable {
  let destinationURL: URL
  let sourceFrameIndices: [Int]
  let totalDuration: TimeInterval
  let width: Int
  let height: Int
  var frameCount: Int { sourceFrameIndices.count }
}

enum AnimatedImageExportError: LocalizedError {
  case unsupportedSource
  case invalidFrameRange
  case invalidFrameRate
  case invalidDestination
  case sourceOverwrite
  case destinationExists
  case sourceChanged
  case frameDecodingFailed(Int)
  case incompleteCanvas
  case encodingFailed

  var errorDescription: String? {
    switch self {
    case .unsupportedSource:
      MotionMediaL10n.text("animation.error.unsupportedSource")
    case .invalidFrameRange:
      MotionMediaL10n.text("animation.error.invalidFrameRange")
    case .invalidFrameRate:
      MotionMediaL10n.text("animation.error.invalidFrameRate")
    case .invalidDestination:
      MotionMediaL10n.text("animation.error.invalidDestination")
    case .sourceOverwrite:
      MotionMediaL10n.text("animation.error.sourceOverwrite")
    case .destinationExists:
      MotionMediaL10n.text("animation.error.destinationExists")
    case .sourceChanged:
      MotionMediaL10n.text("animation.error.sourceChanged")
    case .frameDecodingFailed(let index):
      MotionMediaL10n.format("animation.error.frameDecodingFailed", index + 1)
    case .incompleteCanvas:
      MotionMediaL10n.text("animation.error.incompleteCanvas")
    case .encodingFailed:
      MotionMediaL10n.text("animation.error.encodingFailed")
    }
  }
}
