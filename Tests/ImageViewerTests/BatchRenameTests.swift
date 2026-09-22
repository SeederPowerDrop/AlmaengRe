import Foundation
import Testing

@testable import ImageViewer

@Suite("선택한 이미지 일괄 이름 변경")
struct BatchRenameTests {
  @Test("접두사·접미사·번호가 확장자 앞에 붙고 선택 순서를 따른다")
  func prefixSuffixAndNumbering() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = try file("여행.original.JPG", in: folder, contents: "first")
    let second = try file("두번째.JPG", in: folder, contents: "second")
    var options = BatchRenameOptions()
    options.prefix = "2026_"
    options.suffix = "_보정"
    options.addsNumber = true
    options.startNumber = 5
    options.numberStep = 2
    options.numberDigits = 3
    options.extensionMode = .lowercase

    let plan = BatchRenamePlanner.plan(urls: [second, first], options: options)
    #expect(plan.canApply)
    #expect(plan.changedCount == 2)
    #expect(plan.entries.map { $0.destinationURL.lastPathComponent } == [
      "2026_두번째_보정_005.jpg", "2026_여행.original_보정_007.jpg",
    ])
  }

  @Test("문자열 바꾸기는 확장자를 제외한 이름에 적용된다")
  func replaceText() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try file("jpg-photo-jpg.jpg", in: folder, contents: "image")
    var options = BatchRenameOptions()
    options.nameMode = .replaceText
    options.searchText = "jpg"
    options.replacementText = "JPEG"
    let plan = BatchRenamePlanner.plan(urls: [source], options: options)
    #expect(plan.canApply)
    #expect(plan.entries.first?.destinationURL.lastPathComponent == "JPEG-photo-JPEG.jpg")
    options.searchText = ""
    #expect(!BatchRenamePlanner.plan(urls: [source], options: options).canApply)
  }

  @Test("동일 형식 확장자 별칭과 대소문자 변경은 원본 데이터를 보존한다")
  func extensionAliasAndCaseOnly() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try file("photo.JPG", in: folder, contents: "original image bytes")
    var options = BatchRenameOptions()
    options.extensionMode = .lowercase
    let firstPlan = BatchRenamePlanner.plan(urls: [source], options: options)
    #expect(firstPlan.canApply)
    let firstResult = try await BatchRenamer().apply(firstPlan)
    let lowercase = try #require(firstResult[source])
    #expect(lowercase.lastPathComponent == "photo.jpg")
    #expect(try names(in: folder) == ["photo.jpg"])

    options.extensionMode = .custom
    options.customExtension = ".jpeg"
    let secondPlan = BatchRenamePlanner.plan(urls: [lowercase], options: options)
    #expect(secondPlan.canApply)
    let result = try await BatchRenamer().apply(secondPlan)
    let final = try #require(result[lowercase])
    #expect(final.lastPathComponent == "photo.jpeg")
    #expect(try String(contentsOf: final, encoding: .utf8) == "original image bytes")
    #expect(try names(in: folder) == ["photo.jpeg"])
  }

  @Test("다른 형식 확장자와 잘못된 확장자는 실행 전에 차단한다")
  func invalidExtensionChanges() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try file("photo.jpg", in: folder, contents: "image")
    for target in ["png", "heic", "", "../jpg", "jpg/png", "j pg", "."] {
      var options = BatchRenameOptions()
      options.extensionMode = .custom
      options.customExtension = target
      let plan = BatchRenamePlanner.plan(urls: [source], options: options)
      #expect(!plan.canApply)
      #expect(plan.entries[0].issue != nil)
    }
    #expect(BatchRenamePlanner.extensionsAreEquivalent("TIF", "tiff"))
    #expect(BatchRenamePlanner.extensionsAreEquivalent("tga", "targa"))
    #expect(!BatchRenamePlanner.extensionsAreEquivalent("heif", "avif"))
  }

  @Test("빈 이름·숨김·경로·제어 문자·긴 이름은 차단한다")
  func invalidNames() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try file("photo.jpg", in: folder, contents: "image")
    for name in ["", "   ", ".hidden", "../outside", "sub/file", "sub\\file", "bad:name", "line\nname", "null\0name", String(repeating: "한", count: 90)] {
      var options = BatchRenameOptions()
      options.nameMode = .replace
      options.newName = name
      #expect(!BatchRenamePlanner.plan(urls: [source], options: options).canApply)
    }
    #expect(try names(in: folder) == ["photo.jpg"])
  }

  @Test("중복 대상과 기존 파일은 덮어쓰지 않는다")
  func duplicateAndOccupiedTargets() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = try file("one.jpg", in: folder, contents: "one")
    let second = try file("two.jpg", in: folder, contents: "two")
    let existing = try file("occupied.jpg", in: folder, contents: "keep me")
    var options = BatchRenameOptions()
    options.nameMode = .replace
    options.newName = "duplicate"
    let duplicates = BatchRenamePlanner.plan(urls: [first, second], options: options)
    #expect(!duplicates.canApply)
    #expect(duplicates.entries.allSatisfy { $0.issue != nil })
    await #expect(throws: (any Error).self) { try await BatchRenamer().apply(duplicates) }

    options.newName = "OCCUPIED"
    let occupied = BatchRenamePlanner.plan(urls: [first], options: options)
    #expect(!occupied.canApply)
    await #expect(throws: (any Error).self) { try await BatchRenamer().apply(occupied) }
    #expect(try String(contentsOf: first, encoding: .utf8) == "one")
    #expect(try String(contentsOf: second, encoding: .utf8) == "two")
    #expect(try String(contentsOf: existing, encoding: .utf8) == "keep me")
  }

  @Test("유니코드 정규화가 다른 기존 이름도 충돌로 처리한다")
  func unicodeCollision() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try file("source.jpg", in: folder, contents: "source")
    _ = try file("Cafe\u{301}.jpg", in: folder, contents: "existing")
    var options = BatchRenameOptions()
    options.nameMode = .replace
    options.newName = "CAFÉ"
    #expect(!BatchRenamePlanner.plan(urls: [source], options: options).canApply)
  }

  @Test("번호 계산 범위 초과와 잘못된 입력은 안전하게 차단한다")
  func numberingOverflow() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let urls = try (1...3).map { try file("photo\($0).jpg", in: folder, contents: "\($0)") }
    var options = BatchRenameOptions()
    options.addsNumber = true
    options.startNumber = Int.max
    #expect(!BatchRenamePlanner.plan(urls: urls, options: options).canApply)
    options.startNumber = 0
    options.numberStep = Int.max
    #expect(!BatchRenamePlanner.plan(urls: urls, options: options).canApply)
    options.numberStep = 0
    #expect(!BatchRenamePlanner.plan(urls: urls, options: options).canApply)
    options.numberStep = 1
    options.numberDigits = 0
    #expect(!BatchRenamePlanner.plan(urls: urls, options: options).canApply)
  }

  @Test("선택한 세 파일의 이름을 순환 교환해도 각 파일 내용이 유지된다")
  func cyclicRename() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = try file("p1.jpg", in: folder, contents: "first")
    let second = try file("p2.jpg", in: folder, contents: "second")
    let third = try file("p3.jpg", in: folder, contents: "third")
    var options = BatchRenameOptions()
    options.nameMode = .replace
    options.newName = "p"
    options.addsNumber = true
    options.numberDigits = 1
    options.numberSeparator = ""
    let plan = BatchRenamePlanner.plan(urls: [second, third, first], options: options)
    #expect(plan.canApply)
    let result = try await BatchRenamer().apply(plan)
    #expect(result.count == 3)
    #expect(try String(contentsOf: first, encoding: .utf8) == "second")
    #expect(try String(contentsOf: second, encoding: .utf8) == "third")
    #expect(try String(contentsOf: third, encoding: .utf8) == "first")
    #expect(try names(in: folder) == ["p1.jpg", "p2.jpg", "p3.jpg"])
  }

  @Test("미리보기 뒤 생긴 대상 파일은 실행을 막고 그대로 보존한다")
  func lateConflict() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try file("photo.jpg", in: folder, contents: "original")
    var options = BatchRenameOptions()
    options.prefix = "new_"
    let plan = BatchRenamePlanner.plan(urls: [source], options: options)
    #expect(plan.canApply)
    let destination = try file("new_photo.jpg", in: folder, contents: "external")
    await #expect(throws: (any Error).self) { try await BatchRenamer().apply(plan) }
    #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    #expect(try String(contentsOf: destination, encoding: .utf8) == "external")
    #expect(try names(in: folder) == ["new_photo.jpg", "photo.jpg"])
  }

  @Test("미리보기 뒤 원본이 교체되면 다시 미리보기를 요구한다")
  func changedSource() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try file("photo.jpg", in: folder, contents: "original")
    var options = BatchRenameOptions()
    options.prefix = "new_"
    let plan = BatchRenamePlanner.plan(urls: [source], options: options)
    try Data("replaced".utf8).write(to: source, options: .atomic)
    await #expect(throws: (any Error).self) { try await BatchRenamer().apply(plan) }
    #expect(try String(contentsOf: source, encoding: .utf8) == "replaced")
    #expect(try names(in: folder) == ["photo.jpg"])
  }

  @Test("최종 이동 직전에 생긴 대상도 원자적으로 덮어쓰기를 막는다")
  func conflictDuringCommit() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try file("photo.jpg", in: folder, contents: "original")
    let destination = folder.appendingPathComponent("new_photo.jpg")
    var options = BatchRenameOptions()
    options.prefix = "new_"
    let plan = BatchRenamePlanner.plan(urls: [source], options: options)
    let renamer = BatchRenamer { from, to in
      if to == destination { try Data("external".utf8).write(to: destination, options: .withoutOverwriting) }
      try BatchRenamer.moveExclusively(from, to)
    }
    await #expect(throws: (any Error).self) { try await renamer.apply(plan) }
    #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    #expect(try String(contentsOf: destination, encoding: .utf8) == "external")
    #expect(try names(in: folder) == ["new_photo.jpg", "photo.jpg"])
  }

  @Test("일부 이름을 바꾼 뒤 실패해도 모든 원본 이름과 내용이 복원된다")
  func rollbackAfterPartialCommit() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = try file("first.jpg", in: folder, contents: "first bytes")
    let second = try file("second.jpg", in: folder, contents: "second bytes")
    var options = BatchRenameOptions()
    options.prefix = "new_"
    let plan = BatchRenamePlanner.plan(urls: [first, second], options: options)
    let operations = FailingMoves(failures: [4])
    let renamer = BatchRenamer(moveFile: operations.move)
    await #expect(throws: (any Error).self) { try await renamer.apply(plan) }
    #expect(try String(contentsOf: first, encoding: .utf8) == "first bytes")
    #expect(try String(contentsOf: second, encoding: .utf8) == "second bytes")
    #expect(try names(in: folder) == ["first.jpg", "second.jpg"])
  }

  @Test("복원까지 실패하면 임시 파일을 보존하고 복구 위치를 알려준다")
  func incompleteRollbackPreservesData() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = try file("first.jpg", in: folder, contents: "first bytes")
    let second = try file("second.jpg", in: folder, contents: "second bytes")
    var options = BatchRenameOptions()
    options.prefix = "new_"
    let plan = BatchRenamePlanner.plan(urls: [first, second], options: options)
    let operations = FailingMoves(failures: [4, 6])
    let renamer = BatchRenamer(moveFile: operations.move)
    do {
      _ = try await renamer.apply(plan)
      Issue.record("Expected rollback failure")
    } catch BatchRenameError.rollbackIncomplete(_, let locations) {
      #expect(locations.contains(".imageviewer-rename-"))
      #expect(locations.contains(first.path))
    }
    let preserved = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
      .compactMap { $0 as? URL }
      .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    #expect(Set(preserved) == Set(["first bytes", "second bytes"]))
    #expect(try String(contentsOf: second, encoding: .utf8) == "second bytes")
  }

  @Test("디렉터리와 심볼릭 링크는 원본 파일로 취급하지 않는다")
  func rejectsNonRegularFiles() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try file("photo.jpg", in: folder, contents: "original")
    let link = folder.appendingPathComponent("link.jpg")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    let directory = folder.appendingPathComponent("directory.jpg")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    var options = BatchRenameOptions()
    options.prefix = "new_"
    #expect(!BatchRenamePlanner.plan(urls: [link], options: options).canApply)
    #expect(!BatchRenamePlanner.plan(urls: [directory], options: options).canApply)
  }

  private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("imageviewer-rename-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
  }

  private func file(_ name: String, in folder: URL, contents: String) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
    return url
  }

  private func names(in folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
  }
}

/// Deterministic I/O failures exercise rollback without depending on volume permissions.
private final class FailingMoves: @unchecked Sendable {
  private let lock = NSLock()
  private let failures: Set<Int>
  private var count = 0

  init(failures: Set<Int>) { self.failures = failures }

  func move(_ source: URL, _ destination: URL) throws {
    lock.lock()
    count += 1
    let shouldFail = failures.contains(count)
    lock.unlock()
    if shouldFail { throw CocoaError(.fileWriteNoPermission) }
    try BatchRenamer.moveExclusively(source, destination)
  }
}
