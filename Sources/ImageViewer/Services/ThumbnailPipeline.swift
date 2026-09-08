import Foundation
import QuickLookThumbnailing

enum ThumbnailPipelineError: LocalizedError {
  case generationFailed(URL)

  var errorDescription: String? {
    switch self {
    case .generationFailed(let url):
      L10n.format("‘%@’의 빠른 미리보기를 만들지 못했습니다.", url.lastPathComponent)
    }
  }
}

private final class ThumbnailImageBox: NSObject {
  let image: CGImage

  init(_ image: CGImage) {
    self.image = image
  }
}

private struct GeneratedThumbnail: @unchecked Sendable {
  let image: CGImage
}

/// 경로뿐 아니라 파일 버전 정보도 포함해 같은 위치의 이미지가 교체됐을 때
/// 앱 메모리 캐시에서 예전 썸네일을 반환하지 않게 합니다.
struct ThumbnailCacheKey: Hashable, Sendable {
  let fileURL: URL
  let byteCount: Int64?
  let modificationDate: Date?
  let pixelSize: Int

  init(asset: ImageAsset, pixelSize: Int) {
    fileURL = asset.url.standardizedFileURL
    byteCount = asset.byteCount
    modificationDate = asset.modificationDate
    self.pixelSize = pixelSize
  }

  var encoded: NSString {
    let sizePart = byteCount.map(String.init) ?? "unknown"
    let datePart =
      modificationDate.map {
        String($0.timeIntervalSinceReferenceDate.bitPattern)
      } ?? "unknown"
    return "\(fileURL.absoluteString)|\(sizePart)|\(datePart)|\(pixelSize)" as NSString
  }
}

/// macOS의 디스크 썸네일 캐시를 이용하는 가벼운 미리보기 전용 파이프라인입니다.
///
/// 목록과 대용량 RAW의 첫 화면은 Quick Look 결과로 즉시 채우고, 뷰어 타일은 뒤에서
/// ImagePipeline의 색상 관리 결과로 교체합니다. 앱에 별도 코덱을 포함하지 않으므로
/// 실행 파일 크기를 늘리지 않으면서 Finder와 같은 캐시 이점을 얻습니다.
actor ThumbnailPipeline {
  private let cache = NSCache<NSString, ThumbnailImageBox>()

  init() {
    cache.totalCostLimit = 128 * 1_024 * 1_024
    cache.countLimit = 1_024
  }

  func thumbnail(for asset: ImageAsset, maxPixelSize: Int) async throws -> CGImage {
    let url = asset.url
    // 앱 자체 디코더 형식에는 Quick Look 생성기가 없으므로 실패 응답을 기다리지 않습니다.
    if url.pathExtension.lowercased() == "qoi" || url.pathExtension.lowercased() == "pcx" {
      throw ThumbnailPipelineError.generationFailed(url)
    }

    let pixelSize = Self.pixelBucket(maxPixelSize)
    let key = ThumbnailCacheKey(asset: asset, pixelSize: pixelSize).encoded
    if let cached = cache.object(forKey: key) {
      return cached.image
    }

    try Task.checkCancellation()
    // 2x로 요청하면 Retina와 외장 1x 화면 모두에서 같은 캐시 키와 충분한 선명도를 얻습니다.
    let scale: CGFloat = 2
    let pointSize = CGFloat(pixelSize) / scale
    let request = QLThumbnailGenerator.Request(
      fileAt: url,
      size: CGSize(width: pointSize, height: pointSize),
      scale: scale,
      representationTypes: .thumbnail
    )

    let generated: GeneratedThumbnail = try await withCheckedThrowingContinuation {
      continuation in
      QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
        representation, error in
        if let image = representation?.cgImage {
          continuation.resume(returning: GeneratedThumbnail(image: image))
        } else {
          continuation.resume(throwing: error ?? ThumbnailPipelineError.generationFailed(url))
        }
      }
    }
    try Task.checkCancellation()

    let image = generated.image
    cache.setObject(
      ThumbnailImageBox(image),
      forKey: key,
      cost: image.bytesPerRow * image.height
    )
    return image
  }

  func purgeCache() {
    cache.removeAllObjects()
  }

  private static func pixelBucket(_ value: Int) -> Int {
    let clamped = min(4_096, max(96, value))
    return ((clamped + 127) / 128) * 128
  }
}
