import SwiftUI

struct InspectorView: View {
  @ObservedObject var store: AppStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        fileInformation
        Divider()
        adjustmentControls
        Divider()
        exportControls
      }
      .padding(16)
    }
    .frame(width: 278)
    .background(.ultraThinMaterial)
  }

  private var fileInformation: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("파일 정보", systemImage: "info.circle")
        .font(.headline)

      Text(store.currentAsset?.filename ?? "—")
        .font(.subheadline.weight(.medium))
        .lineLimit(2)
        .truncationMode(.middle)

      LabeledContent("크기", value: store.currentMetadata?.dimensionsDescription ?? "확인 중")
      LabeledContent("파일", value: store.currentAsset?.formattedFileSize ?? "—")
      LabeledContent("프레임", value: "\(store.currentMetadata?.frameCount ?? 1)")

      if let profile = store.currentMetadata?.profileName {
        LabeledContent("색상", value: profile)
          .lineLimit(1)
      }
      if let depth = store.currentMetadata?.bitDepth {
        LabeledContent("비트", value: "\(depth)-bit")
      }
    }
    .font(.caption)
  }

  private var adjustmentControls: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack {
        Label("이미지 조정", systemImage: "slider.horizontal.3")
          .font(.headline)
        Spacer()
        Button("초기화") { store.resetAdjustments() }
          .font(.caption)
      }

      adjustmentSlider(
        title: "밝기",
        value: adjustmentBinding(\.brightness),
        range: -1...1
      )
      adjustmentSlider(
        title: "대비",
        value: adjustmentBinding(\.contrast),
        range: 0.25...2
      )
      adjustmentSlider(
        title: "채도",
        value: adjustmentBinding(\.saturation),
        range: 0...2
      )
      adjustmentSlider(
        title: "하이라이트",
        value: adjustmentBinding(\.highlights),
        range: -1...1
      )

      Toggle("색상 반전", isOn: adjustmentBinding(\.isInverted))

      HStack {
        Button {
          store.rotateCounterclockwise()
        } label: {
          Label("왼쪽", systemImage: "rotate.left")
        }
        Button {
          store.rotateClockwise()
        } label: {
          Label("오른쪽", systemImage: "rotate.right")
        }
      }
      .labelStyle(.iconOnly)
      .help("이미지 회전")
    }
  }

  private var exportControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("다른 형식으로 저장", systemImage: "square.and.arrow.up")
        .font(.headline)

      Picker("형식", selection: $store.exportFormat) {
        ForEach(ExportFormat.available) { format in
          Text(format.title).tag(format)
        }
      }

      if store.exportFormat.usesLossyQuality {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("품질")
            Spacer()
            Text("\(Int(store.exportQuality * 100))%")
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          Slider(value: $store.exportQuality, in: 0.1...1)
        }
      }

      Button {
        store.exportCurrentImage()
      } label: {
        if store.isExporting {
          ProgressView()
            .controlSize(.small)
        } else {
          Label("내보내기…", systemImage: "square.and.arrow.up")
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(store.currentAsset == nil || store.isExporting || ExportFormat.available.isEmpty)
      .frame(maxWidth: .infinity, alignment: .trailing)

      Text("원본은 수정하지 않으며 현재 조정값을 새 파일에 적용합니다.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func adjustmentSlider(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Slider(value: value, in: range)
    }
  }

  private func adjustmentBinding<Value>(
    _ keyPath: WritableKeyPath<ImageAdjustments, Value>
  ) -> Binding<Value> {
    Binding(
      get: { store.currentAdjustments[keyPath: keyPath] },
      set: { newValue in
        store.updateAdjustments { $0[keyPath: keyPath] = newValue }
      }
    )
  }
}
