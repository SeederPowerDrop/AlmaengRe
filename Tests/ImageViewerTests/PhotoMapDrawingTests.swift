import Foundation
import Testing

@testable import ImageViewer

@Suite("지도 영역 그리기")
struct PhotoMapDrawingTests {
  private func coordinate(_ point: CGPoint) -> GeoCoordinate {
    GeoCoordinate(latitude: 80 - point.y, longitude: point.x - 50)
  }

  @Test("역방향 드래그도 화면의 위쪽을 북쪽으로 변환한다")
  func reversedRectangle() {
    let result = PhotoMapDrawingGeometry.selection(
      for: [CGPoint(x: 90, y: 60), CGPoint(x: 10, y: 20)],
      mode: .rectangle, coordinateAt: coordinate)
    #expect(result == .rectangle(
      southWest: GeoCoordinate(latitude: 20, longitude: -40),
      northEast: GeoCoordinate(latitude: 60, longitude: 40)))
  }

  @Test("날짜 변경선을 지나는 사각형은 서쪽과 동쪽을 뒤집지 않는다")
  func dateLineRectangle() {
    let result = PhotoMapDrawingGeometry.selection(
      for: [CGPoint(x: 10, y: 10), CGPoint(x: 190, y: 90)], mode: .rectangle
    ) { point in
      let longitude = 170 + point.x / 10
      return GeoCoordinate(latitude: 80 - point.y,
        longitude: longitude > 180 ? longitude - 360 : longitude)
    }
    #expect(result == .rectangle(
      southWest: GeoCoordinate(latitude: -10, longitude: 171),
      northEast: GeoCoordinate(latitude: 70, longitude: -171)))
  }

  @Test("클릭이나 선만 그린 경우 기존 영역을 덮어쓰지 않는다")
  func degenerateDrags() {
    #expect(PhotoMapDrawingGeometry.selection(
      for: [CGPoint(x: 10, y: 10), CGPoint(x: 12, y: 12)],
      mode: .radius, coordinateAt: coordinate) == nil)
    #expect(PhotoMapDrawingGeometry.selection(
      for: [CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 70)],
      mode: .rectangle, coordinateAt: coordinate) == nil)
    #expect(PhotoMapDrawingGeometry.selection(
      for: [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20), CGPoint(x: 30, y: 30)],
      mode: .polygon, coordinateAt: coordinate) == nil)
    #expect(PhotoMapDrawingGeometry.selection(
      for: [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 40)], mode: .rectangle,
      coordinateAt: { _ in GeoCoordinate(latitude: .nan, longitude: 0) }) == nil)
  }

  @Test("자유 영역을 자동으로 닫고 중복된 마지막 점을 제거한다")
  func closesLasso() throws {
    let a = CGPoint(x: 10, y: 10), b = CGPoint(x: 30, y: 10), c = CGPoint(x: 30, y: 30)
    let result = PhotoMapDrawingGeometry.selection(
      for: [a, b, c, c], mode: .polygon, coordinateAt: coordinate)
    #expect(result == .polygon([coordinate(a), coordinate(b), coordinate(c), coordinate(a)]))
    let alreadyClosed = PhotoMapDrawingGeometry.selection(
      for: [a, b, c, a], mode: .polygon, coordinateAt: coordinate)
    #expect(alreadyClosed == result)
  }

  @Test("반경은 화면 픽셀이 아닌 지리적 거리로 저장한다")
  func geographicRadius() throws {
    let selection = PhotoMapDrawingGeometry.selection(
      for: [CGPoint.zero, CGPoint(x: 10, y: 0)], mode: .radius,
      coordinateAt: { GeoCoordinate(latitude: 0, longitude: $0.x / 1_000) })
    guard case .radius(let center, let meters) = selection else {
      Issue.record("Expected a circular selection")
      return
    }
    #expect(center == GeoCoordinate(latitude: 0, longitude: 0))
    #expect(meters > 1_100 && meters < 1_120)
  }

  @Test("지도 바깥 드래그를 경계에 고정하고 취소 후 마우스를 놓아도 선택하지 않는다")
  func boundedDragAndCancellation() {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
    var path = PhotoMapDrawingPath()
    path.begin(at: CGPoint(x: -5, y: 10), bounds: bounds)
    path.append(CGPoint(x: 200, y: 90), mode: .rectangle, bounds: bounds)
    #expect(path.points == [CGPoint(x: 0, y: 10), CGPoint(x: 100, y: 80)])
    path.cancel()
    path.append(CGPoint(x: 50, y: 50), mode: .rectangle, bounds: bounds, final: true)
    #expect(path.finish().isEmpty)
    #expect(path.points.isEmpty)
  }

  @Test("긴 자유곡선은 저장 가능한 점 수를 유지하며 마지막 좌표를 보존한다")
  func boundedLassoSize() {
    let bounds = CGRect(x: 0, y: 0, width: 10_000, height: 1_000)
    var path = PhotoMapDrawingPath()
    path.begin(at: .zero, bounds: bounds)
    for i in 1...2_000 {
      path.append(CGPoint(x: Double(i) * 5, y: Double(i % 2) * 100), mode: .polygon, bounds: bounds)
    }
    let points = path.finish()
    #expect(points.count <= 256)
    #expect(points.first == .zero)
    #expect(points.last == CGPoint(x: 10_000, y: 0))
    #expect(path.points.isEmpty)
  }

  @Test("반경과 사각형은 현재 보이는 화면 중심에 생성된다")
  func centeredCreation() throws {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
    let rectangle = PhotoMapDrawingGeometry.centeredSelection(
      in: bounds, mode: .rectangle, coordinateAt: coordinate)
    #expect(rectangle == .rectangle(
      southWest: GeoCoordinate(latitude: 24, longitude: -20),
      northEast: GeoCoordinate(latitude: 56, longitude: 20)))
    let radius = PhotoMapDrawingGeometry.centeredSelection(
      in: bounds, mode: .radius, coordinateAt: coordinate)
    guard case .radius(let center, let meters) = radius else {
      Issue.record("Expected a centered radius")
      return
    }
    #expect(center == GeoCoordinate(latitude: 40, longitude: 0))
    #expect(meters > 0)
    // A panned viewport changes the coordinate mapping without changing its pixel dimensions.
    let panned = PhotoMapDrawingGeometry.centeredSelection(in: bounds, mode: .radius) {
      GeoCoordinate(latitude: 60 - Double($0.y) / 10, longitude: Double($0.x) / 10 + 120)
    }
    guard case .radius(let pannedCenter, _) = panned else {
      Issue.record("Expected a radius in the panned viewport")
      return
    }
    #expect(pannedCenter == GeoCoordinate(latitude: 56, longitude: 125))
    #expect(PhotoMapDrawingGeometry.centeredSelection(
      in: .zero, mode: .rectangle, coordinateAt: coordinate) == nil)
    #expect(PhotoMapDrawingGeometry.centeredSelection(
      in: bounds, mode: .polygon, coordinateAt: coordinate) == nil)
  }

  @Test("원형 영역 이동은 반경을 유지하고 날짜 변경선을 짧은 방향으로 넘는다")
  func radiusTranslationAcrossDateLine() throws {
    let original = GeographicSelection.radius(
      center: GeoCoordinate(latitude: 0, longitude: 179), meters: 2_500)
    let moved = PhotoMapDrawingGeometry.translated(original,
      from: GeoCoordinate(latitude: 0, longitude: 179),
      to: GeoCoordinate(latitude: 0, longitude: -179))
    guard case .radius(let center, let meters) = moved else {
      Issue.record("Expected a translated radius")
      return
    }
    #expect(abs(center.latitude) < 0.000_001)
    #expect(center.longitude == -179)
    #expect(meters == 2_500)
    #expect(PhotoMapDrawingGeometry.translated(original,
      from: GeoCoordinate(latitude: .nan, longitude: 0),
      to: GeoCoordinate(latitude: 0, longitude: 0)) == nil)
  }

  @Test("사각형 이동은 날짜 변경선 경계를 유지하고 극지방에서 전체 영역을 제한한다")
  func rectangleTranslationAtDateLineAndPole() throws {
    let original = GeographicSelection.rectangle(
      southWest: GeoCoordinate(latitude: 70, longitude: 170),
      northEast: GeoCoordinate(latitude: 80, longitude: -170))
    let moved = PhotoMapDrawingGeometry.translated(original,
      from: GeoCoordinate(latitude: 75, longitude: 179),
      to: GeoCoordinate(latitude: 90, longitude: -176))
    guard case .rectangle(let south, let north) = moved else {
      Issue.record("Expected a translated rectangle")
      return
    }
    #expect(south.isValid && north.isValid)
    #expect(south.latitude < north.latitude)
    #expect(abs(north.latitude - 85.051_128_779_806_6) < 0.000_001)
    #expect(south.longitude == 175)
    #expect(north.longitude == -165)

    let worldwide = GeographicSelection.rectangle(
      southWest: GeoCoordinate(latitude: -20, longitude: -180),
      northEast: GeoCoordinate(latitude: 20, longitude: 180))
    let shiftedWorld = PhotoMapDrawingGeometry.translated(worldwide,
      from: GeoCoordinate(latitude: 0, longitude: 0),
      to: GeoCoordinate(latitude: 0, longitude: 50))
    guard case .rectangle(let worldSouth, let worldNorth) = shiftedWorld else {
      Issue.record("Expected a whole-world rectangle")
      return
    }
    #expect(worldSouth.longitude == -180 && worldNorth.longitude == 180)
  }

  @Test("자유 영역 이동은 닫힌 모양과 점 수를 보존한다")
  func polygonTranslation() throws {
    let coordinates = [GeoCoordinate(latitude: 5, longitude: 175),
      GeoCoordinate(latitude: 5, longitude: -175),
      GeoCoordinate(latitude: -5, longitude: -175),
      GeoCoordinate(latitude: 5, longitude: 175)]
    let translated = PhotoMapDrawingGeometry.translated(.polygon(coordinates),
      from: GeoCoordinate(latitude: 0, longitude: 179),
      to: GeoCoordinate(latitude: 10, longitude: -171))
    guard case .polygon(let points) = translated else {
      Issue.record("Expected a translated polygon")
      return
    }
    #expect(points.count == coordinates.count)
    #expect(points.first == points.last)
    #expect(points.allSatisfy { $0.isValid })
    #expect(points[0].longitude == -175)
    #expect(points[1].longitude == -165)
    #expect(points[0].latitude > coordinates[0].latitude)
  }

  @Test("크기 손잡이는 원 중심과 사각형 북서쪽 모서리를 고정한다")
  func resizing() throws {
    let center = GeoCoordinate(latitude: 0, longitude: 0)
    let resizedCircle = PhotoMapDrawingGeometry.resized(.radius(center: center, meters: 1_000),
      to: GeoCoordinate(latitude: 0, longitude: 0.02))
    guard case .radius(let newCenter, let meters) = resizedCircle else {
      Issue.record("Expected a resized circle")
      return
    }
    #expect(newCenter == center)
    #expect(meters > 2_200 && meters < 2_240)
    let rectangle = GeographicSelection.rectangle(
      southWest: GeoCoordinate(latitude: 10, longitude: 179),
      northEast: GeoCoordinate(latitude: 20, longitude: -179))
    #expect(PhotoMapDrawingGeometry.resized(rectangle,
      to: GeoCoordinate(latitude: 5, longitude: -178)) == .rectangle(
        southWest: GeoCoordinate(latitude: 5, longitude: 179),
        northEast: GeoCoordinate(latitude: 20, longitude: -178)))
    #expect(PhotoMapDrawingGeometry.resized(rectangle,
      to: GeoCoordinate(latitude: 25, longitude: -178)) == nil)
    #expect(PhotoMapDrawingGeometry.resized(rectangle,
      to: GeoCoordinate(latitude: 15, longitude: 179)) == nil)
  }

}
