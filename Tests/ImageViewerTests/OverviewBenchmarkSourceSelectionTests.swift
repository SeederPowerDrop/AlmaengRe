import CryptoKit
import Foundation
import Testing

@testable import ImageViewer

@Suite("릴리스 측정의 원래 파일 목록 고정")
struct OverviewBenchmarkSourceSelectionTests {
  private func urls() -> [URL] {
    ["first.dng", "second.heic", "notes.txt"].map {
      URL(fileURLWithPath: "/private/diagnostic-source/\($0)")
    }
  }

  private func inventory(_ urls: [URL], fileCount: Int? = nil,
    hashes: [String]? = nil) throws -> Data {
    let records = (hashes ?? urls.map {
      SHA256.hash(data: Data($0.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }).sorted().map { ["pathSHA256": $0] }
    let canonical = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
    let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    return try JSONSerialization.data(withJSONObject: ["fileCount": fileCount ?? records.count,
      "sha256": digest, "files": records], options: [.sortedKeys])
  }

  @Test("추가된 파일은 제외하고 원래 파일만 경로 해시로 선택한다")
  func excludesAdditionsWithoutChangingOriginalMembership() throws {
    let original = urls()
    let added = URL(fileURLWithPath: "/private/diagnostic-source/new-video.mp4")
    let selected = try OverviewBenchmarkSourceSelection.select(sourceURLs: original + [added],
      inventoryData: inventory(original), expectedFileCount: original.count)
    #expect(Set(selected.sourceURLs) == Set(original))
    #expect(original.allSatisfy { selected.includes($0) })
    #expect(!selected.includes(added))
    #expect(selected.report.originalRegularFileCount == 3)
    #expect(selected.report.discoveredRegularFileCount == 4)
    #expect(selected.report.excludedAddedRegularFileCount == 1)
    #expect(selected.report.excludedAddedPathSHA256 == [OverviewBenchmarkSourceSelection.pathHash(added)])
  }

  @Test("중복 허용 해시와 중복 현재 경로는 거절한다")
  func rejectsDuplicateMembership() throws {
    let original = urls()
    let duplicate = Array(repeating: OverviewBenchmarkSourceSelection.pathHash(original[0]), count: 3)
    #expect(throws: OverviewBenchmarkSourceSelection.Failure.duplicateHash) {
      try OverviewBenchmarkSourceSelection.select(sourceURLs: original,
        inventoryData: inventory(original, hashes: duplicate), expectedFileCount: 3)
    }
    #expect(throws: OverviewBenchmarkSourceSelection.Failure.duplicateCurrentFile) {
      try OverviewBenchmarkSourceSelection.select(sourceURLs: original + [original[0]],
        inventoryData: inventory(original), expectedFileCount: 3)
    }
  }

  @Test("형식이 잘못된 해시는 거절한다")
  func rejectsBadHash() throws {
    #expect(throws: OverviewBenchmarkSourceSelection.Failure.invalidHash) {
      try OverviewBenchmarkSourceSelection.select(sourceURLs: urls(),
        inventoryData: inventory(urls(), hashes: ["BAD", String(repeating: "a", count: 64),
          String(repeating: "b", count: 64)]), expectedFileCount: 3)
    }
  }

  @Test("원래 개수가 맞지 않거나 파일 목록 데이터가 아니면 거절한다")
  func rejectsWrongCountAndSchema() throws {
    #expect(throws: OverviewBenchmarkSourceSelection.Failure.invalidCount) {
      try OverviewBenchmarkSourceSelection.select(sourceURLs: urls(),
        inventoryData: inventory(urls(), fileCount: 4), expectedFileCount: 3)
    }
    #expect(throws: OverviewBenchmarkSourceSelection.Failure.invalidInventory) {
      try OverviewBenchmarkSourceSelection.select(sourceURLs: urls(),
        inventoryData: Data("plain document text".utf8), expectedFileCount: 3)
    }
  }

  @Test("원래 파일 하나라도 없으면 축소된 표본으로 실행하지 않는다")
  func rejectsMissingOriginal() throws {
    #expect(throws: OverviewBenchmarkSourceSelection.Failure.missingOriginalFile) {
      try OverviewBenchmarkSourceSelection.select(sourceURLs: Array(urls().dropLast()),
        inventoryData: inventory(urls()), expectedFileCount: 3)
    }
  }

  @Test("정상 여러 파일 열기는 추가 사진·영상 없이 원래 공통 폴더를 유지한다")
  func normalMultiFileOpenRetainsOriginalFolderAndFiles() async throws {
    let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
      "OverviewBenchmarkSelection-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let qoi = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
      0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    let first = folder.appendingPathComponent("first.qoi")
    let second = folder.appendingPathComponent("second.qoi")
    let notes = folder.appendingPathComponent("notes.txt")
    for url in [first, second] { try qoi.write(to: url) }
    try Data("original sidecar".utf8).write(to: notes)
    // Match the real inventory's enumerated path spelling. Foundation's
    // temporaryDirectory uses /var while directory enumeration returns
    // /private/var, even after resolvingSymlinksInPath on this macOS version.
    let originals = try FileManager.default.contentsOfDirectory(at: folder,
      includingPropertiesForKeys: nil)
    let originalImages = originals.filter { $0.pathExtension == "qoi" }
    let inventoryData = try inventory(originals)
    let before = originals.map { ImageFileVersion(url: $0) }
    try qoi.write(to: folder.appendingPathComponent("added.qoi"))
    try Data("added video".utf8).write(to: folder.appendingPathComponent("added.mp4"))
    let current = try FileManager.default.contentsOfDirectory(at: folder,
      includingPropertiesForKeys: nil)
    let selected = try OverviewBenchmarkSourceSelection.select(sourceURLs: current,
      inventoryData: inventoryData, expectedFileCount: 3)
    let library = ImageLibrary()
    let images = selected.sourceURLs.filter {
      !MediaFormatRegistry.isPlaybackMedia($0) && ImageFormatRegistry.canAttemptToDecode($0)
    }
    #expect(Set(images) == Set(originalImages))
    let opened = try await library.open(urls: images, includesVideos: false)
    #expect(Set(opened.assets.map(\.url)) == Set(originalImages))
    #expect(opened.folderURL?.resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
    #expect(originals.map { ImageFileVersion(url: $0) } == before)
    #expect(selected.report.excludedAddedRegularFileCount == 2)
  }
}
