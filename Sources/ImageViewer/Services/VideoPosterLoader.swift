import Combine
import CoreGraphics
import Foundation

/// Display metadata does not change a movie's first-frame pixels. Keep that
/// metadata available to callbacks without making it part of decoder identity.
struct VideoTilePosterRequest: Hashable, Sendable {
  let asset: ImageAsset
  let maxPixelSize: Int

  init(asset: ImageAsset, maxPixelSize: Int) {
    self.asset = asset
    self.maxPixelSize = ((min(1_024, max(256, maxPixelSize)) + 127) / 128) * 128
  }

  func hasSameSource(as other: Self) -> Bool {
    asset.url == other.asset.url && asset.byteCount == other.asset.byteCount
      && asset.modificationDate == other.asset.modificationDate
      && asset.archiveOrigin == other.asset.archiveOrigin && asset.isAudio == other.asset.isAudio
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.hasSameSource(as: rhs) && lhs.maxPixelSize == rhs.maxPixelSize
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(asset.url); hasher.combine(asset.byteCount)
    hasher.combine(asset.modificationDate); hasher.combine(asset.archiveOrigin)
    hasher.combine(asset.isAudio); hasher.combine(maxPixelSize)
  }
}

/// Opt-in metadata only. A publication is not a native backing/physical-paint
/// measurement; cancellation, superseded work and retained posters emit nothing.
struct VideoPosterDiagnosticEvent: Sendable {
  struct Failure: Equatable, Sendable {
    let kind: MediaLoadFailure
    let errorDomain: String
    let errorCode: Int

    init(error: Error) {
      kind = MediaLoadFailure.reason(for: error) ?? .unknown
      let native = error as NSError
      // Never serialize a custom error's domain, userInfo or localized reason:
      // a caller can put a filename in any of those strings.
      let nativeDomains: Set<String> = [NSCocoaErrorDomain, NSPOSIXErrorDomain,
        NSURLErrorDomain, "AVFoundationErrorDomain", "NSOSStatusErrorDomain"]
      let knownProductError = error is ImagePipelineError || error is BitmapDecoderError
        || error is VideoProcessingError || error is ThumbnailPipelineError
      errorDomain = knownProductError || nativeDomains.contains(native.domain) ? native.domain : "other"
      errorCode = native.code
    }
  }
  enum Outcome: Equatable, Sendable {
    case accepted
    case terminalFailure(Failure)
  }
  let request: VideoTilePosterRequest
  let outcome: Outcome
}

/// One tile owns one destination, borrowing posters from the existing bounded
/// thumbnail pipeline. Enlarging retains its current bitmap until a sufficient
/// replacement arrives; source changes and teardown discard the previous file.
@MainActor
final class VideoPosterLoader: ObservableObject {
  typealias DiagnosticObserver = @MainActor (VideoPosterDiagnosticEvent) -> Void
  /// Normal application execution keeps this nil; only explicit private QA
  /// installs an observer. No bitmap or localized error text leaves the loader.
  static var diagnosticObserver: DiagnosticObserver?

  struct Presentation {
    let request: VideoTilePosterRequest
    let image: CGImage?
    /// Exact thumbnail generation can be complete even for a smaller original.
    let fulfilledPixelSize: Int
  }
  typealias Load = @Sendable (VideoTilePosterRequest) async throws -> CGImage
  typealias FailureReason = @Sendable (Error, URL) async -> String?

  @Published private(set) var presentation: Presentation?
  @Published private(set) var errorMessage: String?
  private var target: VideoTilePosterRequest?
  private var task: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var hasAnnouncedReady = false
  private var onReady: (ImageAsset) -> Void = { _ in }
  private var onDisplayedAssetChange: ((ImageAsset?) -> Void)?
  private let failureReason: FailureReason

  init(failureReason: @escaping FailureReason = { await MediaLoadFailure.message(for: $0, url: $1) }) {
    self.failureReason = failureReason
  }

  deinit { task?.cancel() }

