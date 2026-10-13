import Foundation
import Testing

@testable import ImageViewer

@Suite("분류 상속 설정")
@MainActor
struct PhotoMarkPreferencesTests {
  @Test("복사와 내보내기는 기본적으로 분류를 상속하지 않는다")
  func defaultsDoNotInheritTags() throws {
    let suite = "ImageViewer.PhotoMarkPreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let preferences = PhotoMarkPreferences(defaults: defaults)
    #expect(!preferences.inheritOnCopy)
    #expect(!preferences.inheritOnExport)
  }

  @Test("복사·내보내기 설정은 독립적으로 즉시 저장되고 재실행 시 복원된다")
  func preferencesPersistIndependently() throws {
    let suite = "ImageViewer.PhotoMarkPreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let preferences = PhotoMarkPreferences(defaults: defaults)
    preferences.inheritOnCopy = true
    let copyOnly = PhotoMarkPreferences(defaults: defaults)
    #expect(copyOnly.inheritOnCopy)
    #expect(!copyOnly.inheritOnExport)

    preferences.inheritOnCopy = false
    preferences.inheritOnExport = true
    let exportOnly = PhotoMarkPreferences(defaults: defaults)
    #expect(!exportOnly.inheritOnCopy)
    #expect(exportOnly.inheritOnExport)

    preferences.inheritOnExport = false
    let disabled = PhotoMarkPreferences(defaults: defaults)
    #expect(!disabled.inheritOnCopy)
    #expect(!disabled.inheritOnExport)
  }
}
