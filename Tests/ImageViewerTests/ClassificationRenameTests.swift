import Foundation
import Testing

@testable import ImageViewer

@Suite("분류 이름으로 파일 일괄 변경")
struct ClassificationRenameTests {
  @Test("고른 분류의 선택 파일만 목록 순서로 번호를 붙이고 다른 분류는 섞지 않는다")
  func chosenClassificationAndSelectionScope() async throws {
    let fixture = try Fixture(count: 4)
    defer { fixture.remove() }
    let classifications = BatchRenameClassifications(
      labels: [.one: "업로드", .two: "인쇄"],
      marksByURL: [fixture.urls[0]: [.one, .two], fixture.urls[1]: [.two],
        fixture.urls[2]: [.one], fixture.urls[3]: [.one]])
    var options = classificationOptions()
    // Old manual fields must never leak into the classification naming rule.
    options.prefix = "unused_"
    options.suffix = "_unused"
    options.addsNumber = true
    options.startNumber = -1
    options.numberStep = 0
    options.numberDigits = 0
    options.numberSeparator = "___"
    let plan = BatchRenamePlanner.plan(
      urls: [fixture.urls[2], fixture.urls[1], fixture.urls[0]],
      options: options, classifications: classifications)
    try #require(plan.canApply)
    #expect(plan.entries.map(\.sourceURL) == [fixture.urls[2], fixture.urls[0]].map(\.standardizedFileURL))
    #expect(plan.entries.map(\.destinationURL.lastPathComponent) == ["업로드01.jpg", "업로드02.jpg"])
    let mapping = try await BatchRenamer().apply(plan)
    #expect(mapping.count == 2)
    #expect(try String(contentsOf: fixture.folder.appendingPathComponent("업로드01.jpg"), encoding: .utf8) == "2")
    #expect(try String(contentsOf: fixture.folder.appendingPathComponent("업로드02.jpg"), encoding: .utf8) == "0")
    #expect(try String(contentsOf: fixture.urls[1], encoding: .utf8) == "1")
    #expect(try String(contentsOf: fixture.urls[3], encoding: .utf8) == "3")
  }

  @Test("기본 두 자리에서 대상 100개는 세 자리, 1000개는 네 자리로 늘어난다")
  func automaticWidthUsesMatchingCount() throws {
    let fixture = try Fixture(count: 1_001)
    defer { fixture.remove() }
    for (count, first, last) in [(1, "01", "01"), (99, "01", "99"),
      (100, "001", "100"), (101, "001", "101"), (1_000, "0001", "1000")] {
      let classifications = BatchRenameClassifications(
        labels: [.one: "업로드"],
        marksByURL: Dictionary(uniqueKeysWithValues: fixture.urls.prefix(count).map { ($0, Set([PhotoMarkSlot.one])) }))
      let plan = BatchRenamePlanner.plan(urls: fixture.urls, options: classificationOptions(), classifications: classifications)
      #expect(plan.canApply)
      #expect(plan.entries.count == count)
      #expect(plan.entries.first?.destinationURL.lastPathComponent == "업로드\(first).jpg")
      #expect(plan.entries.last?.destinationURL.lastPathComponent == "업로드\(last).jpg")
    }
    #expect(BatchRenameOptions().numberDigits == 2)
  }

  @Test("분류 선택·정보·이름·해당 파일이 없으면 이유를 알리고 실행을 막는다")
  func invalidClassificationContext() async throws {
    let fixture = try Fixture(count: 1)
    defer { fixture.remove() }
    let source = fixture.urls[0]
    var options = classificationOptions()
    let marks = [source: Set([PhotoMarkSlot.one])]
    let valid = BatchRenameClassifications(labels: [.one: "업로드"], marksByURL: marks)
    options.classificationSlot = nil
    let missingSlot = BatchRenamePlanner.plan(urls: fixture.urls, options: options, classifications: valid)
    options.classificationSlot = .one
    let missingContext = BatchRenamePlanner.plan(urls: fixture.urls, options: options)
    let missingName = BatchRenamePlanner.plan(urls: fixture.urls, options: options,
      classifications: BatchRenameClassifications(labels: [:], marksByURL: marks))
    let blankName = BatchRenamePlanner.plan(urls: fixture.urls, options: options,
      classifications: BatchRenameClassifications(labels: [.one: " \n "], marksByURL: marks))
    let noMatches = BatchRenamePlanner.plan(urls: fixture.urls, options: options,
      classifications: BatchRenameClassifications(labels: [.one: "업로드"], marksByURL: [source: [.two]]))
    for plan in [missingSlot, missingContext, missingName, blankName, noMatches] {
      #expect(!plan.canApply)
      #expect(plan.issue?.isEmpty == false)
      await #expect(throws: (any Error).self) { try await BatchRenamer().apply(plan) }
    }
    #expect(try String(contentsOf: source, encoding: .utf8) == "0")
  }

