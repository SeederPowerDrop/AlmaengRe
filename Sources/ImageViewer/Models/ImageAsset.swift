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

  var dimensionsDescription: String {
    guard pixelWidth > 0, pixelHeight > 0 else { return "크기 확인 중" }
    return "\(pixelWidth) × \(pixelHeight)"
  }
}
