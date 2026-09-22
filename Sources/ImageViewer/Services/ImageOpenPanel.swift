import AppKit
import UniformTypeIdentifiers

/// 모든 열기 진입점은 파일과 폴더를 함께 고르는 같은 대화상자를 사용합니다.
@MainActor
enum ImageOpenPanel {
  static func make() -> NSOpenPanel {
    let panel = NSOpenPanel()
    panel.title = L10n.text("열기")
    panel.prompt = L10n.text("열기")
    panel.message = L10n.text("이미지 또는 폴더를 선택하세요.")
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    // QOI/PCX처럼 등록되지 않은 코덱도 선택하고, 폴더 자체도 열 수 있습니다.
    panel.allowedContentTypes = [.image, .data, .folder]
    return panel
  }
}
