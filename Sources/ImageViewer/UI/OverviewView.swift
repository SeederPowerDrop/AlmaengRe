import AppKit
import SwiftUI

struct OverviewView: View {
  @ObservedObject var store: AppStore
  @ObservedObject private var thumbnailSizeState: OverviewThumbnailSizeState
  @Environment(\.layoutDirection) private var layoutDirection
  @Environment(\.displayScale) private var displayScale
  @State private var cellFrames = OverviewCellFrameCache()
  @State private var nativeCellGeometry = OverviewNativeCellGeometryRegistry()
  @State private var thumbnailPreloader = OverviewThumbnailPreloader()
  @StateObject private var refinementGate: OverviewRefinementGate
  private let onBitmapStateApplied: (@MainActor (ThumbnailBitmapStateEvent) -> Void)?
  private let onScrollRequestApplied: (@MainActor (OverviewFocusScrollRequest, Bool) -> Void)?
  @State private var appliedScrollRequest: OverviewFocusScrollRequest?
  @State private var appliedScrollIndex: Int?
  @State private var measuredCollectionRevision: UUID?
  @State private var selectionRectangle: CGRect?
  @State private var dragID: UUID?
  @State private var pendingMarqueeCompletion: UUID?
  @State private var isAdjustingThumbnailSize = false
  @State private var footerWidth: CGFloat = 0
  @GestureState private var isDragging = false
  @Namespace private var contentSpace

  init(store: AppStore, thumbnailPreloader: OverviewThumbnailPreloader = OverviewThumbnailPreloader(),
    refinementGate: OverviewRefinementGate = OverviewRefinementGate(requiresVisibleMembership: true),
    onBitmapStateApplied: (@MainActor (ThumbnailBitmapStateEvent) -> Void)? = nil,
    onScrollRequestApplied: (@MainActor (OverviewFocusScrollRequest, Bool) -> Void)? = nil) {
    self.store = store
    _thumbnailSizeState = ObservedObject(wrappedValue: store.overviewThumbnailSize)
    _thumbnailPreloader = State(initialValue: thumbnailPreloader)
    _refinementGate = StateObject(wrappedValue: refinementGate)
    self.onBitmapStateApplied = onBitmapStateApplied
    self.onScrollRequestApplied = onScrollRequestApplied
  }

  private var focusScrollRequest: OverviewFocusScrollRequest {
    OverviewFocusScrollRequest(collectionRevision: store.assetOrderRevision, assetID: store.currentAsset?.id)
  }

  private func columns(for size: CGFloat) -> [GridItem] {
    [
      GridItem(
        .adaptive(minimum: size + 14, maximum: (size + 14) * 1.35), spacing: 12)
    ]
  }

