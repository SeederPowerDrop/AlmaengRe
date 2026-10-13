import Foundation

struct GeoCoordinate: Codable, Hashable, Sendable {
  let latitude: Double
  let longitude: Double

  var isValid: Bool {
    latitude.isFinite && longitude.isFinite
      && (-90...90).contains(latitude) && (-180...180).contains(longitude)
  }
}

/// A portable map selection, shared with the Rust collection filter and saved sessions.
/// A rectangle whose west longitude exceeds its east longitude crosses the date line.
enum GeographicSelection: Hashable, Sendable, Codable {
  case radius(center: GeoCoordinate, meters: Double)
  case rectangle(southWest: GeoCoordinate, northEast: GeoCoordinate)
  case polygon([GeoCoordinate])
  indirect case multiple([GeographicSelection])

  static let maximumAreaCount = 3

  /// Areas are alternatives: a photo inside any one of them belongs to the selection.
  var areas: [GeographicSelection] {
    if case .multiple(let areas) = self { return areas }
    return [self]
  }

  /// Normalizes UI edits, preserving area order and the first three individual shapes.
  /// Callers should check the limit before adding an area so existing selections stay visible.
  static func combining(_ areas: [GeographicSelection]) -> GeographicSelection? {
    var shapes: [GeographicSelection] = []
    func append(_ area: GeographicSelection) {
      guard shapes.count < maximumAreaCount else { return }
      if case .multiple(let children) = area {
        for child in children { append(child) }
      } else {
        shapes.append(area)
      }
    }
    for area in areas { append(area) }
    switch shapes.count {
    case 0: return nil
    case 1: return shapes[0]
    default: return .multiple(shapes)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind, center, meters, southWest, northEast, points, areas
  }
  private enum Kind: String, Codable { case radius, rectangle, polygon, multiple }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(Kind.self, forKey: .kind) {
    case .radius:
      self = .radius(center: try values.decode(GeoCoordinate.self, forKey: .center),
        meters: try values.decode(Double.self, forKey: .meters))
    case .rectangle:
      self = .rectangle(southWest: try values.decode(GeoCoordinate.self, forKey: .southWest),
        northEast: try values.decode(GeoCoordinate.self, forKey: .northEast))
    case .polygon:
      let points = try values.decode([GeoCoordinate].self, forKey: .points)
      guard (3...512).contains(points.count) else {
        throw DecodingError.dataCorruptedError(forKey: .points, in: values,
          debugDescription: "A drawn area needs 3...512 points")
      }
      self = .polygon(points)
    case .multiple:
      let areas = try values.decode([GeographicSelection].self, forKey: .areas)
      let containsGroup = areas.contains {
        if case .multiple = $0 { return true }
        return false
      }
      guard (1...Self.maximumAreaCount).contains(areas.count), !containsGroup else {
        throw DecodingError.dataCorruptedError(forKey: .areas, in: values,
          debugDescription: "A map selection needs 1...3 individual areas")
      }
      self = .multiple(areas)
    }
  }

  func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .radius(let center, let meters):
      try values.encode(Kind.radius, forKey: .kind)
      try values.encode(center, forKey: .center)
      try values.encode(meters, forKey: .meters)
    case .rectangle(let southWest, let northEast):
      try values.encode(Kind.rectangle, forKey: .kind)
      try values.encode(southWest, forKey: .southWest)
      try values.encode(northEast, forKey: .northEast)
    case .polygon(let points):
      try values.encode(Kind.polygon, forKey: .kind)
      try values.encode(points, forKey: .points)
    case .multiple(let areas):
      try values.encode(Kind.multiple, forKey: .kind)
      try values.encode(areas, forKey: .areas)
    }
  }
}
