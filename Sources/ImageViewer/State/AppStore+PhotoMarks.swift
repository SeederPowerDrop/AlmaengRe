import AppKit

extension AppStore {
  struct PresentedAssetVersion: Hashable {
    let id: URL
    let byteCount: Int64?
    let modificationDate: Date?

    init(_ asset: ImageAsset) {
      id = asset.id
      byteCount = asset.byteCount
      modificationDate = asset.modificationDate
    }
  }

  var photoMarkAsset: ImageAsset? { photoMarkAssets.first }

  var photoMarkAssets: [ImageAsset] {
    let candidates: [ImageAsset]
    if let fullScreenVideoAsset { candidates = [fullScreenVideoAsset] }
    else if presentationMode == .folderComparison {
      candidates = folderComparison.photoMarkTarget.sides.compactMap {
        folderComparison.pane($0).currentAsset
      }
    } else {
      // Selection is shared with file actions, including mixed image/video
      // selections and items chosen on other pages. Clearing it means no target.
      candidates = presentationMode == .map ? [] : selectedAssets
    }
    var identities = Set<String>()
    return candidates.filter { identities.insert($0.photoMarkID).inserted }
  }

  func photoMarkSelectionState(for slot: PhotoMarkSlot) -> PhotoMarkSelectionState {
    let selected: [Bool]
    if fullScreenVideoAsset == nil, presentationMode == .folderComparison {
      selected = folderComparison.photoMarkTarget.sides.map { side in
        folderComparison.pane(side).currentAsset.map {
          photoMarks.marks(for: $0).contains(slot)
        } ?? false
      }
    } else { selected = photoMarkAssets.map { photoMarks.marks(for: $0).contains(slot) } }
    guard selected.contains(true) else { return .none }
    return selected.allSatisfy { $0 } ? .all : .mixed
  }

  var canMarkPhoto: Bool {
    if fullScreenVideoAsset == nil, presentationMode == .folderComparison {
      guard isPhotoMarking, photoMarks.isReady, photoMarks.errorMessage == nil,
        canInteractWhileMarking, !folderComparison.isMatching,
        folderComparison.alert == nil else { return false }
      return folderComparison.photoMarkTarget.sides.allSatisfy { side in
        let pane = folderComparison.pane(side)
        return !pane.isLoading && !pane.isFiltering && pane.errorMessage == nil
          && pane.currentAsset != nil && pane.canMarkPresentedAsset
      }
    }
    if let fullScreenVideoAsset { return canMarkPhoto(fullScreenVideoAsset) }
    guard isPhotoMarking, photoMarks.isReady, photoMarks.errorMessage == nil,
      canInteractWhileMarking, presentationMode != .map else { return false }
    let targets = photoMarkAssets
    guard !targets.isEmpty else { return false }
    if presentationMode == .overview || !tracksViewerPresentation { return true }
    // Validate every selected visible slot before changing any item. Off-page
    // selections are explicit list selections, but a retained frame must never
    // let the keyboard mark a newly requested file that is not yet on screen.
    return visibleAssets.enumerated().allSatisfy { slot, asset in
      !selectedURLs.contains(asset.url) || viewerPresentedAssets[slot] == PresentedAssetVersion(asset)
    }
  }

  func canMarkPhoto(_ asset: ImageAsset) -> Bool {
    guard isPhotoMarking, photoMarks.isReady, photoMarks.errorMessage == nil,
      canInteractWhileMarking else { return false }
    if let fullScreenVideoAsset {
      return Self.matchesPresentedAsset(asset, fullScreenVideoAsset)
        && allAssets.contains { Self.matchesPresentedAsset($0, asset) }
        && isFullScreenVideoReadyToMark
    }
    if presentationMode == .folderComparison {
      let pane = folderComparison.pane(folderComparison.activeSide)
      return canNavigateWhileMarking && pane.canMarkPresentedAsset
        && pane.currentAsset.map { Self.matchesPresentedAsset($0, asset) } == true
    }
    guard presentationMode != .map,
      assets.contains(where: { Self.matchesPresentedAsset($0, asset) }) else { return false }
    if presentationMode == .overview { return true }
    guard let slot = visibleAssets.firstIndex(where: { Self.matchesPresentedAsset($0, asset) }) else {
      return false
    }
    return !tracksViewerPresentation
      || viewerPresentedAssets[slot] == PresentedAssetVersion(asset)
  }

