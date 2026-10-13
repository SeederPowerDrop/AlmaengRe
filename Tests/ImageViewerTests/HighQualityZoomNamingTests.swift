import Foundation
import Testing

@testable import ImageViewer

@Suite("고화질 확대 명칭과 이전 설정 호환")
struct HighQualityZoomNamingTests {
  @Test("10개 언어의 메뉴·비교·설정에 고화질 확대 이름을 사용한다")
  func namesAreLocalized() {
    let titles = ["ko": "고화질 확대", "en": "High-Quality Zoom", "zh-Hans": "高画质缩放",
      "ja": "高画質拡大", "fr": "Zoom haute qualité", "es": "Ampliación de alta calidad",
      "ar": "تكبير عالي الجودة", "vi": "Phóng to chất lượng cao",
      "de": "Hochwertiger Zoom", "ru": "Качественное увеличение"]
    for locale in L10n.supportedLocalizations {
      #expect(L10n.text("고화질 확대", localeIdentifier: locale) == titles[locale])
      let keys = L10n.keys(localeIdentifier: locale)
      for key in ["고화질 확대 켜기/끄기", "고화질 확대 및 비교",
        "기본 확대 · 픽셀 그대로", "고화질 확대 · 부드럽게"] {
        #expect(keys.contains(key))
        #expect(!L10n.text(key, localeIdentifier: locale).contains("AA"))
      }
      for oldKey in ["안티앨리어싱 확대", "안티앨리어싱 확대 및 비교",
        "AA 끔 · 원본 픽셀", "AA 켬 · 부드러운 확대", "부드럽게 (안티앨리어싱)"] {
        #expect(!keys.contains(oldKey))
      }
    }
  }

  @Test("표시 이름만 바꾸고 저장된 확대 모드와 사용자 단축키를 유지한다")
  @MainActor
  func legacyPreferences() async throws {
    let suite = "ImageViewer.HighQualityZoomNaming.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let customKey = KeyBinding(key: "h", modifiers: [.control, .option])
    defaults.set("pixelated", forKey: "ImageViewer.ImageInterpolationMode.v1")
    defaults.set(try JSONEncoder().encode(["toggleAntialiasing": customKey]),
      forKey: "ImageViewer.ShortcutBindings.v1")
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("zoom-naming-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let photo = folder.appendingPathComponent("synthetic.qoi")
    try Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
      0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]).write(to: photo)
    store.open(urls: [photo])
    let deadline = ContinuousClock.now + .seconds(5)
    while (store.isLoading || store.isFiltering), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!store.isLoading && !store.isFiltering && store.assets.count == 1)
    try #require(!store.showsHome && store.presentationMode == .viewer)
    let shortcuts = ShortcutStore(defaults: defaults)
    #expect(!store.isAntialiasingEnabled)
    #expect(shortcuts.binding(for: .toggleAntialiasing) == customKey)
    #expect(ShortcutAction.toggleAntialiasing.title == L10n.text("고화질 확대 켜기/끄기"))
    store.perform(.toggleAntialiasing)
    #expect(store.isAntialiasingEnabled)
    #expect(store.imageInterpolationMode.title == L10n.text("고화질 확대"))
    #expect(defaults.string(forKey: "ImageViewer.ImageInterpolationMode.v1") == "smooth")
  }
}
