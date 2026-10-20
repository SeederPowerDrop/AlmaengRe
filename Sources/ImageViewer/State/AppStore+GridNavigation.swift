import AppKit

extension AppStore {
  /// Modified arrows share the click selection rules: Command toggles the
  /// destination, Shift selects an anchored range, and Command-Shift adds it.
  /// An edge is consumed without changing the current selection again.
  @discardableResult
  func navigateOverviewSelection(_ direction: ViewerSelectionDirection,
    modifiers: NSEvent.ModifierFlags = .command) -> Bool {
    guard presentationMode == .overview else { return false }
    guard !showsHome, !isRestoringSession, !isLoading, !isFiltering,
      !isExporting, !isSavingMetadata, !isVideoFullScreenPresented,
      motionMediaAsset == nil, batchSheet == nil, !isBatchBusy,
      wallpaperRequest == nil, !isSettingWallpaper, !showsAIUpscaling,
      !showsPhotoMarkEditor, !showsPhotoMarkTrackingReport, alert == nil,
      overviewSelectionSession == nil, assets.indices.contains(currentIndex) else { return true }
    let columns = min(assets.count, max(1, overviewColumnCount))
    let target: Int
    switch direction {
    case .left, .right:
      let rowStart = currentIndex / columns * columns
      let rowEnd = min(assets.count, rowStart + columns) - 1
      let towardHigherIndex = (direction == .right) != overviewIsRightToLeft
      target = min(rowEnd, max(rowStart, currentIndex + (towardHigherIndex ? 1 : -1)))
    case .up, .down:
      target = GridRowNavigation.target(from: currentIndex, direction: direction == .up ? -1 : 1,
        count: assets.count, columns: columns)
    }
    if target != currentIndex { selectForBatch(index: target, modifiers: modifiers) }
    return true
  }

  /// Called after user-assigned shortcuts, so a customized modified-arrow
  /// binding retains its normal behavior. Native arrows may also set Fn/pad.
  func handleOverviewSelectionKeyDown(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard event.type == .keyDown,
      modifiers == .command || modifiers == .shift || modifiers == [.command, .shift] else {
      return false
    }
    let direction: ViewerSelectionDirection
    switch event.keyCode {
    case 123: direction = .left
    case 124: direction = .right
    case 125: direction = .down
    case 126: direction = .up
    default: return false
    }
    return navigateOverviewSelection(direction, modifiers: modifiers)
  }

  /// Selects a spatial neighbour without navigating to another page. Edges wrap
  /// within the chosen direction, following the user's frame positions and sizes.
  @discardableResult
  func navigateViewerSelection(_ direction: ViewerSelectionDirection) -> Bool {
    guard presentationMode == .viewer, imagesPerPage > 1 else { return false }
    guard !showsHome, !isRestoringSession, !isLoading, !isFiltering,
      !isExporting, !isSavingMetadata, !isEditingViewerFrames, !isVideoFullScreenPresented,
      motionMediaAsset == nil, batchSheet == nil, !isBatchBusy,
      wallpaperRequest == nil, !isSettingWallpaper, !showsAIUpscaling,
      !showsPhotoMarkEditor, !showsPhotoMarkTrackingReport, alert == nil,
      overviewSelectionSession == nil, assets.indices.contains(pageStartIndex) else { return true }
    let count = min(imagesPerPage, assets.count - pageStartIndex)
    guard (pageStartIndex..<(pageStartIndex + count)).contains(currentIndex) else { return true }
    let targetSlot = frameLayout.selectionTarget(from: currentIndex - pageStartIndex,
      direction: direction, count: count, in: viewerViewportSize)
    let target = pageStartIndex + targetSlot
    // A page with only one remaining frame still collapses a multiple selection;
    // an already-single selection keeps its existing zoom and pan untouched.
    if target != currentIndex || selectedURLs != [assets[target].url] {
      select(index: target)
    }
    return true
  }

  /// Returns true when this view owns vertical grid navigation, even at an edge.
  /// Viewer selection stays within its page; left/right changes pages.
  @discardableResult
  func navigateGridRow(_ direction: Int) -> Bool {
    let start: Int
    let count: Int
    let columns: Int
    switch presentationMode {
    case .overview:
      start = 0
      count = assets.count
      columns = overviewColumnCount
    case .viewer where imagesPerPage > 1:
      start = pageStartIndex
      count = min(imagesPerPage, assets.count - start)
      columns = viewerColumnCount
    default:
      return false
    }
    guard !showsHome, !isLoading, !isFiltering, !isExporting, !isSavingMetadata,
      motionMediaAsset == nil, batchSheet == nil, !isBatchBusy,
      overviewSelectionSession == nil, count > 0 else { return true }
    let targetSlot = presentationMode == .viewer
      ? frameLayout.rowTarget(from: currentIndex - start, direction: direction, count: count, in: viewerViewportSize)
      : GridRowNavigation.target(from: currentIndex - start, direction: direction,
          count: count, columns: columns)
    let target = start + targetSlot
    if target != currentIndex { select(index: target) }
    return true
  }
}