  func beginTrackingViewerPresentation() {
    tracksViewerPresentation = true
    objectWillChange.send()
  }

  func endTrackingViewerPresentation() {
    tracksViewerPresentation = false
    viewerPresentedAssets.removeAll()
    objectWillChange.send()
  }

  /// A retained frame can still belong to the previous request. Only mark a
  /// requested asset after that exact file version has reached its visible slot.
  func recordPresentedAsset(_ asset: ImageAsset?, slot: Int, requestedAsset: ImageAsset? = nil) {
    if let requestedAsset {
      guard visibleAssets.indices.contains(slot),
        Self.matchesPresentedAsset(visibleAssets[slot], requestedAsset) else { return }
    }
    if let asset {
      viewerPresentedAssets[slot] = PresentedAssetVersion(asset)
    } else {
      if let requestedAsset, let previous = viewerPresentedAssets[slot],
        previous != PresentedAssetVersion(requestedAsset) { return }
      viewerPresentedAssets.removeValue(forKey: slot)
    }
    objectWillChange.send()
  }

  private static func matchesPresentedAsset(_ lhs: ImageAsset, _ rhs: ImageAsset) -> Bool {
    lhs.id == rhs.id && lhs.byteCount == rhs.byteCount && lhs.modificationDate == rhs.modificationDate
  }

  private var canInteractWhileMarking: Bool {
    guard !showsHome, !isRestoringSession, !isLoading, !isFiltering, !isBatchBusy, !isSavingMetadata, !isExporting,
      batchSheet == nil, !showsPhotoMarkEditor, !showsPhotoMarkTrackingReport, !showsAIUpscaling,
      wallpaperRequest == nil, !isSettingWallpaper, alert == nil,
      overviewSelectionSession == nil, motionMediaAsset == nil,
      !folderComparison.isEditingNames, folderComparison.editingPhotoMarkSide == nil else { return false }
    return true
  }

  private var canNavigateWhileMarking: Bool {
    guard canInteractWhileMarking else { return false }
    if presentationMode == .folderComparison {
      let pane = folderComparison.pane(folderComparison.activeSide)
      return !pane.isLoading && !pane.isFiltering && !folderComparison.isMatching
    }
    return presentationMode != .map && !assets.isEmpty
  }

  func togglePhotoMarking() {
    guard canTogglePhotoMarking else { return }
    if !isPhotoMarking, presentationMode == .map { presentationMode = .viewer }
    isPhotoMarking.toggle()
    if isPhotoMarking { clearPhotoMarkTextFocus(in: NSApp?.keyWindow) }
  }

  var canTogglePhotoMarking: Bool {
    !showsHome && !isRestoringSession && motionMediaAsset == nil && batchSheet == nil && !isBatchBusy && !showsPhotoMarkEditor && !showsPhotoMarkTrackingReport && !showsAIUpscaling
      && wallpaperRequest == nil && !isSettingWallpaper && !isSavingMetadata
      && !isExporting && alert == nil && !folderComparison.isEditingControls
  }

  var canEditPhotoMarkLabels: Bool {
    photoMarks.isReady && canTogglePhotoMarking && !isVideoFullScreenPresented
  }

  func presentPhotoMarkEditor() {
    guard canEditPhotoMarkLabels else { return }
    showsPhotoMarkEditor = true
  }

