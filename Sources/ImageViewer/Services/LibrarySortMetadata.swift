@preconcurrency import AVFoundation
import Darwin
import Foundation
import ImageIO

/// Small, display-oriented values shared by image, overview and comparison queries.
struct LibrarySortMetadata: Hashable, Sendable {
  var pixelWidth: Int?
  var pixelHeight: Int?
  var capturedAt: Date?
  var exposureTime: Double?
  var cameraMake: String?
  var cameraModel: String?
  var aperture: Double?
  var colorSpace: String?
  var capturedDay: LibraryCalendarDay?
  var embeddedLocation: ImageLocation?
  var locationText: String?
  var additionalSearchText: String?

  var searchableText: String {
    [cameraMake, cameraModel, colorSpace, additionalSearchText,
      pixelWidth.map { "Width \($0)" }, pixelHeight.map { "Height \($0)" },
      exposureTime.map { "ExposureTime \($0)" }, aperture.map { "FNumber \($0)" }]
      .compactMap { $0 }.joined(separator: "\n")
  }
}

/// Includes identity and nanosecond change time so replacing a file at the same
/// URL/size/mtime does not reuse its predecessor's embedded metadata.
struct LibrarySortFileVersion: Hashable, Sendable {
  let url: URL
  private let signature: String?

  init(url: URL) {
    self.url = url.standardizedFileURL
    var info = stat()
    let status = self.url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return fstatat(AT_FDCWD, path, &info, 0)
    }
    signature = status == 0 ? "\(info.st_dev):\(info.st_ino):\(info.st_size):"
      + "\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec):"
      + "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):"
      + "\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)" : nil
  }
}

/// Cross-library positive and negative cache. The fallback queue is serial;
/// callers with an app governor use its shared I/O budget instead.
actor LibrarySortMetadataCache {
  static let shared = LibrarySortMetadataCache()
  typealias Reader = @Sendable (URL, Bool) async throws -> LibrarySortMetadata
  private let namespace = UUID()
  private var values: ImageCostCache<LibrarySortFileVersion, LibrarySortMetadata>
  private let scheduler = ImageWorkScheduler<LibrarySortFileVersion, LibrarySortMetadata>(maxConcurrentTasks: 1)
  private let reader: Reader

  init(maximumEntries: Int = 4_096, reader: @escaping Reader = LibrarySortMetadataReader.read) {
    values = ImageCostCache(costLimit: maximumEntries)
    self.reader = reader
  }

  func metadata(for version: LibrarySortFileVersion, isVideo: Bool,
    governor: ImageResourceGovernor? = nil
  ) async throws -> LibrarySortMetadata {
    try Task.checkCancellation()
    if let value = values.value(for: version) { return value }
    let reader = reader
    let operation: @Sendable (Int) async throws -> LibrarySortMetadata = { _ in
      try Task.checkCancellation()
      let result = try await reader(version.url, isVideo)
      try Task.checkCancellation()
      return result
    }
    let result: LibrarySortMetadata
    if let governor {
      result = try await governor.value(
        for: ImageResourceWorkKey(namespace: namespace, key: version), url: version.url,
        workload: LibrarySortMetadataReader.workload(for: version.url, isVideo: isVideo),
        operation: operation)
    } else {
      result = try await scheduler.value(for: version, operation: operation)
    }
    try Task.checkCancellation()
    if LibrarySortFileVersion(url: version.url) == version {
      values.insert(result, for: version, cost: 1)
    }
    return result
  }
}

enum LibrarySortMetadataReader {
  static func workload(for url: URL, isVideo: Bool) -> ImageResourceWorkload {
    isVideo || MediaFormatRegistry.isAudio(url) ? .source : .metadataHeader
  }

