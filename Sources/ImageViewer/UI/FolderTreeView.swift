import AppKit
import SwiftUI

/// 폴더 목록과 사진 목록을 같은 탐색 열에서 사용합니다. 펼치기는 탐색만,
/// 이름 선택은 현재 뷰어(비교 중에는 선택한 A/B 칸)의 폴더를 바꿉니다.
struct FolderTreeView: View {
  @ObservedObject var store: AppStore
  @ObservedObject var comparison: FolderComparisonStore
  @ObservedObject var tree: FolderTreeStore

  private var selectedFolder: URL? {
    let folder = store.presentationMode == .folderComparison
      ? comparison.pane(comparison.activeSide).folderURL
      : store.currentFolderURL ?? store.currentAsset?.archiveOrigin?.archiveURL.deletingLastPathComponent()
        ?? store.currentAsset?.url.deletingLastPathComponent()
    return folder?.standardizedFileURL
  }

  private var locked: Bool {
    store.presentationMode == .folderComparison && comparison.pane(comparison.activeSide).isLocked
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if !store.favoriteFolders.isEmpty {
        favorites
        Divider()
      }
      ScrollViewReader { proxy in
        GeometryReader { viewport in
          ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 2) {
              ForEach(tree.rows) { row in
                folderRow(row).id(row.id)
              }
            }
            .padding(.vertical, 6)
            .frame(width: max(240, CGFloat(tree.rows.map(\.depth).max() ?? 0) * 14 + 170), alignment: .topLeading)
            // 양축 스크롤의 짧은 목록도 화면 높이를 채워 위쪽에 고정합니다.
            .frame(minHeight: viewport.size.height, alignment: .topLeading)
          }
          .defaultScrollAnchor(.topLeading)
          .task(id: selectedFolder) {
            await tree.reveal(selectedFolder)
            guard !Task.isCancelled, let selectedFolder else { return }
            await Task.yield()
            proxy.scrollTo(selectedFolder, anchor: .topLeading)
          }
        }
      }
      Divider()
      Text(L10n.text(locked ? "잠긴 칸은 폴더를 바꿀 수 없습니다."
        : "폴더 이름을 누르면 해당 폴더의 사진을 엽니다."))
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
    .background(ViewerTheme.sidebar)
  }

  private var header: some View {
    VStack(spacing: 9) {
      HStack {
        Label("폴더 트리", systemImage: "list.bullet.indent")
          .font(.system(size: 12, weight: .semibold))
        Spacer(minLength: 4)
        if let folder = selectedFolder ?? tree.rootURL {
          Button { store.toggleFavoriteFolder(folder) } label: {
            Image(systemName: store.isFavoriteFolder(folder) ? "pin.fill" : "pin")
          }
          .buttonStyle(.plain)
          .foregroundStyle(store.isFavoriteFolder(folder) ? ViewerTheme.accent : Color.secondary)
          .help(store.isFavoriteFolder(folder) ? "즐겨찾는 폴더에서 해제" : "즐겨찾는 폴더에 고정")
          .accessibilityLabel(store.isFavoriteFolder(folder) ? "즐겨찾는 폴더에서 해제" : "즐겨찾는 폴더에 고정")
        }
        Button { store.showsFolderTree = false } label: {
          Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("폴더 트리 닫기")
        .accessibilityLabel("폴더 트리 닫기")
      }
      HStack(spacing: 4) {
        Button { chooseRoot() } label: {
          HStack(spacing: 6) {
            Image(systemName: "folder.badge.plus")
            Text(tree.rootURL.map { folderName($0) } ?? L10n.text("폴더 열기"))
              .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
          }
        }
        .buttonStyle(ViewerToolButtonStyle())
        .help("탐색할 폴더 선택…")
        .accessibilityLabel("탐색할 폴더 선택…")
        Button { Task { await tree.showParent() } } label: {
          Image(systemName: "arrow.up")
        }
        .buttonStyle(ViewerToolButtonStyle())
        .disabled(!tree.canShowParent)
        .help("상위 폴더 보기")
        .accessibilityLabel("상위 폴더 보기")
        Button { Task { await tree.refresh() } } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(ViewerToolButtonStyle())
        .help("폴더 트리 새로고침")
        .accessibilityLabel("폴더 트리 새로고침")
      }
      if store.presentationMode == .folderComparison {
        Picker("보기", selection: $comparison.activeSide) {
          Text(verbatim: "A").tag(FolderComparisonSide.first)
          Text(verbatim: "B").tag(FolderComparisonSide.second)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 11)
  }

  private var favorites: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("즐겨찾는 폴더")
        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 12)
      ScrollView {
        VStack(spacing: 2) {
          ForEach(store.favoriteFolders) { favorite in
            HStack(spacing: 6) {
              Button { store.openFavoriteFolder(favorite) } label: {
                HStack(spacing: 7) {
                  Image(systemName: "folder.fill").foregroundStyle(ViewerTheme.accent)
                  Text(verbatim: favorite.name).lineLimit(1).truncationMode(.middle)
                  Spacer(minLength: 0)
                }
                .frame(height: 27).contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .disabled(!store.canOpenFolderFromTree)
              Button { store.removeFavoriteFolder(favorite.id) } label: {
                Image(systemName: "pin.slash").foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
              .help("즐겨찾는 폴더에서 해제")
              .accessibilityLabel("즐겨찾는 폴더에서 해제")
            }
            .padding(.horizontal, 12)
            .help(favorite.location.url.path)
          }
        }
      }
      .frame(height: min(145, CGFloat(store.favoriteFolders.count) * 29))
    }
    .font(.system(size: 12))
    .padding(.vertical, 8)
  }

  private func folderRow(_ row: FolderTreeRow) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 2) {
        Button { Task { await tree.toggleExpansion(row.url) } } label: {
          Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .opacity(row.canExpand ? 1 : 0)
            .frame(width: 20, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.canExpand)
        .accessibilityLabel(L10n.text(row.isExpanded ? "폴더 접기" : "폴더 펼치기"))
        .accessibilityValue(folderName(row.url))
        Button { store.openFolderFromTree(row.url) } label: {
          HStack(spacing: 7) {
            Image(systemName: selectedFolder == row.url ? "folder.fill" : "folder")
              .foregroundStyle(selectedFolder == row.url ? ViewerTheme.accent : Color.secondary)
            Text(verbatim: folderName(row.url))
              .font(.system(size: 12, weight: selectedFolder == row.url ? .semibold : .regular))
              .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if row.isLoading { ProgressView().controlSize(.mini) }
          }
          .frame(height: 28)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!store.canOpenFolderFromTree)
        .accessibilityLabel(folderName(row.url))
        .accessibilityHint("이 폴더 열기")
        .accessibilityAddTraits(selectedFolder == row.url ? .isSelected : [])
      }
      .padding(.leading, CGFloat(row.depth) * 14 + 6)
      .padding(.trailing, 10)
      .background(selectedFolder == row.url ? ViewerTheme.selection : Color.clear,
        in: RoundedRectangle(cornerRadius: 5))
      .help(row.url.path)
      .contextMenu {
        Button(store.isFavoriteFolder(row.url) ? "즐겨찾는 폴더에서 해제" : "즐겨찾는 폴더에 고정") {
          store.toggleFavoriteFolder(row.url)
        }
      }
      if let error = row.errorMessage {
        Label("폴더를 읽을 수 없습니다.", systemImage: "exclamationmark.circle")
          .font(.system(size: 10)).foregroundStyle(.secondary)
          .padding(.leading, CGFloat(row.depth) * 14 + 28)
          .help(error)
      } else if row.isExpanded && !row.isLoading && !row.canExpand {
        Text("하위 폴더 없음")
          .font(.system(size: 10)).foregroundStyle(.tertiary)
          .padding(.leading, CGFloat(row.depth) * 14 + 28)
      }
    }
    .padding(.horizontal, 4)
  }

  private func folderName(_ url: URL) -> String {
    url.path == "/" ? "/" : url.lastPathComponent
  }

  private func chooseRoot() {
    let panel = NSOpenPanel()
    panel.title = L10n.text("탐색할 폴더 선택…")
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = tree.rootURL
    if panel.runModal() == .OK, let folder = panel.url {
      Task { await tree.setRoot(folder) }
    }
  }
}