  func load(_ request: VideoTilePosterRequest, preview: @escaping Load, render: @escaping Load,
    onReady: @escaping (ImageAsset) -> Void = { _ in },
    onDisplayedAssetChange: ((ImageAsset?) -> Void)? = nil) {
    let previous = target
    let sameSource = previous?.hasSameSource(as: request) == true
    self.onReady = onReady
    self.onDisplayedAssetChange = onDisplayedAssetChange
    target = request
    if sameSource, let presentation, presentation.request.asset != request.asset {
      self.presentation = Presentation(request: request, image: presentation.image,
        fulfilledPixelSize: presentation.fulfilledPixelSize)
      if hasAnnouncedReady { onDisplayedAssetChange?(request.asset) }
    }
    // A metadata-only update also refreshes the callbacks used by pending work.
    if sameSource, previous == request { return }
    generation &+= 1
    let revision = generation
    task?.cancel(); task = nil
    if !sameSource {
      presentation = nil; errorMessage = nil; hasAnnouncedReady = false
      onDisplayedAssetChange?(nil)
    }
    if request.asset.isAudio {
      presentation = Presentation(request: request, image: nil, fulfilledPixelSize: 0)
      announceReady()
      return
    }
    if sameSource, let presentation, presentation.fulfilledPixelSize >= request.maxPixelSize { return }
    errorMessage = nil
    task = Task { [weak self, failureReason] in
      defer { if self?.generation == revision { self?.task = nil } }
      do {
        if self?.presentation?.image == nil {
          do {
            let image = try await preview(request)
            try Task.checkCancellation()
            guard self?.accept(image, revision: revision,
              fulfilledPixelSize: max(image.width, image.height) >= request.maxPixelSize ? request.maxPixelSize : 0) == true else { return }
            if max(image.width, image.height) >= request.maxPixelSize { return }
          } catch {
            if MediaLoadFailure.isCancellation(error) { throw CancellationError() }
            try Task.checkCancellation()
            // Browsing already tries the native video decoder. Repeating that
            // decoder cannot fix an empty source or a confirmed missing codec
            // or track. Unknown/cache-only failures still get the exact path.
            guard Self.permitsExactFallback(after: error) else { throw error }
          }
        }
        let image = try await render(request)
        try Task.checkCancellation()
        _ = self?.accept(image, revision: revision, fulfilledPixelSize: request.maxPixelSize)
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, !MediaLoadFailure.isCancellation(error), self?.generation == revision,
          self?.presentation?.image == nil else { return }
        let reason = await failureReason(error, request.asset.url)
        guard !Task.isCancelled, let self, self.generation == revision,
          let current = self.target, current.hasSameSource(as: request),
          self.presentation?.image == nil else { return }
        self.errorMessage = reason
        if self.generation == revision, let latest = self.target,
          latest.hasSameSource(as: current), let observer = Self.diagnosticObserver {
          observer(VideoPosterDiagnosticEvent(request: latest,
            outcome: .terminalFailure(.init(error: error))))
        }
      }
    }
  }

  /// A per-attempt decision, never a negative cache. Reappearing or replacing
  /// the source can retry normally after a codec or file becomes available.
  private nonisolated static func permitsExactFallback(after error: Error) -> Bool {
    if let error = error as? ImagePipelineError {
      switch error {
      case .emptyFile, .unsupported: return false
      case .decodingFailed, .renderingFailed: return true
      }
    }
    switch MediaLoadFailure.reason(for: error) {
    case .empty, .unsupported, .noVideoTrack, .protectedContent, .invalidVideo, .unreadableData, .tooLarge:
      return false
    default: return true
    }
  }

  func stop() {
    generation &+= 1
    task?.cancel(); task = nil; target = nil
    presentation = nil; errorMessage = nil; hasAnnouncedReady = false
    onReady = { _ in }; onDisplayedAssetChange = nil
  }

  private func accept(_ image: CGImage, revision: UInt64, fulfilledPixelSize: Int) -> Bool {
    guard generation == revision, let target else { return false }
    presentation = Presentation(request: target, image: image, fulfilledPixelSize: fulfilledPixelSize)
    errorMessage = nil
    announceReady()
    if generation == revision, let current = self.target,
      current.hasSameSource(as: target), let observer = Self.diagnosticObserver {
      observer(VideoPosterDiagnosticEvent(request: current, outcome: .accepted))
    }
    return true
  }

  private func announceReady() {
    guard !hasAnnouncedReady, let target else { return }
    hasAnnouncedReady = true
    onReady(target.asset)
    onDisplayedAssetChange?(target.asset)
  }
}