  var body: some View {
    VStack(spacing: 0) {
      GeometryReader { geometry in
        // 최대 크기를 골라도 사이드바/정보 패널 사이의 좁은 공간을 넘지 않습니다.
        let size = min(thumbnailSizeState.value, max(1, geometry.size.width - 50))
        let pixels = OverviewThumbnailSizing.requestedPixelSize(for: size, displayScale: displayScale)
        let collectionRevision = store.assetOrderRevision
        let nativeGeometryScope = OverviewNativeCellGeometryScope(collectionRevision: collectionRevision,
          pointSize: size, paneWidth: geometry.size.width, isRightToLeft: layoutDirection == .rightToLeft)
        let scrollRequest = focusScrollRequest
        let scrollTaskID = OverviewFocusScrollTaskID(request: scrollRequest,
          measuredCollectionRevision: measuredCollectionRevision)
        ScrollViewReader { proxy in
          ScrollView {
            LazyVGrid(columns: columns(for: size), spacing: 16) {
              ForEach(OverviewIndexedAssets(store.assets), id: \.element.id) { index, asset in
                OverviewThumbnailCell(store: store, index: index, asset: asset, size: size,
                  isAdjustingSize: isAdjustingThumbnailSize,
                  defersLoadingForOcclusion: refinementGate.isWindowSuppressed,
                  defersRefinement: refinementGate.isDeferring,
                  overviewRefinementGate: refinementGate,
                  onBitmapStateApplied: onBitmapStateApplied,
                  currentIndexForAsset: { assetID in
                    cellFrames.assetIndexMap.index(for: assetID, in: store.assets,
                      collectionRevision: store.assetOrderRevision)
                  })
                  .background {
                    GeometryReader { cell in
                      let contentFrame = cell.frame(in: .named(contentSpace))
                      Color.clear
                        .preference(key: OverviewCellFramesKey.self,
                          value: isDragging || dragID != nil
                            ? [asset.id: contentFrame] : [:])
                        .preference(key: OverviewRealizedCellFramesKey.self,
                          value: [collectionRevision: OverviewRealizedCellFrames(
                            frames: [asset.id: contentFrame],
                            capturedIndices: OverviewFocusRevealTrace.isEnabled ? [asset.id: index] : [:])])
                        .preference(key: OverviewFocusedCellFrameKey.self,
                          value: OverviewFocusRevealTrace.isEnabled && asset.id == scrollRequest.assetID
                            ? [collectionRevision: cell.frame(in: .named(contentSpace))] : [:])
                    }
                    // Reattach only measurement when filtering/sorting reuses a
                    // card at a different row. Its bitmap State keeps its URL ID.
                    .id(OverviewCellMeasurementIdentity(assetID: asset.id,
                      collectionRevision: collectionRevision))
                  }
                  .background {
                    OverviewNativeCellGeometry(registry: nativeCellGeometry,
                      assetID: asset.id, scope: nativeGeometryScope)
                      .allowsHitTesting(false)
                      .accessibilityHidden(true)
                  }
              }
            }
            .padding(18)
            .frame(minHeight: geometry.size.height, alignment: .top)
            .contentShape(Rectangle())
            .coordinateSpace(name: contentSpace)
            .simultaneousGesture(marqueeGesture)
            .background(alignment: .topLeading) {
              OverviewScrollMotionObserver(gate: refinementGate, cellGeometryRegistry: nativeCellGeometry,
                onViewportChange: { viewport in
                cellFrames.nativeViewport = viewport
                updateNativeViewportMembership(pixels: pixels, scope: nativeGeometryScope)
                traceReveal("native_viewport")
              })
                // A zero-height full-width anchor has a physical left edge in
                // both layout directions; a zero-width .leading anchor does not.
                .frame(maxWidth: .infinity)
                .frame(height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .background(alignment: .topLeading) {
              if onBitmapStateApplied != nil {
                // Only diagnostic runs need a native anchor. A taller sidebar
                // document must never be mistaken for this overview grid.
                OverviewBenchmarkScrollMarker()
                  .frame(width: 0, height: 0)
                  .allowsHitTesting(false)
                  .accessibilityHidden(true)
              }
            }
            .overlay(alignment: .topLeading) {
              if let rectangle = selectionRectangle {
                Rectangle()
                  .fill(ViewerTheme.selection)
                  .overlay { Rectangle().stroke(ViewerTheme.accent, lineWidth: 1) }
                  .frame(width: rectangle.width, height: rectangle.height)
                  .offset(x: rectangle.minX, y: rectangle.minY)
                  .allowsHitTesting(false)
                  .accessibilityHidden(true)
              }
            }
            .onPreferenceChange(OverviewCellFramesKey.self) { frames in
              cellFrames.frames = frames
              updateMarqueeSelection()
              // A very short drag can finish before its first preference pass.
              // Complete against that pass instead of accepting an empty or old
              // frame table merely because the mouse-up arrived in the same turn.
              if !frames.isEmpty, let completed = pendingMarqueeCompletion {
                store.finishOverviewSelection(completed)
                pendingMarqueeCompletion = nil
                dragID = nil
                selectionRectangle = nil
              }
            }
          }
          .onPreferenceChange(OverviewFocusedCellFrameKey.self) { frames in
            cellFrames.focusedFrames = frames
            traceReveal("focused_frame_measurement")
          }
          .onPreferenceChange(OverviewRealizedCellFramesKey.self) { byRevision in
            let revision = store.assetOrderRevision
            let measured = byRevision[revision]
            if OverviewFocusRevealTrace.isEnabled {
              cellFrames.contentFramesRevision = measured == nil ? nil : revision
              cellFrames.contentFrames = measured?.frames ?? [:]
              cellFrames.capturedIndices = measured?.capturedIndices ?? [:]
            }
            // This is an after-layout wakeup, never a source of admission
            // coordinates. SwiftUI can move native ancestors after individual
            // representable frames and the document notification have settled.
            // Join the existing native invalidation so both paths read once.
            refinementGate.nativeContentAnchor?.nativeCellGeometryDidChange()
            traceReveal("content_frame_measurement")
          }
          .onChange(of: pixels) { _, _ in
            if OverviewFocusRevealTrace.isEnabled, cellFrames.traceCount < 256 {
              // A stationary focus can survive several size changes. Give each
              // explicit diagnostic layout a bounded observation window too.
              cellFrames.traceRequestCount = 0
              cellFrames.traceDeadline = ProcessInfo.processInfo.systemUptime + 2
              traceReveal("thumbnail_pixel_size_changed", extra: ["requestedPixels": pixels])
            }
            updateNativeViewportMembership(pixels: pixels, scope: nativeGeometryScope)
          }
          .onChange(of: isAdjustingThumbnailSize) { _, _ in
            updateThumbnailPreloading(visibleIndices: thumbnailPreloader.visibleIndices, pixels: pixels)
          }
          .onChange(of: refinementGate.isWindowSuppressed) { _, _ in
            updateThumbnailPreloading(visibleIndices: thumbnailPreloader.visibleIndices, pixels: pixels)
          }
          .onChange(of: store.assetOrderRevision, initial: true) { _, _ in
            refinementGate.collectionChanged()
            traceReveal("collection_change")
            // Preferences can arrive before or after this callback. Never map
            // the previous collection's scalar indices onto the new photos.
            let visible = cellFrames.visibleRevision == store.assetOrderRevision
              ? cellFrames.visibleIndices : []
            updateThumbnailPreloading(visibleIndices: visible, pixels: pixels)
          }
          .onChange(of: store.libraryRevision) { _, _ in
            // Metadata/source versions still refresh preload inputs, but an
            // unchanged URL order keeps measured geometry and manual scrolling.
            let visible = cellFrames.visibleRevision == store.assetOrderRevision
              ? cellFrames.visibleIndices : []
            updateThumbnailPreloading(visibleIndices: visible, pixels: pixels)
          }
          .task(id: scrollTaskID) {
            // A filter commits both a collection and its remapped focus. Let
            // that transaction and its first measured layout settle before
            // consuming one reveal. Matching layout readiness restarts a task
            // that arrived before the new collection's geometry preference.
            await Task.yield()
            traceReveal("task_ready", requested: scrollRequest,
              extra: ["taskCancelled": Task.isCancelled])
            guard !Task.isCancelled, focusScrollRequest == scrollRequest,
              measuredCollectionRevision == scrollRequest.collectionRevision,
              appliedScrollRequest != scrollRequest, let target = scrollRequest.assetID else { return }
            let sameCollection = appliedScrollRequest?.collectionRevision == scrollRequest.collectionRevision
            let visibleCount = cellFrames.visibleRevision == scrollRequest.collectionRevision
              ? cellFrames.visibleIndices.count : 0
            let nearby = appliedScrollIndex.map {
              abs(store.currentIndex - $0) <= max(1, visibleCount)
            } ?? false
            // A distant reveal need not animate through many intermediate
            // rows. Keep the familiar animation for nearby keyboard navigation.
            let animated = sameCollection && nearby
            // A collection replacement cancels the selection session, while
            // its mouse-up can still be pending. Reveal the replacement once;
            // only same-collection focus changes stay blocked during a drag.
            guard dragID == nil || !sameCollection else { return }
            appliedScrollRequest = scrollRequest
            appliedScrollIndex = store.currentIndex
            traceReveal("will_scroll", requested: scrollRequest, extra: ["animated": animated])
            scrollTo(target, with: proxy, animated: animated)
            traceReveal("scroll_submitted", requested: scrollRequest, extra: ["animated": animated])
            onScrollRequestApplied?(scrollRequest, animated)
          }
          .onChange(of: geometry.size) { _, _ in cancelMarquee() }
        }
        .onChange(of: OverviewGridNavigation.columnCount(
          width: geometry.size.width, thumbnailSize: thumbnailSizeState.value), initial: true) { _, count in
          store.overviewColumnCount = count
        }
      }

      Divider()

      OverviewFooterLayout {
        overviewControls
        ViewThatFits(in: .horizontal) {
          BatchQuickActionsView(store: store)
          BatchQuickActionsView(store: store, layout: .icons)
          BatchQuickActionsView(store: store, layout: .twoRows)
        }
      }
      .background {
        GeometryReader { geometry in
          Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in
            footerWidth = width
          }
        }
      }
      .font(ViewerUIMetrics.font(size: 12))
      .controlSize(.small)
      .viewerPadding(.horizontal, 12)
      .viewerPadding(.vertical, 8)
      .frame(maxWidth: .infinity)
      .background(ViewerTheme.panelGradient)
    }
    .background(ViewerTheme.chromeGradient)
    .onChange(of: layoutDirection, initial: true) { _, direction in
      store.overviewIsRightToLeft = direction == .rightToLeft
    }
    .onChange(of: thumbnailSizeState.value) { _, _ in cancelMarquee() }
    .onChange(of: store.showsOverviewNumbers) { _, _ in cancelMarquee() }
    .onChange(of: store.libraryRevision) { _, _ in
      cancelMarquee()
      cellFrames.frames.removeAll(keepingCapacity: true)
    }
    .onChange(of: store.overviewSelectionSession?.id) { _, sessionID in
      if sessionID == nil {
        selectionRectangle = nil
        pendingMarqueeCompletion = nil
      }
    }
    .onChange(of: isDragging) { _, dragging in
      if !dragging {
        // 정상 mouse-up의 onEnded가 먼저 완료하도록 양보한 뒤 취소된 제스처만 복구합니다.
        Task { @MainActor in
          await Task.yield()
          if !isDragging, pendingMarqueeCompletion == nil { cancelMarquee(); dragID = nil }
        }
      }
    }
    .onDisappear {
      cancelMarquee()
      appliedScrollRequest = nil
      appliedScrollIndex = nil
      measuredCollectionRevision = nil
      cellFrames.nativeViewport = nil
      cellFrames.contentFramesRevision = nil
      cellFrames.contentFrames.removeAll(keepingCapacity: true)
      isAdjustingThumbnailSize = false
      thumbnailPreloader.stop(pipeline: store.thumbnailPipeline)
      nativeCellGeometry.stop()
      refinementGate.stop()
    }
  }

  private func updateThumbnailPreloading(visibleIndices: Set<Int>, pixels: Int) {
    // A new folder/filter can keep the same visible index set. Remap URLs on
    // libraryRevision changes too, rather than waiting for a changed preference.
    refinementGate.updateVisibleAssets(Set(visibleIndices.compactMap { index in
      store.assets.indices.contains(index) ? store.assets[index].url : nil
    }))
    thumbnailPreloader.update(assets: store.assets, visibleIndices: visibleIndices,
      libraryRevision: store.libraryRevision, maxPixelSize: pixels,
      pipeline: store.thumbnailPipeline, defersLoading: isAdjustingThumbnailSize,
      preparesVisiblePreviews: refinementGate.isWindowSuppressed)
  }

  private func updateNativeViewportMembership(pixels: Int, scope: OverviewNativeCellGeometryScope) {
    let revision = store.assetOrderRevision
    guard scope.collectionRevision == revision else { return }
    let measuredIDs: Set<URL>
    if let scroll = refinementGate.nativeScrollView, let window = scroll.window {
      // Lazy SwiftUI preference coordinates can be an earlier layout during a
      // deep adaptive-column change. The actual clipped native card rectangles
      // are authoritative for admission; bitmap and selection identity stay put.
      measuredIDs = nativeCellGeometry.visibleAssetIDs(in: scroll, window: window, scope: scope)
      cellFrames.visibleRevision = revision
      if !measuredIDs.isEmpty, measuredCollectionRevision != revision {
        measuredCollectionRevision = revision
      }
    } else {
      measuredIDs = []
      cellFrames.visibleRevision = nil
    }
    let indices = cellFrames.assetIndexMap.indices(for: measuredIDs, in: store.assets,
      collectionRevision: revision)
    cellFrames.visibleIndices = indices
    cellFrames.visibleAssetCount = measuredIDs.count
    cellFrames.capturedVisibleIndexHints = OverviewFocusRevealTrace.isEnabled
      ? Set(measuredIDs.compactMap { cellFrames.capturedIndices[$0] }) : []
    updateThumbnailPreloading(visibleIndices: indices, pixels: pixels)
  }

  /// Explicit local diagnosis only: no filenames, URLs, pixels or timer work.
  /// Limit both the entire view lifetime and each reveal's immediate layouts.
  private func traceReveal(_ stage: String, requested: OverviewFocusScrollRequest? = nil,
    extra: [String: Any] = [:]) {
    guard OverviewFocusRevealTrace.isEnabled, cellFrames.traceCount < 256 else { return }
    let current = focusScrollRequest
    let now = ProcessInfo.processInfo.systemUptime
    if cellFrames.traceRequest != current {
      cellFrames.traceRequest = current
      cellFrames.traceRequestCount = 0
      cellFrames.traceDeadline = now + 2
    }
    guard cellFrames.traceRequestCount < 24, now <= cellFrames.traceDeadline else { return }
    cellFrames.traceRequestCount += 1
    cellFrames.traceCount += 1
    let request = requested ?? current
    var value: [String: Any] = ["stage": stage, "uptime": now,
      "event": cellFrames.traceCount, "collectionRevision": current.collectionRevision.uuidString,
      "requestedRevision": request.collectionRevision.uuidString,
      "requestedIsCurrent": request == current,
      "currentIndex": store.currentIndex, "assetCount": store.assets.count,
      "measuredRevisionMatchesRequest": measuredCollectionRevision == request.collectionRevision,
      "visibleRevisionMatchesRequest": cellFrames.visibleRevision == request.collectionRevision,
      "alreadyAppliedRequest": appliedScrollRequest == request,
      "visibleIndices": cellFrames.visibleIndices.sorted(), "dragActive": dragID != nil,
      "capturedVisibleIndexHints": cellFrames.capturedVisibleIndexHints.sorted(),
      "visibleAssetCount": cellFrames.visibleAssetCount,
      "visibleIndexScope": "current_layout_native_card_visible_rect_then_URL_mapped_current_order",
      "isFiltering": store.isFiltering, "thumbnailSize": thumbnailSizeState.value,
      "appActive": NSApp.isActive]
    value["realizedContentFrameCount"] = cellFrames.contentFrames.count
    let frameRows = cellFrames.contentFrames.compactMap { id, frame -> (Int, CGRect)? in
      guard let index = cellFrames.assetIndexMap.index(for: id, in: store.assets,
        collectionRevision: store.assetOrderRevision) else { return nil }
      return (index, frame)
    }.sorted { $0.0 < $1.0 }
    value["measuredFrameRows"] = frameRows.prefix(24).map {
      ["ordinal": $0.0, "frame": OverviewFocusRevealTrace.rectangle($0.1)] as [String: Any]
    }
    value["measuredFrameRowsTruncated"] = frameRows.count > 24
    value["contentFramesRevisionMatchesRequest"] = cellFrames.contentFramesRevision == request.collectionRevision
    value["nativeContentOrigin"] = cellFrames.nativeViewport.map {
      ["x": Double($0.contentOriginInDocument.x), "y": Double($0.contentOriginInDocument.y)] as Any
    } ?? NSNull()
    value["nativeViewportInDocument"] = cellFrames.nativeViewport.map {
      OverviewFocusRevealTrace.rectangle($0.viewportInDocument) as Any
    } ?? NSNull()
    value["requestedMappedIndex"] = request.assetID.flatMap { id in store.assets.firstIndex { $0.id == id } }
      .map { $0 as Any } ?? NSNull()
    value["focusedFrameCurrentRevision"] = cellFrames.focusedFrames[current.collectionRevision]
      .map { OverviewFocusRevealTrace.rectangle($0) as Any } ?? NSNull()
    value["focusedMeasuredContentFrame"] = current.assetID.flatMap { cellFrames.contentFrames[$0] }
      .map { OverviewFocusRevealTrace.rectangle($0) as Any } ?? NSNull()
    value["preloaderVisibleIndices"] = thumbnailPreloader.visibleIndices.sorted()
    value["nativeCellGeometry"] = nativeCellGeometry.diagnosticSnapshot ?? NSNull()
    value["refinementIsDeferred"] = refinementGate.isDeferring
    value["refinementMotionGeneration"] = refinementGate.motionGeneration
    if let anchor = refinementGate.nativeContentAnchor {
      let fresh = anchor.currentViewportGeometry()
      value["freshGeometryMatchesCached"] = fresh == cellFrames.nativeViewport
      value["freshNativeContentOrigin"] = fresh.map {
        ["x": Double($0.contentOriginInDocument.x), "y": Double($0.contentOriginInDocument.y)] as Any
      } ?? NSNull()
      value["freshNativeViewportInDocument"] = fresh.map {
        OverviewFocusRevealTrace.rectangle($0.viewportInDocument) as Any
      } ?? NSNull()
      value["anchorFrame"] = OverviewFocusRevealTrace.rectangle(anchor.frame)
      value["anchorBounds"] = OverviewFocusRevealTrace.rectangle(anchor.bounds)
      value["freshVisibleMeasuredIndices"] = fresh.map {
        cellFrames.assetIndexMap.indices(for: $0.visibleAssetIDs(in: cellFrames.contentFrames),
          in: store.assets, collectionRevision: store.assetOrderRevision).sorted() as Any
      } ?? NSNull()
    }
    if let scroll = refinementGate.nativeScrollView {
      value["clip"] = OverviewFocusRevealTrace.rectangle(scroll.contentView.bounds)
      value["document"] = scroll.documentView.map { OverviewFocusRevealTrace.rectangle($0.bounds) as Any } ?? NSNull()
      value["documentIsFlipped"] = scroll.documentView?.isFlipped ?? false
      value["windowVisible"] = scroll.window?.isVisible ?? false
      if let window = scroll.window {
        let native = OverviewBitmapProbeRegistry.visible(in: scroll, window: window)
        let urls = Set(native.map(\.assetURL))
        value["nativeBitmapProbeVisibleIndices"] = cellFrames.assetIndexMap.indices(for: urls,
          in: store.assets, collectionRevision: store.assetOrderRevision).sorted()
        value["nativeBitmapProbeVisibleCount"] = native.count
        value["nativeBitmapProbeReadyCount"] = native.filter(\.hasBitmap).count
      }
    }
    value.merge(extra, uniquingKeysWith: { _, newest in newest })
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
      FileHandle.standardOutput.write(Data("OVERVIEW_REVEAL_TRACE ".utf8) + data + Data("\n".utf8))
    }
  }

