import CoreLocation
import Foundation

/// Screen geometry is independent of the live map, so dragging and cancellation remain testable.
enum PhotoMapDrawingGeometry {
  /// New area tools always use the visible viewport, rather than the folder's photo bounds.
  static func centeredSelection(
    in bounds: CGRect, mode: PhotoMapDrawingMode,
    coordinateAt: (CGPoint) -> GeoCoordinate
  ) -> GeographicSelection? {
    guard bounds.width.isFinite, bounds.height.isFinite,
      bounds.width >= 20, bounds.height >= 20 else { return nil }
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    switch mode {
    case .radius:
      return selection(for: [center, CGPoint(x: center.x + min(bounds.width, bounds.height) * 0.2,
        y: center.y)], mode: mode, coordinateAt: coordinateAt)
    case .rectangle:
      let inset = bounds.insetBy(dx: bounds.width * 0.3, dy: bounds.height * 0.3)
      return selection(for: [CGPoint(x: inset.minX, y: inset.minY),
        CGPoint(x: inset.maxX, y: inset.maxY)], mode: mode, coordinateAt: coordinateAt)
    case .move, .polygon: return nil
    }
  }

  /// Translate in the map's Mercator plane so rectangles and lassos retain their screen shape.
  /// Clamp the entire region at the map's latitude limits, and wrap longitude across the date line.
  static func translated(
    _ selection: GeographicSelection, from start: GeoCoordinate, to end: GeoCoordinate
  ) -> GeographicSelection? {
    guard start.isValid, end.isValid else { return nil }
    let vertices: [GeoCoordinate]
    switch selection {
    case .radius(let center, let meters):
      guard meters.isFinite, meters > 0 else { return nil }
      vertices = [center]
    case .rectangle(let southWest, let northEast): vertices = [southWest, northEast]
    case .polygon(let points): vertices = points
    case .multiple: return nil
    }
    guard !vertices.isEmpty, vertices.allSatisfy(\.isValid) else { return nil }
    let longitudeDelta = normalizedLongitude(end.longitude - start.longitude)
    let ys = vertices.map { mercatorY($0.latitude) }
    guard let minY = ys.min(), let maxY = ys.max() else { return nil }
    let deltaY = min(.pi - maxY, max(-Double.pi - minY,
      mercatorY(end.latitude) - mercatorY(start.latitude)))
    func moved(_ point: GeoCoordinate) -> GeoCoordinate {
      GeoCoordinate(latitude: latitude(mercatorY(point.latitude) + deltaY),
        longitude: normalizedLongitude(point.longitude + longitudeDelta))
    }
    switch selection {
    case .radius(let center, let meters): return .radius(center: moved(center), meters: meters)
    case .rectangle(let southWest, let northEast):
      let wholeWorld = northEast.longitude - southWest.longitude >= 360
      let south = moved(southWest), north = moved(northEast)
      return .rectangle(
        southWest: GeoCoordinate(latitude: south.latitude,
          longitude: wholeWorld ? -180 : south.longitude),
        northEast: GeoCoordinate(latitude: north.latitude,
          longitude: wholeWorld ? 180 : north.longitude))
    case .polygon(let points): return .polygon(points.map(moved))
    case .multiple: return nil
    }
  }

  static func resized(
    _ selection: GeographicSelection, to edge: GeoCoordinate
  ) -> GeographicSelection? {
    guard edge.isValid else { return nil }
    switch selection {
    case .radius(let center, _):
      guard center.isValid else { return nil }
      let meters = CLLocation(latitude: center.latitude, longitude: center.longitude).distance(
        from: CLLocation(latitude: edge.latitude, longitude: edge.longitude))
      guard meters.isFinite else { return nil }
      return .radius(center: center, meters: min(20_000_000, max(10, meters)))
    case .rectangle(let southWest, let northEast):
      // The northwest corner stays fixed while the southeast handle moves.
      guard southWest.isValid, northEast.isValid, edge.latitude < northEast.latitude else { return nil }
      let width = (edge.longitude - southWest.longitude + 360).truncatingRemainder(dividingBy: 360)
      guard width > 0.000_001, width < 359.999_999 else { return nil }
      return .rectangle(
        southWest: GeoCoordinate(latitude: max(-mercatorLatitudeLimit, edge.latitude),
          longitude: southWest.longitude),
        northEast: GeoCoordinate(latitude: northEast.latitude, longitude: edge.longitude))
    case .polygon, .multiple: return nil
    }
  }

