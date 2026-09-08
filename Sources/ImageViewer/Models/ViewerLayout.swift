import CoreGraphics
import Foundation

enum PresentationMode: String, CaseIterable, Identifiable, Sendable {
  case viewer
  case overview

  var id: Self { self }

  var title: String {
    switch self {
    case .viewer: L10n.text("뷰어")
    case .overview: L10n.text("전체 보기")
    }
  }
}

enum BaseScaleMode: String, CaseIterable, Identifiable, Sendable {
  case fit
  case actualPixels

  var id: Self { self }

  var title: String {
    switch self {
    case .fit: L10n.text("화면 맞춤")
    case .actualPixels: L10n.text("실제 크기")
    }
  }
}

/// 뷰어 왼쪽 위에 표시하는 파일 이름의 크기와 표시 여부입니다.
///
/// 원시값을 UserDefaults에 저장하므로 사용자가 고른 크기가 다음 실행에도 유지됩니다.
enum FilenameDisplaySize: String, CaseIterable, Codable, Identifiable, Sendable {
  case hidden
  case small
  case medium
  case large
  case extraLarge

  var id: Self { self }

  var title: String {
    switch self {
    case .hidden: L10n.text("숨김")
    case .small: L10n.text("작게")
    case .medium: L10n.text("보통")
    case .large: L10n.text("크게")
    case .extraLarge: L10n.text("매우 크게")
    }
  }

  var isVisible: Bool {
    self != .hidden
  }

  /// 기존 caption보다 기본값부터 크게 보이도록 15pt를 보통 크기로 사용합니다.
  var fontSize: CGFloat {
    switch self {
    case .hidden: 0
    case .small: 12
    case .medium: 15
    case .large: 19
    case .extraLarge: 24
    }
  }

  var horizontalPadding: CGFloat {
    switch self {
    case .hidden: 0
    case .small: 9
    case .medium: 11
    case .large: 13
    case .extraLarge: 15
    }
  }

  var verticalPadding: CGFloat {
    switch self {
    case .hidden: 0
    case .small: 5
    case .medium: 7
    case .large: 9
    case .extraLarge: 11
    }
  }
}

/// 폴더 썸네일을 창의 어느 가장자리에 둘지 나타냅니다.
///
/// 문자열 원시값을 그대로 저장하므로 이후 열거형 순서가 바뀌어도 사용자 설정이
/// 깨지지 않습니다.
enum ThumbnailPanelPlacement: String, CaseIterable, Codable, Identifiable, Sendable {
  case hidden
  case left
  case right
  case top
  case bottom

  var id: Self { self }

  /// 툴바 메뉴에서 사용자가 요청한 빠른 선택 순서를 고정합니다.
  static let quickSelectionOrder: [Self] = [.hidden, .left, .right, .bottom, .top]

  var title: String {
    switch self {
    case .hidden: L10n.text("숨김")
    case .left: L10n.text("왼쪽")
    case .right: L10n.text("오른쪽")
    case .top: L10n.text("위쪽")
    case .bottom: L10n.text("아래쪽")
    }
  }

  var systemImage: String {
    switch self {
    case .hidden: "rectangle"
    case .left: "rectangle.leadingthird.inset.filled"
    case .right: "rectangle.trailingthird.inset.filled"
    case .top: "rectangle.topthird.inset.filled"
    case .bottom: "rectangle.bottomthird.inset.filled"
    }
  }

  var isHorizontal: Bool {
    self == .top || self == .bottom
  }
}

/// 오른쪽 보조 패널은 정보와 편집을 분리해 필요한 도구만 표시합니다.
enum InspectorPanel: String, CaseIterable, Identifiable, Sendable {
  case information
  case editing

  var id: Self { self }

  var title: String {
    switch self {
    case .information: L10n.text("이미지 정보")
    case .editing: L10n.text("이미지 편집")
    }
  }
}

/// AppKit 이벤트 감시기에서 뷰어로 전달하는 포인터 팬 입력입니다.
enum PanInputKind: Sendable {
  case spacePrimaryDrag
  case secondaryDrag
  case middleDrag
  case trackpadScroll
}

/// 확대 이미지를 옮기는 포인터 조작 방식을 사용자가 선택할 수 있게 합니다.
enum PanInteractionMode: String, CaseIterable, Codable, Identifiable, Sendable {
  case primaryDrag
  case spacePrimaryDrag
  case secondaryDrag
  case middleDrag
  case trackpadScroll

  var id: Self { self }

  var title: String {
    switch self {
    case .primaryDrag: L10n.text("왼쪽 버튼 드래그")
    case .spacePrimaryDrag: L10n.text("Space + 왼쪽 드래그")
    case .secondaryDrag: L10n.text("오른쪽 버튼 드래그")
    case .middleDrag: L10n.text("가운데 버튼 드래그")
    case .trackpadScroll: L10n.text("트랙패드 두 손가락 이동")
    }
  }

  var detail: String {
    switch self {
    case .primaryDrag: L10n.text("이미지를 직접 잡아 옮깁니다.")
    case .spacePrimaryDrag: L10n.text("Space를 누른 동안만 왼쪽 버튼으로 옮깁니다.")
    case .secondaryDrag: L10n.text("오른쪽 버튼을 누른 채 이미지를 옮깁니다.")
    case .middleDrag: L10n.text("휠 또는 가운데 버튼을 누른 채 옮깁니다.")
    case .trackpadScroll: L10n.text("확대 중 두 손가락 스크롤로 상하좌우를 이동합니다.")
    }
  }

  func accepts(_ input: PanInputKind) -> Bool {
    switch (self, input) {
    case (.spacePrimaryDrag, .spacePrimaryDrag),
      (.secondaryDrag, .secondaryDrag),
      (.middleDrag, .middleDrag),
      (.trackpadScroll, .trackpadScroll):
      true
    default:
      false
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

/// 단일 보기에는 프레임을 그리지 않고, 여러 이미지를 함께 볼 때만 타일 경계와
/// 현재 이미지 강조를 표시합니다.
enum ViewerTileChrome {
  static func showsBoundary(itemCount: Int) -> Bool {
    itemCount > 1
  }

  static func highlightsSelection(isCurrent: Bool, itemCount: Int) -> Bool {
    showsBoundary(itemCount: itemCount) && isCurrent
  }
}
