import SwiftUI

struct LibraryControlsView: View {
  @ObservedObject var store: AppStore

  var body: some View {
    HStack(spacing: 12) {
      LibraryQueryControls(query: $store.libraryQuery, isWorking: store.isFiltering,
        availableExtensions: store.allAssets.map(\.fileExtension))
        .disabled(store.isBatchBusy || store.batchSheet != nil || store.isSavingMetadata || store.isExporting)
      if store.presentationMode == .map && store.libraryQuery.geographicSelection != nil {
        Button { store.libraryQuery.geographicSelection = nil } label: {
          Label("지도 영역 해제", systemImage: "map.fill")
        }
        .buttonStyle(ViewerActionButtonStyle())
        .help("위치 필터를 해제하고 폴더의 사진을 다시 표시합니다.")
        .disabled(store.isBatchBusy || store.isSavingMetadata || store.isExporting)
      }
      PhotoMarkFilterMenu(store: store, marks: store.photoMarks)
        .disabled(!store.photoMarks.isReady || store.isBatchBusy || store.isLoading)
      Toggle(isOn: $store.showsVideos) {
        Label(MotionMediaL10n.text("showVideos"), systemImage: "film")
      }
      .toggleStyle(.button)
      .fixedSize()
      .help(MotionMediaL10n.text("showVideos.help"))
      .disabled(!store.canOpenFolderFromTree)
      Spacer(minLength: 0)
      if !store.allAssets.isEmpty {
        Text(L10n.format("%d / %d개", store.assets.count, store.allAssets.count))
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(ViewerTheme.controlFill.opacity(0.65), in: Capsule())
          .fixedSize()
          .accessibilityLabel("검색 결과 수")
      }
    }
  }
}

/// Keep the geographic scope visible even with hidden chrome or an empty result.
struct MapSelectionScopeView: View {
  @ObservedObject var store: AppStore

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 16) {
        summary
        Spacer(minLength: 8)
        actions
      }
      VStack(alignment: .leading, spacing: 8) {
        summary
        actions
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(ViewerTheme.accent.opacity(0.14))
    .overlay(alignment: .leading) {
      Rectangle().fill(ViewerTheme.accent).frame(width: 3)
        .allowsHitTesting(false)
    }
  }

  private var summary: some View {
    HStack(spacing: 10) {
      Image(systemName: "map.fill")
        .font(.system(size: 21, weight: .medium))
        .foregroundStyle(ViewerTheme.accent)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(MapSelectionL10n.text("지도에서 선택한 사진만 보는 중"))
          .font(.system(size: 12, weight: .semibold))
        HStack(spacing: 6) {
          Text(MapSelectionL10n.format("영역 %lld개 · 표시 %lld장",
            Int64(store.libraryQuery.geographicSelection?.areas.count ?? 0),
            Int64(store.assets.count)))
            .monospacedDigit()
          if store.isFiltering { ProgressView().controlSize(.mini) }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }

  private var actions: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        returnToMapButton
        clearMapSelectionButton
      }
      .fixedSize(horizontal: true, vertical: false)
      VStack(alignment: .leading, spacing: 8) {
        returnToMapButton
        clearMapSelectionButton
      }
    }
    .buttonStyle(ViewerActionButtonStyle())
    .disabled(store.isBatchBusy || store.batchSheet != nil || store.isSavingMetadata || store.isExporting)
  }

  private var returnToMapButton: some View {
    Button { store.presentationMode = .map } label: {
      Label(MapSelectionL10n.text("지도로 돌아가기"), systemImage: "arrow.uturn.backward")
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityIdentifier("mapScope.return")
  }

  private var clearMapSelectionButton: some View {
    Button { store.libraryQuery.geographicSelection = nil } label: {
      Label("지도 영역 해제", systemImage: "xmark.circle")
        .fixedSize(horizontal: false, vertical: true)
    }
    .help("위치 필터를 해제하고 폴더의 사진을 다시 표시합니다.")
    .accessibilityIdentifier("mapScope.clear")
  }
}

/// Shared controls for the normal collection and the A/B comparison collection.
struct LibraryQueryControls: View {
  @Binding var query: LibraryQuery
  var isWorking = false
  var availableExtensions: [String] = []
  @FocusState private var isSearchFocused: Bool
  @State private var showsAdvancedSearch = false

  var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 5) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(isSearchFocused ? ViewerTheme.accent : Color.secondary)
          .font(.system(size: 11, weight: .medium))
        TextField("파일 이름 검색", text: $query.searchText)
          .textFieldStyle(.plain)
          .focused($isSearchFocused)
          .help(LibrarySearchL10n.text("wildcard.hint"))
          .accessibilityIdentifier("librarySearch.filename")
          .frame(minWidth: 100, idealWidth: 160, maxWidth: 240)
        if !query.searchText.isEmpty {
          Button { query.searchText = "" } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help("검색 지우기")
          .accessibilityLabel("검색 지우기")
        }
      }
      .padding(.horizontal, 10).padding(.vertical, 7)
      .background(ViewerTheme.panel, in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(isSearchFocused ? ViewerTheme.selectionBorder : ViewerTheme.separator,
            lineWidth: isSearchFocused ? 1.25 : 0.75)
          .allowsHitTesting(false)
      }
      Menu {
        ForEach(Array(LibrarySort.groupedCases.enumerated()), id: \.offset) { _, group in
          Menu(group.title) {
            Picker(group.title, selection: $query.sort) {
              ForEach(group.sorts) { Text($0.title).tag($0) }
            }
          }
        }
      } label: {
        Label("정렬", systemImage: "arrow.up.arrow.down")
      }
      .fixedSize()
      .help(query.sort.title)
      LibraryFormatMenu(query: $query, availableExtensions: availableExtensions)
      Button {
        showsAdvancedSearch = true
      } label: {
        Label(LibrarySearchL10n.text("advanced.title"),
          systemImage: query.searchFilters.isActive ? "slider.horizontal.3" : "line.3.horizontal.decrease")
      }
      .fixedSize()
      .foregroundStyle(query.searchFilters.isActive ? ViewerTheme.accent : Color.primary)
      .help(LibrarySearchL10n.text("advanced.hint"))
      .accessibilityIdentifier("librarySearch.advanced")
      .popover(isPresented: $showsAdvancedSearch, arrowEdge: .bottom) {
        LibraryAdvancedSearchView(filters: $query.searchFilters)
      }
      if isWorking { ProgressView().controlSize(.mini) }
    }
    .controlSize(.small)
  }
}