  private var overviewControls: some View {
    HStack(spacing: 8) {
      Image(systemName: "photo")
        .accessibilityHidden(true)
      // Keep one control and a stable track while the grid and footer are remeasured.
      // Replacing ViewThatFits candidates during a drag loses native slider tracking.
      Slider(value: Binding(get: { thumbnailSizeState.value }, set: { thumbnailSizeState.set($0) }),
        in: OverviewThumbnailSizing.range) { editing in
        isAdjustingThumbnailSize = editing
      }
        // Only the available pane width changes the track, never its current value.
        .frame(width: min(140, max(40, footerWidth - 100)))
        .accessibilityLabel(L10n.text("썸네일 크기"))
        .accessibilityValue(L10n.format("%.1f pt", Double(thumbnailSizeState.value)))
        .accessibilityIdentifier("overview.thumbnailSize")
      numberToggle
      if footerWidth >= 360 {
        Text(L10n.format("%.1f pt", Double(thumbnailSizeState.value)))
          .font(ViewerUIMetrics.font(.caption).monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 60, alignment: .trailing)
      }
      Spacer(minLength: 0)
      if footerWidth >= 360 {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) {
            BatchActionsMenu(store: store)
            Text(store.positionDescription)
              .font(ViewerUIMetrics.font(size: 11, weight: .medium))
              .monospacedDigit()
              .foregroundStyle(.secondary)
              .viewerPadding(.horizontal, 8)
              .viewerPadding(.vertical, 4)
              .background(ViewerTheme.controlFill, in: RoundedRectangle(cornerRadius: 5))
              .fixedSize()
          }
          BatchActionsMenu(store: store, compact: true)
        }
      } else {
        BatchActionsMenu(store: store, compact: true)
      }
    }
  }

  private var numberToggle: some View {
    Toggle(isOn: $store.showsOverviewNumbers) {
      Label("몽땅보기 번호 표시", systemImage: "number")
    }
    .toggleStyle(.button)
    .labelStyle(.iconOnly)
    .help("몽땅보기 번호 표시")
  }

  private var marqueeGesture: some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .named(contentSpace))
      .updating($isDragging) { _, active, _ in active = true }
      .onChanged { value in
        if dragID == nil { dragID = store.beginOverviewSelection(modifiers: NSEvent.modifierFlags) }
        // Esc 뒤에도 mouse-up 전까지 같은 드래그를 다시 시작하지 않습니다.
        guard let dragID, store.overviewSelectionSession?.id == dragID else { return }
        selectionRectangle = OverviewMarqueeGeometry.rectangle(from: value.startLocation, to: value.location)
        updateMarqueeSelection()
      }
      .onEnded { value in
        if let dragID, store.overviewSelectionSession?.id == dragID {
          selectionRectangle = OverviewMarqueeGeometry.rectangle(from: value.startLocation, to: value.location)
          if cellFrames.frames.isEmpty {
            pendingMarqueeCompletion = dragID
            return
          }
          updateMarqueeSelection()
          store.finishOverviewSelection(dragID)
        }
        dragID = nil
        selectionRectangle = nil
      }
  }

  private func updateMarqueeSelection() {
    guard let dragID, let selectionRectangle, !cellFrames.frames.isEmpty else { return }
    store.updateOverviewSelection(
      dragID, hits: OverviewMarqueeGeometry.hits(in: selectionRectangle, frames: cellFrames.frames))
  }

  private func cancelMarquee() {
    if let dragID { store.cancelOverviewSelection(dragID) }
    selectionRectangle = nil
    pendingMarqueeCompletion = nil
  }

  private func scrollTo(
    _ target: URL,
    with proxy: ScrollViewProxy,
    animated: Bool = true
  ) {
    if animated {
      withAnimation(.easeOut(duration: 0.2)) {
        proxy.scrollTo(target, anchor: .center)
      }
    } else {
      var transaction = Transaction(animation: nil)
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        proxy.scrollTo(target, anchor: .center)
      }
    }
  }
}

