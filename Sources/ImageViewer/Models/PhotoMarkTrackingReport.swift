import Foundation

/// Historical observations, not deletion claims. An unavailable file may simply
/// live on an unmounted disk or behind permissions that are no longer granted.
struct PhotoMarkTrackingReport: Codable, Identifiable, Sendable, Equatable {
  enum Event: String, Codable, Sendable { case unavailable, relocated, recovered }

  let id: UUID
  let observedAt: Date
  let event: Event
  let assetID: String
  let previousURL: URL?
  let currentURL: URL?
  let archiveEntryPath: String?
  let slots: [PhotoMarkSlot]
  let labels: [PhotoMarkSlot: String]

  var filename: String {
    if let archiveEntryPath { return URL(fileURLWithPath: archiveEntryPath).lastPathComponent }
    return (currentURL ?? previousURL)?.lastPathComponent ?? PhotoMarkReportL10n.text("unknownFile")
  }

  var classificationDescription: String {
    slots.map { slot in
      let name = labels[slot] ?? slot.defaultLabel
      return name.isEmpty ? slot.keyLabel : "\(slot.keyLabel) · \(name)"
    }.joined(separator: ", ")
  }
}
