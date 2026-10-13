import CryptoKit
import Foundation
import Testing

@Suite("읽기 전용 RAW 파일 페이지 초기화 검증", .serialized)
struct RAWFileCachePreparationTests {
  @Test("합성 파일의 페이지를 비우고 내용과 메타데이터를 유지한다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_EVICT_FILE_PAGES"] == "1"))
  func syntheticFileIsUnchangedAndPagesAreAbsent() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("RAWFileCachePreparation-\(UUID()).bin")
    let content = Data(repeating: 0xA5, count: 8 * 1_024 * 1_024)
    try content.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    // Read and hash only this owned synthetic fixture, never a user's photo.
    let before = SHA256.hash(data: try Data(contentsOf: url))
    let report = try RAWFileCachePreparation.prepare(urls: [url], phase: "synthetic_validation")
    #expect(report.requested)
    #expect(report.totalPages > 0)
    #expect(report.osFilePagesVerifiedZero)
    #expect(report.residentPagesAfter == 0)
    #expect(report.metadataUnchangedFiles == 1 && report.metadataChangedFiles == 0)
    #expect(report.verifiedFiles == 1 && report.errors.isEmpty)
    #expect(SHA256.hash(data: try Data(contentsOf: url)) == before)
  }
}
