import Combine
import Foundation

struct ViewerFrameRequest: Hashable, Sendable {
  let asset: ImageAsset
  let maxPixelSize: Int
  let adjustments: ImageAdjustments
  let prefersHDR: Bool

  func hasSameContent(as other: Self) -> Bool {
    asset == other.asset && adjustments == other.adjustments && prefersHDR == other.prefersHDR
  }
}

/// A tile keeps one preview in flight and replaces only the pending destination.
/// Cancelling every preview on key repeat can otherwise prevent *any* image from
/// completing. Completed samples remain visible, with their own filename, until
/// the next sample arrives. Full resolution and animation wait for a quiet input.
@MainActor
final class ViewerFrameLoader: ObservableObject {
  struct Presentation {
    let request: ViewerFrameRequest
    let frame: RenderedFrame
    fileprivate let revision: UInt64
  }

  typealias Preview = @Sendable (ViewerFrameRequest) async throws -> RenderedFrame
  typealias Render = @Sendable (ViewerFrameRequest, Int) async throws -> RenderedFrame
  typealias FailureReason = @Sendable (Error, URL) async -> String?

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
  private var renderTask: Task<Void, Never>?
  private let settleDelay: Duration
  private let failureReason: FailureReason

  init(
    settleDelay: Duration = .milliseconds(120),
    failureReason: @escaping FailureReason = { error, url in
      await MediaLoadFailure.message(for: error, url: url)
    }
  ) {
    self.settleDelay = settleDelay
    self.failureReason = failureReason
  }

  deinit {
    previewTask?.cancel()
    renderTask?.cancel()
  }

  func load(
    _ request: ViewerFrameRequest, preview: @escaping Preview, render: @escaping Render,
    onReady: @escaping (ImageAsset) -> Void = { _ in }
  ) {
    guard target?.request != request else { return }
    revision &+= 1
    let work = Work(request: request, revision: revision, preview: preview,
      render: render, onReady: onReady)
    target = work
    errorMessage = nil
    renderTask?.cancel()
    let session = lifetime
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
    renderTask = Task { [weak self, settleDelay, failureReason] in
      do {
        try await Task.sleep(for: settleDelay)
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
    renderTask?.cancel()
    previewTask = nil
    renderTask = nil
    target = nil
    presentation = nil
    errorMessage = nil
  }

  private func previewWork(lifetime session: UInt64) -> Work? {
    lifetime == session ? target : nil
  }

  private func acceptPreview(_ frame: RenderedFrame, for work: Work, lifetime session: UInt64) -> Bool {
    guard lifetime == session else { return false }
    // A late preview cannot overwrite a newer frame or full-quality result.
    if (errorMessage == nil || target?.revision == work.revision),
      presentation.map({ $0.revision < work.revision }) ?? true
    {
      present(frame, for: work)
    }
    return true
  }

  private func acceptRenderedFrame(
    _ frame: RenderedFrame, for work: Work, lifetime session: UInt64
  ) -> Bool {
    guard target?.revision == work.revision, lifetime == session else { return false }
    present(frame, for: work)
    return true
  }

  private func present(_ frame: RenderedFrame, for work: Work) {
    presentation = Presentation(request: work.request, frame: frame, revision: work.revision)
    if target?.revision == work.revision {
      errorMessage = nil
      work.onReady(work.request.asset)
    }
  }
}
