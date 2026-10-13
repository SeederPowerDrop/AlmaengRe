import Foundation

enum PhotoMarkCSVExporter {
  struct Strings: Sendable {
    let values: [String: String]

    init(localeIdentifier: String? = nil) {
      let keys = Self.columns + ["available", "unavailable", "unknown", "none"]
      values = Dictionary(uniqueKeysWithValues: keys.map { key in
        (key, localeIdentifier.map { PhotoMarkReportL10n.text("csv.\(key)", localeIdentifier: $0) }
          ?? PhotoMarkReportL10n.text("csv.\(key)"))
      })
    }

    static let columns = ["folder", "filename", "classification", "classifiedAt",
      "previous1", "previous1At", "previous2", "previous2At", "archive", "availability"]
    subscript(_ key: String) -> String { values[key] ?? key }
  }

  /// UTF-8 BOM lets spreadsheet apps recognize Korean names without an import
  /// wizard. Quote every field, preserving commas, quotes and embedded newlines.
  static func data(for records: [PhotoMarkClassificationRecord], strings: Strings = Strings(),
    timeZone: TimeZone = .current) -> Data {
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.timeZone = timeZone
    dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func timestamp(_ date: Date?) -> String { date.map(dateFormatter.string(from:)) ?? strings["unknown"] }
    func description(_ state: PhotoMarkClassificationState?) -> String {
      guard let state else { return strings["unknown"] }
      guard !state.marks.isEmpty else { return strings["none"] }
      return PhotoMarkSlot.allCases.filter { state.marks.contains($0) }.map { slot in
        let name = state.labels[slot] ?? slot.defaultLabel
        return name.isEmpty ? slot.keyLabel : "\(slot.keyLabel) · \(name)"
      }.joined(separator: "; ")
    }
    var output = Data([0xEF, 0xBB, 0xBF])
    func append(_ fields: [String]) {
      output.append(Data((fields.map(escaped).joined(separator: ",") + "\r\n").utf8))
    }
    append(Strings.columns.map { strings[$0] })
    for record in records {
      let first = record.previous.first
      let second = record.previous.dropFirst().first
      let filename = record.archiveEntryPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        ?? record.sourceURL?.lastPathComponent ?? strings["unknown"]
      // For archive entries the folder column includes the archive's full path;
      // the internal path remains a separate, unambiguous column.
      let folder = record.sourceURL.map {
        record.archiveEntryPath == nil ? $0.deletingLastPathComponent().path : $0.path
      } ?? strings["unknown"]
      append([folder, filename, description(record.current), timestamp(record.current.changedAt),
        description(first), timestamp(first?.changedAt), description(second), timestamp(second?.changedAt),
        record.archiveEntryPath ?? "", strings[record.isUnavailable ? "unavailable" : "available"]])
    }
    return output
  }

  private static func escaped(_ value: String) -> String {
    // A filename or user-defined label must remain text when opened in Excel.
    let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let needsTextPrefix = candidate.first.map { "=+-@".contains($0) } == true
      || value.first.map { $0 == "\t" || $0 == "\r" || $0 == "\n" } == true
    let safeValue = (needsTextPrefix ? "'" : "") + value
    return "\"" + safeValue.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
