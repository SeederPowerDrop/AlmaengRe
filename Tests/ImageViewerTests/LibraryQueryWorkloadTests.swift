import AppKit
import Combine
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

@Suite("검색 전환의 불필요한 목록·메타데이터 작업", .serialized)
struct LibraryQueryWorkloadTests {
  @Test("준비된 검색 조건은 날짜·와일드카드·GPS와 빈 조건의 의미를 유지한다")
  func preparedSearchSemantics() throws {
    let metadata = LibrarySortMetadata(cameraMake: "Canon", cameraModel: "EOS R5",
      colorSpace: "Display P3", embeddedLocation: ImageLocation(latitude: 37.5, longitude: 127),
      locationText: "Seoul", additionalSearchText: "Lens RF 50mm ISO 200")
    let a = ImageAsset(url: URL(fileURLWithPath: "/fixture/a.dng"), byteCount: 200,
      modificationDate: nil, sortMetadata: metadata)
    let b = ImageAsset(url: URL(fileURLWithPath: "/fixture/b.mp4"), byteCount: 500,
      modificationDate: nil)
    let cases: [(LibrarySearchFilters, [String])] = [
      (.init(), ["a.dng", "b.mp4"]),
      (.init(metadataText: "CAN%R5"), ["a.dng"]),
      (.init(metadataText: "ISO 200", locationText: "seóul"), ["a.dng"]),
      (.init(locationText: "37.500000"), ["a.dng"]),
      (.init(gps: .absent), ["b.mp4"]),
      (.init(gps: .present, maximumBytes: 300), ["a.dng"]),
      (.init(minimumBytes: 300), ["b.mp4"]),
      (.init(metadataText: "missing"), []),
    ]
    for (filters, expected) in cases {
      let predicate = LibrarySearchPredicate(filters: filters)
      #expect([a, b].filter(predicate.matches).map(\.filename) == expected)
      #expect(try RustImageEngine.query([a, b], options: LibraryQuery(searchFilters: filters))
        .map(\.filename) == expected)
    }
  }

  @MainActor
  @Test("동일 결과의 검색은 원본 목록·표시 목록과 현재 사진 메타데이터를 다시 발행하지 않는다")
  func identicalQueryRetainsCollectionsAndMetadata() async throws {
    let suite = "LibraryQueryWorkload.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("sample.png")
    let context = try #require(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: folder.appendingPathComponent("marks.sqlite"), thumbnailDiskCache: nil)
    await store.photoMarks.waitUntilReady()
    store.open(urls: [url])
    try await wait { !store.isLoading && !store.isFiltering && store.currentMetadata != nil }
    let metadata = store.currentMetadata
    let extensions = store.availableFileExtensions
    var sourceUpdates = 0, assetUpdates = 0, metadataClears = 0
    let sourceToken = store.$allAssets.dropFirst().sink { _ in sourceUpdates += 1 }
    let assetToken = store.$assets.dropFirst().sink { _ in assetUpdates += 1 }
    let metadataToken = store.$currentMetadata.dropFirst().sink { if $0 == nil { metadataClears += 1 } }
    defer { sourceToken.cancel(); assetToken.cancel(); metadataToken.cancel(); store.saveSessionNow() }
    store.libraryQuery.searchText = "sample*"
    try await wait { !store.isFiltering }
    #expect(sourceUpdates == 0 && assetUpdates == 0)
    #expect(metadataClears == 0 && store.currentMetadata == metadata)
    #expect(store.availableFileExtensions == extensions && extensions == ["png"])
    store.libraryQuery.searchText = "missing"
    try await wait { !store.isFiltering }
    #expect(store.assets.isEmpty && sourceUpdates == 0)
    #expect(store.currentMetadata == nil)
    store.libraryQuery = LibraryQuery()
    try await wait { !store.isFiltering && store.currentMetadata != nil }
    #expect(store.assets.map(\.url) == [url] && sourceUpdates == 0)
  }

  @MainActor
  private func wait(_ predicate: () -> Bool) async throws {
    for _ in 0..<500 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw NSError(domain: "LibraryQueryWorkload", code: 1)
  }
}
