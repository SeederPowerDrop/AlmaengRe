import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

@Suite("다중 이미지 형식 변환")
struct BatchImageExporterTests {
  @Test("PNG와 JPEG로 실제 변환하며 원본 바이트를 보존한다", arguments: [ExportFormat.png, .jpeg])
  func convertsImages(format: ExportFormat) async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sources = ["first.qoi", "second.qoi"].map { directory.appendingPathComponent($0) }
    let original = makeImageData()
    for source in sources { try original.write(to: source) }

    let items = try BatchImageExporter.plan(urls: sources, destinationFolder: directory, format: format)
    let result = await BatchImageExporter(pipeline: ImagePipeline()).export(
      items: items, format: format, quality: 0.9, adjustments: [:], progress: { _, _ in }
    )

    #expect(result.completed.count == 2)
    #expect(result.failures.isEmpty)
    #expect(!result.wasCancelled)
    for item in result.completed {
      #expect(try Data(contentsOf: item.sourceURL) == original)
      let output = try #require(CGImageSourceCreateWithURL(item.destinationURL as CFURL, nil))
      #expect(CGImageSourceGetType(output) as String? == format.typeIdentifier)
      let decoded = try #require(CGImageSourceCreateImageAtIndex(output, 0, nil))
      #expect(decoded.width == 2)
      #expect(decoded.height == 1)
    }
    #expect(try temporaryFiles(in: directory).isEmpty)
  }

  @Test("동일 형식 원본과 대소문자·유니코드·출력끼리 겹치는 이름을 피한다")
  func plansUniqueNames() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let originals = directory.appendingPathComponent("originals", isDirectory: true)
    try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: false)
    let existing = directory.appendingPathComponent("PHOTO.png")
    try Data([1]).write(to: existing)
    try Data([2]).write(to: directory.appendingPathComponent("Café.png"))
    let sources = [
      existing,
      originals.appendingPathComponent("photo.qoi"),
      originals.appendingPathComponent("Cafe\u{301}.qoi"),
      originals.appendingPathComponent("CAFE\u{301}.jpeg"),
    ]

    let plan = try BatchImageExporter.plan(urls: sources, destinationFolder: directory, format: .png)
    #expect(plan.map(\.destinationURL.lastPathComponent) == [
      "PHOTO-2.png", "photo-3.png", "Cafe\u{301}-2.png", "CAFE\u{301}-3.png",
    ])
    #expect(try Data(contentsOf: existing) == Data([1]))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 3)
  }

  @Test("미리보기 이후 생긴 출력 파일을 덮어쓰지 않고 다음 파일을 계속 변환한다")
  func rejectsNewDestinationConflict() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sources = ["first.qoi", "second.qoi"].map { directory.appendingPathComponent($0) }
    let original = makeImageData()
    for source in sources { try original.write(to: source) }
    let items = try BatchImageExporter.plan(urls: sources, destinationFolder: directory, format: .png)
    let concurrentContents = Data("Created after preview".utf8)
    try concurrentContents.write(to: items[0].destinationURL)

    let result = await BatchImageExporter(pipeline: ImagePipeline()).export(
      items: items, format: .png, quality: 1, adjustments: [:], progress: { _, _ in }
    )

    #expect(result.completed.map(\.sourceURL) == [sources[1]])
    #expect(result.failures.map(\.sourceURL) == [sources[0]])
    #expect(!result.wasCancelled)
    #expect(try Data(contentsOf: items[0].destinationURL) == concurrentContents)
    for source in sources { #expect(try Data(contentsOf: source) == original) }
    #expect(try temporaryFiles(in: directory).isEmpty)
  }

  @Test("잘못된 확장자와 원본 경로로 직접 요청해도 파일을 바꾸지 않는다")
  func rejectsUnsafeItems() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("original.png")
    let original = Data("Original file contents".utf8)
    try original.write(to: source)
    let wrongExtension = directory.appendingPathComponent("wrong.jpg")
    let items = [
      BatchExportItem(sourceURL: source, destinationURL: source),
      BatchExportItem(sourceURL: source, destinationURL: wrongExtension),
    ]

    let result = await BatchImageExporter(pipeline: ImagePipeline()).export(
      items: items, format: .png, quality: 1, adjustments: [:], progress: { _, _ in }
    )

    #expect(result.completed.isEmpty)
    #expect(result.failures.count == 2)
    #expect(try Data(contentsOf: source) == original)
    #expect(!FileManager.default.fileExists(atPath: wrongExtension.path))
    #expect(try temporaryFiles(in: directory).isEmpty)
  }

  @Test("한 장 변환 뒤 취소하면 완성된 파일만 남기고 나머지 원본을 보존한다")
  func cancelsBetweenFiles() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sources = ["first.qoi", "second.qoi", "third.qoi"].map { directory.appendingPathComponent($0) }
    let original = makeImageData()
    for source in sources { try original.write(to: source) }
    let items = try BatchImageExporter.plan(urls: sources, destinationFolder: directory, format: .png)
    let task = Task {
      await BatchImageExporter(pipeline: ImagePipeline()).export(
        items: items, format: .png, quality: 1, adjustments: [:],
        progress: { processed, _ in
          if processed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        }
      )
    }
    let result = await task.value

    #expect(result.wasCancelled)
    #expect(result.completed.map(\.sourceURL) == [sources[0]])
    #expect(result.failures.isEmpty)
    #expect(FileManager.default.fileExists(atPath: items[0].destinationURL.path))
    #expect(!FileManager.default.fileExists(atPath: items[1].destinationURL.path))
    #expect(!FileManager.default.fileExists(atPath: items[2].destinationURL.path))
    for source in sources { #expect(try Data(contentsOf: source) == original) }
    #expect(try temporaryFiles(in: directory).isEmpty)
  }

  @Test("해독 실패 시 임시 파일을 지우고 정상 이미지는 계속 변환한다")
  func continuesAfterDecodingFailure() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let broken = directory.appendingPathComponent("broken.qoi")
    let valid = directory.appendingPathComponent("valid.qoi")
    let corruptContents = Data([0, 1, 2])
    try corruptContents.write(to: broken)
    try makeImageData().write(to: valid)
    let items = try BatchImageExporter.plan(urls: [broken, valid], destinationFolder: directory, format: .png)

    let result = await BatchImageExporter(pipeline: ImagePipeline()).export(
      items: items, format: .png, quality: 1, adjustments: [:], progress: { _, _ in }
    )

    #expect(result.completed.map(\.sourceURL) == [valid])
    #expect(result.failures.map(\.sourceURL) == [broken])
    #expect(!result.wasCancelled)
    #expect(try Data(contentsOf: broken) == corruptContents)
    #expect(!FileManager.default.fileExists(atPath: items[0].destinationURL.path))
    #expect(try temporaryFiles(in: directory).isEmpty)
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imageviewer-batch-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
  }

  private func temporaryFiles(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix(".imageviewer-convert-") }
  }

  private func makeImageData() -> Data {
    // 독립된 2×1 QOI 픽스처: 불투명한 빨강 픽셀 두 개입니다.
    Data([
      0x71, 0x6F, 0x69, 0x66,
      0, 0, 0, 2, 0, 0, 0, 1, 4, 0,
      0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xC0,
      0, 0, 0, 0, 0, 0, 0, 1,
    ])
  }
}
