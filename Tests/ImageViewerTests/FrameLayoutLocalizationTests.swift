import AppKit
import Foundation
import Testing

@testable import ImageViewer

@Suite("프레임 배치 메뉴의 다국어 문구")
struct FrameLayoutLocalizationTests {
  @Test("배치 메뉴와 접근성 안내에 모든 지원 언어의 번역이 있다",
    arguments: L10n.supportedLocalizations)
  func localizedFrameControls(language: String) {
    let keys = [
      "title", "preset.balanced", "preset.horizontal", "preset.vertical",
      "columns", "columns.count", "edit", "reset", "editing.help", "done",
      "move.help", "move.accessibility", "swap.with", "resize.columns", "resize.rows", "equalize",
    ]
    for key in keys {
      let text = FrameLayoutL10n.text(key, language: language)
      #expect(!text.isEmpty && text != key, "Missing \(language): \(key)")
    }
    for key in ["columns.count", "move.accessibility", "swap.with"] {
      let text = FrameLayoutL10n.text(key, language: language)
      let formatted = String(format: text, locale: Locale(identifier: "en_US"), 4)
      #expect(formatted.contains("4"))
      #expect(!formatted.contains("%"))
    }
  }

  @Test("긴 번역의 메뉴 항목과 완료 버튼이 한 줄에 들어간다",
    arguments: L10n.supportedLocalizations)
  @MainActor
  func translatedLabelsRemainCompact(language: String) {
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    for key in ["title", "preset.balanced", "preset.horizontal", "preset.vertical",
      "columns", "edit", "reset", "equalize", "done"] {
      let text = FrameLayoutL10n.text(key, language: language)
      #expect(!text.contains("\n"))
      let width = (text as NSString).size(withAttributes: [.font: font]).width
      // The compact toolbar uses only the symbol; expanded controls and native
      // menus must still remain readable within the minimum window width.
      #expect(width + 52 < 340, "\(language): \(key): \(width)")
    }
  }
}
