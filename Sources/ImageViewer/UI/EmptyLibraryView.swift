import SwiftUI

struct EmptyLibraryView: View {
  @ObservedObject var store: AppStore

  var body: some View {
    VStack(spacing: 18) {
      ZStack {
        RoundedRectangle(cornerRadius: 18)
          .fill(.white.opacity(0.06))
          .frame(width: 112, height: 92)
        Image(systemName: "photo.on.rectangle.angled")
          .font(.system(size: 42, weight: .light))
          .foregroundStyle(.secondary)
      }

      VStack(spacing: 6) {
        Text("이미지뷰어")
          .font(.largeTitle.weight(.semibold))
        Text("폴더를 열거나 이미지 파일을 이 창에 놓으세요.")
          .foregroundStyle(.secondary)
      }

      HStack {
        Button("폴더 열기…") { store.chooseFolder() }
          .buttonStyle(.borderedProminent)
        Button("파일 열기…") { store.chooseFiles() }
          .buttonStyle(.bordered)
      }

      Text("JPEG XL · AVIF · HEIC · WebP · EXR · RAW · QOI · PCX 등")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
  }
}
