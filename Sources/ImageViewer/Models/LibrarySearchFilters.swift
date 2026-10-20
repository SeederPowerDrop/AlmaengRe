import Foundation

/// Calendar components keep a saved day stable when the Mac's timezone changes.
struct LibraryCalendarDay: Codable, Hashable, Comparable, Sendable {
  static var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = .current
    return value
  }

  var year: Int
  var month: Int
  var day: Int

  init(_ date: Date, calendar: Calendar = LibraryCalendarDay.calendar) {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    year = parts.year ?? 1970; month = parts.month ?? 1; day = parts.day ?? 1
  }

  init?(year: Int, month: Int, day: Int) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let value = calendar.date(from: DateComponents(year: year, month: month, day: day)),
      calendar.component(.year, from: value) == year,
      calendar.component(.month, from: value) == month,
      calendar.component(.day, from: value) == day else { return nil }
    self.year = year; self.month = month; self.day = day
  }

  /// Both EXIF (yyyy:MM:dd) and ISO/container dates (yyyy-MM-dd) retain their
  /// original calendar day, including timestamps carrying an explicit offset.
  init?(metadataString: String?) {
    guard let metadataString else { return nil }
    let prefix = String(metadataString.prefix(10)).replacingOccurrences(of: ":", with: "-")
    let fields = prefix.split(separator: "-").compactMap { Int($0) }
    guard fields.count == 3 else { return nil }
    self.init(year: fields[0], month: fields[1], day: fields[2])
  }

  var date: Date {
    Self.calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
  }
}

enum LibraryDateSource: String, Codable, CaseIterable, Identifiable, Sendable {
  case captured, created, modified
  var id: Self { self }
  var title: String { LibrarySearchL10n.text("date.source." + rawValue) }
}

enum LibraryDateRelation: String, Codable, CaseIterable, Identifiable, Sendable {
  case on, between, before, after
  var id: Self { self }
  var title: String { LibrarySearchL10n.text("date.relation." + rawValue) }
}

struct LibraryDateFilter: Codable, Equatable, Sendable {
  var source: LibraryDateSource = .captured
  var relation: LibraryDateRelation = .on
  var start: LibraryCalendarDay = LibraryCalendarDay(Date())
  var end: LibraryCalendarDay = LibraryCalendarDay(Date())

  func matches(_ asset: ImageAsset, calendar: Calendar = LibraryCalendarDay.calendar) -> Bool {
    let candidate: LibraryCalendarDay?
    switch source {
    case .captured:
      candidate = asset.sortMetadata?.capturedDay
        ?? asset.sortMetadata?.capturedAt.map { LibraryCalendarDay($0, calendar: calendar) }
    case .created: candidate = asset.creationDate.map { LibraryCalendarDay($0, calendar: calendar) }
    case .modified: candidate = asset.modificationDate.map { LibraryCalendarDay($0, calendar: calendar) }
    }
    guard let candidate else { return false }
    switch relation {
    case .on: return candidate == start
    case .between: return candidate >= min(start, end) && candidate <= max(start, end)
    case .before: return candidate < start
    case .after: return candidate > start
    }
  }
}

enum LibraryGPSFilter: String, Codable, CaseIterable, Identifiable, Sendable {
  case any, present, absent
  var id: Self { self }
  var title: String { LibrarySearchL10n.text("gps." + rawValue) }
}

struct LibrarySearchFilters: Codable, Equatable, Sendable {
  var metadataText: String = ""
  var locationText: String = ""
  var gps: LibraryGPSFilter = .any
  var minimumBytes: Int64?
  var maximumBytes: Int64?
  var date: LibraryDateFilter?

  var isActive: Bool {
    requiresMetadata || minimumBytes != nil || maximumBytes != nil || date != nil
  }

  var requiresMetadata: Bool {
    !metadataText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !locationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || gps != .any || date?.source == .captured
  }

  func matches(_ asset: ImageAsset, calendar: Calendar = LibraryCalendarDay.calendar) -> Bool {
    LibrarySearchPredicate(filters: self, calendar: calendar).matches(asset)
  }
}

/// Compile text patterns and capture the user's calendar once per collection,
/// rather than rebuilding them for every photograph. Inactive text fields must
/// not assemble EXIF text or format GPS coordinates on a simple filename query.
struct LibrarySearchPredicate: Sendable {
  private let filters: LibrarySearchFilters
  private let calendar: Calendar
  private let metadataMatcher: LibraryTextMatcher
  private let locationMatcher: LibraryTextMatcher

