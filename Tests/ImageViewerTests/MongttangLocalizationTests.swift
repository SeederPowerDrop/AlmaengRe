import Foundation
import Testing

@testable import ImageViewer

@Suite("몽땅보기 다국어와 설정 호환성")
struct MongttangLocalizationTests {
  @Test("8개 언어의 모드·전환·돌아가기 문구가 같은 이름을 사용한다")
  func localizedModeLabels() {
    let translations: [(String, [String])] = [
      ("ko", ["몽땅보기", "몽땅보기 전환", "몽땅보기로 돌아가기 (Esc)"]),
      ("en", ["All at Once", "Toggle All at Once", "Return to All at Once (Esc)"]),
      ("zh-Hans", ["一览无余", "切换一览无余", "返回一览无余 (Esc)"]),
      ("ja", ["まとめて見る", "「まとめて見る」に切り替え", "「まとめて見る」に戻る (Esc)"]),
      (
        "fr", ["Tout voir", "Activer/désactiver « Tout voir »", "Revenir à « Tout voir » (Échap.)"]
      ),
      (
        "es",
        ["Todo a la vista", "Alternar « Todo a la vista »", "Volver a « Todo a la vista » (Esc)"]
      ),
      ("ar", ["عرض الكل", "تبديل عرض الكل", "العودة إلى عرض الكل (Esc)"]),
      ("vi", ["Xem tất cả", "Bật/tắt Xem tất cả", "Trở lại Xem tất cả (Esc)"]),
    ]
    let keys = ["몽땅보기", "몽땅보기 전환", "몽땅보기로 돌아가기 (Esc)"]
    let oldKeys = ["전체 보기", "전체 보기 전환", "전체 보기로 돌아가기 (Esc)"]
    #expect(Set(translations.map { $0.0 }) == Set(L10n.supportedLocalizations))
    for (locale, expectedValues) in translations {
      let resourceKeys = L10n.keys(localeIdentifier: locale)
      for (key, expected) in zip(keys, expectedValues) {
        #expect(resourceKeys.contains(key))
        #expect(L10n.text(key, localeIdentifier: locale) == expected)
      }
      for oldKey in oldKeys { #expect(!resourceKeys.contains(oldKey)) }
    }
  }

  @Test("이름이 바뀌어도 모드·사용자 단축키·썸네일 크기는 유지한다")
  @MainActor
  func legacyPreferencesRemainUsable() throws {
    let suite = "ImageViewer.MongttangTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // 이전 버전에서 저장한 키를 그대로 읽어 사용자 재설정을 요구하지 않습니다.
    let customBinding = KeyBinding(key: "j", modifiers: [.command, .shift])
    defaults.set(
      try JSONEncoder().encode(["toggleOverview": customBinding]),
      forKey: "ImageViewer.ShortcutBindings.v1"
    )
    defaults.set(240.5, forKey: "ImageViewer.OverviewThumbnailSize.v1")
    let shortcuts = ShortcutStore(defaults: defaults)
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)

    #expect(PresentationMode.overview.rawValue == "overview")
    #expect(ShortcutAction.toggleOverview.rawValue == "toggleOverview")
    #expect(ShortcutAction.toggleOverview.defaultBinding == KeyBinding(key: "g"))
    #expect(shortcuts.binding(for: .toggleOverview) == customBinding)
    #expect(store.thumbnailSize == 240.5)
    #expect(PresentationMode.overview.title == L10n.text("몽땅보기"))
    #expect(ShortcutAction.toggleOverview.title == L10n.text("몽땅보기 전환"))
    store.perform(.toggleOverview)
    #expect(store.presentationMode == .overview)
    store.perform(.toggleOverview)
    #expect(store.presentationMode == .viewer)
    store.returnToOverview()
    #expect(store.presentationMode == .overview)
    #expect(store.thumbnailSize == 240.5)
  }
}
