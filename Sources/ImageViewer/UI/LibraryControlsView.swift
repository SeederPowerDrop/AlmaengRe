import SwiftUI

struct LibraryControlsView: View {
  @ObservedObject var store: AppStore

  var body: some View {
    HStack(spacing: 12) {
      LibraryQueryControls(query: $store.libraryQuery, isWorking: store.isFiltering)
        .disabled(store.isBatchBusy || store.batchSheet != nil || store.isSavingMetadata || store.isExporting)
      Spacer(minLength: 0)
      if !store.allAssets.isEmpty {
        Text(L10n.format("%d / %d개", store.assets.count, store.allAssets.count))
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(.secondary)
          .fixedSize()
          .accessibilityLabel("검색 결과 수")
      }
    }
  }
}

/// Shared controls for the normal collection and the A/B comparison collection.
struct LibraryQueryControls: View {
  @Binding var query: LibraryQuery
  var isWorking = false

  var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 5) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("파일 이름 검색", text: $query.searchText)
          .textFieldStyle(.plain)
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
      .padding(.horizontal, 8).padding(.vertical, 5)
      .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
      Menu {
        Picker("정렬", selection: $query.sort) {
          ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
        }
      } label: {
        Label("정렬", systemImage: "arrow.up.arrow.down")
      }
      .fixedSize()
      .help(query.sort.title)
      Menu {
        Button("모든 형식") { query.formats = [] }
        Divider()
        ForEach(ImageFormatFilter.allCases) { format in
          Toggle(format.title, isOn: Binding(
            get: { query.formats.contains(format) },
            set: { enabled in
              if enabled { query.formats.insert(format) }
              else { query.formats.remove(format) }
            }))
        }
      } label: {
        Label(query.formats.isEmpty ? L10n.text("형식")
          : L10n.format("형식 %d", query.formats.count), systemImage: "line.3.horizontal.decrease.circle")
      }
      .fixedSize()
      .help("이미지 형식 필터")
      if isWorking { ProgressView().controlSize(.mini) }
    }
    .controlSize(.small)
  }
}
