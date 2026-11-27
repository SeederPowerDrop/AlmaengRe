import Foundation
import Testing
@testable import ImageViewer

#if DEBUG
// The legacy JSON differential entry point is intentionally absent in release.
@Suite("타입 지정 검색 전달의 기존 엔진 동일성", .serialized)
struct RustQueryTransportTests {
  @Test("빈 조건의 이미 정렬된 결과는 원본 배열을 공유하고 순서가 바뀌면 별도 결과를 반환한다")
  func sortedResultSharesSourceBuffer() throws {
    let source = (0..<1000).map { index in
      ImageAsset(url: URL(fileURLWithPath: String(format: "/fixture/photo%05d.dng",index)),
        byteCount: Int64(index),modificationDate: nil)
    }
    let address = source.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    let result = try RustImageEngine.query(source,options: LibraryQuery())
    #expect(result.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) } == address)
    let reversed = try RustImageEngine.query(source,options: LibraryQuery(sort: .nameDescending))
    #expect(reversed.map(\.url) == source.reversed().map(\.url))
    #expect(reversed.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) } != address)
    #expect(source.first?.filename == "photo00000.dng")
  }

  @Test("모든 정렬에서 유니코드·결측 EXIF·동률·영상·음성 결과가 기존 JSON 경로와 같다")
  func transportMatchesLegacy() throws {
    let assets = (0..<160).map { index in
      let prefixes = ["사진", "사진", "Été", "E\u{301}te\u{301}", "PHOTO", "photo", "旅行", "عربي"]
      let ext = ["dng", "jpeg", "jpg", "m4a", "mp4", "png", "qoi", "tiff"][index % 8]
      var asset = ImageAsset(url: URL(fileURLWithPath: "/fixture/\(index % 3)/\(prefixes[index % 8])\(index % 17).\(ext)"),
        byteCount: index % 7 == 0 ? nil : Int64(index % 19),
        modificationDate: index % 3 == 0 ? nil : Date(timeIntervalSince1970: Double(index % 13)))
      asset.creationDate = index % 2 == 0 ? Date(timeIntervalSince1970: Double(index % 11)) : nil
      if index % 4 != 0 { asset.location = ImageLocation(latitude: Double(index % 80), longitude: Double(index % 170)) }
      if index % 3 != 0 {
        asset.sortMetadata = LibrarySortMetadata(pixelWidth: index % 5 == 0 ? nil : index % 17,
          pixelHeight: index % 7, capturedAt: Date(timeIntervalSince1970: Double(index % 31)),
          exposureTime: index % 7 == 0 ? nil : Double(index % 13) / 1000,
          cameraMake: index % 2 == 0 ? " Canon " : "캐논",
          cameraModel: index % 5 == 0 ? "" : "R\(index % 10)",
          aperture: index % 2 == 0 ? nil : Double(index % 11), colorSpace: index % 5 == 0 ? nil : "Display P3")
      }
      return asset
    }
    for count in [0,1,20,160] {
      let input = Array(assets.prefix(count))
      for sort in LibrarySort.allCases {
        for formats: Set<ImageFormatFilter> in [[], [.jpeg,.raw], [.other]] {
          var options = LibraryQuery(sort: sort, formats: formats)
          for text in ["", "photo*", "*.mp4", "missing"] {
            options.searchText = text
            let expected = try RustImageEngine.queryUsingLegacyJSON(input, options: options)
            #expect(try RustImageEngine.query(input, options: options) == expected,
              "count=\(count) sort=\(sort) formats=\(formats) text=\(text)")
          }
        }
      }
    }
  }

  @Test("캔슬된 검색은 네이티브 버퍼를 남기지 않고 종료한다")
  func cancelledQuery() async throws {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        _ = try RustImageEngine.query([], options: LibraryQuery())
        Issue.record("A cancelled query must throw")
      } catch { #expect(error is CancellationError) }
    }
    await task.value
  }

  @Test("지도 영역·날짜·크기·확장자 조건을 함께 적용해도 전달 경로의 결과가 같다")
  func geographicAndAdvancedPredicates() throws {
    let assets = (0..<40).map { index -> ImageAsset in
      let fileExtension = index % 2 == 0 ? "dng" : "mp4"
      let url = URL(fileURLWithPath: "/fixture/photo\(index).\(fileExtension)")
      var asset = ImageAsset(url: url, byteCount: Int64(index * 1000),
        modificationDate: Date(timeIntervalSince1970: Double(index)))
      if index % 5 != 0 { asset.location = ImageLocation(latitude: Double(index), longitude: Double(index)) }
      return asset
    }
    let area = GeographicSelection.rectangle(southWest: GeoCoordinate(latitude: 5,longitude: 5),
      northEast: GeoCoordinate(latitude: 35,longitude: 35))
    for sort in LibrarySort.allCases {
      var options = LibraryQuery(sort: sort, geographicSelection: area, fileExtensions: ["mp4"],
        searchFilters: LibrarySearchFilters(minimumBytes: 10_000,maximumBytes: 30_000))
      #expect(try RustImageEngine.query(assets, options: options)
        == RustImageEngine.queryUsingLegacyJSON(assets, options: options))
      options.geographicSelection = .radius(center: GeoCoordinate(latitude: 20,longitude: 20),meters: 300_000)
      #expect(try RustImageEngine.query(assets, options: options)
        == RustImageEngine.queryUsingLegacyJSON(assets, options: options))
    }
  }
}
#endif
