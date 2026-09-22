import Foundation
import Testing

@testable import ImageViewer

@Suite("이미지 로딩 설정")
@MainActor
struct LoadingSettingsTests {
  private let modeKey = "ImageViewer.ImageLoadingMode.v1"

  @Test("설정이 없거나 알 수 없는 모드이면 쾌적 모드로 시작한다")
  func conservativeDefault() throws {
    let suite = "ImageViewer.LoadingSettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(AppStore(defaults: defaults, monitorsSystemResources: false).imageLoadingMode == .comfortable)
    defaults.set("unknown-future-mode", forKey: modeKey)
    #expect(AppStore(defaults: defaults, monitorsSystemResources: false).imageLoadingMode == .comfortable)
  }

  @Test("자원 사용 설정은 네 모드 모두 다시 열 때 복원된다")
  func restoresSavedPreference() throws {
    let suite = "ImageViewer.LoadingSettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)

    for mode in ImageLoadingMode.allCases {
      store.imageLoadingMode = mode
      #expect(defaults.string(forKey: modeKey) == mode.rawValue)
      let reopened = AppStore(defaults: defaults, monitorsSystemResources: false)
      #expect(reopened.imageLoadingMode == mode)
    }
  }
}
