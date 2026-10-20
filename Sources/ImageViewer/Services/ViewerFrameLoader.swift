import Combine
import Foundation

enum ViewerFrameLoadingPolicy: Hashable, Sendable {
  case quality
  case responsive

  /// A partial last page and a focused tile use their actual visible count,
  /// never the folder's size or the configured maximum number of slots.
  static func forVisibleItemCount(_ count: Int) -> Self {
    count > 4 ? .responsive : .quality
  }
}

struct ViewerFrameRequest: Hashable, Sendable {
  let asset: ImageAsset
  let maxPixelSize: Int
  let adjustments: ImageAdjustments
  let prefersHDR: Bool
  var loadingPolicy: ViewerFrameLoadingPolicy = .quality

  func hasSameContent(as other: Self) -> Bool {
    asset.url == other.asset.url && asset.byteCount == other.asset.byteCount
      && asset.modificationDate == other.asset.modificationDate
      && asset.archiveOrigin == other.asset.archiveOrigin
      && adjustments == other.adjustments && prefersHDR == other.prefersHDR
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.hasSameContent(as: rhs) && lhs.maxPixelSize == rhs.maxPixelSize
      && lhs.loadingPolicy == rhs.loadingPolicy
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(asset.url)
    hasher.combine(asset.byteCount)
    hasher.combine(asset.modificationDate)
    hasher.combine(asset.archiveOrigin)
    hasher.combine(adjustments)
    hasher.combine(prefersHDR)
    hasher.combine(maxPixelSize)
    hasher.combine(loadingPolicy)
  }
}

/// A tile keeps one preview in flight and replaces only the pending destination.
/// Cancelling every preview on key repeat can otherwise prevent *any* image from
/// completing. Completed samples remain visible, with their own filename, until
/// the next sample arrives. Full resolution and animation wait for a quiet input.
@MainActor
final class ViewerFrameLoader: ObservableObject {
  /// Explicit in-process release diagnostics only; normal app runs leave this nil.
  static var diagnosticPresentationObserver: ((ViewerFrameRequest, RenderedFrame, Bool) -> Void)?
  struct Presentation {
    let request: ViewerFrameRequest
    let frame: RenderedFrame
    fileprivate let revision: UInt64
    fileprivate let refinedPixelSize: Int?
  }

  typealias Preview = @Sendable (ViewerFrameRequest) async throws -> RenderedFrame
  typealias CachedPreview = @Sendable (ViewerFrameRequest) async -> RenderedFrame?
  typealias Render = @Sendable (ViewerFrameRequest, Int) async throws -> RenderedFrame
  typealias FailureReason = @Sendable (Error, URL) async -> String?
  typealias SettleWait = @Sendable (Duration) async throws -> Void

  private struct Work {
    let request: ViewerFrameRequest
    let revision: UInt64
    let preview: Preview
    let render: Render
    let onReady: (ImageAsset) -> Void
  }

  @Published private(set) var presentation: Presentation?
  @Published private(set) var errorMessage: String?
  private var target: Work?
  private var revision: UInt64 = 0
  private var lifetime: UInt64 = 0
  private var previewTask: Task<Void, Never>?
  private var cachedPreviewTask: Task<Void, Never>?
  private var renderTask: Task<Void, Never>?
  private let settleDelay: Duration
  private let rawNavigationSettleDelay: Duration
  private let editingSettleDelay: Duration
  private let multiImageSettleDelay: Duration
  private let waitForSettling: SettleWait
  private let failureReason: FailureReason

  init(
    settleDelay: Duration? = nil,
    rawNavigationSettleDelay: Duration? = nil,
    editingSettleDelay: Duration? = nil,
    multiImageSettleDelay: Duration? = nil,
    waitForSettling: @escaping SettleWait = { try await Task.sleep(for: $0) },
    failureReason: @escaping FailureReason = { error, url in
      await MediaLoadFailure.message(for: error, url: url)
    }
  ) {
    self.settleDelay = settleDelay ?? .milliseconds(120)
    // Explicit delays also govern RAW/edits unless separately overridden, preserving
    // deterministic zero-delay callers and tests of the original loading contract.
    self.rawNavigationSettleDelay = rawNavigationSettleDelay ?? settleDelay ?? .milliseconds(280)
    self.editingSettleDelay = editingSettleDelay ?? settleDelay ?? .milliseconds(280)
    self.multiImageSettleDelay = multiImageSettleDelay ?? settleDelay ?? .milliseconds(450)
    self.waitForSettling = waitForSettling
    self.failureReason = failureReason
  }

