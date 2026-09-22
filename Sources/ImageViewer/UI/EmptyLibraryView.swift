import SwiftUI

struct EmptyLibraryView: View {
  @ObservedObject var store: AppStore

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 36)
      VStack(alignment: .leading, spacing: 26) {
        HStack(spacing: 20) {
          if let icon = NSImage(named: NSImage.applicationIconName) {
            Image(nsImage: icon).resizable().interpolation(.high)
              .aspectRatio(contentMode: .fit).frame(width: 76, height: 76)
              .accessibilityHidden(true)
          }
          VStack(alignment: .leading, spacing: 8) {
            Text(store.currentFolderURL == nil ? L10n.text("알맹Re") : store.activeFolderName)
              .font(.system(size: 27, weight: .semibold))
              .lineLimit(2).truncationMode(.middle)
            Text(L10n.text(store.currentFolderURL == nil
              ? "이미지나 폴더를 열거나 이 창에 놓으세요." : "이미지가 없는 폴더입니다."))
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            if store.currentFolderURL != nil {
              Text("폴더 트리에서 다른 폴더를 선택하거나 파일을 열어 주세요.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }

        Divider()

        HStack(spacing: 12) {
          Button { store.chooseItems() } label: {
            Label("열기…", systemImage: "folder")
              .frame(minWidth: 140)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          Spacer()
        }

        Button { store.presentationMode = .folderComparison } label: {
          HStack(spacing: 14) {
            Image(systemName: "rectangle.split.2x1")
              .font(.system(size: 21, weight: .light))
              .foregroundStyle(ViewerTheme.accent)
              .frame(width: 36)
            VStack(alignment: .leading, spacing: 5) {
              Text("이미지 비교 시작")
                .font(.system(size: 13, weight: .semibold))
              Text("이미지 두 장을 좌우·상하로 비교합니다.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
              .font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
          }
          .padding(16)
          .background(ViewerTheme.chrome, in: RoundedRectangle(cornerRadius: 9))
          .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
      }
      .padding(32)
      .frame(maxWidth: 550)
      .background(ViewerTheme.panel, in: RoundedRectangle(cornerRadius: 16))
      .overlay { RoundedRectangle(cornerRadius: 16).stroke(ViewerTheme.separator) }
      Spacer(minLength: 36)
      Text("JPEG XL · AVIF · HEIC · WebP · EXR · RAW · QOI · PCX 등")
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(.bottom, 22)
    }
    .padding(.horizontal, 36)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ViewerTheme.chrome)
  }
}
