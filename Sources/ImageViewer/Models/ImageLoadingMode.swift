import Foundation

/// Persist the raw value so changing the order or translation keeps the preference.
enum ImageLoadingMode: String, CaseIterable, Identifiable, Sendable {
  case priority
  case comfortable
  case normal
  case slow

  static let defaultMode: Self = .comfortable

  var id: Self { self }

  var title: String {
    switch self {
    case .priority: L10n.text("최우선")
    case .comfortable: L10n.text("쾌적")
    case .normal: L10n.text("로딩 모드 일반")
    case .slow: L10n.text("느림")
    }
  }

  var detail: String {
    switch self {
    case .priority: L10n.text("현재 사진을 더 빠르게 표시하도록 자원을 적극적으로 사용합니다.")
    case .comfortable: L10n.text("다른 앱과 함께 사용하기 좋도록 사진 로딩과 시스템 여유를 조절합니다.")
    case .normal: L10n.text("동시에 처리하는 사진과 미리 읽기를 줄여 자원 사용을 낮춥니다.")
    case .slow: L10n.text("사진을 한 장씩 처리하고 미리 읽기를 멈춰 자원 사용을 최소화합니다.")
    }
  }
}
