import SwiftUI

struct RootView: View {
  @ObservedObject var store: AppStore
  @ObservedObject var shortcuts: ShortcutStore

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if store.assets.isEmpty {
        EmptyLibraryView(store: store)
      } else {
        viewerWorkspace
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
      ToolbarItemGroup(placement: .navigation) {
        Button {
          store.chooseFolder()
        } label: {
          Image(systemName: "folder")
        }
        .help("폴더 열기")

        Button {
          store.chooseFiles()
        } label: {
          Image(systemName: "photo.badge.plus")
        }
        .help("이미지 파일 열기")
      }

      ToolbarItem(placement: .principal) {
        Picker("보기", selection: $store.presentationMode) {
          ForEach(PresentationMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 190)
      }

      ToolbarItemGroup(placement: .primaryAction) {
        if store.presentationMode == .viewer {
          Picker(
            "한 화면 이미지 수",
            selection: Binding(
              get: { store.imagesPerPage },
              set: { store.setImagesPerPage($0) }
            )
          ) {
            ForEach(1...10, id: \.self) { count in
              Text(L10n.format("%d장", count)).tag(count)
            }
          }
          .frame(width: 76)
          .help("한 화면에 표시할 이미지 수")
        }

        Button {
          store.prefersHDR.toggle()
        } label: {
          Image(systemName: store.prefersHDR ? "sun.max.fill" : "sun.max")
        }
        .help(L10n.text(store.prefersHDR ? "HDR 출력 켜짐" : "HDR 출력 꺼짐"))

        thumbnailPlacementMenu

        Button {
          store.toggleInspector(.information)
        } label: {
          Image(
            systemName: store.inspectorPanel == .information ? "info.circle.fill" : "info.circle")
        }
        .accessibilityLabel("이미지 정보")
        .help("이미지 정보 (i)")

        Button {
          store.toggleInspector(.editing)
        } label: {
          EditingGlyph(isActive: store.inspectorPanel == .editing)
        }
        .accessibilityLabel("이미지 편집")
        .help("이미지 편집 (e)")

        Button {
          store.toggleFocusMode()
        } label: {
          Image(systemName: "viewfinder")
        }
        .help("집중 모드")
      }
    }
    .alert(item: $store.alert) { alert in
      Alert(
        title: Text(alert.title),
        message: Text(alert.message),
        dismissButton: .default(Text("확인"))
      )
    }
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
    .preferredColorScheme(.dark)
  }

  private var viewerWorkspace: some View {
    VStack(spacing: 0) {
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

  private var viewerContent: some View {
    Group {
      switch store.presentationMode {
      case .viewer:
        ViewerCanvas(store: store)
      case .overview:
        OverviewView(store: store)
      }
    }
    .background {
      InputEventMonitor(
        onKeyDown: { event in
          // Esc는 사용자 설정과 무관하게 언제나 현재 보기에서 한 단계 돌아갑니다.
          if event.keyCode == 53 {
            return store.handleEscapeKey()
          }
          // Space+드래그 모드에서는 확대 중 Space를 팬 전용으로 예약합니다.
          if event.keyCode == 49, store.canPan, store.panInteractionMode == .spacePrimaryDrag {
            return true
          }
          guard let action = shortcuts.action(matching: event) else { return false }
          store.perform(action)
          return true
        },
        onPointerPan: { input, delta in
          store.handlePanInput(input, delta: delta)
        },
        onHorizontalSwipe: { delta in
          guard store.presentationMode == .viewer else { return }
          store.navigatePage(delta < 0 ? 1 : -1)
        }
      )
    }
  }

  private var thumbnailPlacementMenu: some View {
    Menu {
      ForEach(ThumbnailPanelPlacement.quickSelectionOrder) { placement in
        Button {
          store.thumbnailPanelPlacement = placement
        } label: {
          Label(
            placement.title,
            systemImage: store.thumbnailPanelPlacement == placement
              ? "checkmark" : placement.systemImage
          )
        }
      }
    } label: {
      Image(systemName: store.thumbnailPanelPlacement.systemImage)
    }
    .help("썸네일 패널 위치")
  }

  private func showsThumbnailPanel(at placement: ThumbnailPanelPlacement) -> Bool {
    !store.isFocusMode && store.thumbnailPanelPlacement == placement
  }
}

/// SF Symbols에 없는 소문자 e를 편집 도구의 고유하고 가벼운 글리프로 사용합니다.
private struct EditingGlyph: View {
  let isActive: Bool

  var body: some View {
    Text("e")
      .font(.system(size: 14, weight: .bold, design: .rounded))
      .foregroundStyle(isActive ? Color.accentColor : .primary)
      .frame(width: 17, height: 17)
      .overlay {
        RoundedRectangle(cornerRadius: 4)
          .stroke(isActive ? Color.accentColor : Color.secondary, lineWidth: 1.25)
      }
  }
}
