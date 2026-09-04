import SwiftUI

/// 툴바의 i/e 버튼에 맞춰 정보와 편집 도구 중 하나만 보여 줍니다.
struct InspectorView: View {
  @ObservedObject var store: AppStore
  let panel: InspectorPanel

  var body: some View {
    ScrollView {
      Group {
        switch panel {
        case .information:
          informationPanel
        case .editing:
          editingPanel
        }
      }
      .padding(16)
    }
    .frame(width: 294)
    .background(.ultraThinMaterial)
  }

  private var informationPanel: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 7) {
        Label("이미지 정보", systemImage: "info.circle")
          .font(.headline)
        Text(store.currentAsset?.filename ?? "—")
          .font(.subheadline.weight(.medium))
          .lineLimit(2)
          .truncationMode(.middle)
      }

      Divider()
      basicInformation

      if hasCameraInformation {
        Divider()
        cameraInformation
      }

      if let location = store.currentMetadata?.location {
        Divider()
        locationInformation(location)
      }
    }
    .font(.caption)
  }

  private var basicInformation: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("파일 및 이미지")
        .font(.subheadline.weight(.semibold))

      informationRow("크기", store.currentMetadata?.dimensionsDescription ?? "확인 중")
      informationRow("파일 용량", store.currentAsset?.formattedFileSize ?? "—")
      informationRow("포맷", formatDescription)
      informationRow("프레임", "\(store.currentMetadata?.frameCount ?? 1)")

      if let modified = store.currentAsset?.modificationDate {
        informationRow(
          "수정일",
          modified.formatted(date: .abbreviated, time: .shortened)
        )
      }
      if let profile = store.currentMetadata?.profileName {
        informationRow("색상 프로파일", profile)
      }
      if let model = store.currentMetadata?.colorModel {
        informationRow("색상 모델", model)
      }
      if let depth = store.currentMetadata?.bitDepth {
        informationRow("비트 심도", "\(depth)-bit")
      }
      if let hasAlpha = store.currentMetadata?.hasAlpha {
        informationRow("알파 채널", hasAlpha ? "있음" : "없음")
      }
      if let dpi = dpiDescription {
        informationRow("해상도", dpi)
      }
      if let orientation = store.currentMetadata?.orientation {
        informationRow("방향", orientationDescription(orientation))
      }
      if let typeIdentifier = store.currentMetadata?.typeIdentifier {
        informationRow("UTI", typeIdentifier)
      }

      if let path = store.currentAsset?.url.path {
        Text(path)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineLimit(4)
          .truncationMode(.middle)
          .padding(.top, 3)
      }
    }
  }

  private var cameraInformation: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("카메라 / EXIF")
        .font(.subheadline.weight(.semibold))

      if let make = store.currentMetadata?.cameraMake {
        informationRow("제조사", make)
      }
      if let model = store.currentMetadata?.cameraModel {
        informationRow("카메라", model)
      }
      if let lens = store.currentMetadata?.lensModel {
        informationRow("렌즈", lens)
      }
      if let capturedAt = store.currentMetadata?.capturedAt {
        informationRow("촬영 시각", capturedAt)
      }
      if let exposure = store.currentMetadata?.exposureTime {
        informationRow("셔터", exposureDescription(exposure))
      }
      if let aperture = store.currentMetadata?.aperture {
        informationRow("조리개", "ƒ/\(decimal(aperture))")
      }
      if let iso = store.currentMetadata?.iso {
        informationRow("감도", "ISO \(iso)")
      }
      if let focalLength = store.currentMetadata?.focalLength {
        informationRow("초점 거리", "\(decimal(focalLength)) mm")
      }
      if let software = store.currentMetadata?.software {
        informationRow("소프트웨어", software)
      }
      if let artist = store.currentMetadata?.artist {
        informationRow("작성자", artist)
      }
    }
  }

  private func locationInformation(_ location: ImageLocation) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("촬영 위치", systemImage: "location.fill")
        .font(.subheadline.weight(.semibold))

      informationRow("좌표", location.coordinateDescription)
      if let altitude = location.altitude {
        informationRow("고도", "\(decimal(altitude)) m")
      }
      if let direction = location.direction {
        informationRow("촬영 방향", "\(decimal(direction))°")
      }

      HStack(spacing: 7) {
        Button {
          store.openMap(.apple)
        } label: {
          Label("Apple 지도", systemImage: "map")
        }

        Button {
          store.openMap(.google)
        } label: {
          Label("Google 지도", systemImage: "globe")
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  private var editingPanel: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 8) {
        Text("e")
          .font(.system(size: 14, weight: .bold, design: .rounded))
          .frame(width: 18, height: 18)
          .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary, lineWidth: 1.2))
        Text("이미지 편집")
          .font(.headline)
      }

      Text(store.currentAsset?.filename ?? "—")
        .font(.subheadline.weight(.medium))
        .lineLimit(2)
        .truncationMode(.middle)

      Divider()
      adjustmentControls
      Divider()
      exportControls
    }
  }

  private var adjustmentControls: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack {
        Label("비파괴 조정", systemImage: "slider.horizontal.3")
          .font(.subheadline.weight(.semibold))
        Spacer()
        Button("초기화") { store.resetAdjustments() }
          .font(.caption)
      }

      adjustmentSlider(title: "밝기", value: adjustmentBinding(\.brightness), range: -1...1)
      adjustmentSlider(title: "대비", value: adjustmentBinding(\.contrast), range: 0.25...2)
      adjustmentSlider(title: "채도", value: adjustmentBinding(\.saturation), range: 0...2)
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
        .font(.subheadline.weight(.semibold))

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

  private var formatDescription: String {
    let extensionName = store.currentAsset?.fileExtension.uppercased() ?? "—"
    guard let type = store.currentMetadata?.typeIdentifier else { return extensionName }
    return extensionName == "" ? type : extensionName
  }

  private var dpiDescription: String? {
    guard let width = store.currentMetadata?.dpiWidth else { return nil }
    let height = store.currentMetadata?.dpiHeight ?? width
    return "\(decimal(width)) × \(decimal(height)) dpi"
  }

  private var hasCameraInformation: Bool {
    guard let metadata = store.currentMetadata else { return false }
    return metadata.cameraMake != nil || metadata.cameraModel != nil || metadata.lensModel != nil
      || metadata.software != nil || metadata.artist != nil || metadata.capturedAt != nil
      || metadata.exposureTime != nil || metadata.aperture != nil || metadata.iso != nil
      || metadata.focalLength != nil
  }

  private func informationRow(_ title: String, _ value: String) -> some View {
    LabeledContent(title) {
      Text(value)
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
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

  private func exposureDescription(_ seconds: Double) -> String {
    guard seconds > 0 else { return "—" }
    if seconds < 0.5 {
      return "1/\(max(1, Int((1 / seconds).rounded())))초"
    }
    return "\(decimal(seconds))초"
  }

  private func decimal(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...2)))
  }

  private func orientationDescription(_ value: Int) -> String {
    switch value {
    case 1: "정방향"
    case 2: "좌우 반전"
    case 3: "180°"
    case 4: "상하 반전"
    case 5: "좌우 반전 + 90°"
    case 6: "90°"
    case 7: "좌우 반전 + 270°"
    case 8: "270°"
    default: "\(value)"
    }
  }
}
