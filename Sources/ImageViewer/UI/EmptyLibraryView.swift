import SwiftUI

struct EmptyLibraryView: View {
  @ObservedObject var store: AppStore

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 24)
      VStack(spacing: 24) {
        if store.currentFolderURL != nil {
          VStack(spacing: 8) {
            Text(store.activeFolderName)
              .font(.system(size: 22, weight: .semibold))
              .lineLimit(2).truncationMode(.middle)
            Text("이미지가 없는 폴더입니다.")
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Text("폴더 트리에서 다른 폴더를 선택하거나 파일을 열어 주세요.")
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .multilineTextAlignment(.center)
        }

        Button { store.chooseItems() } label: {
          Label("열기…", systemImage: "folder")
            .font(.system(size: 14, weight: .semibold))
            .frame(minWidth: 140, minHeight: 44)
        }
        .buttonStyle(ViewerActionButtonStyle(prominent: true))
        .controlSize(.large)
      }
      .frame(maxWidth: 550)
      Spacer(minLength: 24)
      VStack(spacing: 12) {
        HStack(spacing: 3) {
          Capsule().fill(ViewerTheme.accent)
          Capsule().fill(Color(red: 0.85, green: 0.68, blue: 0.23))
          Capsule().fill(Color(red: 0.80, green: 0.33, blue: 0.29))
        }
        .frame(width: 28, height: 3)
        .opacity(0.8)
        .accessibilityHidden(true)
        Text("Mac에 꼭 필요한 도구, 누구나 자유롭게.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 420)
      }
      .padding(.bottom, 26)
    }
    .padding(.horizontal, 36)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ViewerTheme.chromeGradient)
  }
}
