import AppKit

/// 번호 배지와 실제 aspect-fit 이미지의 면적을 비교합니다. 원본을 별도로 읽지
/// 않고, 이미 디코딩된 썸네일의 크기를 사용하므로 대용량 폴더에도 부담이 작습니다.
enum OverviewNumberPlacement {
  static func fittedImageSize(pixels: CGSize?, in bounds: CGSize) -> CGSize? {
    guard let pixels, pixels.width.isFinite, pixels.height.isFinite,
      pixels.width > 0, pixels.height > 0, bounds.width.isFinite, bounds.height.isFinite,
      bounds.width > 0, bounds.height > 0 else { return nil }
    let scale = min(bounds.width / pixels.width, bounds.height / pixels.height)
    return CGSize(width: pixels.width * scale, height: pixels.height * scale)
  }

  static func isOutside(badge: CGSize, image: CGSize?) -> Bool {
    // 로딩 중에는 사진을 가리지 않는 위치를 먼저 사용합니다.
    guard let image, image.width > 0, image.height > 0 else { return true }
    return badge.width * badge.height >= image.width * image.height * 0.25
      || badge.width + 12 > image.width || badge.height + 12 > image.height
  }
}

enum OverviewSelectionOperation: Sendable {
  case replace, add, toggle

  init(modifiers: NSEvent.ModifierFlags) {
    self = modifiers.contains(.command) ? .toggle : modifiers.contains(.shift) ? .add : .replace
  }

  func applying(hits: Set<URL>, to baseline: Set<URL>) -> Set<URL> {
    switch self {
    case .replace: hits
    case .add: baseline.union(hits)
    // 매 이벤트마다 현재 선택을 뒤집지 않고 드래그 시작 시점과 비교합니다.
    case .toggle: baseline.symmetricDifference(hits)
    }
  }
}

/// 시작 시점의 선택과 라이브러리 세대를 고정해 폴더 변경 뒤 늦은 이벤트를 무시합니다.
struct OverviewSelectionSession {
  let id = UUID()
  let libraryRevision: UUID
  let baseline: Set<URL>
  let allowedURLs: Set<URL>
  let operation: OverviewSelectionOperation
}

enum OverviewMarqueeGeometry {
  static func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
    CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
      width: abs(end.x - start.x), height: abs(end.y - start.y))
  }

  static func hits(in rectangle: CGRect, frames: [URL: CGRect]) -> Set<URL> {
    guard rectangle.width > 0, rectangle.height > 0 else { return [] }
    return Set(frames.compactMap { url, frame in
      let overlap = rectangle.intersection(frame)
      return !overlap.isNull && overlap.width > 0 && overlap.height > 0 ? url : nil
    })
  }
}
