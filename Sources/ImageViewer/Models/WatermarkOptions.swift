import Foundation

enum WatermarkMetadataField: String, CaseIterable, Codable, Identifiable, Sendable {
  case captureDate, cameraMake, cameraModel, lens, shutterSpeed, aperture, iso, focalLength, filename
  var id: Self { self }
  var title: String { WatermarkL10n.text("field.\(rawValue)") }
}

enum WatermarkPosition: String, CaseIterable, Codable, Identifiable, Sendable {
  case topLeading, top, topTrailing, leading, center, trailing, bottomLeading, bottom, bottomTrailing
  var id: Self { self }
}

enum WatermarkColor: String, CaseIterable, Codable, Identifiable, Sendable {
  case white, black
  var id: Self { self }
}

enum WatermarkReadability: String, CaseIterable, Codable, Identifiable, Sendable {
  case none, shadow, background
  var id: Self { self }
}

/// A watermark belongs to an exported copy, never to the source pixels or metadata.
/// Its block contains an optional proportional logo above text and selected EXIF lines.
/// Dimensions refer to the final image, after its crop, rotation, and resize.
struct WatermarkOptions: Equatable, Codable, Sendable {
  var isEnabled = false
  var text = ""
  var fontPostScriptName = "Helvetica"
  var metadataFields: Set<WatermarkMetadataField> = []
  var logoURL: URL?
  var position: WatermarkPosition = .bottomTrailing
  /// Normalized overlay center, measured from the resized original's top-left.
  /// A custom center takes precedence over the preset and its margin.
  var customPosition: WatermarkPoint?
  var expandsCanvas = false
  /// Logo long-edge fraction. Text uses this fraction times image width / 8;
  /// adding text or EXIF never changes the font size of existing lines.
  var sizeFraction = 0.25
  /// Inset on each edge as a fraction of the shorter output dimension.
  var marginFraction = 0.03
  var opacity = 0.75
  var textColor: WatermarkColor = .white
  var readability: WatermarkReadability = .shadow

  static let disabled = WatermarkOptions()

  var hasContent: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !metadataFields.isEmpty || logoURL != nil
  }

  /// Validate persisted settings as well as values assembled by the editor.
  func validate() throws {
    guard sizeFraction.isFinite, (0.02...0.9).contains(sizeFraction),
      marginFraction.isFinite, (0...0.2).contains(marginFraction),
      opacity.isFinite, (0...1).contains(opacity),
      text.utf16.count <= 2_000, text.components(separatedBy: .newlines).count <= 20,
      !fontPostScriptName.isEmpty, fontPostScriptName.utf16.count <= 256,
      !fontPostScriptName.contains("\0"), logoURL == nil || logoURL?.isFileURL == true
    else { throw WatermarkError.invalidOptions }
    if let customPosition {
      guard customPosition.x.isFinite, customPosition.y.isFinite,
        (-4...5).contains(customPosition.x), (-4...5).contains(customPosition.y)
      else { throw WatermarkError.invalidOptions }
    }
  }
}

extension WatermarkOptions {
  private enum CodingKeys: String, CodingKey {
    case isEnabled, text, fontPostScriptName, metadataFields, logoURL, position
    case customPosition, expandsCanvas
    case sizeFraction, marginFraction, opacity, textColor, readability
  }

  init(from decoder: Decoder) throws {
    self.init()
    let values = try decoder.container(keyedBy: CodingKeys.self)
    isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
    text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
    fontPostScriptName = try values.decodeIfPresent(String.self, forKey: .fontPostScriptName) ?? "Helvetica"
    metadataFields = try values.decodeIfPresent(Set<WatermarkMetadataField>.self, forKey: .metadataFields) ?? []
    logoURL = try values.decodeIfPresent(URL.self, forKey: .logoURL)
    position = try values.decodeIfPresent(WatermarkPosition.self, forKey: .position) ?? .bottomTrailing
    customPosition = try values.decodeIfPresent(WatermarkPoint.self, forKey: .customPosition)
    expandsCanvas = try values.decodeIfPresent(Bool.self, forKey: .expandsCanvas) ?? false
    sizeFraction = try values.decodeIfPresent(Double.self, forKey: .sizeFraction) ?? 0.25
    marginFraction = try values.decodeIfPresent(Double.self, forKey: .marginFraction) ?? 0.03
    opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.75
    textColor = try values.decodeIfPresent(WatermarkColor.self, forKey: .textColor) ?? .white
    readability = try values.decodeIfPresent(WatermarkReadability.self, forKey: .readability) ?? .shadow
    try validate()
  }
}

enum WatermarkError: LocalizedError, Equatable {
  case invalidOptions, logoUnreadable, renderFailed, sourceMetadataUnreadable
  case contentOverflow(fittingScale: Double)
  case unsafeCanvas

  var errorDescription: String? {
    switch self {
    case .invalidOptions: WatermarkL10n.text("error.invalidOptions")
    case .logoUnreadable: WatermarkL10n.text("error.logoUnreadable")
    case .renderFailed: WatermarkL10n.text("error.renderFailed")
    case .sourceMetadataUnreadable: WatermarkL10n.text("error.sourceMetadataUnreadable")
    case .contentOverflow: WatermarkL10n.text("error.contentOverflow")
    case .unsafeCanvas: WatermarkL10n.text("error.unsafeCanvas")
    }
  }
}
