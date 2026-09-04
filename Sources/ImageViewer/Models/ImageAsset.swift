import Foundation

/// 폴더 안의 이미지 한 개를 나타내는 가벼운 값 타입입니다.
///
/// 원본 픽셀은 이 모델에 넣지 않습니다. 수천 장을 읽어도 목록 자체가 메모리를
/// 거의 차지하지 않도록 파일 시스템 메타데이터만 보관합니다.
struct ImageAsset: Identifiable, Hashable, Sendable {
  let url: URL
  let byteCount: Int64?
  let modificationDate: Date?

  /// URL은 폴더를 다시 읽어도 안정적으로 같은 파일을 가리키므로 식별자로 씁니다.
  var id: URL { url }

  var filename: String { url.lastPathComponent }

  var fileExtension: String {
    url.pathExtension.lowercased()
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
  var software: String?
  var artist: String?
  var capturedAt: String?
  var exposureTime: Double?
  var aperture: Double?
  var iso: Int?
  var focalLength: Double?
  var location: ImageLocation?

  var dimensionsDescription: String {
    guard pixelWidth > 0, pixelHeight > 0 else { return "크기 확인 중" }
    return "\(pixelWidth) × \(pixelHeight)"
  }
}

/// EXIF GPS 값을 플랫폼 지도 링크로 전달하기 위한 불변 좌표입니다.
struct ImageLocation: Equatable, Sendable {
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
        URLQueryItem(name: "q", value: "사진 위치"),
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
    case .apple: "Apple 지도"
    case .google: "Google 지도"
    }
  }
}