  @Test("분류 이름의 경로 문자와 기존 파일 충돌은 덮어쓰기 없이 차단한다")
  func unsafeLabelsAndCollisions() async throws {
    let fixture = try Fixture(count: 1)
    defer { fixture.remove() }
    let source = fixture.urls[0]
    for label in ["../outside", "folder/name", "bad:name", ".hidden", String(repeating: "한", count: 90)] {
      let plan = BatchRenamePlanner.plan(urls: fixture.urls, options: classificationOptions(),
        classifications: BatchRenameClassifications(labels: [.one: label], marksByURL: [source: [.one]]))
      #expect(!plan.canApply)
    }
    let existing = fixture.folder.appendingPathComponent("업로드01.jpg")
    try Data("keep".utf8).write(to: existing)
    let plan = BatchRenamePlanner.plan(urls: fixture.urls, options: classificationOptions(),
      classifications: BatchRenameClassifications(labels: [.one: "업로드"], marksByURL: [source: [.one]]))
    #expect(!plan.canApply)
    await #expect(throws: (any Error).self) { try await BatchRenamer().apply(plan) }
    #expect(try String(contentsOf: existing, encoding: .utf8) == "keep")
    #expect(try String(contentsOf: source, encoding: .utf8) == "0")
  }

  @Test("분류 이름 변경 미리보기 이후 파일이 교체되면 실행하지 않는다")
  func sourceReplacementAfterPreview() async throws {
    let fixture = try Fixture(count: 1)
    defer { fixture.remove() }
    let source = fixture.urls[0]
    let plan = BatchRenamePlanner.plan(urls: fixture.urls, options: classificationOptions(),
      classifications: BatchRenameClassifications(labels: [.one: "업로드"], marksByURL: [source: [.one]]))
    try #require(plan.canApply)
    try Data("replacement".utf8).write(to: source, options: .atomic)
    await #expect(throws: (any Error).self) { try await BatchRenamer().apply(plan) }
    #expect(try String(contentsOf: source, encoding: .utf8) == "replacement")
    #expect(!FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("업로드01.jpg").path))
  }

  @Test("열 언어에서 분류 이름 변경 문구와 서식 인자를 빠짐없이 제공한다")
  func localizations() {
    let keys = BatchRenameL10n.keys(localeIdentifier: "ko")
    #expect(keys.count == 11)
    for locale in L10n.supportedLocalizations {
      #expect(BatchRenameL10n.keys(localeIdentifier: locale) == keys)
      for key in keys {
        let text = BatchRenameL10n.text(key, localeIdentifier: locale)
        #expect(!text.isEmpty && text != key)
      }
      let scope = BatchRenameL10n.text("classification.scope", localeIdentifier: locale)
      #expect(scope.components(separatedBy: "%d").count == 3)
      #expect(!scope.replacingOccurrences(of: "%d", with: "").contains("%"))
      let option = BatchRenameL10n.text("classification.option", localeIdentifier: locale)
      #expect(option.components(separatedBy: "%@").count == 3)
      #expect(option.components(separatedBy: "%d").count == 2)
      #expect(!option.replacingOccurrences(of: "%@", with: "").replacingOccurrences(of: "%d", with: "").contains("%"))
      let help = BatchRenameL10n.text("numbering.help", localeIdentifier: locale)
      #expect(help.components(separatedBy: "%@").count == 2)
      #expect(!help.replacingOccurrences(of: "%@", with: "").contains("%"))
    }
  }

  private func classificationOptions() -> BatchRenameOptions {
    var options = BatchRenameOptions()
    options.nameMode = .classification
    options.classificationSlot = .one
    return options
  }

  private struct Fixture {
    let folder: URL
    let urls: [URL]

    init(count: Int) throws {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("classification-rename-\(UUID())", isDirectory: true)
      self.folder = folder
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
      urls = try (0..<count).map { index in
        let url = folder.appendingPathComponent("photo-\(index).jpg")
        try Data("\(index)".utf8).write(to: url, options: .withoutOverwriting)
        return url
      }
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }
  }
}
