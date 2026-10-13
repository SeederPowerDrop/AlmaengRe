import CryptoKit
import Darwin
import Foundation
import Testing

@testable import ImageViewer

@Suite("전용 가상 외장 볼륨의 실제 용량 부족")
@MainActor
struct ExternalVolumeCapacityTests {
  @Test("실제 ENOSPC 발생 후 이동 원본·분류와 전체 바이트를 보존하고 임시 사본을 제거한다",
    .enabled(if: ProcessInfo.processInfo.environment["ALMAENG_CAPACITY_QA_ROOT"] != nil))
  func realDiskFullMovePreservesSource() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["ALMAENG_CAPACITY_QA_ROOT"])
    let volume = URL(fileURLWithPath: path, isDirectory: true)
    try ExternalVolumeTestSafety.requireDisposableDiskImage(volume)
    let values = try volume.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
    let capacity = try #require(values.volumeTotalCapacity)
    let free = try #require(values.volumeAvailableCapacity)
    let mib = 1_048_576
    // This test intentionally exhausts only the parent's disposable 256 MiB image.
    // A real disk, ordinary directory, or unexpectedly large volume is rejected.
    try #require(capacity >= 200 * mib && capacity <= 270 * mib)
    try #require(free > 32 * mib && free <= capacity)
    let sourceSize = ((free + mib - 1) / mib + 16) * mib
    try #require(sourceSize > free && sourceSize <= 300 * mib)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Almaeng-Capacity-Source-\(UUID())")
    let destination = volume.appendingPathComponent("Almaeng-Capacity-Destination-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: destination) }
    let sourceDevice = try deviceID(root)
    let destinationDevice = try deviceID(destination)
    try #require(sourceDevice != destinationDevice)
    let source = root.appendingPathComponent("Capacity-Synthetic-Source.bin")
    try Data().write(to: source)
    let writer = try FileHandle(forWritingTo: source)
    let block = Data((0..<mib).map { UInt8(truncatingIfNeeded: $0) })
    var expectedHash = SHA256()
    for _ in 0..<(sourceSize / mib) {
      try writer.write(contentsOf: block)
      expectedHash.update(data: block)
    }
    try writer.close()
    let digest = Data(expectedHash.finalize())
    let snapshot = try BatchFileOperationSourceSnapshot.capture(source)
    let identity = try #require(PhotoMarkFileIdentity.read(source)?.key)
    let asset = ImageAsset(url: source, byteCount: Int64(sourceSize), modificationDate: nil,
      photoMarkIdentity: identity)
    let database = root.appendingPathComponent("marks.sqlite")
    let marks = PhotoMarkStore(databaseURL: database)
    await marks.waitUntilReady()
    try #require(marks.isReady)
    marks.toggle(.one, for: asset)
    marks.toggle(.q, for: asset)
    marks.flush()
    let errorRecorder = CopyErrorRecorder()
    let worker = BatchFileOperator(copyFile: { original, staging in
      // Execute the real native copy. Record, but never synthesize, its errno.
      do { try BatchFileOperator.copyExclusively(original, staging) }
      catch {
        errorRecorder.record(error as NSError)
        throw error
      }
    })
    let plan = try BatchFileOperationPlanner.plan(assets: [asset], operation: .move,
      destinationFolder: destination)
    let result = await worker.execute(plan)
    #expect(!result.wasCancelled && result.completed.isEmpty && result.failures.count == 1)
    let copyError = try #require(errorRecorder.error())
    #expect(copyError.domain == NSPOSIXErrorDomain && copyError.code == Int(ENOSPC),
      "Expected a real disk-full error, received \(copyError)")
    #expect(try BatchFileOperationSourceSnapshot.capture(source) == snapshot)
    #expect(PhotoMarkFileIdentity.read(source)?.key == identity)
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    let reader = try FileHandle(forReadingFrom: source)
    defer { try? reader.close() }
    var actualHash = SHA256()
    var readCount = 0
    while let data = try reader.read(upToCount: mib), !data.isEmpty {
      actualHash.update(data: data)
      readCount += data.count
    }
    #expect(readCount == sourceSize)
    #expect(Data(actualHash.finalize()) == digest)
    let restartedMarks = PhotoMarkStore(databaseURL: database)
    await restartedMarks.waitUntilReady()
    #expect(restartedMarks.isReady)
    #expect(restartedMarks.marks(for: asset) == [.one, .q])
  }

  private func deviceID(_ url: URL) throws -> dev_t {
    var info = stat()
    guard url.withUnsafeFileSystemRepresentation({ lstat($0!, &info) }) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return info.st_dev
  }

  private final class CopyErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: NSError?
    func record(_ error: NSError) { lock.lock(); defer { lock.unlock() }; recorded = error }
    func error() -> NSError? { lock.lock(); defer { lock.unlock() }; return recorded }
  }
}

/// Refuse physical removable disks even when the opt-in environment variable is
/// accidentally pointed at one. Only an already-mounted disposable disk image
/// created under /tmp/Almaeng-External-QA-* is eligible for saturation/cancel QA.
enum ExternalVolumeTestSafety {
  static func requireDisposableDiskImage(_ volume: URL) throws {
    let requested = volume.resolvingSymlinksInPath().standardizedFileURL
    let values = try requested.resourceValues(forKeys: [.volumeURLKey, .volumeTotalCapacityKey])
    let mounted = try #require(values.volume)
    try #require(mounted.resolvingSymlinksInPath().standardizedFileURL == requested,
      "The supplied path must be the root of the disposable mounted volume")
    let capacity = try #require(values.volumeTotalCapacity)
    try #require(capacity >= 200 * 1_048_576 && capacity <= 270 * 1_048_576)
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = ["info", "-plist"]
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    let dictionary = try #require(plist as? [String: Any])
    let images = try #require(dictionary["images"] as? [[String: Any]])
    let matchingImage = images.first { image in
      guard let entities = image["system-entities"] as? [[String: Any]] else { return false }
      return entities.contains { entity in
        guard let path = entity["mount-point"] as? String else { return false }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL == requested
      }
    }
    let image = try #require(matchingImage, "Physical disks are not permitted for this test")
    let imagePath = try #require(image["image-path"] as? String)
    let imageURL = URL(fileURLWithPath: imagePath).resolvingSymlinksInPath().standardizedFileURL
    let parent = imageURL.deletingLastPathComponent()
    let temporaryRoot = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().standardizedFileURL
    try #require(parent.deletingLastPathComponent() == temporaryRoot
      && parent.lastPathComponent.hasPrefix("Almaeng-External-QA-"),
      "Only explicitly disposable QA images under /tmp are permitted")
  }
}
