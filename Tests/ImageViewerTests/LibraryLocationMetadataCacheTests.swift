import Foundation
import Testing

@testable import ImageViewer

@Suite("지도·EXIF가 같은 파일 헤더를 재사용한다")
struct LibraryLocationMetadataCacheTests {
  @Test("GPS 다음 촬영 정보 검색과 새 폴더 스캔은 양성·음성 헤더를 재사용한다")
  func locationThenMetadataUsesOneRead() async throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let assets = (0..<2).map { ImageAsset(url: folder.appendingPathComponent("\($0).dng"),
      byteCount: 1, modificationDate: nil) }
    let counter = ReadCounter()
    let expected = ImageLocation(latitude: 48, longitude: 2)
    let cache = LibrarySortMetadataCache { url, _ in
      await counter.increment()
      return LibrarySortMetadata(pixelWidth: 8_064,
        embeddedLocation: url.lastPathComponent == "0.dng" ? expected : nil)
    }
    let library = ImageLibrary()
    let located = try await library.enrichLocations(assets, cache: cache)
    #expect(located.allSatisfy { $0.hasReadLocation })
    #expect(located[0].location == expected && located[1].location == nil)
    let sorted = try await library.enrichSortMetadata(located, for: .capturedNewest, cache: cache)
    #expect(sorted.allSatisfy { $0.sortMetadata?.pixelWidth == 8_064 })
    // A fresh library instance and fresh assets still reuse the versioned cache.
    let rescanned = try await ImageLibrary().enrichLocations(assets, cache: cache)
    #expect(rescanned.map(\.location) == located.map(\.location))
    #expect(await counter.value == 2)
  }

  @Test("촬영 정보 다음 지도는 캐시에서 밀려난 항목도 보유한 헤더로 재사용한다")
  func retainedSortMetadataFeedsMap() async throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let assets = (0..<2).map { ImageAsset(url: folder.appendingPathComponent("\($0).dng"),
      byteCount: 1, modificationDate: nil) }
    let counter = ReadCounter()
    let cache = LibrarySortMetadataCache(maximumEntries: 1) { _, _ in
      await counter.increment()
      return LibrarySortMetadata(embeddedLocation: ImageLocation(latitude: 35, longitude: 139))
    }
    let library = ImageLibrary()
    let sorted = try await library.enrichSortMetadata(assets, for: .widthAscending, cache: cache)
    let located = try await library.enrichLocations(sorted, cache: cache)
    #expect(located.allSatisfy { $0.hasReadLocation && $0.location != nil })
    #expect(await counter.value == 2)
  }

  @Test("헤더 읽기 도중 바뀐 파일의 GPS는 적용하지 않고 다음 조회에서 다시 읽는다")
  func changedSourceDoesNotPublishStaleLocation() async throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("0.dng")
    let source = [ImageAsset(url: url, byteCount: 1, modificationDate: nil)]
    let counter = ReadCounter()
    let cache = LibrarySortMetadataCache { url, _ in
      let read = await counter.increment()
      if read == 1 { try Data([2, 3]).write(to: url, options: .atomic) }
      return LibrarySortMetadata(embeddedLocation: ImageLocation(latitude: Double(read), longitude: 2))
    }
    let library = ImageLibrary()
    let changed = try await library.enrichLocations(source, cache: cache)
    #expect(!changed[0].hasReadLocation && changed[0].location == nil)
    let refreshed = try await library.enrichLocations(changed, cache: cache)
    #expect(refreshed[0].hasReadLocation && refreshed[0].location?.latitude == 2)
    #expect(await counter.value == 2)
  }

  @Test("GPS 색인을 취소하면 대기 중인 헤더 읽기를 시작하지 않고 공용 작업 예산을 지킨다")
  func locationRequestsRespectGovernorAndCancellation() async throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("0.dng")
    let governor = ImageResourceGovernor(storageOverride: .internalSSD, maximumConcurrentLoadsOverride: 1)
    let blocker = Task {
      try await governor.value(for: ImageResourceWorkKey(namespace: UUID(), key: 0), url: url) { _ in
        try await Task.sleep(for: .seconds(30))
        return 0
      }
    }
    defer { blocker.cancel() }
    try await waitUntil { await governor.stateSnapshot().runningCount == 1 }
    let counter = ReadCounter()
    let cache = LibrarySortMetadataCache { _, _ in
      await counter.increment()
      return LibrarySortMetadata()
    }
    let pending = Task {
      try await ImageLibrary().enrichLocations(
        [ImageAsset(url: url, byteCount: 1, modificationDate: nil)], governor: governor, cache: cache)
    }
    defer { pending.cancel() }
    try await waitUntil { await governor.stateSnapshot().queuedCount == 1 }
    #expect(await counter.value == 0)
    pending.cancel()
    do {
      _ = try await pending.value
      Issue.record("Cancelled GPS indexing must not return a completed collection")
    } catch is CancellationError {}
    #expect(await counter.value == 0)
    blocker.cancel()
    _ = try? await blocker.value
    try await waitUntil {
      let state = await governor.stateSnapshot()
      return state.runningCount == 0 && state.queuedCount == 0 && state.waiterCount == 0
    }
  }

  @Test("지도 색인은 동영상 헤더를 열지 않는다")
  func videoRemainsOutsideMapScope() async throws {
    let counter = ReadCounter()
    let cache = LibrarySortMetadataCache { _, _ in
      await counter.increment()
      return LibrarySortMetadata()
    }
    let asset = ImageAsset(url: URL(fileURLWithPath: "/synthetic/movie.mp4"),
      byteCount: 1, modificationDate: nil)
    let located = try await ImageLibrary().enrichLocations([asset], cache: cache)
    #expect(located[0].hasReadLocation && located[0].location == nil)
    #expect(await counter.value == 0)
  }

  private func fixture() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("location-cache-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for index in 0..<2 { try Data([1]).write(to: folder.appendingPathComponent("\(index).dng")) }
    return folder
  }

  private func waitUntil(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await predicate()), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(await predicate())
  }

  private actor ReadCounter {
    var value = 0
    @discardableResult func increment() -> Int { value += 1; return value }
  }
}
