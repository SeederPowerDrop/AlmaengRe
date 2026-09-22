import SwiftUI

/// 사진의 색을 판단하는 캔버스와 macOS의 밝고 어두운 작업 영역을 구분합니다.
/// 패널은 시스템 색을 사용하므로 접근성 대비·시스템 외관과 함께 바뀝니다.
enum ViewerTheme {
  static let canvas = Color(white: 0.105)
  static let chrome = Color(nsColor: .windowBackgroundColor)
  static let panel = Color(nsColor: .controlBackgroundColor)
  static let sidebar = Color(nsColor: .underPageBackgroundColor)
  static let separator = Color.primary.opacity(0.10)
  static let accent = Color(red: 0.22, green: 0.46, blue: 0.82)
  static let selection = accent.opacity(0.10)
}

/// 보기 조작부의 동일한 타깃 크기와 선택 상태를 유지합니다.
struct ViewerToolButtonStyle: ButtonStyle {
  var isSelected = false
  func makeBody(configuration: Configuration) -> some View {
    ToolBody(configuration: configuration, isSelected: isSelected)
  }

  private struct ToolBody: View {
    let configuration: Configuration
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
      configuration.label
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 9)
        .frame(minWidth: 30, minHeight: 28)
        .foregroundStyle(isSelected ? ViewerTheme.accent : Color.primary)
        .background(
          isSelected ? ViewerTheme.selection
            : Color.primary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.06 : 0),
          in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovered = $0 }
    }
  }
}
