import Foundation
import Testing

@testable import ImageViewer

@Suite("10개 앱 언어의 리소스와 배포 설정")
struct LocalizationCoverageTests {
  private let expectedLanguages = ["ko", "en", "ja", "zh-Hans", "vi", "es", "fr", "de", "ru", "ar"]
  private let requiredTables: Set<String> = [
    "About", "BatchActions", "BatchRename", "BatchResize", "ComparisonNames", "InfoPlist",
    "Localizable", "MapSelection", "MotionMedia", "PhotoMarkReports", "PhotoMarks",
    "Shortcuts", "Sort", "Watermark", "LibrarySearch", "MediaFormats", "MediaPlayback",
    "FileOperations", "MediaLoadFailure", "LanguageSettings", "FrameLayout", "ImageFit",
  ]

  private var projectDirectory: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var resourcesDirectory: URL {
    projectDirectory.appendingPathComponent("Sources/ImageViewer/Resources")
  }

  @Test("언어 목록과 배포 매니페스트 및 실제 번역 폴더가 일치한다")
  func declaredLanguagesMatchResources() throws {
    #expect(L10n.supportedLocalizations == expectedLanguages)
    let data = try Data(contentsOf: projectDirectory.appendingPathComponent("Packaging/Info.plist"))
    let info = try #require(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(info["CFBundleLocalizations"] as? [String] == expectedLanguages)
    #expect(info["CFBundleDevelopmentRegion"] as? String == "ko")

    let folders = try FileManager.default.contentsOfDirectory(
      at: resourcesDirectory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "lproj" }
      .map { $0.deletingPathExtension().lastPathComponent }
    #expect(Set(folders) == Set(expectedLanguages))
  }

  @Test("모든 앱 언어가 같은 표·키·서식 인수를 번들에서 읽는다", arguments: L10n.supportedLocalizations)
  func tablesAndArguments(language: String) throws {
    let directory = resourcesDirectory.appendingPathComponent("\(language).lproj")
    let availableTables = Set(try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "strings" }
      .map { $0.deletingPathExtension().lastPathComponent })
    #expect(availableTables == requiredTables)

    for table in requiredTables.sorted() {
      let reference = try readTable("\(table).strings", language: "en")
      let translated = try readTable("\(table).strings", language: language)
      #expect(!reference.isEmpty)
      #expect(Set(translated.keys) == Set(reference.keys), "\(language): \(table)")
      for key in reference.keys.sorted() {
        let referenceValue = try #require(reference[key])
        let value = try #require(translated[key], "\(language): \(table).\(key)")
        #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          "\(language): \(table).\(key)")
        #expect(try formatArguments(in: value) == formatArguments(in: referenceValue),
          "\(language): \(table).\(key)")
        #expect(L10n.text(key, localeIdentifier: language, table: table) == value,
          "\(language): \(table).\(key)")
      }
    }
  }

  @Test("macOS 지역별 선호 언어가 지원하는 앱 언어로 연결된다")
  func regionalLanguagePreferences() {
    let regionalLanguages = [
      "ko-KR": "ko", "en-GB": "en", "ja-JP": "ja", "zh-Hans-CN": "zh-Hans",
      "vi-VN": "vi", "es-MX": "es", "fr-FR": "fr", "de-DE": "de",
      "de-AT": "de", "ru-RU": "ru", "ar-SA": "ar",
    ]
    for (identifier, language) in regionalLanguages {
      #expect(Bundle.preferredLocalizations(
        from: L10n.supportedLocalizations, forPreferences: [identifier]).first == language)
    }
  }

  private func readTable(_ filename: String, language: String) throws -> [String: String] {
    let url = resourcesDirectory.appendingPathComponent("\(language).lproj/\(filename)")
    let data = try Data(contentsOf: url)
    return try #require(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
  }

  private func formatArguments(in value: String) throws -> [String] {
    // 번호를 지정한 인수의 순서는 바꿀 수 있지만 %@·%d·%lld 등의 자료형은 유지합니다.
    // 공백 플래그는 사용하지 않으므로 일반 문장의 "75% quality"는 서식으로 읽지 않습니다.
    let pattern = #"%%|%(?:([1-9]\d*)\$)?[-+#0]*(?:\d+)?(?:\.\d+)?((?:hh|ll|h|l|L|j|z|t)?[diouxXfFeEgGaAcCsSp@])"#
    let expression = try NSRegularExpression(pattern: pattern)
    let string = value as NSString
    var nextArgument = 1
    var arguments: [String] = []
    for match in expression.matches(in: value, range: NSRange(location: 0, length: string.length)) {
      guard string.substring(with: match.range) != "%%" else { continue }
      let position = match.range(at: 1)
      let index: String
      if position.location == NSNotFound {
        index = String(nextArgument)
        nextArgument += 1
      } else {
        index = string.substring(with: position)
      }
      arguments.append("\(index):\(string.substring(with: match.range(at: 2)))")
    }
    return arguments.sorted()
  }
}
