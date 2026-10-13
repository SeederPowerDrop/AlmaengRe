import Darwin
import Foundation
import Testing

@testable import ImageViewer

@Suite("선택 파일 원본 복사·이동·휴지통")
struct BatchFileOperationTests {
  @Test("원본 복사는 파일명·내용·수정일을 보존하고 같은 폴더에서는 사본을 만든다")
  func copiesOriginalBytesAndMetadata() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.file("Original.RAW", contents: "original binary bytes")
    let date = Date(timeIntervalSince1970: 1_600_000_000)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
    let plan = try BatchFileOperationPlanner.plan(assets: [asset(source)], operation: .copy,
      destinationFolder: fixture.destination)
    let result = await BatchFileOperator().execute(plan)
    let copied = try #require(result.completed.first?.destinationURL)
    #expect(copied.lastPathComponent == "Original.RAW")
    #expect(try Data(contentsOf: copied) == Data(contentsOf: source))
    #expect(try copied.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == date)
    #expect(result.failures.isEmpty)
    let duplicatePlan = try BatchFileOperationPlanner.plan(assets: [asset(source)], operation: .copy,
      destinationFolder: fixture.source)
    let duplicate = await BatchFileOperator().execute(duplicatePlan)
    #expect(duplicate.completed.first?.destinationURL?.lastPathComponent == "Original (2).RAW")
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  @Test("동일 이름과 정규화·대소문자 충돌을 번호로 구분하고 기존 파일을 보존한다")
  func plansNumberedConflicts() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.file("Café.JPG", contents: "first")
    let nested = fixture.source.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
    let second = try fixture.file("Café.JPG", in: nested, contents: "second")
    let existing = try fixture.file("CAFE\u{301}.jpg", in: fixture.destination, contents: "existing")
    let plan = try BatchFileOperationPlanner.plan(assets: [asset(source), asset(second)], operation: .copy,
      destinationFolder: fixture.destination)
    #expect(plan.entries.map { $0.destinationURL?.lastPathComponent } == ["Café (2).JPG", "Café (3).JPG"])
    let result = await BatchFileOperator().execute(plan)
    #expect(result.completed.count == 2)
    #expect(try String(contentsOf: existing, encoding: .utf8) == "existing")
    #expect(try String(contentsOf: #require(result.completed[0].destinationURL), encoding: .utf8) == "first")
    #expect(try String(contentsOf: #require(result.completed[1].destinationURL), encoding: .utf8) == "second")
  }

  @Test("계획 이후 생긴 대상은 덮어쓰지 않고 실행 결과에 실제 사본 경로를 돌려준다")
  func handlesLateCopyConflict() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.file("photo.png")
    let plan = try BatchFileOperationPlanner.plan(assets: [asset(source)], operation: .copy,
      destinationFolder: fixture.destination)
    let occupied = try fixture.file("photo.png", in: fixture.destination, contents: "late arrival")
    let result = await BatchFileOperator().execute(plan)
    #expect(result.completed.first?.destinationURL?.lastPathComponent == "photo (2).png")
    #expect(try String(contentsOf: occupied, encoding: .utf8) == "late arrival")
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  @Test("이동 시스템 호출 직전 생긴 파일도 덮어쓰지 않고 다른 이름으로 이동한다")
  func handlesAtomicMoveConflict() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.file("photo.png", contents: "original")
    let plan = try BatchFileOperationPlanner.plan(assets: [asset(source)], operation: .move,
      destinationFolder: fixture.destination)
    let expected = fixture.destination.appendingPathComponent("photo.png")
    let worker = BatchFileOperator(moveFile: { from, to in
      if to == expected { try Data("external".utf8).write(to: to, options: .withoutOverwriting) }
      try BatchFileOperator.moveExclusively(from, to)
    })
    let result = await worker.execute(plan)
    #expect(result.completed.first?.destinationURL?.lastPathComponent == "photo (2).png")
    #expect(try String(contentsOf: expected, encoding: .utf8) == "external")
    #expect(try String(contentsOf: #require(result.completed.first?.destinationURL), encoding: .utf8) == "original")
    #expect(!FileManager.default.fileExists(atPath: source.path))
  }

  @Test("변경·삭제된 원본은 건너뛰고 성공·실패를 파일별로 돌려준다")
  func partialFailureForChangedAndMissingSources() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let changed = try fixture.file("changed.png")
    let missing = try fixture.file("missing.png")
    let valid = try fixture.file("valid.png")
    let plan = try BatchFileOperationPlanner.plan(assets: [changed, missing, valid].map(asset), operation: .move,
      destinationFolder: fixture.destination)
    try Data("replacement".utf8).write(to: changed, options: .atomic)
    try FileManager.default.removeItem(at: missing)
    let result = await BatchFileOperator().execute(plan)
    #expect(result.completed.map(\.sourceURL) == [valid])
    #expect(result.failures.map(\.sourceURL) == [changed, missing])
    #expect(try String(contentsOf: changed, encoding: .utf8) == "replacement")
    #expect(!FileManager.default.fileExists(atPath: valid.path))
    #expect(!result.wasCancelled)
  }

  @Test("심볼릭 링크·폴더·같은 폴더 이동·빈 선택은 계획을 거부한다")
  func invalidPlans() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.file("photo.png")
    let link = fixture.source.appendingPathComponent("link.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    for url in [link, fixture.source] {
      #expect(throws: (any Error).self) {
        try BatchFileOperationPlanner.plan(assets: [asset(url)], operation: .trash)
      }
    }
    #expect(throws: (any Error).self) {
      try BatchFileOperationPlanner.plan(assets: [asset(source)], operation: .move,
        destinationFolder: fixture.source)
    }
    #expect(throws: (any Error).self) {
      try BatchFileOperationPlanner.plan(assets: [], operation: .trash)
    }
    #expect(throws: (any Error).self) {
      try BatchFileOperationPlanner.plan(assets: [asset(source)], operation: .copy)
    }
    #expect(throws: (any Error).self) {
      try BatchFileOperationPlanner.plan(assets: [asset(source)], operation: .copy,
        destinationFolder: link)
    }
  }

  @Test("압축 항목은 논리 파일명으로 복사하며 이동·휴지통을 거부한다")
  func archiveEntriesAreCopyOnly() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.file("extracted-cache.png")
    var archived = asset(source)
    archived.archiveOrigin = ArchiveImageOrigin(archiveURL: fixture.root.appendingPathComponent("album.zip"),
      entryPath: "folder/Original Image.png")
    for operation in [BatchFileOperation.move, .trash] {
      #expect(throws: (any Error).self) {
        try BatchFileOperationPlanner.plan(assets: [archived], operation: operation,
          destinationFolder: fixture.destination)
      }
    }
    let plan = try BatchFileOperationPlanner.plan(assets: [archived], operation: .copy,
      destinationFolder: fixture.destination)
    let result = await BatchFileOperator().execute(plan)
    #expect(result.completed.first?.destinationURL?.lastPathComponent == "Original Image.png")
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  @Test("휴지통 의존성을 주입해 성공과 실패를 확인하며 영구 삭제로 우회하지 않는다")
  func trashSuccessAndFailureWithoutPermanentDeletion() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let first = try fixture.file("first.png")
    let second = try fixture.file("second.png")
    let plan = try BatchFileOperationPlanner.plan(assets: [asset(first), asset(second)], operation: .trash)
    let worker = BatchFileOperator(trashFile: { source in
      if source == second { throw CocoaError(.fileWriteNoPermission) }
      let target = fixture.destination.appendingPathComponent(source.lastPathComponent)
      try BatchFileOperator.moveExclusively(source, target)
      return target
    })
    let result = await worker.execute(plan)
    #expect(result.completed.map(\.sourceURL) == [first])
    #expect(result.failures.map(\.sourceURL) == [second])
    #expect(FileManager.default.fileExists(atPath: second.path))
    let trashed = try #require(result.completed.first?.destinationURL)
    #expect(FileManager.default.fileExists(atPath: trashed.path))
    #expect(!FileManager.default.fileExists(atPath: first.path))
  }

  @Test("취소 이후 남은 원본은 건드리지 않고 이미 끝난 항목은 결과에 남긴다")
  func cancellationPreservesRemainingFiles() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let first = try fixture.file("first.png")
    let second = try fixture.file("second.png")
    let plan = try BatchFileOperationPlanner.plan(assets: [asset(first), asset(second)], operation: .move,
      destinationFolder: fixture.destination)
    let task = Task {
      await BatchFileOperator().execute(plan) { finished, _ in
        if finished == 1 { withUnsafeCurrentTask { $0?.cancel() } }
      }
    }
    let result = await task.value
    #expect(result.wasCancelled)
    #expect(result.completed.map(\.sourceURL) == [first])
    #expect(result.failures.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(FileManager.default.fileExists(atPath: second.path))
  }

  @Test("다른 볼륨 이동에서 복사가 실패하면 원본과 기존 대상이 보존된다")
  func crossVolumeCopyFailurePreservesSource() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.file("photo.png", contents: "original")
    let existing = try fixture.file("photo.png", in: fixture.destination, contents: "existing")
    let plan = try BatchFileOperationPlanner.plan(assets: [asset(source)], operation: .move,
      destinationFolder: fixture.destination)
    let worker = BatchFileOperator(moveFile: { _, target in
      throw BatchFileOperationPlanner.posixError(target, code: EXDEV)
    }, copyFile: { _, target in
      try Data("partial copy".utf8).write(to: target, options: .withoutOverwriting)
      throw CocoaError(.fileWriteOutOfSpace)
    })
    let result = await worker.execute(plan)
    #expect(result.completed.isEmpty)
    #expect(result.failures.count == 1)
    #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    #expect(try String(contentsOf: existing, encoding: .utf8) == "existing")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path) == ["photo.png"])
  }

  @Test("다른 볼륨 이동은 사본 완성 뒤 원본을 지운다")
  func crossVolumeMoveCompletes() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.file("photo.png", contents: "original")
    let plan = try BatchFileOperationPlanner.plan(assets: [asset(source)], operation: .move,
      destinationFolder: fixture.destination)
    let worker = BatchFileOperator(moveFile: { _, target in
      throw BatchFileOperationPlanner.posixError(target, code: EXDEV)
    })
    let result = await worker.execute(plan)
    #expect(result.failures.isEmpty)
    #expect(try String(contentsOf: #require(result.completed.first?.destinationURL), encoding: .utf8) == "original")
    #expect(!FileManager.default.fileExists(atPath: source.path))
  }

  @Test("복사 중 바뀐 원본은 대상에 게시하지 않고 원본을 보존한다")
  func sourceChangeDuringCopy() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.file("photo.png")
    let plan = try BatchFileOperationPlanner.plan(assets: [asset(source)], operation: .move,
      destinationFolder: fixture.destination)
    let worker = BatchFileOperator(moveFile: { _, target in
      throw BatchFileOperationPlanner.posixError(target, code: EXDEV)
    }, copyFile: { from, to in
      try BatchFileOperator.copyExclusively(from, to)
      try Data("new source".utf8).write(to: from, options: .atomic)
    })
    let result = await worker.execute(plan)
    #expect(result.completed.isEmpty)
    #expect(result.failures.count == 1)
    #expect(try String(contentsOf: source, encoding: .utf8) == "new source")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
  }

  @Test("선택 후 바뀐 대상 폴더에는 파일을 쓰지 않는다")
  func destinationReplacementIsRejected() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.file("photo.png")
    let plan = try BatchFileOperationPlanner.plan(assets: [asset(source)], operation: .copy,
      destinationFolder: fixture.destination)
    let oldDestination = fixture.root.appendingPathComponent("old-destination")
    try FileManager.default.moveItem(at: fixture.destination, to: oldDestination)
    try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
    let result = await BatchFileOperator().execute(plan)
    #expect(result.completed.isEmpty)
    #expect(result.failures.count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  @Test("중복 선택은 한 번만 처리한다")
  func deduplicatesSelection() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.file("photo.png")
    let plan = try BatchFileOperationPlanner.plan(assets: [asset(source), asset(source)], operation: .trash)
    #expect(plan.entries.count == 1)
  }

  @Test("파일을 선택한 뒤 계획을 만들기 전에 교체되면 다른 파일을 처리하지 않는다")
  func replacementBeforePlanningIsRejected() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.file("photo.png")
    var selected = asset(source)
    selected.photoMarkIdentity = try #require(PhotoMarkFileIdentity.read(source)?.key)
    _ = try BatchFileOperationPlanner.plan(assets: [selected], operation: .trash)
    try Data("replacement before preview".utf8).write(to: source, options: .atomic)
    #expect(throws: (any Error).self) {
      try BatchFileOperationPlanner.plan(assets: [selected], operation: .trash)
    }
    #expect(try String(contentsOf: source, encoding: .utf8) == "replacement before preview")
  }

  @Test("취소된 미리보기 계획은 즉시 종료한다")
  func cancelledPlanning() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = try fixture.file("photo.png")
    let selected = asset(source)
    let cancelled = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        _ = try BatchFileOperationPlanner.plan(assets: [selected], operation: .trash)
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }.value
    #expect(cancelled)
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  private func asset(_ url: URL) -> ImageAsset {
    ImageAsset(url: url, byteCount: nil, modificationDate: nil)
  }

  private struct Fixture: Sendable {
    let root: URL
    let source: URL
    let destination: URL

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("almaeng-file-tests-\(UUID().uuidString)",
        isDirectory: true)
      source = root.appendingPathComponent("Source", isDirectory: true)
      destination = root.appendingPathComponent("Destination", isDirectory: true)
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    }

    func file(_ name: String, in folder: URL? = nil, contents: String = "fixture bytes") throws -> URL {
      let url = (folder ?? source).appendingPathComponent(name)
      try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
      return url
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
  }
}
