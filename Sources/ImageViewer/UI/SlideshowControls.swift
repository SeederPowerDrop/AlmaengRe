import SwiftUI

/// 일반 설정과 집중 보기 팝오버가 공유하는 간격·반복 옵션입니다.
struct SlideshowOptionsView: View {
  @ObservedObject var store: AppStore

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("사진 표시 시간(초)")
        Spacer()
        TextField("사진 표시 시간(초)", value: $store.slideshowInterval,
          format: .number.precision(.fractionLength(0)))
          .textFieldStyle(.roundedBorder)
          .viewerFrame(width: 65)
        Stepper("사진 표시 시간(초)", value: $store.slideshowInterval,
          in: SlideshowSettings.intervalRange, step: 1)
          .labelsHidden()
      }
      Toggle("전자 앨범 반복 재생", isOn: $store.slideshowRepeats)
      Text("1~300초. 사진은 표시된 뒤 시간을 세고, 영상은 끝까지 재생한 뒤 넘어갑니다. 집중 보기를 나가거나 다른 앱으로 전환하면 일시정지합니다.")
        .font(ViewerUIMetrics.font(.caption))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct SlideshowMenuItems: View {
  @ObservedObject var store: AppStore
  @ObservedObject var shortcuts: ShortcutStore

  var body: some View {
    Button(L10n.format("%@  %@",
      L10n.text(store.isSlideshowPlaying ? "전자 앨범 일시정지" : "전자 앨범 재생"),
      shortcuts.binding(for: .toggleSlideshow).displayText)) {
      store.toggleSlideshow()
    }
    .disabled(!store.isSlideshowPlaying && !store.canStartSlideshow)
    Divider()
    ForEach(SlideshowSettings.presets, id: \.self) { interval in
      Button {
        store.slideshowInterval = interval
      } label: {
        Label(L10n.format("%d초 간격", Int(interval)),
          systemImage: store.slideshowInterval == interval ? "checkmark" : "timer")
      }
    }
    Toggle("전자 앨범 반복 재생", isOn: $store.slideshowRepeats)
  }
}

/// 집중 보기 안에서도 재생/일시정지와 임의의 초 단위 간격에 바로 접근합니다.
struct SlideshowPlaybackControls: View {
  @ObservedObject var store: AppStore
  @State private var showsOptions = false

  var body: some View {
    HStack(spacing: 14) {
      Button { store.toggleSlideshow() } label: {
        Label(L10n.text(store.isSlideshowPlaying ? "전자 앨범 일시정지" : "전자 앨범 재생"),
          systemImage: store.isSlideshowPlaying ? "pause.fill" : "play.fill")
      }
      .disabled(!store.isSlideshowPlaying && !store.canStartSlideshow)
      Button { showsOptions.toggle() } label: {
        Label(L10n.format("%d초 간격", Int(store.slideshowInterval)), systemImage: "timer")
      }
      .help("전자 앨범 설정")
      .popover(isPresented: $showsOptions) {
        VStack(alignment: .leading, spacing: 16) {
          Text("전자 앨범 설정").font(ViewerUIMetrics.font(.headline))
          SlideshowOptionsView(store: store)
        }
        .viewerPadding(18)
        .viewerFrame(width: 350)
      }
    }
    .font(ViewerUIMetrics.font(.caption))
  }
}
