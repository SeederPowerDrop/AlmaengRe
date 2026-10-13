import Foundation
import ImageIO
import Testing

@testable import ImageViewer

@Suite("파일 와일드카드·촬영 정보·날짜 검색")
struct LibraryAdvancedSearchTests {
  @Test("와일드카드 이름 검색은 접두·접미·전체·유니코드와 리터럴 기호를 처리한다")
  func filenameWildcards() throws {
    let assets = ["IMG_001.JPG", "my_IMG_002.png", "여행_부산.png", "café.jpg", "notes[1].png"]
      .map { asset($0) }
    func names(_ text: String) throws -> [String] {
      try RustImageEngine.query(assets, options: LibraryQuery(searchText: text)).map(\.filename)
    }
    #expect(try names("img*") == ["IMG_001.JPG"])
    #expect(try names("%img%") == ["IMG_001.JPG", "my_IMG_002.png"])
    #expect(try names("*.png").count == 3)
    #expect(try names("*부산*") == ["여행_부산.png"])
    #expect(try names("cafe%").count == 1)
    #expect(try names("[1]") == ["notes[1].png"])
    #expect(try names("IMG").count == 2)
    #expect(try names("*%***").count == assets.count)
    #expect(try names("img*.png").isEmpty)
    #expect(LibraryTextMatcher(pattern: "").matches(""))
    #expect(LibraryTextMatcher(pattern: "*").matches(""))
    #expect(!LibraryTextMatcher(pattern: "a*").matches(""))
    #expect(LibraryTextMatcher(pattern: "summer beach").matches("beach_summer_2024.jpg"))
    #expect(!LibraryTextMatcher(pattern: "summer beach").matches("summer_mountain.jpg"))
  }

  @Test("촬영일은 원래 EXIF 날짜를 유지하고 기간·이전·이후 경계를 일 단위로 처리한다")
  func capturedDateBoundaries() throws {
    let properties: [CFString: Any] = [kCGImagePropertyExifDictionary: [
      kCGImagePropertyExifDateTimeOriginal: "2024:01:02 00:30:00",
      kCGImagePropertyExifOffsetTimeOriginal: "+09:00",
    ]]
    let metadata = LibrarySortMetadataReader.imageMetadata(properties)
    #expect(metadata.capturedAt == ISO8601DateFormatter().date(from: "2024-01-01T15:30:00Z"))
    let photo = asset("captured.jpg", metadata: metadata)
    let missing = asset("unknown.jpg")
    let january2 = day("2024-01-02"), january1 = day("2024-01-01"), january3 = day("2024-01-03")
    let on = LibraryDateFilter(source: .captured, relation: .on, start: january2, end: january2)
    #expect(on.matches(photo))
    #expect(!on.matches(missing))
    #expect(!LibraryDateFilter(source: .captured, relation: .before, start: january2).matches(photo))
    #expect(!LibraryDateFilter(source: .captured, relation: .after, start: january2).matches(photo))
    #expect(LibraryDateFilter(source: .captured, relation: .before, start: january3).matches(photo))
    #expect(LibraryDateFilter(source: .captured, relation: .after, start: january1).matches(photo))
    #expect(LibraryDateFilter(source: .captured, relation: .between, start: january1, end: january2).matches(photo))
    #expect(LibraryDateFilter(source: .captured, relation: .between, start: january3, end: january2).matches(photo))
    #expect(LibraryCalendarDay(metadataString: "2024:02:30 10:00:00") == nil)
  }

