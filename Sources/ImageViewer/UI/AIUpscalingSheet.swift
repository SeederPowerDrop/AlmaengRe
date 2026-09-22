import SwiftUI

struct AIUpscalingSheet: View {
  @ObservedObject var store: AIUpscalingStore
  let sourceURL: URL?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.displayScale) private var displayScale
  @State private var showsOriginal = false
  @State private var actualPixels = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("AI 확대").font(.title2.weight(.semibold))
          Text(sourceURL?.lastPathComponent ?? L10n.text("이미지를 먼저 열어 주세요."))
            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        Spacer()
        Button("닫기") { store.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
      }
      Text("QuickSRNet으로 가로·세로를 2배 확대합니다. 모든 처리는 이 Mac에서 이루어집니다.")
        .font(.callout).foregroundStyle(.secondary)

      Group {
        if let result = store.result {
          preview(result)
        } else if store.isRunning {
          VStack(spacing: 16) {
            ProgressView(value: store.progress)
              .frame(width: 280)
            Text(L10n.format("AI 확대 중… %d%%", Int(store.progress * 100)))
              .monospacedDigit()
            Button("취소") { store.cancel() }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ContentUnavailableView("AI로 더 크게 보기", systemImage: "sparkles",
            description: Text("실행을 누르면 확대 결과를 미리 보고 PNG 사본으로 저장할 수 있습니다."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(minHeight: 320)
      .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
      .clipShape(RoundedRectangle(cornerRadius: 12))

      if let error = store.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.red).textSelection(.enabled)
      }
      if let savedURL = store.savedURL {
        HStack {
          Label("사본을 저장했습니다.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
          Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
        }.font(.callout)
      }
      Text("결과는 SDR · sRGB입니다. 투명도는 유지하며, 움직이는 이미지는 첫 프레임만 확대합니다. 원본은 변경하지 않습니다.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Text("2× · QuickSRNet Small").font(.caption).foregroundStyle(.secondary)
        Spacer()
        if store.isSaving { ProgressView().controlSize(.small) }
        Button("PNG 사본 저장…") { store.chooseSaveDestination() }
          .disabled(store.result == nil || store.isRunning || store.isSaving)
        Button(store.result == nil ? "AI 확대 실행" : "다시 실행") { store.start() }
          .buttonStyle(.borderedProminent)
          .disabled(sourceURL == nil || store.isRunning || store.isSaving)
      }
    }
    .padding(24)
    .frame(minWidth: 720, idealWidth: 820, minHeight: 580, idealHeight: 680)
    .onChange(of: sourceURL, initial: true) { _, value in
      store.prepare(sourceURL: value)
      showsOriginal = false
    }
    .onDisappear { store.cancel() }
  }

  private func preview(_ result: AIUpscalingResult) -> some View {
    VStack(spacing: 0) {
      HStack {
        Picker("미리보기", selection: $showsOriginal) {
          Text("AI 확대 결과").tag(false)
          Text("원본과 비교").tag(true)
        }.pickerStyle(.segmented).frame(width: 270)
        Spacer()
        Text("\(result.image.width) × \(result.image.height)")
          .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        Toggle("실제 픽셀", isOn: $actualPixels).toggleStyle(.button)
      }.padding(12)
      Divider()
      GeometryReader { geometry in
        let image = showsOriginal ? result.original : result.image
        let pixelWidth = CGFloat(result.image.width)
        let pixelHeight = CGFloat(result.image.height)
        let scale = actualPixels ? 1 / max(displayScale, 1)
          : min(geometry.size.width / pixelWidth, geometry.size.height / pixelHeight)
        // Both images occupy the same output extent and shared scroll view. The
        // original uses nearest-neighbor pixels so its lack of detail is visible.
        ScrollView([.horizontal, .vertical]) {
          Image(decorative: image, scale: 1)
            .resizable().interpolation(showsOriginal ? .none : .high)
            .frame(width: pixelWidth * scale, height: pixelHeight * scale)
            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
        }
        .background(.black.opacity(0.8))
        .defaultScrollAnchor(.center)
      }
    }
  }
}
