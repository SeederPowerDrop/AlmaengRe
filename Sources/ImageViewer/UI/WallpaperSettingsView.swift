import SwiftUI

/// 설정창을 여는 시점의 파일과 화면을 고정해 탐색 도중 다른 사진이 적용되지 않게 합니다.
struct WallpaperSettingsView: View {
  @ObservedObject var store: AppStore
  let request: WallpaperRequest
  @State private var appliesToAllDisplays = false
  @State private var scaling: WallpaperScaling = .fill
  @State private var appliesAdjustments = true

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label("현재 이미지를 바탕화면으로 설정", systemImage: "desktopcomputer")
        .font(ViewerUIMetrics.font(.title3).weight(.semibold))
      Text(request.asset.filename)
        .lineLimit(2)
        .truncationMode(.middle)
        .textSelection(.enabled)

      Picker("적용할 화면", selection: $appliesToAllDisplays) {
        Text(L10n.format("이 화면: %@",
          request.displays.first(where: { $0.id == request.currentDisplayID })?.name ?? "—"))
          .tag(false)
        if request.displays.count > 1 { Text("모든 연결된 화면").tag(true) }
      }
      Picker("사진 배치", selection: $scaling) {
        ForEach(WallpaperScaling.allCases) { Text($0.title).tag($0) }
      }
      Toggle("현재 보정 적용", isOn: $appliesAdjustments)
      Text("원본은 변경하지 않습니다. 별도 PNG 사본을 보관하며, 애니메이션은 첫 프레임·HDR은 SDR로 적용합니다. 다른 데스크탑 공간은 macOS 설정을 따릅니다.")
        .font(ViewerUIMetrics.font(.caption))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        if store.isSettingWallpaper {
          ProgressView().controlSize(.small)
          Text("바탕화면 이미지 준비 중…").font(ViewerUIMetrics.font(.caption))
        }
        Spacer()
        Button("취소", role: .cancel) { store.wallpaperRequest = nil }
          .keyboardShortcut(.cancelAction)
        Button("바탕화면에 적용") {
          let ids = appliesToAllDisplays
            ? Set(request.displays.map(\.id)) : [request.currentDisplayID]
          Task { await store.applyWallpaper(request, displayIDs: ids,
            scaling: scaling, appliesAdjustments: appliesAdjustments) }
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .viewerPadding(24)
    .frame(width: 490)
    .disabled(store.isSettingWallpaper)
    .interactiveDismissDisabled(store.isSettingWallpaper)
  }
}
