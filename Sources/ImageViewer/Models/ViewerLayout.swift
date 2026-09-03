import CoreGraphics
import Foundation

enum PresentationMode: String, CaseIterable, Identifiable, Sendable {
  case viewer
  case overview

  var id: Self { self }

  var title: String {
    switch self {
    case .viewer: "뷰어"
    case .overview: "전체 보기"
    }
  }
}

enum BaseScaleMode: String, CaseIterable, Identifiable, Sendable {
  case fit
  case actualPixels

  var id: Self { self }

  var title: String {
    switch self {
    case .fit: "화면 맞춤"
    case .actualPixels: "실제 크기"
    }
  }
}

/// 1~10개의 이미지를 창 비율에 맞춰 균형 있게 배치합니다.
enum ViewerGridLayout {
  static func columnCount(itemCount: Int, containerSize: CGSize) -> Int {
    guard itemCount > 1 else { return 1 }

    let safeHeight = max(containerSize.height, 1)
    let aspectRatio = max(0.5, min(2.5, containerSize.width / safeHeight))
    let suggested = Int(ceil(sqrt(Double(itemCount) * aspectRatio)))
    return max(1, min(itemCount, suggested))
  }
}