  deinit {
    previewTask?.cancel()
    cachedPreviewTask?.cancel()
    renderTask?.cancel()
  }

  func load(
    _ request: ViewerFrameRequest, cachedPreview: CachedPreview? = nil,
    preview: @escaping Preview, render: @escaping Render,
    onReady: @escaping (ImageAsset) -> Void = { _ in }
  ) {
    guard target?.request != request else { return }
    let isNavigatingRAW = target.map { $0.request.asset.id != request.asset.id } == true
      && ImageFormatRegistry.cameraRAWExtensions.contains(request.asset.fileExtension)
    let isEditing = target.map {
      $0.request.asset.id == request.asset.id && $0.request.adjustments != request.adjustments
    } == true
    let refinementDelay = request.loadingPolicy == .responsive ? multiImageSettleDelay
      : isEditing ? editingSettleDelay : isNavigatingRAW ? rawNavigationSettleDelay : settleDelay
    revision &+= 1
    let work = Work(request: request, revision: revision, preview: preview,
      render: render, onReady: onReady)
    target = work
    errorMessage = nil
    renderTask?.cancel()
    cachedPreviewTask?.cancel()
    cachedPreviewTask = nil
    if let presentation, let pixels = presentation.refinedPixelSize,
      canReuse(presentation, for: request)
    {
      // A small viewport/zoom reduction can use the pixels already on screen.
      // Keep the original refinement size across repeated reductions, and only
      // retain up to 25% extra edge length so a large shrink still releases memory.
      present(presentation.frame, for: work, refinedPixelSize: pixels)
      return
    }
    let session = lifetime
    if let cachedPreview {
      // The one coalesced source preview may still be decoding the previous
      // photo. A current RAM hit must not wait for that noninterruptible work.
      // This lane only borrows an existing bitmap, never admits another decode.
      cachedPreviewTask = Task { [weak self] in
        defer {
          if self?.lifetime == session, self?.target?.revision == work.revision {
            self?.cachedPreviewTask = nil
          }
        }
        guard let frame = await cachedPreview(request), !Task.isCancelled,
          self?.lifetime == session, self?.target?.revision == work.revision else { return }
        // The normal revision gate also keeps a cache reply from replacing a
        // full-quality result or another preview already accepted for this load.
        _ = self?.acceptPreview(frame, for: work, lifetime: session)
      }
    }
    if previewTask == nil {
      previewTask = Task { [weak self] in
        defer { if self?.lifetime == session { self?.previewTask = nil } }
        // Keep ownership weak across decoding. Calling an async instance method
        // here would retain the tile's loader for the entire suspended operation.
        while !Task.isCancelled, let work = self?.previewWork(lifetime: session) {
          // Resizing/zooming keeps the detailed bitmap until refinement.
          if self?.presentation?.request.hasSameContent(as: work.request) != true {
            do {
              let frame = try await work.preview(work.request)
              try Task.checkCancellation()
              guard self?.acceptPreview(frame, for: work, lifetime: session) == true else { return }
            } catch {
              guard !Task.isCancelled, self?.lifetime == session else { return }
              // Unsupported previews still get the precise decoder after settling.
            }
          }
          if self?.target?.revision == work.revision { return }
          // Intermediate key repeats never become an unbounded queue.
        }
      }
    }
    renderTask = Task { [weak self, waitForSettling, failureReason] in
      do {
        // Larger pages prioritize immediate previews, then let the bounded
        // decoder pool refine every settled tile at its original requested quality.
        // RAW navigation also avoids committing too early to sensor development,
        // which cannot stop midway. Edits keep previews immediate while a longer
        // quiet window prevents detail work at brief pauses during a slider drag.
        // The delay applies only once, never per frame of an animated image.
        try await waitForSettling(refinementDelay)
        // Previews have queue priority, but a slow system thumbnail must not stop
        // the precise decoder from trying after input settles. Both share a budget.
        try Task.checkCancellation()
        var index = 0
        while !Task.isCancelled {
          let frame = try await work.render(request, index)
          try Task.checkCancellation()
          guard self?.acceptRenderedFrame(frame, for: work, lifetime: session) == true else { return }
          guard frame.frameCount > 1 else { return }
          // Do not hold the loader strongly during an animation frame's delay.
          try await Task.sleep(for: .seconds(frame.duration ?? 0.1))
          index = (index + 1) % frame.frameCount
        }
      } catch is CancellationError {
        // Only refinement is cancelled by navigation, never the next sample.
      } catch {
        guard !Task.isCancelled, self?.lifetime == session,
          self?.target?.revision == work.revision else { return }
        // Keep a usable preview, and avoid retaining a discarded tile while the
        // source-file check determines a readable reason for a total failure.
        let message: String?
        if self?.presentation?.request.hasSameContent(as: request) != true {
          message = await failureReason(error, request.asset.url)
        } else {
          message = nil
        }
        guard let self, !Task.isCancelled, self.lifetime == session,
          self.target?.revision == work.revision else { return }
        // A preview can finish during the asynchronous error lookup.
        if self.presentation?.request.hasSameContent(as: request) != true {
          guard let message else { return }
          self.presentation = nil
          self.errorMessage = message
        }
        work.onReady(request.asset)
      }
    }
  }

