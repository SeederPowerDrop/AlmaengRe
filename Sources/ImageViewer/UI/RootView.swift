import SwiftUI

struct RootView: View {
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject var store: AppStore
  @ObservedObject var shortcuts: ShortcutStore
  @State private var isFileDropTargeted = false
  private let overviewPreloader: OverviewThumbnailPreloader?
  private let onOverviewBitmapStateApplied: (@MainActor (ThumbnailBitmapStateEvent) -> Void)?
  private let onSidebarBitmapStateApplied: (@MainActor (ThumbnailBitmapStateEvent) -> Void)?

  init(store: AppStore, shortcuts: ShortcutStore,
    overviewPreloader: OverviewThumbnailPreloader? = nil,
    onOverviewBitmapStateApplied: (@MainActor (ThumbnailBitmapStateEvent) -> Void)? = nil,
    onSidebarBitmapStateApplied: (@MainActor (ThumbnailBitmapStateEvent) -> Void)? = nil) {
    self.store = store
    self.shortcuts = shortcuts
    self.overviewPreloader = overviewPreloader
    self.onOverviewBitmapStateApplied = onOverviewBitmapStateApplied
    self.onSidebarBitmapStateApplied = onSidebarBitmapStateApplied
  }

  var body: some View {
    ZStack {
      ViewerTheme.chrome.ignoresSafeArea()

      if store.showsHome {
        HomeView(store: store)
      } else {
        libraryWorkspace
      }

      if store.isLoading || (store.showsHome && store.isRestoringSession) {
        VStack(spacing: 10) {
          ProgressView()
            .controlSize(.large)
          Text("폴더 읽는 중…")
            .font(ViewerUIMetrics.font(.caption))
        }
        .viewerPadding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
      }
    }
    .contentShape(Rectangle())
    .overlay {
      if isFileDropTargeted {
        ZStack {
          RoundedRectangle(cornerRadius: 16)
            .fill(ViewerTheme.accent.opacity(0.08))
          RoundedRectangle(cornerRadius: 16)
            .strokeBorder(ViewerTheme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
          Label(L10n.text("이미지·영상·폴더를 여기에 놓으세요."), systemImage: "arrow.down.doc")
            .font(ViewerUIMetrics.font(size: 17, weight: .semibold))
            .viewerPadding(.horizontal, 24).viewerPadding(.vertical, 18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .viewerPadding(10)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
    }
    .toolbar(store.isFocusMode && !store.showsHome ? .hidden : .visible, for: .windowToolbar)
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Button { store.showHome() } label: {
          Image(systemName: "house")
        }
        .buttonStyle(ViewerToolButtonStyle(isSelected: store.showsHome))
        .help(L10n.text("home.show"))
        .accessibilityLabel(L10n.text("home.show"))
        .disabled(!store.canShowHome)
      }
      if !store.showsHome {
        ToolbarItem(placement: .navigation) {
          Button { store.showsFolderTree.toggle() } label: {
            Label("폴더 트리", systemImage: "list.bullet.indent")
              .foregroundStyle(store.showsFolderTree ? ViewerTheme.accent : Color.primary)
          }
          .labelStyle(.titleAndIcon)
          .buttonStyle(ViewerToolButtonStyle(isSelected: store.showsFolderTree))
          .help("폴더를 펼쳐 다른 폴더로 이동합니다.")
          .accessibilityValue(L10n.text(store.showsFolderTree ? "선택됨" : "선택 안 됨"))
        }
      }
      ToolbarItem(placement: .navigation) {
        Button { store.chooseItems() } label: {
          Label("열기…", systemImage: "folder")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(ViewerToolButtonStyle())
        .help(!store.showsHome && store.presentationMode == .folderComparison
          ? L10n.text("이미지 또는 폴더를 선택하세요.") : MotionMediaL10n.text("open.message"))
      }

      if !store.showsHome {
        ToolbarItem(placement: .principal) {
          Picker("보기", selection: $store.presentationMode) {
            ForEach(PresentationMode.allCases) { mode in
              Text(mode.title).tag(mode)
                .help(mode == .folderComparison
                  ? L10n.text("이미지 두 장을 좌우·상하로 비교합니다.") : mode.title)
            }
          }
          .pickerStyle(.segmented)
          // 언어마다 다른 이름 길이를 반영해 모드 이름이 고정 폭 안에서 잘리지 않게 합니다.
          .fixedSize(horizontal: true, vertical: false)
          .frame(minWidth: 190)
        }

        ToolbarItemGroup(placement: .primaryAction) {

          Button { store.togglePhotoMarking() } label: {
            Label(PhotoMarkL10n.text(store.isPhotoMarking ? "mode.on" : "mode.off"),
              systemImage: store.isPhotoMarking ? "tag.fill" : "tag")
              .foregroundStyle(store.isPhotoMarking ? ViewerTheme.accent : Color.primary)
          }
          .labelStyle(.titleAndIcon)
          .buttonStyle(ViewerToolButtonStyle(isSelected: store.isPhotoMarking))
          .help(PhotoMarkL10n.text("mode.detailHelp"))
          .accessibilityLabel(PhotoMarkL10n.text("mode.title"))
          .accessibilityValue(L10n.text(store.isPhotoMarking ? "선택됨" : "선택 안 됨"))
          .disabled(!store.canTogglePhotoMarking)

          Button {
            store.prefersHDR.toggle()
          } label: {
            Text(verbatim: store.prefersHDR ? "HDR ON" : "HDR OFF")
              .font(ViewerUIMetrics.font(size: 11, weight: .semibold))
              .foregroundStyle(store.prefersHDR ? ViewerTheme.accent : Color.secondary)
              .viewerPadding(.horizontal, 4)
          }
          .accessibilityLabel("HDR 출력")
          .accessibilityValue(Text(verbatim: store.prefersHDR ? "ON" : "OFF"))
          .help(L10n.text(store.prefersHDR ? "HDR 출력 켜짐" : "HDR 출력 꺼짐"))

          if store.presentationMode != .folderComparison {
          thumbnailPlacementMenu

          Button {
            store.pauseSlideshow()
            store.showsAIUpscaling = true
          } label: {
            Label("AI 확대", systemImage: "sparkles")
          }
          .labelStyle(.titleAndIcon)
          .disabled(store.currentAsset == nil || store.currentAsset?.isPlaybackMedia == true || store.isBatchBusy)
          .help("AI로 2배 확대하고 사본으로 저장합니다.")

          Button {
            store.toggleInspector(.information)
          } label: {
            Label("이미지 정보", systemImage: "info.circle")
              .foregroundStyle(store.inspectorPanel == .information ? ViewerTheme.accent : Color.primary)
          }
          .buttonStyle(ViewerToolButtonStyle(isSelected: store.inspectorPanel == .information))
          .accessibilityLabel("이미지 정보")
          .help("이미지 정보 (i)")

          Button {
            store.toggleInspector(.editing)
          } label: {
            Label("이미지 편집", systemImage: "slider.horizontal.3")
              .foregroundStyle(store.inspectorPanel == .editing ? ViewerTheme.accent : Color.primary)
          }
          .buttonStyle(ViewerToolButtonStyle(isSelected: store.inspectorPanel == .editing))
          .accessibilityLabel("이미지 편집")
          .help("이미지 편집 (e)")

          }
        }
      }
    }
    .alert(item: $store.alert) { alert in
      Alert(
        title: Text(alert.title),
        message: Text(alert.message),
        dismissButton: .default(Text("확인"))
      )
    }
    .sheet(item: $store.batchSheet) { sheet in
      switch sheet {
      case .rename: BatchRenameView(store: store)
      case .export: BatchExportView(store: store)
      case .watermark: BatchExportView(store: store, startsWithWatermark: true)
      case .fileOperation:
        if let request = store.fileOperationRequest {
          BatchFileOperationSheet(store: store, request: request)
        }
      }
    }
    .sheet(item: $store.wallpaperRequest) { request in
      WallpaperSettingsView(store: store, request: request)
    }
    .sheet(isPresented: $store.showsAIUpscaling) {
      AIUpscalingSheet(store: store.aiUpscaling, sourceURL: store.currentAsset?.url,
        preparePhotoMarks: { try await store.prepareExportPhotoMarks(sourceURLs: [$0]) })
    }
    .sheet(isPresented: $store.showsPhotoMarkEditor) {
      PhotoMarkEditor(marks: store.photoMarks)
    }
    .sheet(item: $store.motionMediaAsset) { asset in
      MotionMediaEditor(asset: asset, pipeline: store.pipeline,
        preparePhotoMarks: { try await store.prepareExportPhotoMarks(for: [asset]) })
    }
    .sheet(isPresented: $store.showsPhotoMarkTrackingReport) {
      PhotoMarkTrackingReportSheet(marks: store.photoMarks)
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { store.pauseSlideshow(); store.saveSessionNow() }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
      store.pauseSlideshow()
      store.saveSessionNow()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
      store.saveSessionNow()
    }
    .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
      store.pauseSlideshow()
    }
    .onDisappear { store.pauseSlideshow() }
    .dropDestination(for: URL.self) { urls, _ in
      isFileDropTargeted = false
      return store.openExternally(urls: urls)
    } isTargeted: { isTargeted in
      isFileDropTargeted = isTargeted
    }
    .onChange(of: store.prefersHDR) { _, _ in
      store.purgeCaches(clearDisk: false)
    }
    .tint(ViewerTheme.accent)
  }

  private var libraryWorkspace: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        if store.showsFolderTree && !store.isFocusMode {
          folderNavigation
          Divider()
        }
        Group {
          if store.presentationMode == .folderComparison {
            FolderComparisonView(store: store, shortcuts: shortcuts, comparison: store.folderComparison)
          } else {
            VStack(spacing: 0) {
              if !store.isFocusMode && (!store.allAssets.isEmpty || store.currentFolderURL != nil) {
                LibraryControlsView(store: store)
                  .viewerPadding(.horizontal, 16).viewerPadding(.vertical, 10)
                  .background(ViewerTheme.chromeGradient)
                Divider()
              }
              if store.presentationMode != .map && store.libraryQuery.geographicSelection != nil {
                MapSelectionScopeView(store: store)
                Divider()
              }
              if store.presentationMode == .map, !store.allAssets.isEmpty {
                viewerWorkspace
              } else if store.assets.isEmpty {
                if !store.allAssets.isEmpty {
                  ContentUnavailableView {
                    Label("검색 결과 없음", systemImage: "magnifyingglass")
                  } description: {
                    Text(!store.showsVideos && store.allAssets.contains(where: \.isPlaybackMedia)
                      ? MotionMediaL10n.text("hiddenVideos") : PhotoMarkL10n.text("filter.empty"))
                  } actions: {
                    if !store.showsVideos && store.allAssets.contains(where: \.isPlaybackMedia) {
                      Button(MotionMediaL10n.text("showVideos")) { store.showsVideos = true }
                    }
                    Button("검색·필터 초기화") { store.resetLibraryQuery() }
                  }
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                  EmptyLibraryView(store: store)
                }
              } else {
                viewerWorkspace
              }
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if store.isPhotoMarking {
        Divider()
        PhotoMarkPanel(store: store, marks: store.photoMarks, shortcuts: shortcuts)
      }
    }
  }

  private var viewerWorkspace: some View {
    VStack(spacing: 0) {
      if !store.isFocusMode {
        workspaceHeader
        Divider()
      }
      if showsThumbnailPanel(at: .top) {
        SidebarView(store: store, placement: .top, onBitmapStateApplied: onSidebarBitmapStateApplied)
        Divider()
      }

      HStack(spacing: 0) {
        if showsThumbnailPanel(at: .left) {
          SidebarView(store: store, placement: .left, onBitmapStateApplied: onSidebarBitmapStateApplied)
          Divider()
        }

        viewerContent
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        if showsThumbnailPanel(at: .right) {
          Divider()
          SidebarView(store: store, placement: .right, onBitmapStateApplied: onSidebarBitmapStateApplied)
        }

        if let panel = store.inspectorPanel, !store.isFocusMode {
          Divider()
          InspectorView(store: store, panel: panel)
        }
      }

      if showsThumbnailPanel(at: .bottom) {
        Divider()
        SidebarView(store: store, placement: .bottom, onBitmapStateApplied: onSidebarBitmapStateApplied)
      }
    }
  }

  private var folderNavigation: some View {
    VSplitView {
      FolderTreeView(store: store, comparison: store.folderComparison, tree: store.folderTree)
        .frame(minHeight: 180, idealHeight: 300, maxHeight: .infinity)
      if store.thumbnailPanelPlacement == .left && !store.assets.isEmpty
        && store.presentationMode != .folderComparison && store.presentationMode != .map {
        SidebarView(store: store, placement: .left, panelWidth: 240, onBitmapStateApplied: onSidebarBitmapStateApplied)
          .frame(minHeight: 160, idealHeight: 320, maxHeight: .infinity)
      }
    }
    .frame(width: 240)
    .background(ViewerTheme.sidebar)
  }

  private var workspaceHeader: some View {
    HStack(spacing: 10) {
      Image(systemName: "folder")
        .font(ViewerUIMetrics.font(size: 12, weight: .medium))
        .foregroundStyle(ViewerTheme.accent)
        .viewerFrame(width: 25, height: 25)
        .background(ViewerTheme.selection, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
      Text(store.activeFolderName)
        .font(ViewerUIMetrics.font(size: 12, weight: .semibold))
        .lineLimit(1).truncationMode(.middle)
      Text(MotionMediaL10n.format("items.count", store.assets.count))
        .font(ViewerUIMetrics.font(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(.secondary)
        .viewerPadding(.horizontal, 7).viewerPadding(.vertical, 3)
        .background(ViewerTheme.controlFill.opacity(0.65), in: Capsule())
      Spacer(minLength: 12)
      if store.presentationMode == .viewer {
        ViewerPageNavigationHint(store: store, shortcuts: shortcuts)
        Picker("한 화면 이미지 수", selection: Binding(
          get: { store.imagesPerPage }, set: { store.setImagesPerPage($0) }
        )) {
          ForEach(1...10, id: \.self) { count in
            Text(L10n.format("%d장", count)).tag(count)
          }
        }
        .labelsHidden()
        .viewerFrame(width: 66)
        .help("한 화면에 표시할 이미지 수")
        if store.visibleAssets.count > 1 {
          ViewerFrameLayoutMenu(layout: store.frameLayout, count: store.visibleAssets.count)
        }
      }
      BatchActionsMenu(store: store, compact: true)
      if store.presentationMode != .map {
        Button { store.toggleFocusMode() } label: { Image(systemName: "viewfinder") }
          .buttonStyle(ViewerToolButtonStyle())
          .help("집중 모드")
      }
    }
    .viewerPadding(.horizontal, 16)
    .viewerFrame(height: 44)
    .background(ViewerTheme.chromeGradient)
  }


  private var viewerContent: some View {
    Group {
      switch store.presentationMode {
      case .viewer:
        ViewerCanvas(store: store, shortcuts: shortcuts)
      case .overview:
        if let overviewPreloader {
          OverviewView(store: store, thumbnailPreloader: overviewPreloader,
            onBitmapStateApplied: onOverviewBitmapStateApplied)
        } else {
          OverviewView(store: store, onBitmapStateApplied: onOverviewBitmapStateApplied)
        }
      case .map:
        PhotoMapView(store: store, assets: store.mapAssets.filter { $0.location != nil },
          isLoading: store.isLoading || store.isIndexingLocations || store.isFiltering,
          scannedCount: store.locationScanCount, totalCount: store.allAssets.count,
          selection: store.libraryQuery.geographicSelection,
          matchingAssetURLs: Set(store.assets.map(\.url)),
          thumbnailPipeline: store.thumbnailPipeline, pipeline: store.pipeline,
          onSelectionChange: { store.libraryQuery.geographicSelection = $0 },
          onOpenAsset: { store.openAssetFromMap($0) },
          onShowSelection: { store.showMapSelection(in: $0) })
          .id(store.mapCollectionID)
      case .folderComparison:
        FolderComparisonView(store: store, shortcuts: shortcuts, comparison: store.folderComparison)
      }
    }
    .background {
      InputEventMonitor(
        onKeyDown: { event in
          store.presentationMode == .map ? false
            : store.handleViewerKeyDown(event, shortcuts: shortcuts)
        },
        onPointerPan: { input, delta in
          store.handlePanInput(input, delta: delta)
        },
        onHorizontalSwipe: { delta in
          guard store.presentationMode == .viewer, !store.isEditingViewerFrames else { return }
          store.navigatePage(delta < 0 ? 1 : -1)
        },
        canHandleSpaceTap: { store.canToggleImageFocus && !shortcuts.hasPlainSpaceBinding },
        onSpaceTap: { store.toggleImageFocus() }
      )
    }
  }

  private var thumbnailPlacementMenu: some View {
    Menu {
      Text("썸네일 사이드바")
      Text("폴더의 사진 목록을 표시할 위치를 선택하세요.")
      Divider()
      ForEach(ThumbnailPanelPlacement.quickSelectionOrder) { placement in
        Button {
          store.thumbnailPanelPlacement = placement
        } label: {
          Label(
            placement.menuTitle,
            systemImage: store.thumbnailPanelPlacement == placement
              ? "checkmark" : placement.systemImage
          )
        }
      }
    } label: {
      Label("썸네일", systemImage: store.thumbnailPanelPlacement.systemImage)
        .labelStyle(.titleAndIcon)
    }
    .accessibilityLabel("썸네일 사이드바")
    .help("폴더의 사진 목록을 표시할 위치를 선택하세요.")
  }

  private func showsThumbnailPanel(at placement: ThumbnailPanelPlacement) -> Bool {
    !store.isFocusMode && store.presentationMode != .map && store.thumbnailPanelPlacement == placement
      && !(placement == .left && store.showsFolderTree)
  }
}
