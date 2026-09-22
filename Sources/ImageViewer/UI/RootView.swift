import SwiftUI

struct RootView: View {
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject var store: AppStore
  @ObservedObject var shortcuts: ShortcutStore

  var body: some View {
    ZStack {
      ViewerTheme.chrome.ignoresSafeArea()

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
                  .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
              }
              if store.assets.isEmpty {
                if !store.allAssets.isEmpty {
                  ContentUnavailableView {
                    Label("검색 결과 없음", systemImage: "magnifyingglass")
                  } description: {
                    Text("검색어나 이미지 형식 필터를 바꿔 보세요.")
                  } actions: {
                    Button("검색·필터 초기화") { store.resetLibraryQuery() }
                  }
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

      if store.isLoading {
        VStack(spacing: 10) {
          ProgressView()
            .controlSize(.large)
          Text("폴더 읽는 중…")
            .font(.caption)
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
      }
    }
    .toolbar(store.isFocusMode ? .hidden : .visible, for: .windowToolbar)
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Button { store.showsFolderTree.toggle() } label: {
          Label("폴더 트리", systemImage: "list.bullet.indent")
            .foregroundStyle(store.showsFolderTree ? ViewerTheme.accent : Color.primary)
        }
        .labelStyle(.titleAndIcon)
        .help("폴더를 펼쳐 다른 폴더로 이동합니다.")
        .accessibilityValue(L10n.text(store.showsFolderTree ? "선택됨" : "선택 안 됨"))
      }
      ToolbarItem(placement: .navigation) {
        Button { store.chooseItems() } label: {
          Label("열기…", systemImage: "folder")
        }
        .labelStyle(.titleAndIcon)
        .help("이미지 또는 폴더를 선택하세요.")
      }

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

        Button {
          store.prefersHDR.toggle()
        } label: {
          Text(verbatim: store.prefersHDR ? "HDR ON" : "HDR OFF")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(store.prefersHDR ? ViewerTheme.accent : Color.secondary)
            .padding(.horizontal, 4)
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
        .disabled(store.currentAsset == nil || store.isBatchBusy)
        .help("AI로 2배 확대하고 사본으로 저장합니다.")

        Button {
          store.toggleInspector(.information)
        } label: {
          Label("이미지 정보", systemImage: "info.circle")
            .foregroundStyle(store.inspectorPanel == .information ? ViewerTheme.accent : Color.primary)
        }
        .accessibilityLabel("이미지 정보")
        .help("이미지 정보 (i)")

        Button {
          store.toggleInspector(.editing)
        } label: {
          Label("이미지 편집", systemImage: "slider.horizontal.3")
            .foregroundStyle(store.inspectorPanel == .editing ? ViewerTheme.accent : Color.primary)
        }
        .accessibilityLabel("이미지 편집")
        .help("이미지 편집 (e)")

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
      }
    }
    .sheet(item: $store.wallpaperRequest) { request in
      WallpaperSettingsView(store: store, request: request)
    }
    .sheet(isPresented: $store.showsAIUpscaling) {
      AIUpscalingSheet(store: store.aiUpscaling, sourceURL: store.currentAsset?.url)
    }
    .task { await store.restoreLastSession() }
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
      store.open(urls: urls)
      return !urls.isEmpty
    }
    .onReceive(NotificationCenter.default.publisher(for: .imageViewerOpenURLs)) { notification in
      if let urls = notification.object as? [URL] {
        store.open(urls: urls)
      }
    }
    .onChange(of: store.prefersHDR) { _, _ in
      store.purgeCaches()
    }
    .tint(ViewerTheme.accent)
  }

  private var viewerWorkspace: some View {
    VStack(spacing: 0) {
      if !store.isFocusMode {
        workspaceHeader
        Divider()
      }
      if showsThumbnailPanel(at: .top) {
        SidebarView(store: store, placement: .top)
        Divider()
      }

      HStack(spacing: 0) {
        if showsThumbnailPanel(at: .left) {
          SidebarView(store: store, placement: .left)
          Divider()
        }

        viewerContent
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        if showsThumbnailPanel(at: .right) {
          Divider()
          SidebarView(store: store, placement: .right)
        }

        if let panel = store.inspectorPanel, !store.isFocusMode {
          Divider()
          InspectorView(store: store, panel: panel)
        }
      }

      if showsThumbnailPanel(at: .bottom) {
        Divider()
        SidebarView(store: store, placement: .bottom)
      }
    }
  }

  private var folderNavigation: some View {
    VSplitView {
      FolderTreeView(store: store, comparison: store.folderComparison, tree: store.folderTree)
        .frame(minHeight: 180, idealHeight: 300, maxHeight: .infinity)
      if store.thumbnailPanelPlacement == .left && !store.assets.isEmpty
        && store.presentationMode != .folderComparison {
        SidebarView(store: store, placement: .left, panelWidth: 240)
          .frame(minHeight: 160, idealHeight: 320, maxHeight: .infinity)
      }
    }
    .frame(width: 240)
    .background(ViewerTheme.sidebar)
  }

  private var workspaceHeader: some View {
    HStack(spacing: 10) {
      Image(systemName: "folder")
        .foregroundStyle(.secondary)
      Text(store.activeFolderName)
        .font(.system(size: 12, weight: .semibold))
        .lineLimit(1).truncationMode(.middle)
      Text(L10n.format("%d개 이미지", store.assets.count))
        .font(.system(size: 11)).foregroundStyle(.secondary)
      Spacer(minLength: 12)
      if store.presentationMode == .viewer {
        Picker("한 화면 이미지 수", selection: Binding(
          get: { store.imagesPerPage }, set: { store.setImagesPerPage($0) }
        )) {
          ForEach(1...10, id: \.self) { count in
            Text(L10n.format("%d장", count)).tag(count)
          }
        }
        .labelsHidden()
        .frame(width: 66)
        .help("한 화면에 표시할 이미지 수")
      }
      BatchActionsMenu(store: store, compact: true)
      Button { store.toggleFocusMode() } label: { Image(systemName: "viewfinder") }
        .buttonStyle(ViewerToolButtonStyle())
        .help("집중 모드")
    }
    .padding(.horizontal, 16)
    .frame(height: 42)
    .background(ViewerTheme.chrome)
  }

  private var viewerContent: some View {
    Group {
      switch store.presentationMode {
      case .viewer:
        ViewerCanvas(store: store, shortcuts: shortcuts)
      case .overview:
        OverviewView(store: store)
      case .folderComparison:
        FolderComparisonView(store: store, shortcuts: shortcuts, comparison: store.folderComparison)
      }
    }
    .background {
      InputEventMonitor(
        onKeyDown: { event in
          store.handleViewerKeyDown(event, shortcuts: shortcuts)
        },
        onPointerPan: { input, delta in
          store.handlePanInput(input, delta: delta)
        },
        onHorizontalSwipe: { delta in
          guard store.presentationMode == .viewer else { return }
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
    !store.isFocusMode && store.thumbnailPanelPlacement == placement
      && !(placement == .left && store.showsFolderTree)
  }
}