/// Both URL order and focus matter: metadata enrichment leaves the collection
/// unchanged, while a sort can move the same focused photo to a different row.
struct OverviewFocusScrollRequest: Equatable {
  let collectionRevision: UUID
  let assetID: URL?
}

private struct OverviewFocusScrollTaskID: Equatable {
  let request: OverviewFocusScrollRequest
  let measuredCollectionRevision: UUID?
}

private struct OverviewCellMeasurementIdentity: Hashable {
  let assetID: URL
  let collectionRevision: UUID
}

/// Preserve the asset array's copy-on-write storage instead of materializing
/// hundreds of index/asset pairs whenever selection, hover or scrolling changes.
/// Indices still follow the current filtered/sorted collection and card identity
/// remains the file identity used by ScrollViewReader and lazy-cell state.
struct OverviewIndexedAssets: RandomAccessCollection {
  typealias Index = Int
  typealias Element = (offset: Int, element: ImageAsset)
  private let assets: [ImageAsset]

  init(_ assets: [ImageAsset]) { self.assets = assets }
  var startIndex: Int { assets.startIndex }
  var endIndex: Int { assets.endIndex }
  subscript(position: Int) -> Element { (position, assets[position]) }
}

/// Rebuild once when URL order changes, then map only the measured identities.
/// Metadata-only updates retain the same order revision and need no array scan.
struct OverviewAssetIndexMap {
  private var collectionRevision: UUID?
  private var indicesByAssetID: [URL: Int] = [:]

