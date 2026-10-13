import Foundation
import Testing

@testable import ImageViewer

@Suite("지도 선택 Swift·Rust 연결")
struct GeographicSelectionTests {
  @Test("반경은 모서리를 포함하는 사각형이 아닌 실제 지구상 거리를 사용한다")
  func radiusUsesDistance() throws {
    let assets = [
      asset("center.jpg", latitude: 0, longitude: 0),
      asset("north.jpg", latitude: 1, longitude: 0),
      asset("east.jpg", latitude: 0, longitude: 1),
      asset("corner.jpg", latitude: 1, longitude: 1),
      asset("outside.jpg", latitude: 1.1, longitude: 0),
    ]
    let selection = GeographicSelection.radius(center: coordinate(0, 0), meters: 112_000)
    let matches = try RustImageEngine.query(assets,
      options: LibraryQuery(geographicSelection: selection))
    #expect(matches.map(\.filename) == ["center.jpg", "east.jpg", "north.jpg"])
    // Returned values preserve the original assets, including metadata used by the map.
    try #require(matches.count == 3)
    #expect(matches[0] == assets[0])
    #expect(matches[1].location == assets[2].location)
  }

  @Test("고위도 경도 간격과 극점에서도 반경은 거리로 판정한다")
  func radiusNearPole() throws {
    let assets = [
      asset("near-pole.jpg", latitude: 89, longitude: 170),
      asset("too-far.jpg", latitude: 88, longitude: -170),
    ]
    let query = LibraryQuery(geographicSelection:
      .radius(center: coordinate(90, 0), meters: 120_000))
    #expect(try RustImageEngine.query(assets, options: query).map(\.filename) == ["near-pole.jpg"])
  }

