import SwiftUI

struct BottomControlBar: View {
  @ObservedObject var store: AppStore

  var body: some View {
    HStack(spacing: 8) {
      Button {
        if store.isFocusMode {
          store.exitFocusMode()
        } else {
          store.returnToOverview()
        }
      } label: {
        if store.isFocusMode {
          Label("집중 보기 종료", systemImage: "xmark")
        } else {
          Image(systemName: "rectangle.grid.3x2")
        }
      }
      .help(store.isFocusMode ? "집중 보기 종료 (Esc)" : "전체 보기로 돌아가기 (Esc)")

      Divider()
        .frame(height: 16)

      Button {
        store.navigatePage(-1)
      } label: {
        Image(systemName: "chevron.left")
      }
      .help("이전 이미지/페이지")

      Text(store.positionDescription)
        .font(.caption.monospacedDigit())
        .frame(minWidth: 76)

      Button {
        store.zoomOut()
      } label: {
        Image(systemName: "minus.magnifyingglass")
      }
      .help("축소")

      Slider(value: $store.zoom, in: 0.1...8)
        .frame(width: 150)

      Button {
        store.zoomIn()
      } label: {
        Image(systemName: "plus.magnifyingglass")
      }
      .help("확대")

      Button {
        store.setFitToWindow()
      } label: {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
      }
      .help("화면 맞춤")

      Button {
        store.setActualPixels()
      } label: {
        Text("1:1")
          .font(.caption.monospaced())
      }
      .help("실제 픽셀 크기")

      Menu {
        Picker("확대 이미지 이동", selection: $store.panInteractionMode) {
          ForEach(PanInteractionMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
      } label: {
        Image(systemName: "hand.draw")
      }
      .menuStyle(.borderlessButton)
      .help("팬 조작: \(store.panInteractionMode.title)")

      Button {
        store.navigatePage(1)
      } label: {
        Image(systemName: "chevron.right")
      }
      .help("다음 이미지/페이지")
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay {
      Capsule().stroke(.white.opacity(0.12), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
  }
}