  mutating func index(for assetID: URL, in assets: [ImageAsset],
    collectionRevision: UUID) -> Int? {
    prepare(assets: assets, collectionRevision: collectionRevision)
    return indicesByAssetID[assetID]
  }

  mutating func indices(for assetIDs: Set<URL>, in assets: [ImageAsset],
    collectionRevision: UUID) -> Set<Int> {
    prepare(assets: assets, collectionRevision: collectionRevision)
    return Set(assetIDs.compactMap { indicesByAssetID[$0] })
  }

  private mutating func prepare(assets: [ImageAsset], collectionRevision: UUID) {
    guard self.collectionRevision != collectionRevision else { return }
    indicesByAssetID.removeAll(keepingCapacity: true)
    indicesByAssetID.reserveCapacity(assets.count)
    for (index, asset) in assets.enumerated() { indicesByAssetID[asset.id] = index }
    self.collectionRevision = collectionRevision
  }
}

/// SwiftUI content frames have a physical left-to-right x axis and a downward
/// y axis, including the grid's padding. The zero-height full-width native anchor
/// locates that origin in the scroll document, whose y axis may be flipped.
struct OverviewNativeViewportGeometry: Equatable {
  let viewportInDocument: CGRect
  let contentOriginInDocument: CGPoint
  let documentIsFlipped: Bool

  func documentFrame(for contentFrame: CGRect) -> CGRect {
    CGRect(x: contentOriginInDocument.x + contentFrame.minX,
      y: documentIsFlipped ? contentOriginInDocument.y + contentFrame.minY
        : contentOriginInDocument.y - contentFrame.maxY,
      width: contentFrame.width, height: contentFrame.height)
  }

  func visibleAssetIDs(in frames: [URL: CGRect]) -> Set<URL> {
    Set(frames.compactMap { assetID, frame in
      OverviewThumbnailPreloadPlan.isVisible(documentFrame(for: frame), in: viewportInDocument) ? assetID : nil
    })
  }
}

