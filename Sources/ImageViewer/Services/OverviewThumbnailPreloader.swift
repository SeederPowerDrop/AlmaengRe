import Foundation

/// A screenful is measured from the actual intersecting cards, rather than the
/// folder's size or LazyVGrid's larger set of instantiated cells.
struct OverviewThumbnailPreloadPlan: Equatable {
  enum Direction: Equatable {
    case forward, backward
  }

  let visibleIndices: [Int]
  let nearbyIndices: [Int]
  let direction: Direction
  private let itemCount: Int

  static func isVisible(_ frame: CGRect, in viewport: CGRect) -> Bool {
    guard frame.width > 0, frame.height > 0, viewport.width > 0, viewport.height > 0,
      frame.minX.isFinite, frame.minY.isFinite, frame.maxX.isFinite, frame.maxY.isFinite,
      viewport.minX.isFinite, viewport.minY.isFinite, viewport.maxX.isFinite, viewport.maxY.isFinite
    else { return false }
    let intersection = frame.intersection(viewport)
    return !intersection.isNull && intersection.width > 0 && intersection.height > 0
  }

  /// Built only after the quiet interval, rather than scanning the whole folder
  /// for every fractional scroll event that changes the visible boundary row.
  var backgroundIndices: [Int] {
    guard let first = visibleIndices.first, let last = visibleIndices.last else { return [] }
    let prepared = Set(visibleIndices).union(nearbyIndices)
    let order: [Int]
    if direction == .forward {
      order = Array((last + 1)..<itemCount) + Array(0...last)
    } else {
      order = Array((0..<first).reversed()) + Array((first..<itemCount).reversed())
    }
    return order.filter { !prepared.contains($0) }
  }

  static func make(
    itemCount: Int, visibleIndices: Set<Int>, previousVisibleIndices: Set<Int> = [],
    previousDirection: Direction = .forward
  ) -> Self {
    let visible = visibleIndices.filter { $0 >= 0 && $0 < itemCount }.sorted()
    guard let first = visible.first, let last = visible.last else {
      return Self(visibleIndices: [], nearbyIndices: [], direction: previousDirection,
        itemCount: max(0, itemCount))
    }
    let previous = previousVisibleIndices.filter { $0 >= 0 && $0 < itemCount }
    let direction: Direction
    if let previousFirst = previous.min(), let previousLast = previous.max(),
      first + last != previousFirst + previousLast {
      direction = first + last > previousFirst + previousLast ? .forward : .backward
    } else {
      direction = previousDirection
    }

    let screenCount = max(1, last - first + 1)
    let aheadCount = screenCount > itemCount / 2 ? itemCount : screenCount * 2
    let behindCount = min(itemCount, screenCount)
    let followingEnd = last + 1 + min(itemCount - last - 1,
      direction == .forward ? aheadCount : behindCount)
    let following = Array((last + 1)..<followingEnd)
    let preceding = Array(max(0, first - (direction == .backward ? aheadCount : behindCount))..<first).reversed()
    let nearby = direction == .forward ? following + Array(preceding) : Array(preceding) + following
    return Self(visibleIndices: visible, nearbyIndices: nearby, direction: direction,
      itemCount: itemCount)
  }
}

/// Kept behind a Sendable boundary so cancellation/ordering can be tested without
/// decoding photos or depending on the machine's current resource pressure.
protocol OverviewThumbnailPreloading: Sendable {
  func updateOverviewVisibleAssets(_ assets: [ImageAsset]) async
  // This boundary deliberately exposes only compact, disk-only preparation.
  // Visible cells own refinement to their current display size after scrolling.
  func warmOverviewPreviews(assets: [ImageAsset]) async -> Bool
}

extension ThumbnailPipeline: OverviewThumbnailPreloading {}

/// This reference is held in View State, without publishing each scrolling or
/// completion event back through the entire grid's AppStore.
@MainActor
final class OverviewThumbnailPreloader {
  private struct Request {
    let assets: [ImageAsset]
    let visibleIndices: Set<Int>
    let libraryRevision: UUID
    let maxPixelSize: Int
    let plan: OverviewThumbnailPreloadPlan
    let defersLoading: Bool
    let preparesVisiblePreviews: Bool
  }

  private var request: Request?
  private var pendingRequest: Request?
  private var task: Task<Void, Never>?
  private var workerID: UUID?
  private var protectionTask: Task<Void, Never>?
  private var generation: UInt64 = 0
  private let quietInterval: Duration
  private let retryInterval: Duration

  init(quietInterval: Duration = .milliseconds(250), retryInterval: Duration = .seconds(1)) {
    self.quietInterval = quietInterval
    self.retryInterval = retryInterval
  }

