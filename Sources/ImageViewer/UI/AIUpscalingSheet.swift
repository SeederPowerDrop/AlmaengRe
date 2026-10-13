import SwiftUI

struct AIUpscalingSheet: View {
  @ObservedObject var store: AIUpscalingStore
  let sourceURL: URL?
  var preparePhotoMarks: @MainActor (URL) async throws -> PhotoMarkExportContext = { _ in .disabled }
  @Environment(\.dismiss) private var dismiss
  @State private var comparesOriginal = false
  @State private var comparisonAxis: AIUpscalingComparisonAxis = .leftRight
  @State private var zoom: CGFloat = 1
  @State private var fitsWindow = true
  @State private var splitFraction: CGFloat = 0.5

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
        Button("PNG 사본 저장…") { store.chooseSaveDestination(preparePhotoMarks: preparePhotoMarks) }
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
      comparesOriginal = false
      comparisonAxis = .leftRight
      fitsWindow = true
      splitFraction = 0.5
    }
    .onDisappear { store.cancel() }
  }

  private func preview(_ result: AIUpscalingResult) -> some View {
    VStack(spacing: 0) {
      HStack {
        Picker("미리보기", selection: $comparesOriginal) {
          Text("AI 확대 결과").tag(false)
          Text("원본과 비교").tag(true)
        }.pickerStyle(.segmented).frame(maxWidth: 440)
        Spacer()
        Text("\(result.image.width) × \(result.image.height)")
          .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      }.padding(12)
      previewControls
      .padding(.horizontal, 12).padding(.bottom, 10)
      Divider()
      AIUpscalingPreview(original: result.original, upscaled: result.image,
        comparesOriginal: comparesOriginal, comparisonAxis: comparisonAxis,
        zoom: $zoom, fitsWindow: $fitsWindow,
        splitFraction: $splitFraction)
      .overlay {
        if comparesOriginal {
          VStack {
            HStack {
              previewLabel("aiPreview.original")
              Spacer()
              if comparisonAxis == .leftRight { previewLabel("aiPreview.result") }
            }
            Spacer()
            if comparisonAxis == .topBottom {
              HStack {
                Spacer()
                previewLabel("aiPreview.result")
              }
            }
          }.padding(12).allowsHitTesting(false)
        }
      }
      Text(verbatim: L10n.text("aiPreview.hint"))
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
    }
  }

  private var previewControls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        zoomPresets
        if comparesOriginal { directionPicker }
        Spacer(minLength: 8)
        zoomControls
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          zoomPresets
          Spacer(minLength: 8)
          zoomControls
        }
        if comparesOriginal { directionPicker }
      }
    }
  }

  private var directionPicker: some View {
    Picker(L10n.text("aiPreview.direction"), selection: $comparisonAxis) {
      Text(L10n.text("aiPreview.leftRight")).tag(AIUpscalingComparisonAxis.leftRight)
      Text(L10n.text("aiPreview.topBottom")).tag(AIUpscalingComparisonAxis.topBottom)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
    .accessibilityIdentifier("aiPreview.direction")
  }

  private var zoomPresets: some View {
    HStack(spacing: 10) {
      Button(L10n.text("aiPreview.fit")) { fitsWindow = true }
        .tint(fitsWindow ? .accentColor : nil)
      Button(L10n.text("aiPreview.actual")) { setZoom(1) }
        .help(L10n.text("aiPreview.actualHelp"))
    }.fixedSize()
  }

  private var zoomControls: some View {
    HStack(spacing: 10) {
      Button { setZoom(zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
        .accessibilityLabel(L10n.text("aiPreview.zoomOut"))
        .help(L10n.text("aiPreview.zoomOut"))
        .disabled(zoom <= 0.01)
      Text(Double(zoom).formatted(.percent.precision(.fractionLength(zoom < 0.1 ? 1 : 0))))
        .font(.callout.monospacedDigit())
        .frame(minWidth: 54)
        .accessibilityLabel(L10n.text("aiPreview.zoom"))
        .accessibilityValue(Double(zoom).formatted(.percent))
      Button { setZoom(zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
        .accessibilityLabel(L10n.text("aiPreview.zoomIn"))
        .help(L10n.text("aiPreview.zoomIn"))
        .disabled(zoom >= 8)
    }.fixedSize()
  }

  private func setZoom(_ value: CGFloat) {
    fitsWindow = false
    // A tiny image can fit above 800%; zoom out from that fitted size smoothly.
    zoom = min(max(value, min(zoom, AIUpscalingPreviewGeometry.minimumZoom)),
      max(zoom, AIUpscalingPreviewGeometry.maximumZoom))
  }

  private func previewLabel(_ key: String) -> some View {
    Text(verbatim: L10n.text(key))
      .font(.caption.weight(.semibold)).foregroundStyle(.white)
      .padding(.horizontal, 10).padding(.vertical, 5)
      .background(.black.opacity(0.7), in: Capsule())
  }
}
