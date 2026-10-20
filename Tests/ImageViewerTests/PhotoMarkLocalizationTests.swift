import Foundation
import Testing

@testable import ImageViewer

@Suite("사진 분류 다국어")
struct PhotoMarkLocalizationTests {
  @Test("10개 언어가 동일한 분류 문구를 제공한다")
  func resourcesCoverEverySupportedLanguage() {
    let expectedKeys = PhotoMarkL10n.keys(localeIdentifier: "ko")
    let essentialKeys: Set<String> = [
      "panel.title", "panel.hint", "panel.multipleHint", "panel.close",
      "panel.viewerGridHint", "panel.viewerSelectionHint", "panel.viewerSelectionHelp",
      "labels.title", "labels.hint", "labels.safety", "labels.keyFormat",
      "filter.title", "filter.activeFormat", "filter.any", "filter.all", "filter.unmarked",
      "filter.unmarkedTitle", "filter.reset", "filter.empty",
      "filter.scope", "filter.conditions", "filter.includeCountFormat", "filter.excludeCountFormat",
      "filter.includeHelp", "filter.excludeHelp", "filter.included", "filter.excluded",
      "filter.ignored", "filter.includeRule", "filter.includeSummaryFormat", "filter.excludeSummaryFormat",
      "mode.help", "storage.error", "error.title",
      "settings.title", "settings.hint", "labels.settingsLink", "labels.editHelp",
      "labels.keyHelpFormat", "labels.previewFormat", "labels.revertHelp", "mode.detailHelp",
      "mark.addHelpFormat", "mark.removeHelpFormat",
      "colors.title", "colors.keyFormat", "colors.help",
      "color.red", "color.orange", "color.yellow", "color.green", "color.teal",
      "color.blue", "color.indigo", "color.purple", "color.pink", "color.gray",
      "comparison.open", "comparison.openHelp", "comparison.filter", "comparison.allPhotos",
      "comparison.titleFormat", "comparison.selectionHelp", "comparison.empty",
      "comparison.emptyHelp", "comparison.reset",
    ]
    #expect(essentialKeys.isSubset(of: expectedKeys))
    for locale in L10n.supportedLocalizations {
      #expect(PhotoMarkL10n.keys(localeIdentifier: locale) == expectedKeys)
      for key in expectedKeys {
        let value = PhotoMarkL10n.text(key, localeIdentifier: locale)
        #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(value != key)
      }
    }
  }

  @Test("접근성 이름과 개수 표시의 형식 인수가 언어마다 일치한다")
  func formatArgumentsRemainCompatible() {
    let placeholders = [
      "panel.viewerGridHint": "%@",
      "panel.viewerSelectionHint": "%@",
      "panel.viewerSelectionHelp": "%@",
      "labels.keyFormat": "%@",
      "labels.keyHelpFormat": "%@",
      "colors.keyFormat": "%@",
      "filter.activeFormat": "%d",
      "filter.includeCountFormat": "%d", "filter.excludeCountFormat": "%d",
      "filter.includeSummaryFormat": "%@", "filter.excludeSummaryFormat": "%@",
      "badge.moreFormat": "%d",
      "badge.accessibilityFormat": "%@",
      "comparison.titleFormat": "%@",
    ]
    for locale in L10n.supportedLocalizations {
      for (key, placeholder) in placeholders {
        let value = PhotoMarkL10n.text(key, localeIdentifier: locale)
        #expect(value.components(separatedBy: placeholder).count == 2)
        #expect(value.replacingOccurrences(of: placeholder, with: "").contains("%") == false)
      }
      for key in ["labels.previewFormat", "mark.addHelpFormat", "mark.removeHelpFormat"] {
        let value = PhotoMarkL10n.text(key, localeIdentifier: locale)
        #expect(value.components(separatedBy: "%@").count == 3)
        #expect(value.replacingOccurrences(of: "%@", with: "").contains("%") == false)
      }
    }
  }

  @Test("12개 키의 기본 이름이 빠지거나 서로 겹치지 않는다")
  func allDefaultLabelsAreDistinct() {
    let keys = ["one", "two", "three", "four", "q", "w", "e", "r", "a", "s", "d", "f"]
    for locale in L10n.supportedLocalizations {
      let names = keys.map { PhotoMarkL10n.text("default.\($0)", localeIdentifier: locale) }
      #expect(Set(names).count == keys.count)
      #expect(names.allSatisfy { !$0.hasPrefix("default.") && !$0.isEmpty })
    }
  }
}