  @Test("파일 날짜는 지정 시간대에서 자정·일광절약시간 경계를 지킨다")
  func fileDateBoundaries() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
    let start = try #require(ISO8601DateFormatter().date(from: "2024-03-30T23:00:00Z"))
    let end = try #require(ISO8601DateFormatter().date(from: "2024-03-31T22:00:00Z"))
    let filter = LibraryDateFilter(source: .modified, relation: .on, start: day("2024-03-31"))
    #expect(!filter.matches(asset("before.jpg", modified: start.addingTimeInterval(-1)), calendar: calendar))
    #expect(filter.matches(asset("start.jpg", modified: start), calendar: calendar))
    #expect(filter.matches(asset("end.jpg", modified: end.addingTimeInterval(-1)), calendar: calendar))
    #expect(!filter.matches(asset("after.jpg", modified: end), calendar: calendar))
    let created = LibraryDateFilter(source: .created, relation: .on, start: day("2024-03-31"))
    var photo = asset("created.jpg", modified: nil)
    photo.creationDate = start
    #expect(created.matches(photo, calendar: calendar))
  }

  @Test("메타데이터·IPTC 지명·GPS 좌표·용량 조건을 AND로 결합한다")
  func combinedMetadataFilters() throws {
    let properties: [CFString: Any] = [
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "EOS R5"],
      kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeedRatings: [200], kCGImagePropertyExifLensModel: "RF 50mm"],
      kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "Seoul", kCGImagePropertyIPTCCountryPrimaryLocationName: "Korea",
        kCGImagePropertyIPTCKeywords: ["travel", "night"]],
      kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.5665, kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 126.978, kCGImagePropertyGPSLongitudeRef: "E"] as [CFString: Any],
    ]
    let metadata = LibrarySortMetadataReader.imageMetadata(properties)
    let matching = asset("IMG_1.jpg", bytes: 2_000_000, metadata: metadata)
    let large = asset("IMG_2.jpg", bytes: 9_000_000, metadata: metadata)
    let unknown = asset("IMG_3.jpg")
    var filter = LibrarySearchFilters(metadataText: "can%R5", locationText: "Seoul", gps: .present,
      minimumBytes: 1_000_000, maximumBytes: 3_000_000)
    #expect(filter.matches(matching))
    #expect(!filter.matches(large) && !filter.matches(unknown))
    filter.metadataText = "RF 50mm"
    filter.locationText = "37.5665"
    #expect(filter.matches(matching))
    filter.metadataText = "night"
    #expect(filter.matches(matching))
    filter.gps = .absent
    #expect(!filter.matches(matching))
    #expect(LibrarySearchFilters(gps: .absent).matches(unknown))
    let result = try RustImageEngine.query([large, unknown, matching],
      options: LibraryQuery(searchText: "IMG*", searchFilters: LibrarySearchFilters(metadataText: "ISO", maximumBytes: 3_000_000)))
    #expect(result.map(\.filename) == ["IMG_1.jpg"])
    #expect(metadata.searchableText.contains("200"))
  }

  @Test("메타데이터 텍스트는 크기가 제한되고 영상 GPS 태그를 읽는다")
  func boundedTextAndVideoLocation() throws {
    let properties: [CFString: Any] = [kCGImagePropertyIPTCDictionary: [
      kCGImagePropertyIPTCKeywords: Array(repeating: String(repeating: "x", count: 100_000), count: 100),
    ], kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: Data(repeating: 255, count: 4096)]]
    let value = try #require(LibrarySortMetadataReader.searchableProperties(properties))
    #expect(value.count <= 8192)
    #expect(LibrarySortMetadataReader.iso6709Location("+37.5665+126.9780+010.0/")
      == ImageLocation(latitude: 37.5665, longitude: 126.978))
    #expect(LibrarySortMetadataReader.iso6709Location("-33.8688+151.2093/")?.latitude == -33.8688)
    #expect(LibrarySortMetadataReader.iso6709Location("+99.0000+999.0000/") == nil)
  }

  @Test("새 메타데이터의 GPS 없음은 교체 전 지도 좌표를 되살리지 않는다")
  func refreshedMissingGPSOverridesPreviousLocation() {
    var photo = asset("replaced.jpg")
    photo.location = ImageLocation(latitude: 37.5665, longitude: 126.978)
    photo.hasReadLocation = true
    #expect(LibrarySearchFilters(gps: .present).matches(photo))
    photo.sortMetadata = LibrarySortMetadata()
    #expect(!LibrarySearchFilters(gps: .present).matches(photo))
    #expect(LibrarySearchFilters(gps: .absent).matches(photo))
    #expect(!LibrarySearchFilters(locationText: "37.5665").matches(photo))
  }

  @Test("기존 쿼리를 기본값으로 읽고 새 날짜·크기·미디어 조건을 보존한다")
  func queryPersistence() throws {
    let old = Data(#"{"searchText":"photo","sort":"sizeLargest","formats":[]}"#.utf8)
    let restored = try JSONDecoder().decode(LibraryQuery.self, from: old)
    #expect(restored.searchFilters == LibrarySearchFilters())
    #expect(restored.mediaKind == .all && restored.fileExtensions.isEmpty)
    let query = LibraryQuery(searchText: "img%", mediaKind: .images, fileExtensions: ["png"],
      searchFilters: LibrarySearchFilters(metadataText: "Canon", gps: .present, minimumBytes: 123,
        date: LibraryDateFilter(source: .created, relation: .between, start: day("2024-01-01"), end: day("2024-12-31"))))
    #expect(try JSONDecoder().decode(LibraryQuery.self, from: JSONEncoder().encode(query)) == query)
    #expect(!LibraryQuery(searchText: "*").requiresMetadata)
    #expect(!LibraryQuery(searchFilters: LibrarySearchFilters(minimumBytes: 10,
      date: LibraryDateFilter(source: .modified))).requiresMetadata)
    #expect(LibraryQuery(searchFilters: LibrarySearchFilters(date: LibraryDateFilter(source: .captured))).requiresMetadata)
  }

  @Test("파일 이름·용량·파일 날짜는 메타데이터를 읽지 않으며 상세 검색은 캐시를 재사용한다")
  func lazyCachedEnrichment() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("search-metadata-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("photo.jpg")
    try Data([1, 2, 3]).write(to: url)
    let source = [ImageAsset(url: url, byteCount: 3, modificationDate: Date())]
    let counter = SearchMetadataReadCounter()
    let cache = LibrarySortMetadataCache { _, _ in
      await counter.increment()
      return LibrarySortMetadata(cameraMake: "Canon")
    }
    let library = ImageLibrary()
    let cheap = LibraryQuery(searchText: "*.jpg", searchFilters: LibrarySearchFilters(minimumBytes: 1,
      date: LibraryDateFilter(source: .modified)))
    _ = try await library.enrichQueryMetadata(source, for: cheap, cache: cache)
    #expect(await counter.count == 0)
    let first = try await library.enrichQueryMetadata(source,
      for: LibraryQuery(searchFilters: LibrarySearchFilters(metadataText: "Canon")), cache: cache)
    #expect(first.first?.sortMetadata?.cameraMake == "Canon")
    _ = try await library.enrichQueryMetadata(source,
      for: LibraryQuery(searchFilters: LibrarySearchFilters(locationText: "Seoul")), cache: cache)
    _ = try await library.enrichSortMetadata(first, for: .capturedNewest, cache: cache)
    #expect(await counter.count == 1)
  }

  @Test("MB 입력은 소수점·쉼표를 지원하고 음수·무한대·오버플로를 거부한다")
  func byteSizeValidation() {
    #expect(LibrarySizeInput.bytes("1.5") == 1_500_000)
    #expect(LibrarySizeInput.bytes("1,5") == 1_500_000)
    #expect(LibrarySizeInput.bytes("0") == 0)
    for invalid in ["", "abc", "-1", "inf", "nan", "1e30"] {
      #expect(LibrarySizeInput.bytes(invalid) == nil)
    }
  }

  private func day(_ value: String) -> LibraryCalendarDay {
    LibraryCalendarDay(metadataString: value)!
  }
  private func asset(_ filename: String, bytes: Int64? = nil, modified: Date? = nil,
    metadata: LibrarySortMetadata? = nil) -> ImageAsset {
    ImageAsset(url: URL(fileURLWithPath: "/synthetic-search/" + filename), byteCount: bytes,
      modificationDate: modified, sortMetadata: metadata)
  }
}

private actor SearchMetadataReadCounter {
  private(set) var count = 0
  func increment() { count += 1 }
}
