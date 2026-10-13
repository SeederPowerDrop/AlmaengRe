import Foundation

enum ToneCurveChannel: String, CaseIterable, Identifiable, Sendable {
  case rgb, red, green, blue
  var id: String { rawValue }
  var title: String {
    switch self { case .rgb: "RGB"; case .red: "빨강"; case .green: "초록"; case .blue: "파랑" }
  }
}

/// Five fixed input positions keep curves bounded, editable and cheap to evaluate.
/// Values outside SDR white keep their headroom instead of being clipped to the curve domain.
struct ImageToneCurve: Codable, Hashable, Sendable {
  var values: [Double] = [0, 0.25, 0.5, 0.75, 1]
  static let identity = ImageToneCurve()
  static let mediumContrast = ImageToneCurve(values: [0, 0.19, 0.5, 0.81, 1])
  static let strongContrast = ImageToneCurve(values: [0, 0.12, 0.5, 0.88, 1])
  var normalizedValues: [Double] {
    guard values.count == 5 else { return Self.identity.values }
    return values.enumerated().map {
      Self.finite($0.element, in: 0...1, fallback: Double($0.offset) / 4)
    }
  }
  var isIdentity: Bool { normalizedValues == Self.identity.values }
  func output(at input: Double) -> Double {
    guard input.isFinite else { return 0 }
    let y = normalizedValues
    if input < 0 { return input + y[0] }
    if input >= 1 { return input + y[4] - 1 }
    let index = min(3, Int(input * 4))
    let fraction = input * 4 - Double(index)
    return y[index] + (y[index + 1] - y[index]) * fraction
  }
  mutating func setValue(_ value: Double, at index: Int) {
    guard (0..<5).contains(index) else { return }
    values = normalizedValues
    values[index] = Self.finite(value, in: 0...1, fallback: Double(index) / 4)
  }
  static func finite(_ value: Double, in range: ClosedRange<Double>, fallback: Double = 0) -> Double {
    value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
  }
}

struct ImageToneCurves: Codable, Hashable, Sendable {
  var rgb = ImageToneCurve.identity
  var red = ImageToneCurve.identity
  var green = ImageToneCurve.identity
  var blue = ImageToneCurve.identity
  var isIdentity: Bool { rgb.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity }
  subscript(channel: ToneCurveChannel) -> ImageToneCurve {
    get {
      switch channel { case .rgb: rgb; case .red: red; case .green: green; case .blue: blue }
    }
    set {
      switch channel {
      case .rgb: rgb = newValue
      case .red: red = newValue
      case .green: green = newValue
      case .blue: blue = newValue
      }
    }
  }
}

enum ColorMixerBand: String, CaseIterable, Identifiable, Codable, Sendable {
  case red, orange, yellow, green, aqua, blue, purple, magenta
  var id: String { rawValue }
  var title: String {
    switch self {
    case .red: "빨강"; case .orange: "주황"; case .yellow: "노랑"; case .green: "초록"
    case .aqua: "청록"; case .blue: "파랑"; case .purple: "보라"; case .magenta: "자홍"
    }
  }
}

struct ColorMixerValues: Codable, Hashable, Sendable {
  /// Hue is degrees; saturation and lightness are relative amounts in -1...1.
  var hue: Double = 0
  var saturation: Double = 0
  var lightness: Double = 0
  var isIdentity: Bool { hue == 0 && saturation == 0 && lightness == 0 }
}

struct ImageColorMixer: Codable, Hashable, Sendable {
  var bands: [ColorMixerBand: ColorMixerValues] = [:]
  var isIdentity: Bool { bands.values.allSatisfy(\.isIdentity) }
  subscript(band: ColorMixerBand) -> ColorMixerValues {
    get { bands[band, default: ColorMixerValues()] }
    set { bands[band] = newValue }
  }
}

enum ImageFilmLook: String, CaseIterable, Identifiable, Codable, Sendable {
  case none, tealOrange, faded, coolNight
  var id: String { rawValue }
  var title: String {
    switch self {
    case .none: "없음"
    case .tealOrange: "시네마 틸 오렌지"
    case .faded: "시네마 페이드"
    case .coolNight: "시네마 나이트"
    }
  }
}

extension ImageToneCurve {
  private enum CodingKeys: String, CodingKey { case values }
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    values = try container.decodeIfPresent([Double].self, forKey: .values) ?? Self.identity.values
    values = normalizedValues
  }
}

extension ImageToneCurves {
  private enum CodingKeys: String, CodingKey { case rgb, red, green, blue }
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    rgb = try container.decodeIfPresent(ImageToneCurve.self, forKey: .rgb) ?? .identity
    red = try container.decodeIfPresent(ImageToneCurve.self, forKey: .red) ?? .identity
    green = try container.decodeIfPresent(ImageToneCurve.self, forKey: .green) ?? .identity
    blue = try container.decodeIfPresent(ImageToneCurve.self, forKey: .blue) ?? .identity
  }
}

extension ColorMixerValues {
  private enum CodingKeys: String, CodingKey { case hue, saturation, lightness }
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    hue = try container.decodeIfPresent(Double.self, forKey: .hue) ?? 0
    saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
    lightness = try container.decodeIfPresent(Double.self, forKey: .lightness) ?? 0
  }
}

extension ImageColorMixer {
  private enum CodingKeys: String, CodingKey { case bands }
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    bands = try container.decodeIfPresent([ColorMixerBand: ColorMixerValues].self, forKey: .bands) ?? [:]
  }
}