  init(filters: LibrarySearchFilters, calendar: Calendar = LibraryCalendarDay.calendar) {
    self.filters = filters
    self.calendar = calendar
    metadataMatcher = LibraryTextMatcher(pattern: filters.metadataText, anchorsWildcards: false)
    locationMatcher = LibraryTextMatcher(pattern: filters.locationText, anchorsWildcards: false)
  }

  func matches(_ asset: ImageAsset) -> Bool {
    if filters.minimumBytes != nil || filters.maximumBytes != nil {
      guard let bytes = asset.byteCount else { return false }
      if let minimumBytes = filters.minimumBytes, bytes < minimumBytes { return false }
      if let maximumBytes = filters.maximumBytes, bytes > maximumBytes { return false }
    }
    if let date = filters.date, !date.matches(asset, calendar: calendar) { return false }
    let metadata = asset.sortMetadata
    // A refreshed negative lookup is authoritative. The map location on an old
    // asset may predate a replacement file whose GPS tags have been removed.
    let location: ImageLocation?
    if let metadata { location = metadata.embeddedLocation }
    else { location = asset.location }
    if filters.gps == .present && location == nil { return false }
    if filters.gps == .absent && location != nil { return false }
    if !metadataMatcher.isEmpty && !metadataMatcher.matches(
      metadata?.searchableText ?? "") { return false }
    guard !locationMatcher.isEmpty else { return true }
    let locationValue = [metadata?.locationText, location?.coordinateDescription]
      .compactMap { $0 }.joined(separator: "\n")
    return locationMatcher.matches(locationValue)
  }
}

/// '*' and '%' match any number of characters. Plain words retain the original
/// query's AND/substring semantics. A pattern with a wildcard matches the whole filename,
/// so img* means a prefix and *.png means a suffix. No regular expression executes.
struct LibraryTextMatcher: Sendable {
  private let pattern: [Unicode.Scalar]
  private let hasWildcard: Bool
  private let plain: String
  private let plainTerms: [String]

  var isEmpty: Bool { plain.isEmpty }

  init(pattern: String, anchorsWildcards: Bool = true) {
    let normalized = Self.fold(pattern.trimmingCharacters(in: .whitespacesAndNewlines))
      .replacingOccurrences(of: "%", with: "*")
    hasWildcard = normalized.contains("*")
    plain = normalized
    plainTerms = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
    let scoped = !anchorsWildcards && hasWildcard ? "*" + normalized + "*" : normalized
    // Collapsing adjacent stars bounds backtracking for inputs such as ****%*.
    var collapsed: [Unicode.Scalar] = []
    for scalar in scoped.unicodeScalars where scalar != "*" || collapsed.last != "*" {
      collapsed.append(scalar)
    }
    self.pattern = collapsed
  }

  func matches(_ value: String) -> Bool {
    if plain.isEmpty { return true }
    let normalized = Self.fold(value)
    guard hasWildcard else { return plainTerms.allSatisfy { normalized.contains($0) } }
    let input = Array(normalized.unicodeScalars)
    var inputIndex = 0, patternIndex = 0
    var starIndex: Int?, starInputIndex = 0
    while inputIndex < input.count {
      if patternIndex < pattern.count, pattern[patternIndex] == "*" {
        starIndex = patternIndex; patternIndex += 1; starInputIndex = inputIndex
      } else if patternIndex < pattern.count, pattern[patternIndex] == input[inputIndex] {
        inputIndex += 1; patternIndex += 1
      } else if let starIndex {
        starInputIndex += 1; inputIndex = starInputIndex; patternIndex = starIndex + 1
      } else { return false }
    }
    while patternIndex < pattern.count, pattern[patternIndex] == "*" { patternIndex += 1 }
    return patternIndex == pattern.count
  }

  private static func fold(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }
}

/// Decimal megabytes agree with the file-size labels in Finder and this app.
enum LibrarySizeInput {
  static func bytes(_ input: String) -> Int64? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ",", with: ".")
    guard !trimmed.isEmpty, let megabytes = Double(trimmed), megabytes.isFinite, megabytes >= 0 else { return nil }
    let bytes = megabytes * 1_000_000
    guard bytes.isFinite, bytes < Double(Int64.max) else { return nil }
    return Int64(bytes.rounded())
  }

  static func text(_ bytes: Int64?) -> String {
    bytes.map { String(Double($0) / 1_000_000) } ?? ""
  }
}