  func stop() {
    lifetime &+= 1
    previewTask?.cancel()
    cachedPreviewTask?.cancel()
    renderTask?.cancel()
    previewTask = nil
    cachedPreviewTask = nil
    renderTask = nil
    target = nil
    presentation = nil
    errorMessage = nil
  }

  private func previewWork(lifetime session: UInt64) -> Work? {
    lifetime == session ? target : nil
  }

  private func canReuse(_ presentation: Presentation, for request: ViewerFrameRequest) -> Bool {
    guard let refinedPixels = presentation.refinedPixelSize,
      presentation.request.hasSameContent(as: request), presentation.frame.frameCount == 1,
      request.maxPixelSize > 0, request.maxPixelSize <= refinedPixels
    else { return false }
    let bitmapPixels = Double(max(presentation.frame.image.width, presentation.frame.image.height))
    var requiredPixels = Double(request.maxPixelSize)
    if let size = presentation.frame.sourcePixelSize {
      let sourcePixels = max(size.width, size.height)
      if sourcePixels.isFinite, sourcePixels > 0 {
        requiredPixels = min(requiredPixels, Double(sourcePixels))
      }
    }
    // Check actual pixels too: a decoder fallback can be smaller than requested.
    // The immutable bitmap edge bounds retained memory across cumulative resizes.
    return bitmapPixels >= requiredPixels - 1
      && bitmapPixels <= Double(request.maxPixelSize) * 1.25
  }

  private func acceptPreview(_ frame: RenderedFrame, for work: Work, lifetime session: UInt64) -> Bool {
    guard lifetime == session else { return false }
    // A late preview cannot overwrite a newer frame or full-quality result.
    if (errorMessage == nil || target?.revision == work.revision),
      presentation.map({ $0.revision < work.revision }) ?? true
    {
      present(frame, for: work, refinedPixelSize: nil)
    }
    return true
  }

  private func acceptRenderedFrame(
    _ frame: RenderedFrame, for work: Work, lifetime session: UInt64
  ) -> Bool {
    guard target?.revision == work.revision, lifetime == session else { return false }
    present(frame, for: work, refinedPixelSize: work.request.maxPixelSize)
    return true
  }

  private func present(_ frame: RenderedFrame, for work: Work, refinedPixelSize: Int?) {
    presentation = Presentation(request: work.request, frame: frame, revision: work.revision,
      refinedPixelSize: refinedPixelSize)
    if target?.revision == work.revision {
      errorMessage = nil
      work.onReady(work.request.asset)
    }
    Self.diagnosticPresentationObserver?(work.request, frame, refinedPixelSize != nil)
  }
}
