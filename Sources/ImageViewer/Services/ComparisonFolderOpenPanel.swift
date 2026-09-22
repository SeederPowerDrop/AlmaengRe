import AppKit

/// A와 B를 각각 고르므로 서로 다른 위치에 있는 폴더도 비교할 수 있습니다.
@MainActor
enum ComparisonFolderOpenPanel {
  static func make(for side: FolderComparisonSide, directoryURL: URL? = nil) -> NSOpenPanel {
    let panel = NSOpenPanel()
    panel.title = L10n.text(side == .first ? "A 폴더 선택 (1/2)" : "B 폴더 선택 (2/2)")
    panel.message = L10n.text(side == .first
      ? "첫 번째로 비교할 폴더를 연 뒤 ‘이 폴더 선택’을 누르세요."
      : "두 번째로 비교할 폴더를 연 뒤 ‘이 폴더 선택’을 누르세요.")
    panel.prompt = L10n.text("이 폴더 선택")
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = directoryURL
    return panel
  }

  static func choose(for side: FolderComparisonSide, directoryURL: URL?) -> URL? {
    let panel = make(for: side, directoryURL: directoryURL)
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }
}
