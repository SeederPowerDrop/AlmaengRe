import Foundation

/// Stable palette identifiers are saved independently from a slot's display name.
enum PhotoMarkColor: String, CaseIterable, Codable, Hashable, Sendable {
  case red, orange, yellow, green, teal, blue, indigo, purple, pink, gray
}

/// Stable slots keep existing marks intact when their visible names change.
enum PhotoMarkSlot: String, CaseIterable, Codable, Hashable, Sendable {
  case one, two, three, four, q, w, e, r, a, s, d, f

  var keyLabel: String {
    switch self {
    case .one: "1"
    case .two: "2"
    case .three: "3"
    case .four: "4"
    default: rawValue.uppercased()
    }
  }

  /// Physical key positions also work while a Korean input source is selected.
  init?(keyCode: UInt16) {
    switch keyCode {
    case 18: self = .one
    case 19: self = .two
    case 20: self = .three
    case 21: self = .four
    case 12: self = .q
    case 13: self = .w
    case 14: self = .e
    case 15: self = .r
    case 0: self = .a
    case 1: self = .s
    case 2: self = .d
    case 3: self = .f
    default: return nil
    }
  }

  var defaultLabel: String { PhotoMarkL10n.text("default.\(rawValue)") }

  var defaultColor: PhotoMarkColor {
    switch self {
    case .one: .yellow
    case .two, .s: .green
    case .three, .d: .blue
    case .four: .purple
    case .q: .red
    case .w: .teal
    case .e: .orange
    case .r: .pink
    case .a: .indigo
    case .f: .gray
    }
  }

  // Bit positions are part of the on-disk format; keep this mapping stable.
  var bit: Int {
    switch self {
    case .one: 1 << 0
    case .two: 1 << 1
    case .three: 1 << 2
    case .four: 1 << 3
    case .q: 1 << 4
    case .w: 1 << 5
    case .e: 1 << 6
    case .r: 1 << 7
    case .a: 1 << 8
    case .s: 1 << 9
    case .d: 1 << 10
    case .f: 1 << 11
    }
  }

  static func mask(for slots: Set<Self>) -> Int {
    slots.reduce(0) { $0 | $1.bit }
  }

  static func slots(in mask: Int) -> Set<Self> {
    Set(allCases.filter { mask & $0.bit != 0 })
  }
}

/// Independent editors merge names and colors separately, even on the same slot.
struct PhotoMarkLabelDraft {
  var labels: [PhotoMarkSlot: String]
  var colors: [PhotoMarkSlot: PhotoMarkColor]
  private var baseline: [PhotoMarkSlot: String]
  private var baselineColors: [PhotoMarkSlot: PhotoMarkColor]

  init(labels: [PhotoMarkSlot: String], colors: [PhotoMarkSlot: PhotoMarkColor] = [:]) {
    self.labels = labels
    self.colors = colors
    baseline = labels
    baselineColors = colors
  }

  var hasChanges: Bool { labels != baseline || colors != baselineColors }

  func applyingChanges(to latest: [PhotoMarkSlot: String]) -> [PhotoMarkSlot: String] {
    var result = latest
    for slot in PhotoMarkSlot.allCases where labels[slot] != baseline[slot] {
      result[slot] = labels[slot]
    }
    return result
  }

  func applyingColorChanges(to latest: [PhotoMarkSlot: PhotoMarkColor]) -> [PhotoMarkSlot: PhotoMarkColor] {
    var result = latest
    for slot in PhotoMarkSlot.allCases where colors[slot] != baselineColors[slot] {
      result[slot] = colors[slot]
    }
    return result
  }

  mutating func refresh(with latest: [PhotoMarkSlot: String],
    colors latestColors: [PhotoMarkSlot: PhotoMarkColor]? = nil) {
    labels = applyingChanges(to: latest)
    baseline = latest
    if let latestColors {
      colors = applyingColorChanges(to: latestColors)
      baselineColors = latestColors
    }
  }
}

struct PhotoMarkFilter: Codable, Equatable, Sendable {
  var slots: Set<PhotoMarkSlot> = []
  var matchesAll = false
  var unmarkedOnly = false
  var excludedSlots: Set<PhotoMarkSlot> = []

  init(slots: Set<PhotoMarkSlot> = [], matchesAll: Bool = false,
    unmarkedOnly: Bool = false, excludedSlots: Set<PhotoMarkSlot> = []) {
    self.slots = slots
    self.matchesAll = matchesAll
    self.unmarkedOnly = unmarkedOnly
    self.excludedSlots = excludedSlots
  }

  // Existing comparison sessions predate exclusions. Keep those conditions
  // intact, rather than dropping the complete saved session during decoding.
  private enum CodingKeys: String, CodingKey { case slots, matchesAll, unmarkedOnly, excludedSlots }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    slots = try container.decodeIfPresent(Set<PhotoMarkSlot>.self, forKey: .slots) ?? []
    matchesAll = try container.decodeIfPresent(Bool.self, forKey: .matchesAll) ?? false
    unmarkedOnly = try container.decodeIfPresent(Bool.self, forKey: .unmarkedOnly) ?? false
    excludedSlots = try container.decodeIfPresent(Set<PhotoMarkSlot>.self, forKey: .excludedSlots) ?? []
  }

  var conditionCount: Int { slots.union(excludedSlots).count }
  var isActive: Bool { unmarkedOnly || conditionCount > 0 }

  mutating func setIncluded(_ slot: PhotoMarkSlot, enabled: Bool) {
    if enabled {
      slots.insert(slot)
      excludedSlots.remove(slot)
      unmarkedOnly = false
    } else { slots.remove(slot) }
  }

  mutating func setExcluded(_ slot: PhotoMarkSlot, enabled: Bool) {
    if enabled {
      excludedSlots.insert(slot)
      slots.remove(slot)
      unmarkedOnly = false
    } else { excludedSlots.remove(slot) }
  }

  mutating func setUnmarkedOnly(_ enabled: Bool) {
    unmarkedOnly = enabled
    if enabled { slots = []; excludedSlots = [] }
  }

  func matches(_ marks: Set<PhotoMarkSlot>) -> Bool {
    if unmarkedOnly { return marks.isEmpty }
    // A single excluded mark rejects a file, regardless of the include mode.
    guard excludedSlots.isDisjoint(with: marks) else { return false }
    guard !slots.isEmpty else { return true }
    return matchesAll ? slots.isSubset(of: marks) : !slots.isDisjoint(with: marks)
  }
}
