import Foundation
import Testing

@testable import ImageViewer

@Suite("알맹Re 브랜드와 업데이트 호환성")
struct AppBrandingTests {
  // 테스트 소스 위치에서 프로젝트의 실제 배포 설정을 찾아 검사합니다.
  private var projectDirectory: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  @Test("앱 이름만 바꾸고 기존 번들 식별자와 실행 파일을 보존한다")
  func bundleIdentityIsStable() throws {
    let info = try readPropertyList(
      at: projectDirectory.appendingPathComponent("Packaging/Info.plist"))
    #expect(info["CFBundleDisplayName"] as? String == "알맹Re")
    #expect(info["CFBundleName"] as? String == "알맹Re")
    #expect(info["CFBundleIdentifier"] as? String == "org.openimageviewer.ImageViewer")
    #expect(info["CFBundleExecutable"] as? String == "ImageViewer")
    #expect((info["CFBundleDocumentTypes"] as? [[String: Any]])?.isEmpty == false)
  }

  @Test("8개 언어의 Finder 이름과 파일 연결 안내에 새 이름을 사용한다")
  func localizedBranding() throws {
    for locale in L10n.supportedLocalizations {
      let folder = projectDirectory.appendingPathComponent(
        "Sources/ImageViewer/Resources/\(locale).lproj")
      let info = try readPropertyList(at: folder.appendingPathComponent("InfoPlist.strings"))
      #expect(info["CFBundleDisplayName"] as? String == "알맹Re")
      #expect(info["CFBundleName"] as? String == "알맹Re")
      let strings = try readPropertyList(at: folder.appendingPathComponent("Localizable.strings"))
      #expect(strings["알맹Re"] as? String == "알맹Re")
      #expect(strings["이미지뷰어"] == nil)
      let messageKeys = [
        "선택한 파일 형식만 알맹Re로 열리도록 macOS 기본 앱을 변경합니다. 필요한 경우 macOS가 확인 창을 표시합니다.",
        "기본 앱 연결은 배포된 알맹Re.app을 실행했을 때 사용할 수 있습니다.",
        "선택한 %d개 이미지 형식을 알맹Re에 연결했습니다.",
      ]
      for key in messageKeys {
        let value = try #require(strings[key] as? String)
        #expect(value.contains("알맹Re"))
        if key.contains("%d") { #expect(value.contains("%d")) }
      }
    }
  }

  private func readPropertyList(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try #require(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
  }
}