  static func normalizedLongitude(_ longitude: Double) -> Double {
    let wrapped = (longitude + 180).truncatingRemainder(dividingBy: 360)
    return (wrapped < 0 ? wrapped + 360 : wrapped) - 180
  }

  private static let mercatorLatitudeLimit = 85.051_128_779_806_6
  private static func mercatorY(_ latitude: Double) -> Double {
    let radians = min(mercatorLatitudeLimit, max(-mercatorLatitudeLimit, latitude)) * .pi / 180
    return log(tan(.pi / 4 + radians / 2))
  }
  private static func latitude(_ y: Double) -> Double {
    atan(sinh(min(.pi, max(-Double.pi, y)))) * 180 / .pi
  }
  static func selection(
    for points: [CGPoint], mode: PhotoMapDrawingMode,
    coordinateAt: (CGPoint) -> GeoCoordinate
  ) -> GeographicSelection? {
    guard let first = points.first, let last = points.last else { return nil }
    switch mode {
    case .move: return nil
    case .radius:
      guard hypot(last.x - first.x, last.y - first.y) >= 4 else { return nil }
      let center = coordinateAt(first), edge = coordinateAt(last)
      guard center.isValid && edge.isValid else { return nil }
      let meters = CLLocation(latitude: center.latitude, longitude: center.longitude).distance(
        from: CLLocation(latitude: edge.latitude, longitude: edge.longitude))
      guard meters.isFinite && meters > 0 else { return nil }
      return .radius(center: center, meters: min(20_000_000, max(10, meters)))
    case .rectangle:
      guard abs(last.x - first.x) >= 4 && abs(last.y - first.y) >= 4 else { return nil }
      let upperLeft = coordinateAt(CGPoint(x: min(first.x, last.x), y: min(first.y, last.y)))
      let lowerRight = coordinateAt(CGPoint(x: max(first.x, last.x), y: max(first.y, last.y)))
      guard upperLeft.isValid && lowerRight.isValid else { return nil }
      return .rectangle(
        southWest: GeoCoordinate(latitude: lowerRight.latitude, longitude: upperLeft.longitude),
        northEast: GeoCoordinate(latitude: upperLeft.latitude, longitude: lowerRight.longitude))
    case .polygon:
      var vertices: [CGPoint] = []
      for point in points where point != vertices.last { vertices.append(point) }
      if vertices.count > 1 && vertices.last == vertices.first { vertices.removeLast() }
      guard vertices.count >= 3 else { return nil }
      // Reject a click or a straight stroke while allowing a lasso that crosses itself.
      var hasArea = false
      for index in 1..<(vertices.count - 1) {
        let a = vertices[index], b = vertices[index + 1]
        let crossProduct = (a.x - first.x) * (b.y - first.y)
          - (a.y - first.y) * (b.x - first.x)
        if abs(crossProduct) >= 4 { hasArea = true; break }
      }
      guard hasArea else { return nil }
      let coordinates = vertices.map(coordinateAt)
      guard coordinates.allSatisfy(\.isValid), let firstCoordinate = coordinates.first else { return nil }
      return .polygon(coordinates + [firstCoordinate])
    }
  }
}

struct PhotoMapDrawingPath {
  private(set) var points: [CGPoint] = []

  mutating func begin(at point: CGPoint, bounds: CGRect) {
    points = [clamped(point, to: bounds)]
  }

  mutating func append(_ point: CGPoint, mode: PhotoMapDrawingMode, bounds: CGRect, final: Bool = false) {
    guard let previous = points.last else { return }
    let point = clamped(point, to: bounds)
    if mode == .polygon {
      guard final || hypot(point.x - previous.x, point.y - previous.y) >= 5 else { return }
      if points.count >= 256 {
        points = points.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
      }
      points.append(point)
    } else if points.count == 1 {
      points.append(point)
    } else {
      points[1] = point
    }
  }

  mutating func finish() -> [CGPoint] {
    let finished = points
    points = []
    return finished
  }

  mutating func cancel() { points = [] }

  private func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
    CGPoint(x: min(bounds.maxX, max(bounds.minX, point.x)),
      y: min(bounds.maxY, max(bounds.minY, point.y)))
  }
}