/// Wrap the action row without removing/recreating the slider during layout changes.
private struct OverviewFooterLayout: Layout {
  private let horizontalSpacing: CGFloat = 12
  private let verticalSpacing: CGFloat = 8

  struct Measurements {
    let controls: CGSize
    let actions: CGSize
    let wraps: Bool
  }

  struct Cache {
    var ideal: (controls: CGSize, actions: CGSize)?
    var widths: [CGFloat] = []
    var measurements: [CGFloat: Measurements] = [:]
  }

  func makeCache(subviews: Subviews) -> Cache { Cache() }

  func updateCache(_ cache: inout Cache, subviews: Subviews) {
    // Selection, translations and the width-dependent controls can change a
    // subview's ideal size even while the native slider retains its identity.
    cache = Cache()
  }

  private func idealSizes(subviews: Subviews, cache: inout Cache) -> (controls: CGSize, actions: CGSize) {
    if let ideal = cache.ideal { return ideal }
    let ideal = (controls: subviews[0].sizeThatFits(.unspecified),
      actions: subviews[1].sizeThatFits(.unspecified))
    cache.ideal = ideal
    return ideal
  }

  private func sizes(width: CGFloat, subviews: Subviews, cache: inout Cache) -> Measurements {
    if let measured = cache.measurements[width] { return measured }
    let (controls, actions) = idealSizes(subviews: subviews, cache: &cache)
    let wraps = controls.width + horizontalSpacing + actions.width > width
    let measured: Measurements
    if wraps {
      let proposal = ProposedViewSize(width: width, height: nil)
      measured = Measurements(controls: subviews[0].sizeThatFits(proposal),
        actions: subviews[1].sizeThatFits(proposal), wraps: true)
    } else {
      measured = Measurements(controls: subviews[0].sizeThatFits(ProposedViewSize(
        width: width - actions.width - horizontalSpacing, height: nil)), actions: actions, wraps: false)
    }
    // A layout transaction probes several widths for sizing, alignment and
    // placement. Retain only a few exact proposals, never thumbnail pixels.
    if !width.isNaN {
      if cache.widths.count == 8 { cache.measurements.removeValue(forKey: cache.widths.removeFirst()) }
      cache.widths.append(width)
      cache.measurements[width] = measured
    }
    return measured
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    let ideal = idealSizes(subviews: subviews, cache: &cache)
    let idealWidth = ideal.controls.width + horizontalSpacing + ideal.actions.width
    let width = proposal.width ?? idealWidth
    let measured = sizes(width: width, subviews: subviews, cache: &cache)
    return CGSize(width: width, height: measured.wraps
      ? measured.controls.height + verticalSpacing + measured.actions.height
      : max(measured.controls.height, measured.actions.height))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
    let measured = sizes(width: bounds.width, subviews: subviews, cache: &cache)
    subviews[0].place(
      at: CGPoint(x: bounds.minX, y: measured.wraps ? bounds.minY : bounds.midY - measured.controls.height / 2),
      anchor: .topLeading, proposal: ProposedViewSize(measured.controls))
    subviews[1].place(
      at: CGPoint(x: bounds.maxX, y: measured.wraps
        ? bounds.minY + measured.controls.height + verticalSpacing : bounds.midY - measured.actions.height / 2),
      anchor: .topTrailing, proposal: ProposedViewSize(measured.actions))
  }
}

/// Hit-test geometry is collected only for marquee gestures. Its current frame
/// table is bookkeeping, so changes do not invalidate the whole grid when a cell
/// finishes loading or the viewport moves. The selection rectangle stays in State.
@MainActor
private final class OverviewCellFrameCache {
  var frames: [URL: CGRect] = [:]
  // Like marquee frames, viewport measurements are non-publishing bookkeeping.
  var visibleRevision: UUID?
  var visibleIndices: Set<Int> = []
  var assetIndexMap = OverviewAssetIndexMap()
  var capturedVisibleIndexHints: Set<Int> = []
  var visibleAssetCount = 0
  var contentFramesRevision: UUID?
  var contentFrames: [URL: CGRect] = [:]
  var capturedIndices: [URL: Int] = [:]
  var nativeViewport: OverviewNativeViewportGeometry?
  var focusedFrames: [UUID: CGRect] = [:]
  var traceCount = 0
  var traceRequestCount = 0
  var traceRequest: OverviewFocusScrollRequest?
  var traceDeadline: TimeInterval = 0
}

enum OverviewFocusRevealTrace {
  static let isEnabled = ProcessInfo.processInfo.environment["IMAGEVIEWER_OVERVIEW_REVEAL_TRACE"] == "1"

  static func rectangle(_ value: CGRect) -> [String: Double] {
    ["x": Double(value.minX), "y": Double(value.minY),
      "width": Double(value.width), "height": Double(value.height)]
  }
}

private struct OverviewFocusedCellFrameKey: PreferenceKey {
  static let defaultValue: [UUID: CGRect] = [:]
  static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
  }
}

private struct OverviewCellFramesKey: PreferenceKey {
  static let defaultValue: [URL: CGRect] = [:]
  static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
  }
}

private struct OverviewRealizedCellFrames: Equatable {
  var frames: [URL: CGRect] = [:]
  // Diagnostic only; production membership never depends on captured ordinals.
  var capturedIndices: [URL: Int] = [:]
}

private struct OverviewRealizedCellFramesKey: PreferenceKey {
  static let defaultValue: [UUID: OverviewRealizedCellFrames] = [:]
  static func reduce(value: inout [UUID: OverviewRealizedCellFrames],
    nextValue: () -> [UUID: OverviewRealizedCellFrames]) {
    for (revision, membership) in nextValue() {
      value[revision, default: OverviewRealizedCellFrames()].frames.merge(membership.frames,
        uniquingKeysWith: { _, newest in newest })
      value[revision, default: OverviewRealizedCellFrames()].capturedIndices.merge(membership.capturedIndices,
        uniquingKeysWith: { _, newest in newest })
    }
  }
}

