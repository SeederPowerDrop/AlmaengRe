import Foundation
import Testing

@testable import ImageViewer

@Suite("ZIP 임시 파일 정리의 수명과 실행 위치")
@MainActor
struct ArchiveLeaseResourceTests {
  @Test("마지막 이미지가 사라진 뒤 정리를 예약하고 UI에서 파일을 지우지 않는다")
  func cleanupWaitsForLastAssetAndRunsOnQueue() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("archive-lease-resources-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let imageURL = folder.appendingPathComponent("00000001.jpg")
    try Data([1, 2, 3]).write(to: imageURL)
    let queue = DispatchQueue(label: "archive-lease-resources-test")
    queue.suspend()
    var lease: ArchiveImageLease? = ArchiveImageLease(directory: folder, cleanupQueue: queue)
    weak var weakLease = lease
    var asset: ImageAsset? = ImageAsset(url: imageURL, byteCount: 3, modificationDate: nil,
      archiveOrigin: ArchiveImageOrigin(archiveURL: folder.appendingPathExtension("zip"),
        entryPath: "photo.jpg", lease: lease))
    lease = nil
    #expect(weakLease != nil)
    #expect(asset?.filename == "photo.jpg")
    #expect(FileManager.default.fileExists(atPath: imageURL.path))
    asset = nil
    #expect(weakLease == nil)
    // A suspended cleanup queue makes the distinction from synchronous deinit
    // deterministic: releasing the last asset returned without deleting its files.
    #expect(FileManager.default.fileExists(atPath: imageURL.path))
    queue.resume()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async { continuation.resume() }
    }
    #expect(!FileManager.default.fileExists(atPath: folder.path))
  }
}
