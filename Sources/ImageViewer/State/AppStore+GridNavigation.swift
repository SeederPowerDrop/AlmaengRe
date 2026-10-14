extension AppStore {
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