  func togglePhotoMark(_ slot: PhotoMarkSlot) {
    guard canMarkPhoto else { return }
    let targets = photoMarkAssets
    guard !targets.isEmpty else { return }
    let recordWork = makeRecentWorkRecorder()
    let previous = targets.map { (asset: $0, marks: photoMarks.marks(for: $0)) }
    let removes = targets.allSatisfy { photoMarks.marks(for: $0).contains(slot) }
    clearPhotoMarkTextFocus(in: NSApp?.keyWindow)
    pauseSlideshow()
    // A mixed selection becomes fully marked; a fully marked selection clears.
    photoMarks.set(slot, enabled: !removes, for: targets)
    recordCommittedPhotoMarkWork(previous.compactMap {
      $0.marks != photoMarks.marks(for: $0.asset) ? $0.asset : nil
    }, using: recordWork)
  }

  func togglePhotoMark(_ slot: PhotoMarkSlot, for asset: ImageAsset) {
    guard canMarkPhoto(asset) else { return }
    let recordWork = makeRecentWorkRecorder()
    let previous = photoMarks.marks(for: asset)
    clearPhotoMarkTextFocus(in: NSApp?.keyWindow)
    pauseSlideshow()
    photoMarks.toggle(slot, for: asset)
    if previous != photoMarks.marks(for: asset) {
      recordCommittedPhotoMarkWork([asset], using: recordWork)
    }
  }

  private func recordCommittedPhotoMarkWork(_ assets: [ImageAsset],
    using recordWork: @escaping @MainActor ([ImageAsset]) -> Void) {
    guard !assets.isEmpty else { return }
    let marks = photoMarks
    Task {
      // The visible mark is optimistic. Only a successful durable write counts
      // as completed work, and the recorder rejects deleted/replaced history.
      guard await marks.flushAsync() else { return }
      recordWork(assets)
    }
  }

  func clearPhotoMarkTextFocus(in window: NSWindow?) {
    guard let window, window.firstResponder is NSTextView else { return }
    window.makeFirstResponder(nil)
  }

  /// The separate movie window shares classification keys, while leaving arrows
  /// and playback controls with AVKit instead of navigating the hidden gallery.
  func handleFullScreenPhotoMarkKeyDown(_ event: NSEvent) -> Bool {
    guard isVideoFullScreenPresented, event.type == .keyDown else { return false }
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if event.keyCode == 46, modifiers == [.command, .shift] {
      guard canTogglePhotoMarking else { return false }
      if !event.isARepeat { togglePhotoMarking() }
      return true
    }
    guard isPhotoMarking, modifiers.isEmpty, let slot = PhotoMarkSlot(keyCode: event.keyCode) else {
      return false
    }
    if !event.isARepeat { togglePhotoMark(slot) }
    return true
  }

  /// Physical keys preserve the left-hand layout with a Korean input source.
  /// Consume held mark keys without repeatedly undoing and reapplying the mark.
  func handlePhotoMarkKeyDown(_ event: NSEvent) -> Bool {
    guard isPhotoMarking, event.type == .keyDown,
      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
      return false
    }
    if let slot = PhotoMarkSlot(keyCode: event.keyCode) {
      if !event.isARepeat { togglePhotoMark(slot) }
      return true
    }
    if [123, 124, 125, 126].contains(event.keyCode) {
      guard canInteractWhileMarking else { return true }
      let direction = [123, 126].contains(event.keyCode) ? -1 : 1
      if presentationMode == .folderComparison {
        folderComparison.navigateSelection(direction)
      } else {
        guard canNavigateWhileMarking else { return true }
        if (event.keyCode == 125 || event.keyCode == 126), navigateGridRow(direction) {
          return true
        }
        if presentationMode == .viewer, imagesPerPage > 1,
          event.keyCode == 123 || event.keyCode == 124 {
          navigatePage(direction)
          return true
        }
        var index = currentIndex + direction
        if wrapsNavigation { index = (index + assets.count) % assets.count }
        else { index = min(max(0, index), assets.count - 1) }
        select(index: index)
      }
      return true
    }
    return false
  }
}
