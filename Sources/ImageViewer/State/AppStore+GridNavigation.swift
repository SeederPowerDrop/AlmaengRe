extension AppStore {
  /// Selects the previous/next displayed frame without navigating to another page.
  /// This wraps within physical layout order, including positions changed by the user.
  @discardableResult
  func navigateViewerSelection(_ direction: Int) -> Bool {
    guard presentationMode == .viewer, imagesPerPage > 1 else { return false }
    guard direction != 0, !showsHome, !isRestoringSession, !isLoading, !isFiltering,
      !isExporting, !isSavingMetadata, !isEditingViewerFrames, !isVideoFullScreenPresented,
      motionMediaAsset == nil, batchSheet == nil, !isBatchBusy,
      wallpaperRequest == nil, !isSettingWallpaper, !showsAIUpscaling,
      !showsPhotoMarkEditor, !showsPhotoMarkTrackingReport, alert == nil,
      overviewSelectionSession == nil, assets.indices.contains(pageStartIndex) else { return true }
    let count = min(imagesPerPage, assets.count - pageStartIndex)
    guard (pageStartIndex..<(pageStartIndex + count)).contains(currentIndex) else { return true }
    let targetSlot = frameLayout.selectionTarget(from: currentIndex - pageStartIndex,
      direction: direction, count: count)
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