  var visibleIndices: Set<Int> { request?.visibleIndices ?? [] }
  /// Read-only instrumentation for full-folder integration measurements.
  var isPreparing: Bool { task != nil }

  func update(
    assets: [ImageAsset], visibleIndices: Set<Int>, libraryRevision: UUID, maxPixelSize: Int,
    pipeline: any OverviewThumbnailPreloading, defersLoading: Bool = false,
    preparesVisiblePreviews: Bool = false
  ) {
    let visible = Set(visibleIndices.filter { assets.indices.contains($0) })
    let pixels = ((min(4_096, max(96, maxPixelSize)) + 127) / 128) * 128
    if let request, request.libraryRevision == libraryRevision,
      request.visibleIndices == visible, request.maxPixelSize == pixels,
      request.defersLoading == defersLoading,
      request.preparesVisiblePreviews == preparesVisiblePreviews { return }

    let previous = request?.libraryRevision == libraryRevision ? request : nil
    // Occlusion can temporarily remove every visible preference without leaving
    // the overview. Keep its last real viewport as an ordering anchor; explicit
    // onDisappear still calls stop. Empty visibility only requests disk previews.
    let anchor = visible.isEmpty ? Set(previous?.plan.visibleIndices ?? []) : visible
    let plan = OverviewThumbnailPreloadPlan.make(itemCount: assets.count,
      visibleIndices: anchor, previousVisibleIndices: Set(previous?.plan.visibleIndices ?? []),
      previousDirection: previous?.plan.direction ?? .forward)
    request = Request(assets: assets, visibleIndices: visible, libraryRevision: libraryRevision,
      maxPixelSize: pixels, plan: plan, defersLoading: defersLoading,
      preparesVisiblePreviews: preparesVisiblePreviews)
    generation &+= 1
    pendingRequest = !defersLoading && !plan.visibleIndices.isEmpty ? request : nil

    // Serialize these actor hops so a late old viewport or teardown cannot
    // replace the new viewport's protected working set.
    let previousProtection = protectionTask
    let protectedAssets = visible.sorted().map { assets[$0] }
    protectionTask = Task {
      await previousProtection?.value
      await pipeline.updateOverviewVisibleAssets(protectedAssets)
    }
    guard pendingRequest != nil, task == nil else { return }

    let id = UUID()
    workerID = id
    task = Task(priority: .utility) { [weak self] in
      await self?.run(id: id, pipeline: pipeline)
    }
  }

  private func run(id: UUID, pipeline: any OverviewThumbnailPreloading) async {
    defer {
      if workerID == id {
        task = nil
        workerID = nil
      }
    }
    do {
      while let next = pendingRequest {
        pendingRequest = nil
        let requestedGeneration = generation
        try await Task.sleep(for: quietInterval)
        try Task.checkCancellation()
        guard generation == requestedGeneration else { continue }

        // Preparing offscreen exact thumbnails used to admit synchronous RAW
        // decoding at the card's display size, competing with new first pixels
        // even when every compact PNG was already cached. A fully occluded,
        // inactive window also prepares its viewport through this serial worker,
        // so hidden cells need not admit concurrent first-pixel source decodes.
        // Plan tiers are disjoint; each index occurs once in this sequence.
        let viewport = next.preparesVisiblePreviews ? next.plan.visibleIndices : []
        let remainingViewport = !next.preparesVisiblePreviews && next.visibleIndices.isEmpty
          ? next.plan.visibleIndices : []
        let background = viewport + next.plan.nearbyIndices + next.plan.backgroundIndices
          + remainingViewport
        for index in background {
          let asset = next.assets[index]
          if asset.byteCount == 0 { continue }
          while generation == requestedGeneration {
            try Task.checkCancellation()
            if await pipeline.warmOverviewPreviews(assets: [asset]) { break }
            guard generation == requestedGeneration else { break }
            try await Task.sleep(for: retryInterval)
          }
          if generation != requestedGeneration { break }
        }
      }
    } catch {
      // Teardown cancels the owner. A changed viewport only replaces the pending
      // plan and is adopted after the one current decode finishes, avoiding a
      // stream of abandoned synchronous RAW decodes during scrolling.
    }
  }

  func stop(pipeline: any OverviewThumbnailPreloading) {
    generation &+= 1
    request = nil
    pendingRequest = nil
    task?.cancel()
    task = nil
    workerID = nil
    let previousProtection = protectionTask
    protectionTask = Task {
      await previousProtection?.value
      await pipeline.updateOverviewVisibleAssets([])
    }
  }
}
