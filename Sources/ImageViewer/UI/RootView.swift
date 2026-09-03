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
        HStack(spacing: 0) {
          if store.showsSidebar && !store.isFocusMode {
            SidebarView(store: store)
            Divider()
          }

          Group {
            switch store.presentationMode {
            case .viewer:
              ViewerCanvas(store: store)
            case .overview:
              OverviewView(store: store)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)

          if store.showsInspector && !store.isFocusMode {
            Divider()
            InspectorView(store: store)
          }
        }
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
    .background {
      InputEventMonitor(
        onKeyDown: { event in
          guard let action = shortcuts.action(matching: event) else { return false }
          store.perform(action)
          return true
        },
        onHorizontalSwipe: { delta in
          guard store.presentationMode == .viewer else { return }
          store.navigatePage(delta < 0 ? 1 : -1)
        }
      )
      .frame(width: 0, height: 0)
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
              Text("\(count)장").tag(count)
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
        .help(store.prefersHDR ? "HDR 출력 켜짐" : "HDR 출력 꺼짐")

        Button {
          store.showsSidebar.toggle()
        } label: {
          Image(systemName: "sidebar.left")
        }
        .help("썸네일 사이드바")

        Button {
          store.showsInspector.toggle()
        } label: {
          Image(systemName: "sidebar.right")
        }
        .help("이미지 조정 및 내보내기")

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
}