  @Test("직사각형은 내부와 경계를 포함하고 바깥 점을 제외한다")
  func rectangleBoundaries() throws {
    let assets = [
      asset("inside.jpg", latitude: 35.5, longitude: 127.5),
      asset("south-west.jpg", latitude: 35, longitude: 127),
      asset("north-edge.jpg", latitude: 36, longitude: 127.5),
      asset("east-outside.jpg", latitude: 35.5, longitude: 128.001),
      asset("south-outside.jpg", latitude: 34.999, longitude: 127.5),
    ]
    let query = LibraryQuery(geographicSelection: .rectangle(
      southWest: coordinate(35, 127), northEast: coordinate(36, 128)))
    #expect(try RustImageEngine.query(assets, options: query).map(\.filename)
      == ["inside.jpg", "north-edge.jpg", "south-west.jpg"])
  }

  @Test("그린 다각형은 외접 사각형의 바깥 부분을 제외하고 변과 꼭짓점을 포함한다")
  func polygonShapeAndBoundaries() throws {
    let assets = [
      asset("inside.jpg", latitude: 0.5, longitude: 0.5),
      asset("edge.jpg", latitude: 0, longitude: 1),
      asset("vertex.jpg", latitude: 2, longitude: 0),
      asset("outside-shape.jpg", latitude: 1.8, longitude: 1.8),
      asset("outside-bounds.jpg", latitude: -0.01, longitude: 0),
    ]
    let query = LibraryQuery(geographicSelection:
      .polygon([coordinate(0, 0), coordinate(0, 2), coordinate(2, 0)]))
    #expect(try RustImageEngine.query(assets, options: query).map(\.filename)
      == ["edge.jpg", "inside.jpg", "vertex.jpg"])
  }

  @Test("반경·직사각형·다각형은 날짜 변경선 양쪽의 가까운 사진을 함께 포함한다")
  func dateLineAcrossAllShapes() throws {
    let assets = [
      asset("east.jpg", latitude: 0, longitude: 179.9),
      asset("west.jpg", latitude: 0, longitude: -179.9),
      asset("line.jpg", latitude: 0, longitude: 180),
      asset("greenwich.jpg", latitude: 0, longitude: 0),
      asset("north.jpg", latitude: 2, longitude: 179.9),
    ]
    let shapes: [GeographicSelection] = [
      .radius(center: coordinate(0, 179.9), meters: 30_000),
      .rectangle(southWest: coordinate(-1, 179), northEast: coordinate(1, -179)),
      .polygon([coordinate(-1, 179), coordinate(-1, -179),
        coordinate(1, -179), coordinate(1, 179)]),
    ]
    for shape in shapes {
      #expect(try RustImageEngine.query(assets,
        options: LibraryQuery(geographicSelection: shape)).map(\.filename)
        == ["east.jpg", "line.jpg", "west.jpg"])
    }
  }

  @Test("지도 필터에서 GPS 누락·범위 밖 좌표는 제외하고 필터 해제하면 다시 포함한다")
  func missingAndInvalidGPS() throws {
    let missing = ImageAsset(url: URL(fileURLWithPath: "/Pictures/map-test/no-gps.jpg"),
      byteCount: 10, modificationDate: nil)
    let assets = [asset("inside.jpg", latitude: 0, longitude: 0), missing,
      asset("invalid-latitude.jpg", latitude: 91, longitude: 0),
      asset("invalid-longitude.jpg", latitude: 0, longitude: -181)]
    let query = LibraryQuery(geographicSelection:
      .radius(center: coordinate(0, 0), meters: 100_000))
    #expect(try RustImageEngine.query(assets, options: query).map(\.filename) == ["inside.jpg"])
    #expect(try RustImageEngine.query(assets, options: LibraryQuery()).count == assets.count)
  }

  @Test("지리 필터는 검색·형식과 AND 결합하고 남은 결과에 정렬을 적용한다")
  func combinedSearchFormatAndSort() throws {
    let assets = [
      asset("Trip-small.jpg", latitude: 0, longitude: 0, bytes: 100),
      asset("TRIP-large.jpeg", latitude: 0.2, longitude: 0.2, bytes: 900),
      asset("Trip-wrong-format.png", latitude: 0, longitude: 0, bytes: 2000),
      asset("Other.jpg", latitude: 0, longitude: 0, bytes: 3000),
      asset("Trip-outside.jpg", latitude: 5, longitude: 5, bytes: 4000),
      ImageAsset(url: URL(fileURLWithPath: "/Pictures/map-test/Trip-no-gps.jpg"),
        byteCount: 5000, modificationDate: nil),
    ]
    let query = LibraryQuery(searchText: " trip ", sort: .sizeLargest, formats: [.jpeg],
      geographicSelection: .radius(center: coordinate(0, 0), meters: 100_000))
    #expect(try RustImageEngine.query(assets, options: query).map(\.filename)
      == ["TRIP-large.jpeg", "Trip-small.jpg"])
    #expect(assets.count == 6)
  }

  @Test("세 영역은 합집합으로 모으고 겹치는 사진은 한 번만 표시한다")
  func multipleAreasUseUnionWithoutDuplicatePhotos() throws {
    let areas: [GeographicSelection] = [
      .radius(center: coordinate(0, 0), meters: 150_000),
      .rectangle(southWest: coordinate(0, 0), northEast: coordinate(2, 2)),
      .polygon([coordinate(10, 10), coordinate(10, 12), coordinate(12, 10)]),
    ]
    let assets = [
      asset("overlap.jpg", latitude: 0.5, longitude: 0.5),
      asset("radius.jpg", latitude: -1, longitude: 0),
      asset("rectangle.jpg", latitude: 1.8, longitude: 1.8),
      asset("polygon.jpg", latitude: 10.2, longitude: 10.2),
      asset("outside.jpg", latitude: 5, longitude: 5),
      asset("invalid.jpg", latitude: 91, longitude: 0),
      ImageAsset(url: URL(fileURLWithPath: "/Pictures/map-test/missing.jpg"),
        byteCount: 10, modificationDate: nil),
    ]
    let matches = try RustImageEngine.query(assets,
      options: LibraryQuery(geographicSelection: .multiple(areas)))
    #expect(matches.map(\.filename)
      == ["overlap.jpg", "polygon.jpg", "radius.jpg", "rectangle.jpg"])
    #expect(Set(matches.map(\.url)).count == matches.count)
    #expect(matches.first == assets.first)
  }

  @Test("영역 추가·삭제는 세 개까지 유지하고 마지막 영역 삭제는 필터를 해제한다")
  func combiningAndRemovingAreas() {
    let a = GeographicSelection.radius(center: coordinate(0, 0), meters: 100)
    let b = GeographicSelection.rectangle(
      southWest: coordinate(1, 1), northEast: coordinate(2, 2))
    let c = GeographicSelection.radius(center: coordinate(3, 3), meters: 100)
    let d = GeographicSelection.radius(center: coordinate(4, 4), meters: 100)
    #expect(GeographicSelection.maximumAreaCount == 3)
    #expect(GeographicSelection.combining([]) == nil)
    #expect(GeographicSelection.combining([a]) == a)
    #expect(a.areas == [a])
    #expect(GeographicSelection.combining([a, b, c])?.areas == [a, b, c])
    #expect(GeographicSelection.combining([a, b, c, d])?.areas == [a, b, c])
    #expect(GeographicSelection.combining([.multiple([a, .multiple([b, c])]), d])?.areas
      == [a, b, c])

    var remaining = GeographicSelection.combining([a, b, c])?.areas ?? []
    remaining.remove(at: 1)
    #expect(GeographicSelection.combining(remaining) == .multiple([a, c]))
    remaining.remove(at: 0)
    #expect(GeographicSelection.combining(remaining) == c)
    remaining.removeAll()
    #expect(GeographicSelection.combining(remaining) == nil)
  }

  @Test("저장된 복수 영역은 비어 있거나 세 개를 넘거나 중첩되어 있으면 거부한다")
  func invalidMultipleAreasCannotBeRestored() throws {
    let shape = GeographicSelection.radius(center: coordinate(0, 0), meters: 100)
    for selection in [GeographicSelection.multiple([]),
      .multiple(Array(repeating: shape, count: 4)),
      .multiple([.multiple([shape])])]
    {
      let data = try JSONEncoder().encode(selection)
      #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(GeographicSelection.self, from: data)
      }
    }
  }

  @Test("잘못된 지도 도형은 빈 결과로 숨기지 않고 Rust 엔진 오류를 전달한다")
  func invalidGeometryThrowsEngineError() {
    let invalid: [GeographicSelection] = [
      .radius(center: coordinate(91, 0), meters: 100),
      .radius(center: coordinate(0, 0), meters: 0),
      .radius(center: coordinate(0, 0), meters: -1),
      .radius(center: coordinate(0, 0), meters: 50_000_000),
      .rectangle(southWest: coordinate(2, 0), northEast: coordinate(1, 1)),
      .rectangle(southWest: coordinate(0, -181), northEast: coordinate(1, 1)),
      .rectangle(southWest: coordinate(0, 0), northEast: coordinate(0, 1)),
      .rectangle(southWest: coordinate(0, 0), northEast: coordinate(1, 0)),
      .polygon([coordinate(0, 0), coordinate(0, 1)]),
      .polygon([coordinate(0, 0), coordinate(1, 0), coordinate(0, 181)]),
      .polygon([coordinate(0, 0), coordinate(0, 1), coordinate(0, 2)]),
      .polygon(Array(repeating: coordinate(0, 0), count: 3)),
      .polygon(Array(repeating: coordinate(0, 0), count: 513)),
      .multiple([]),
      .multiple(Array(repeating: .radius(center: coordinate(0, 0), meters: 100), count: 4)),
      .multiple([.multiple([.radius(center: coordinate(0, 0), meters: 100)])]),
      .multiple([.radius(center: coordinate(0, 0), meters: 100),
        .radius(center: coordinate(0, 0), meters: -1)]),
    ]
    for selection in invalid {
      #expect(throws: RustImageEngineError.self) {
        _ = try RustImageEngine.query([], options: LibraryQuery(geographicSelection: selection))
      }
    }
  }

  @Test("지도 선택 키가 없는 이전 검색 JSON은 기존 조건 그대로 복원한다")
  func legacyQueryDecode() throws {
    let json = Data("""
      {"searchText":"trip","sort":"modifiedNewest","formats":["jpeg","png"]}
      """.utf8)
    let query = try JSONDecoder().decode(LibraryQuery.self, from: json)
    #expect(query.searchText == "trip")
    #expect(query.sort == .modifiedNewest)
    #expect(query.formats == [.jpeg, .png])
    #expect(query.geographicSelection == nil)
  }

  @Test("모든 지도 선택과 검색 조건은 저장·복원 후 동일하고 엔진 JSON 키를 유지한다")
  func selectionRoundTrip() throws {
    let selections: [GeographicSelection?] = [
      nil,
      .radius(center: coordinate(37.5665, 126.978), meters: 1500),
      .rectangle(southWest: coordinate(-10, 179), northEast: coordinate(10, -179)),
      .polygon([coordinate(48.8, 2.2), coordinate(48.8, 2.4), coordinate(49, 2.3)]),
      .multiple([.radius(center: coordinate(48.8, 2.2), meters: 1000)]),
      .multiple([
        .radius(center: coordinate(48.8, 2.2), meters: 1000),
        .rectangle(southWest: coordinate(-10, 179), northEast: coordinate(10, -179)),
        .polygon([coordinate(10, 10), coordinate(10, 12), coordinate(12, 10)]),
      ]),
    ]
    for selection in selections {
      let original = LibraryQuery(searchText: "여행", sort: .northToSouth,
        formats: [.jpeg, .heic], geographicSelection: selection)
      let encoded = try JSONEncoder().encode(original)
      #expect(try JSONDecoder().decode(LibraryQuery.self, from: encoded) == original)
      let dictionary = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      if selection != nil {
        let shape = try #require(dictionary["geographicSelection"] as? [String: Any])
        #expect(shape["kind"] is String)
        #expect(dictionary["geographic_selection"] == nil)
        if case .multiple(let areas) = selection {
          #expect(shape["kind"] as? String == "multiple")
          #expect((shape["areas"] as? [[String: Any]])?.count == areas.count)
        }
      } else {
        #expect(dictionary["geographicSelection"] == nil)
      }
    }
  }

  private func coordinate(_ latitude: Double, _ longitude: Double) -> GeoCoordinate {
    GeoCoordinate(latitude: latitude, longitude: longitude)
  }

  private func asset(_ name: String, latitude: Double, longitude: Double, bytes: Int64 = 10)
    -> ImageAsset
  {
    ImageAsset(url: URL(fileURLWithPath: "/Pictures/map-test/\(name)"),
      byteCount: bytes, modificationDate: nil,
      location: ImageLocation(latitude: latitude, longitude: longitude))
  }
}
