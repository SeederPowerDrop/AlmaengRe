import AppKit
import Foundation
import Testing

@testable import ImageViewer

@Suite("이미지 맞춤 메뉴의 다국어 문구")
struct ImageFitLocalizationTests {
  private let expectedKeys: Set<String> = [
    "menu.image", "menu.frame", "menu.help", "menu.frameHelp",
    "whole.title", "whole.help", "frame.wholeHelp",
    "width.title", "width.help", "height.title", "height.help",
    "center.title", "center.help", "actual.title", "actual.help",
  ]

  @Test("10개 언어에서 모든 맞춤 항목과 설명을 실제 리소스로 제공한다",
    arguments: L10n.supportedLocalizations)
  func resourcesAndHelpAreComplete(language: String) throws {
    let values = try readTable(language: language)
    #expect(Set(values.keys) == expectedKeys)
    for key in expectedKeys {
      let value = try #require(values[key])
      #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      #expect(ImageFitL10n.text(key, language: language) == value)
      // This table has no format arguments. The numeric ratio is literal text.
      #expect(!value.contains("%"), "Unexpected format argument: \(language): \(key)")
    }
    let actionTitles = ["whole.title", "width.title", "height.title", "center.title", "actual.title"]
      .map { ImageFitL10n.text($0, language: language) }
    #expect(Set(actionTitles).count == actionTitles.count)
    #expect(ImageFitL10n.text("menu.image", language: language)
      != ImageFitL10n.text("menu.frame", language: language))
  }

  @Test("가로·세로 채우기는 서로 다른 명확한 이름과 설명으로 연결된다")
  func scaleModesUsePlainLanguageActions() {
    let expected: [(mode: BaseScaleMode, title: String, help: String)] = [
      (.fit, "전체 이미지 보기", "비율을 유지하면서 이미지 전체가 보이도록 맞춥니다."),
      (.fitWidth, "좌우 여백 채우기", "비율을 유지해 좌우에 맞춥니다. 이미지의 위아래가 잘릴 수 있습니다."),
      (.fitHeight, "상하 여백 채우기", "비율을 유지해 위아래에 맞춥니다. 이미지의 좌우가 잘릴 수 있습니다."),
      (.actualPixels, "실제 크기 (1:1)", "이미지 1픽셀을 화면 1픽셀에 맞춥니다."),
    ]
    for item in expected {
      #expect(ImageFitL10n.title(for: item.mode, language: "ko") == item.title)
      #expect(ImageFitL10n.help(for: item.mode, language: "ko") == item.help)
    }
    #expect(ImageFitL10n.text("center.title", language: "ko") == "가운데로 이동")
    #expect(ImageFitL10n.text("center.help", language: "ko")
      == "확대 비율을 바꾸지 않고 이미지를 가운데로 옮깁니다.")
  }

  @Test("긴 번역의 메뉴 이름과 항목이 한 줄에 들어간다",
    arguments: L10n.supportedLocalizations)
  @MainActor
  func translatedTitlesRemainCompact(language: String) {
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    for key in ["menu.image", "menu.frame", "whole.title", "width.title", "height.title",
      "center.title", "actual.title"] {
      let value = ImageFitL10n.text(key, language: language)
      #expect(!value.contains("\n") && !value.contains("\r"))
      let width = (value as NSString).size(withAttributes: [.font: font]).width
      // Include space for a checkmark and the trailing menu affordance. The
      // whole menu still fits beside a sidebar in the minimum-size window.
      let available: CGFloat = key.hasPrefix("menu.") ? 240 : 340
      #expect(width + 48 < available, "\(language): \(key): \(width)")
    }
  }

  @Test("아랍어에서도 실제 크기의 1:1 표기는 왼쪽에서 오른쪽으로 유지한다")
  func actualSizeRatioUsesIsolatedLTRTextInArabic() {
    let arabic = ImageFitL10n.text("actual.title", language: "ar")
    #expect(arabic.contains("\u{2066}(1:1)\u{2069}"))
    for language in L10n.supportedLocalizations {
      let title = ImageFitL10n.title(for: .actualPixels, language: language)
      #expect(title.components(separatedBy: "1:1").count == 2)
      #expect(title.filter { $0 == "\u{2066}" }.count == title.filter { $0 == "\u{2069}" }.count)
    }
  }

  private func readTable(language: String) throws -> [String: String] {
    let project = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = project.appendingPathComponent("Sources/ImageViewer/Resources/\(language).lproj/ImageFit.strings")
    return try #require(PropertyListSerialization.propertyList(
      from: Data(contentsOf: url), format: nil) as? [String: String])
  }
}
