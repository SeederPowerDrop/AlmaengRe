import Foundation

/// 폴더 안의 이미지 한 개를 나타내는 가벼운 값 타입입니다.
///
/// 원본 픽셀은 이 모델에 넣지 않습니다. 수천 장을 읽어도 목록 자체가 메모리를
/// 거의 차지하지 않도록 파일 시스템 메타데이터만 보관합니다.
struct ImageAsset: Identifiable, Hashable, Sendable {
  let url: URL
  let byteCount: Int64?
  let modificationDate: Date?
  var creationDate: Date? = nil
  var location: ImageLocation? = nil
  /// Includes a negative GPS lookup so changing a map filter never reopens every file.
  var hasReadLocation = false
  var archiveOrigin: ArchiveImageOrigin? = nil
  /// Captured off the main thread; rendering never reads the file system for marks.
  var photoMarkIdentity: String? = nil
  /// Filled only when sorting by embedded metadata; no decoded pixels are retained.
  var sortMetadata: LibrarySortMetadata? = nil
  var sortMetadataVersion: LibrarySortFileVersion? = nil

  var photoMarkID: String { photoMarkIdentity ?? sessionID }

  var isReadOnly: Bool { archiveOrigin != nil }
  var isVideo: Bool { archiveOrigin == nil && MediaFormatRegistry.isVideo(url) }
  var sessionID: String {
    guard let archiveOrigin else { return url.standardizedFileURL.absoluteString }
    return archiveOrigin.archiveURL.standardizedFileURL.absoluteString + "#" + archiveOrigin.entryPath
  }
  func replacingURL(_ url: URL) -> ImageAsset {
    ImageAsset(url: url, byteCount: byteCount, modificationDate: modificationDate,
      creationDate: creationDate, location: location, hasReadLocation: hasReadLocation,
      archiveOrigin: archiveOrigin, photoMarkIdentity: photoMarkIdentity,
      sortMetadata: sortMetadata, sortMetadataVersion: sortMetadataVersion)
  }

  /// URL은 폴더를 다시 읽어도 안정적으로 같은 파일을 가리키므로 식별자로 씁니다.
  var id: URL { url }

  var filename: String { archiveOrigin.map { ($0.entryPath as NSString).lastPathComponent } ?? url.lastPathComponent }

  var fileExtension: String {
    (filename as NSString).pathExtension.lowercased()
  }

  var formattedFileSize: String {
    guard let byteCount else { return "—" }
    return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
  }
}

/// 현재 파일에서 빠르게 읽어 온 표시용 메타데이터입니다.
struct ImageMetadata: Equatable, Sendable {
  var pixelWidth: Int = 0
  var pixelHeight: Int = 0
  var frameCount: Int = 1
  var bitDepth: Int?
  var colorModel: String?
  var profileName: String?
  var typeIdentifier: String?
  var orientation: Int?
  var hasAlpha: Bool?
  var dpiWidth: Double?
  var dpiHeight: Double?
  var cameraMake: String?
  var cameraModel: String?
  var lensModel: String?
  var imageDescription: String?
  var copyright: String?
  var software: String?
  var artist: String?
  var capturedAt: String?
  var exposureTime: Double?
  var aperture: Double?
  var iso: Int?
  var focalLength: Double?
  var location: ImageLocation?

  var dimensionsDescription: String {
    guard pixelWidth > 0, pixelHeight > 0 else { return L10n.text("크기 확인 중") }
    return "\(pixelWidth) × \(pixelHeight)"
  }
}

/// EXIF GPS 값을 플랫폼 지도 링크로 전달하기 위한 불변 좌표입니다.
struct ImageLocation: Hashable, Codable, Sendable {
  let latitude: Double
  let longitude: Double
  var altitude: Double?
  var direction: Double?

  var coordinateDescription: String {
    String(
      format: "%.6f, %.6f",
      locale: Locale(identifier: "en_US_POSIX"),
      latitude,
      longitude
    )
  }

  func mapURL(for service: MapService) -> URL? {
    var components = URLComponents()

    switch service {
    case .apple:
      // Apple의 Map Links 규격은 maps.apple.com HTTP 링크를 지도 앱으로 전달합니다.
      components.scheme = "http"
      components.host = "maps.apple.com"
      components.path = "/"
      components.queryItems = [
        URLQueryItem(
          name: "ll", value: coordinateDescription.replacingOccurrences(of: " ", with: "")),
        URLQueryItem(name: "q", value: L10n.text("사진 위치")),
      ]
    case .google:
      components.scheme = "https"
      components.host = "www.google.com"
      components.path = "/maps/search/"
      components.queryItems = [
        URLQueryItem(name: "api", value: "1"),
        URLQueryItem(
          name: "query", value: coordinateDescription.replacingOccurrences(of: " ", with: "")),
      ]
    }

    return components.url
  }
}

enum MapService: String, CaseIterable, Identifiable, Sendable {
  case apple
  case google

  var id: Self { self }

  var title: String {
    switch self {
    case .apple: L10n.text("Apple 지도")
    case .google: L10n.text("Google 지도")
    }
  }
}

/// An archive member keeps a stable logical identity while its pixels live in a private cache.
struct ArchiveImageOrigin: Codable, Hashable, Sendable {
  let archiveURL: URL
  let entryPath: String
  private var lease: ArchiveImageLease?
  init(archiveURL: URL, entryPath: String, lease: ArchiveImageLease? = nil) {
    self.archiveURL = archiveURL; self.entryPath = entryPath; self.lease = lease
  }
  private enum CodingKeys: String, CodingKey { case archiveURL, entryPath }
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.archiveURL == rhs.archiveURL && lhs.entryPath == rhs.entryPath
  }
  func hash(into hasher: inout Hasher) { hasher.combine(archiveURL); hasher.combine(entryPath) }
}

/// Copies of an asset retain this lease, so an in-flight render can outlive its opened list.
final class ArchiveImageLease: @unchecked Sendable {
  private static let sharedCleanupQueue = DispatchQueue(
    label: "ImageViewer.archiveCleanup", qos: .utility)
  let directory: URL
  private let cleanupQueue: DispatchQueue

  init(directory: URL, cleanupQueue: DispatchQueue = ArchiveImageLease.sharedCleanupQueue) {
    self.directory = directory
    self.cleanupQueue = cleanupQueue
  }

  deinit {
    // The last asset is often released while the UI replaces its library. Unlinking
    // thousands of extracted files must not run on that thread. Only the path survives
    // the lease; serial cleanup does not retain images or spawn competing disk jobs.
    let directory = directory
    cleanupQueue.async { try? FileManager.default.removeItem(at: directory) }
  }
}