/// Scroll coordinates and timer replacement are private bookkeeping. Only the
/// transition into motion and the quiet edge publish view state, so fractional
/// scroll updates do not repeatedly invalidate the grid through AppStore.
@MainActor
final class OverviewRefinementGate: ObservableObject {
  private struct DisplayState {
    var isDeferring = false
    var isWindowSuppressed = false
    var quietRevision: UInt64 = 0
  }
  @Published private var displayState = DisplayState()
  var isDeferring: Bool { displayState.isDeferring || displayState.isWindowSuppressed }
  var isWindowSuppressed: Bool { displayState.isWindowSuppressed }
  var quietRevision: UInt64 { displayState.quietRevision }
  private(set) var motionGeneration: UInt64 = 0
  private var previousOrigin: CGPoint?
  private var quietTask: Task<Void, Never>?
  private var quietDeadline: ContinuousClock.Instant?
  private var isLiveScrolling = false
  private let quietInterval: Duration
  private let requiresVisibleMembership: Bool
  private let observesWindowVisibility: Bool
  private var visibleAssets: Set<URL> = []
  weak var nativeScrollView: NSScrollView?
  weak var nativeContentAnchor: OverviewScrollMotionView?

  init(quietInterval: Duration = .milliseconds(350), requiresVisibleMembership: Bool = false,
    observesWindowVisibility: Bool = true) {
    self.quietInterval = quietInterval
    self.requiresVisibleMembership = requiresVisibleMembership
    self.observesWindowVisibility = observesWindowVisibility
  }

  /// A fully covered inactive window gives compact work to the paced preloader
  /// instead of starting simultaneous per-cell decodes. Precise visible-size
  /// work resumes through the quiet edge when the window is exposed again.
  func windowVisibilityChanged(isApplicationActive: Bool, isWindowVisible: Bool) {
    guard observesWindowVisibility else { return }
    let suppressed = !isApplicationActive && !isWindowVisible
    guard displayState.isWindowSuppressed != suppressed else { return }
    motionGeneration &+= 1
    var state = displayState
    state.isWindowSuppressed = suppressed
    if !suppressed { state.isDeferring = true }
    displayState = state
    if !suppressed { scheduleQuietCheck() }
  }

  func updateVisibleAssets(_ assets: Set<URL>) {
    guard assets != visibleAssets else { return }
    visibleAssets = assets
    // During motion only the final quiet edge publishes. Initial attachment,
    // filtering and stationary layout changes still admit the current cards.
    if !isDeferring { displayState.quietRevision &+= 1 }
  }

  func collectionChanged() {
    motionGeneration &+= 1
    visibleAssets.removeAll(keepingCapacity: true)
    if !displayState.isDeferring { displayState.isDeferring = true }
    scheduleQuietCheck()
  }

  func viewportMoved(to origin: CGPoint) {
    guard origin.x.isFinite, origin.y.isFinite else { return }
    defer { previousOrigin = origin }
    guard let previousOrigin, previousOrigin != origin else { return }
    motionGeneration &+= 1
    if !displayState.isDeferring { displayState.isDeferring = true }
    scheduleQuietCheck()
  }

  func liveScrollBegan() {
    isLiveScrolling = true
    motionGeneration &+= 1
    if !displayState.isDeferring { displayState.isDeferring = true }
    quietDeadline = nil
  }

  func liveScrollEnded() {
    isLiveScrolling = false
    guard displayState.isDeferring else { return }
    scheduleQuietCheck()
  }

  func allowsRefinement(since generation: UInt64) -> Bool {
    !isDeferring && motionGeneration == generation
  }

  func allowsRefinement(for url: URL) -> Bool {
    !isDeferring && (!requiresVisibleMembership || visibleAssets.contains(url))
  }

  func allowsRefinement(for url: URL, since generation: UInt64) -> Bool {
    allowsRefinement(for: url) && motionGeneration == generation
  }

  private func scheduleQuietCheck() {
    guard !isLiveScrolling else { quietDeadline = nil; return }
    quietDeadline = ContinuousClock.now + quietInterval
    guard quietTask == nil else { return }
    quietTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        guard let deadline = self.quietDeadline else { self.quietTask = nil; return }
        let remaining = ContinuousClock.now.duration(to: deadline)
        if remaining > .zero {
          do { try await Task.sleep(for: remaining) } catch { return }
        }
        guard !Task.isCancelled else { return }
        guard !self.isLiveScrolling else { self.quietTask = nil; return }
        guard let latestDeadline = self.quietDeadline, ContinuousClock.now >= latestDeadline else { continue }
        self.quietDeadline = nil
        self.quietTask = nil
        // The quiet edge restarts precise work once, without first invalidating
        // the whole grid for a revision that still has refinement disabled.
        var state = self.displayState
        state.isDeferring = false
        state.quietRevision &+= 1
        self.displayState = state
        return
      }
    }
  }

  func stop() {
    quietTask?.cancel()
    quietTask = nil
    quietDeadline = nil
    isLiveScrolling = false
    previousOrigin = nil
    visibleAssets.removeAll(keepingCapacity: true)
    motionGeneration &+= 1
    if isDeferring { displayState = DisplayState() }
  }
}

/// One native observer belongs to the overview document, never to every cell.
/// Bounds notifications arrive before new lazy cells need refinement admission;
/// a live gesture stays deferred even if it briefly pauses between wheel events.
struct OverviewScrollMotionObserver: NSViewRepresentable {
  let gate: OverviewRefinementGate
  var cellGeometryRegistry: OverviewNativeCellGeometryRegistry? = nil
  var onViewportChange: (@MainActor (OverviewNativeViewportGeometry?) -> Void)? = nil

  func makeNSView(context: Context) -> OverviewScrollMotionView {
    let view = OverviewScrollMotionView(frame: .zero)
    view.gate = gate
    view.onViewportChange = onViewportChange
    view.cellGeometryRegistry = cellGeometryRegistry
    return view
  }

  func updateNSView(_ view: OverviewScrollMotionView, context: Context) {
    view.gate = gate
    view.onViewportChange = onViewportChange
    view.cellGeometryRegistry = cellGeometryRegistry
    view.observeEnclosingScrollView()
    view.observeWindowVisibility()
    view.refreshViewportGeometry()
  }

  static func dismantleNSView(_ view: OverviewScrollMotionView, coordinator: ()) {
    view.stopObserving()
    view.stopObservingWindowVisibility()
    view.onViewportChange = nil
  }
}