  static func read(_ url: URL, isVideo: Bool) async throws -> LibrarySortMetadata {
    try Task.checkCancellation()
    if workload(for: url, isVideo: isVideo) == .source {
      return try await SortPlaybackMetadataRequest(url: url).value()
    }
    let result = autoreleasepool {
      if let source = CGImageSourceCreateWithURL(url as CFURL,
          [kCGImageSourceShouldCache: false] as CFDictionary),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
        return imageMetadata(properties)
      }
      return customHeaderMetadata(url)
    }
    try Task.checkCancellation()
    return result
  }

  static func imageMetadata(_ properties: [CFString: Any]) -> LibrarySortMetadata {
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    var width = positiveInteger(properties[kCGImagePropertyPixelWidth])
    var height = positiveInteger(properties[kCGImagePropertyPixelHeight])
    if [5, 6, 7, 8].contains((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) {
      swap(&width, &height)
    }
    let originalDate = exif[kCGImagePropertyExifDateTimeOriginal] as? String
    let digitizedDate = exif[kCGImagePropertyExifDateTimeDigitized] as? String
    let originalCapturedAt = capturedDate(originalDate,
      offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String,
      subsecond: exif[kCGImagePropertyExifSubsecTimeOriginal] as? String)
    let capturedAt = originalCapturedAt
      ?? capturedDate(digitizedDate,
        offset: exif[kCGImagePropertyExifOffsetTimeDigitized] as? String,
        subsecond: exif[kCGImagePropertyExifSubsecTimeDigitized] as? String)
    let capturedDay = capturedAt == nil ? nil
      : LibraryCalendarDay(metadataString: originalCapturedAt != nil ? originalDate : digitizedDate)
    let exifSpace = (exif[kCGImagePropertyExifColorSpace] as? NSNumber)?.intValue
    let colorSpace = boundedText(properties[kCGImagePropertyProfileName] as? String)
      ?? (exifSpace == 1 ? "sRGB" : nil)
    return LibrarySortMetadata(pixelWidth: width, pixelHeight: height, capturedAt: capturedAt,
      exposureTime: positiveNumber(exif[kCGImagePropertyExifExposureTime]),
      cameraMake: boundedText(tiff[kCGImagePropertyTIFFMake] as? String),
      cameraModel: boundedText(tiff[kCGImagePropertyTIFFModel] as? String),
      aperture: positiveNumber(exif[kCGImagePropertyExifFNumber]), colorSpace: colorSpace,
      capturedDay: capturedDay, embeddedLocation: imageLocation(properties),
      locationText: embeddedPlaceNames(properties), additionalSearchText: searchableProperties(properties))
  }

  private static func imageLocation(_ properties: [CFString: Any]) -> ImageLocation? {
    guard let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
      let latitude = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
      let longitude = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue,
      latitude.isFinite, longitude.isFinite, (0...90).contains(latitude), (0...180).contains(longitude),
      let northSouth = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased(),
      let eastWest = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased(),
      ["N", "S"].contains(northSouth), ["E", "W"].contains(eastWest) else { return nil }
    return ImageLocation(latitude: northSouth == "S" ? -latitude : latitude,
      longitude: eastWest == "W" ? -longitude : longitude)
  }

  private static func embeddedPlaceNames(_ properties: [CFString: Any]) -> String? {
    guard let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] else { return nil }
    let keys = [kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCCity,
      kCGImagePropertyIPTCProvinceState, kCGImagePropertyIPTCCountryPrimaryLocationName,
      kCGImagePropertyIPTCCountryPrimaryLocationCode]
    let result = keys.compactMap { boundedText(iptc[$0] as? String) }.joined(separator: "\n")
    return result.isEmpty ? nil : result
  }

  /// Bounded scalar tags only; skip binary blobs, thumbnails and decoded pixels.
  /// Keeping tag names makes values such as ISO, lens, keywords and descriptions
  /// searchable without maintaining a second metadata decoder.
  static func searchableProperties(_ properties: [CFString: Any]) -> String? {
    var lines: [String] = [], remaining = 8_192, visited = 0
    func append(_ key: String, _ value: String) {
      guard remaining > 0 else { return }
      let text = String((key + " " + value).prefix(min(remaining, 512)))
      lines.append(text); remaining -= text.count + 1
    }
    func walk(_ value: Any, key: String, depth: Int) {
      guard depth <= 3, remaining > 0, visited < 256 else { return }
      visited += 1
      if let string = value as? String { append(key, string) }
      else if let number = value as? NSNumber { append(key, number.stringValue) }
      else if let dictionary = value as? [String: Any] {
        for child in dictionary.keys.sorted() { walk(dictionary[child]!, key: child, depth: depth + 1) }
      } else if let array = value as? [Any] {
        for child in array.prefix(32) { walk(child, key: key, depth: depth + 1) }
      }
    }
    for key in properties.keys.sorted(by: { ($0 as String) < ($1 as String) }) {
      walk(properties[key]!, key: key as String, depth: 0)
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }

  /// EXIF has no timezone unless its offset tag is present. Floating EXIF dates
  /// use UTC consistently so changing the Mac's timezone cannot reorder a library.
  static func capturedDate(_ value: String?, offset: String?, subsecond: String? = nil) -> Date? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      value.count == 19 else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.isLenient = false
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    guard let naive = formatter.date(from: value), formatter.string(from: naive) == value else { return nil }
    let digits = subsecond?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let fraction = !digits.isEmpty && digits.utf8.allSatisfy({ (48...57).contains($0) })
      ? Double("0." + digits.prefix(9)) ?? 0 : 0
    let date = naive.addingTimeInterval(fraction)
    guard let offset = offset?.trimmingCharacters(in: .whitespacesAndNewlines), !offset.isEmpty else { return date }
    let bytes = Array(offset.utf8)
    guard bytes.count == 6, bytes[0] == 43 || bytes[0] == 45, bytes[3] == 58,
      bytes[1...2].allSatisfy({ (48...57).contains($0) }),
      bytes[4...5].allSatisfy({ (48...57).contains($0) }) else { return nil }
    let hours = Int(bytes[1] - 48) * 10 + Int(bytes[2] - 48)
    let minutes = Int(bytes[4] - 48) * 10 + Int(bytes[5] - 48)
    guard hours <= 14, minutes < 60, hours < 14 || minutes == 0 else { return nil }
    let seconds = (hours * 3_600 + minutes * 60) * (bytes[0] == 45 ? -1 : 1)
    return date.addingTimeInterval(-Double(seconds))
  }

  static func boundedText(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return String(value.prefix(256))
  }

  private static func positiveNumber(_ value: Any?) -> Double? {
    guard let number = (value as? NSNumber)?.doubleValue, number.isFinite, number > 0 else { return nil }
    return number
  }

  private static func positiveInteger(_ value: Any?) -> Int? {
    guard let number = positiveNumber(value), number < Double(Int.max) else { return nil }
    return Int(number)
  }

  /// Formats decoded by the Rust raster path still expose dimensions using only
  /// their fixed headers; sorting never reads a full bitmap into memory.
  private static func customHeaderMetadata(_ url: URL) -> LibrarySortMetadata {
    guard ["qoi", "pcx"].contains(url.pathExtension.lowercased()),
      let handle = try? FileHandle(forReadingFrom: url) else { return LibrarySortMetadata() }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 128) else { return LibrarySortMetadata() }
    let bytes = Array(data)
    if bytes.count >= 14, Array(bytes.prefix(4)) == Array("qoif".utf8) {
      let width = bytes[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      let height = bytes[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      guard width > 0, height > 0, [3, 4].contains(bytes[12]), bytes[13] <= 1 else { return LibrarySortMetadata() }
      return LibrarySortMetadata(pixelWidth: Int(width), pixelHeight: Int(height),
        colorSpace: bytes[13] == 1 ? "Linear sRGB" : "sRGB")
    }
    if bytes.count >= 128, bytes[0] == 0x0a {
      func little(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
      let width = little(8) - little(4) + 1
      let height = little(10) - little(6) + 1
      if width > 0, height > 0 { return LibrarySortMetadata(pixelWidth: width, pixelHeight: height) }
    }
    return LibrarySortMetadata()
  }
}

private final class SortPlaybackMetadataRequest: @unchecked Sendable {
  private let asset: AVURLAsset
  init(url: URL) { asset = AVURLAsset(url: url) }

  func value() async throws -> LibrarySortMetadata {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      var result = LibrarySortMetadata()
      if let track = try? await asset.loadTracks(withMediaType: .video).first,
        let (naturalSize, transform) = try? await track.load(.naturalSize, .preferredTransform) {
        let size = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized.size
        if size.width.isFinite, size.height.isFinite,
          size.width >= 1, size.height >= 1,
          size.width < CGFloat(Int.max), size.height < CGFloat(Int.max) {
          result.pixelWidth = Int(size.width.rounded())
          result.pixelHeight = Int(size.height.rounded())
        }
        if let formats = try? await track.load(.formatDescriptions), let format = formats.first {
          let primaries = CMFormatDescriptionGetExtension(format,
            extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
          let transfer = CMFormatDescriptionGetExtension(format,
            extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
          if let primaries = LibrarySortMetadataReader.boundedText(primaries) {
            result.colorSpace = LibrarySortMetadataReader.boundedText(
              [primaries, transfer].compactMap { $0 }.joined(separator: " / "))
          }
        }
      }
      try Task.checkCancellation()
      if let item = try? await asset.load(.creationDate) {
        result.capturedAt = try? await item.load(.dateValue)
        result.capturedDay = LibraryCalendarDay(metadataString: try? await item.load(.stringValue))
      }
      // Native container make/model tags may exist, but photo-only EXIF values
      // (shutter and aperture) are deliberately left unknown for video and audio.
      if let items = try? await asset.load(.metadata) {
        for (identifier, isMake) in [(AVMetadataIdentifier.quickTimeMetadataMake, true),
          (AVMetadataIdentifier.quickTimeMetadataModel, false)] {
          if let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first {
            let value = LibrarySortMetadataReader.boundedText(try? await item.load(.stringValue))
            if isMake { result.cameraMake = value } else { result.cameraModel = value }
          }
        }
        var searchable: [String] = [], places: [String] = [], remaining = 8_192
        for item in items.prefix(128) {
          try Task.checkCancellation()
          guard remaining > 0 else { break }
          guard let value = LibrarySortMetadataReader.boundedText(try? await item.load(.stringValue)) else { continue }
          let identifier = item.identifier?.rawValue ?? ""
          let line = String((identifier + " " + value).prefix(remaining))
          searchable.append(line); remaining -= line.count + 1
          if identifier.lowercased().contains("location") { places.append(value) }
        }
        result.additionalSearchText = searchable.isEmpty ? nil : searchable.joined(separator: "\n")
        result.locationText = places.isEmpty ? nil : places.joined(separator: "\n")
        if let location = AVMetadataItem.metadataItems(from: items,
          filteredByIdentifier: .quickTimeMetadataLocationISO6709).first,
          let value = try? await location.load(.stringValue) {
          result.embeddedLocation = LibrarySortMetadataReader.iso6709Location(value)
        }
      }
      try Task.checkCancellation()
      return result
    } onCancel: {
      self.asset.cancelLoading()
    }
  }
}

extension LibrarySortMetadataReader {
  static func iso6709Location(_ value: String) -> ImageLocation? {
    // Decimal-degree QuickTime GPS tags: +37.5665+126.9780+010.0/.
    let pattern = #"^([+-][0-9]{2}(?:\.[0-9]+)?)([+-][0-9]{3}(?:\.[0-9]+)?)(?:[+-][0-9]+(?:\.[0-9]+)?)?/?$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
      let latitudeRange = Range(match.range(at: 1), in: value),
      let longitudeRange = Range(match.range(at: 2), in: value),
      let latitude = Double(value[latitudeRange]), let longitude = Double(value[longitudeRange]),
      (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
    return ImageLocation(latitude: latitude, longitude: longitude)
  }
}