@MainActor
final class OverviewScrollMotionView: NSView, OverviewNativeCellGeometryObserver {
  weak var gate: OverviewRefinementGate?
  var onViewportChange: (@MainActor (OverviewNativeViewportGeometry?) -> Void)?
  weak var cellGeometryRegistry: OverviewNativeCellGeometryRegistry? {
    didSet {
      if oldValue !== cellGeometryRegistry, oldValue?.observer === self { oldValue?.observer = nil }
      connectCellGeometryObserver()
    }
  }
  private weak var clipView: NSClipView?
  private weak var observedDocument: NSView?
  private var documentObservation: NSObjectProtocol?
  private var membershipRefreshPending = false
  private var observationGeneration: UInt64 = 0
  private var lastViewportGeometry: OverviewNativeViewportGeometry?
  private var observations: [NSObjectProtocol] = []
  private weak var observedWindow: NSWindow?
  private var windowObservations: [NSObjectProtocol] = []

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    observeEnclosingScrollView()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    observeEnclosingScrollView()
    observeWindowVisibility()
  }

  func observeWindowVisibility() {
    if observedWindow !== window {
      stopObservingWindowVisibility()
      observedWindow = window
      let center = NotificationCenter.default
      if let window {
        windowObservations.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
          object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.updateWindowVisibility() }
        })
      }
      for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
        windowObservations.append(center.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.updateWindowVisibility() }
        })
      }
    }
    updateWindowVisibility()
  }

  private func updateWindowVisibility() {
    // Sidebars also use this observer solely for their window, without a
    // native scroll anchor. Reject an explicitly newer owner, not that mode.
    guard gate?.nativeContentAnchor == nil || gate?.nativeContentAnchor === self else { return }
    gate?.windowVisibilityChanged(isApplicationActive: NSApp.isActive,
      isWindowVisible: window?.occlusionState.contains(.visible) == true)
  }

  func stopObservingWindowVisibility() {
    windowObservations.forEach { NotificationCenter.default.removeObserver($0) }
    windowObservations.removeAll(keepingCapacity: true)
    observedWindow = nil
  }

  func observeEnclosingScrollView() {
    observe(enclosingScrollView)
  }

  func observe(_ scroll: NSScrollView?) {
    guard clipView !== scroll?.contentView else {
      observeDocument(scroll?.documentView)
      connectCellGeometryObserver()
      return
    }
    stopObserving()
    guard let scroll else { return }
    gate?.nativeScrollView = scroll
    gate?.nativeContentAnchor = self
    let clip = scroll.contentView
    clipView = clip
    clip.postsBoundsChangedNotifications = true
    observeDocument(scroll.documentView)
    connectCellGeometryObserver()
    refreshViewportGeometry()
    let center = NotificationCenter.default
    observations.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.refreshViewportGeometry()
      }
    })
    observations.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.gate?.nativeContentAnchor === self else { return }
        self.gate?.liveScrollBegan()
      }
    })
    observations.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.gate?.nativeContentAnchor === self else { return }
        self.gate?.liveScrollEnded()
      }
    })
  }

  private func connectCellGeometryObserver() {
    guard clipView != nil, gate == nil || gate?.nativeContentAnchor === self else { return }
    cellGeometryRegistry?.observer = self
  }

  private func observeDocument(_ document: NSView?) {
    guard observedDocument !== document else { return }
    if let documentObservation { NotificationCenter.default.removeObserver(documentObservation) }
    documentObservation = nil
    observedDocument = document
    guard let document else { return }
    document.postsFrameChangedNotifications = true
    documentObservation = NotificationCenter.default.addObserver(
      forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.nativeCellGeometryDidChange() }
      }
    nativeCellGeometryDidChange()
  }

  func nativeCellGeometryDidChange() {
    guard clipView != nil, !membershipRefreshPending else { return }
    membershipRefreshPending = true
    let generation = observationGeneration
    // Cell placement can finish after a document-frame notification. Read once
    // on the next main turn; never force layout or poll every realized card.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.observationGeneration == generation else { return }
      self.membershipRefreshPending = false
      self.observeDocument(self.clipView?.enclosingScrollView?.documentView ?? self.clipView?.documentView)
      self.refreshViewportGeometry(forceMembership: true)
    }
  }

  func currentViewportGeometry() -> OverviewNativeViewportGeometry? {
    guard let clipView, let document = clipView.documentView,
      isDescendant(of: document) else { return nil }
    let anchor = document.convert(bounds, from: self)
    return OverviewNativeViewportGeometry(
      viewportInDocument: document.convert(clipView.bounds, from: clipView),
      contentOriginInDocument: CGPoint(x: anchor.minX,
        y: document.isFlipped ? anchor.minY : anchor.maxY),
      documentIsFlipped: document.isFlipped)
  }

  func refreshViewportGeometry(forceMembership: Bool = false) {
    guard gate == nil || gate?.nativeContentAnchor === self else { return }
    // Mark motion before membership admission. Otherwise the stationary gate's
    // quietRevision would invalidate the grid on each wheel notification.
    if let clipView { gate?.viewportMoved(to: clipView.bounds.origin) }
    let geometry = currentViewportGeometry()
    guard forceMembership || geometry != lastViewportGeometry else { return }
    lastViewportGeometry = geometry
    onViewportChange?(geometry)
  }

  func stopObserving() {
    observationGeneration &+= 1
    membershipRefreshPending = false
    if cellGeometryRegistry?.observer === self { cellGeometryRegistry?.observer = nil }
    if let documentObservation { NotificationCenter.default.removeObserver(documentObservation) }
    documentObservation = nil
    observedDocument = nil
    let ownedAnchor = gate?.nativeContentAnchor === self
    if ownedAnchor {
      gate?.nativeScrollView = nil
      gate?.nativeContentAnchor = nil
    }
    observations.forEach { NotificationCenter.default.removeObserver($0) }
    observations.removeAll(keepingCapacity: true)
    clipView = nil
    lastViewportGeometry = nil
    // A document can be reparented before its old scroll view posts didEnd.
    // Ending that old gesture must not leave the new host deferred forever.
    if ownedAnchor { gate?.liveScrollEnded() }
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
