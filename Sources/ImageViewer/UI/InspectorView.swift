import SwiftUI

private struct CropEditRequest: Identifiable {
  let id = UUID()
  let asset: ImageAsset
  let adjustments: ImageAdjustments
}

/// 선택한 정보 또는 편집 도구를 일관된 보조 패널로 표시합니다.
struct InspectorView: View {
  @ObservedObject var store: AppStore
  let panel: InspectorPanel
  @State private var isMetadataEditorPresented = false
  @State private var cropRequest: CropEditRequest?

  var body: some View {
    VStack(spacing: 0) {
      panelHeader
      Rectangle().fill(ViewerTheme.separator).frame(height: 1)
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          selectedImageHeader
          Divider()
          switch panel {
          case .information:
            informationPanel
          case .editing:
            editingPanel
          }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(width: 304)
    .background(ViewerTheme.sidebar)
    .controlSize(.small)
    .tint(ViewerTheme.accent)
    .sheet(isPresented: $isMetadataEditorPresented) {
      MetadataEditorView(store: store)
    }
    .sheet(item: $cropRequest) { request in
      CropEditorView(
        asset: request.asset, adjustments: request.adjustments,
        pipeline: store.pipeline, prefersHDR: store.prefersHDR
      ) { crop in
        store.applyCrop(crop, to: request.asset,
          relativeToQuarterTurns: request.adjustments.normalizedQuarterTurns)
      }
    }
  }

  private var panelHeader: some View {
    HStack(spacing: 8) {
      Label(panel.title, systemImage: panel == .information ? "info.circle" : "slider.horizontal.3")
        .font(.system(size: 12, weight: .semibold))
      Spacer(minLength: 8)
      Button { store.toggleInspector(panel) } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("패널 닫기")
      .accessibilityLabel("패널 닫기")
    }
    .padding(.leading, 18)
    .padding(.trailing, 10)
    .padding(.vertical, 10)
    .background(ViewerTheme.chrome)
  }

  private var selectedImageHeader: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "photo")
        .font(.system(size: 17, weight: .light))
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 22)
      Text(store.currentAsset?.filename ?? "—")
        .font(.system(size: 12, weight: .medium))
        .lineLimit(3)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      if panel == .information {
        Button {
          store.pauseSlideshow()
          isMetadataEditorPresented = true
        } label: {
          Image(systemName: "square.and.pencil")
        }
        .buttonStyle(.borderless)
        .disabled(store.currentAsset == nil || store.currentMetadata == nil)
        .help("파일 및 내장 메타데이터 수정")
        .accessibilityLabel("수정")
      }
    }
  }

  private var informationPanel: some View {
    VStack(alignment: .leading, spacing: 20) {
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
    VStack(alignment: .leading, spacing: 10) {
      Text("파일 및 이미지")
        .font(.system(size: 12, weight: .semibold))
        .padding(.bottom, 2)

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
      if let description = store.currentMetadata?.imageDescription {
        informationRow("설명", description)
      }
      if let copyright = store.currentMetadata?.copyright {
        informationRow("저작권", copyright)
      }
      if let model = store.currentMetadata?.colorModel {
        informationRow("색상 모델", model)
      }
      if let depth = store.currentMetadata?.bitDepth {
        informationRow("비트 심도", "\(depth)-bit")
      }
      if let hasAlpha = store.currentMetadata?.hasAlpha {
        informationRow("알파 채널", L10n.text(hasAlpha ? "있음" : "없음"))
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
    VStack(alignment: .leading, spacing: 10) {
      Text("카메라 / EXIF")
        .font(.system(size: 12, weight: .semibold))
        .padding(.bottom, 2)

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
        .font(.system(size: 12, weight: .semibold))

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
    VStack(alignment: .leading, spacing: 20) {
      compositionControls
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
          .font(.system(size: 12, weight: .semibold))
        Spacer()
        Button("초기화") { store.resetAdjustments() }
          .font(.caption)
          .buttonStyle(.borderless)
      }

      Text("빛").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.top, 3)
      adjustmentSlider(title: "노출", value: adjustmentBinding(\.exposure), range: -4...4, suffix: " EV")
      adjustmentSlider(title: "휘도", value: adjustmentBinding(\.brightness), range: -1...1)
      adjustmentSlider(title: "대비", value: adjustmentBinding(\.contrast), range: 0.25...2)
      adjustmentSlider(
        title: "하이라이트",
        value: adjustmentBinding(\.highlights),
        range: -1...1
      )

      Divider()
      Text("색상").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      adjustmentSlider(title: "색조", value: adjustmentBinding(\.hue), range: -180...180, suffix: "°")
      adjustmentSlider(title: "색온도", value: adjustmentBinding(\.temperature), range: -100...100)
      HStack {
        Text("차갑게")
        Spacer()
        Text("따뜻하게")
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      adjustmentSlider(title: "색선명도", value: adjustmentBinding(\.vibrance), range: -1...1)
      adjustmentSlider(title: "채도", value: adjustmentBinding(\.saturation), range: 0...2)
      Toggle("색상 반전", isOn: adjustmentBinding(\.isInverted))
        .toggleStyle(.switch)

      Divider()
      Text("디테일").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      adjustmentSlider(title: "선명도", value: adjustmentBinding(\.sharpness), range: 0...2)
      adjustmentSlider(title: "노이즈 감소", value: adjustmentBinding(\.noiseReduction), range: 0...1)
    }
    .font(.system(size: 11))
    .disabled(store.currentAsset == nil)
  }

  private var compositionControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("구도", systemImage: "crop.rotate")
        .font(.system(size: 12, weight: .semibold))
      HStack {
        Button {
          store.pauseSlideshow()
          if let asset = store.currentAsset {
            cropRequest = CropEditRequest(asset: asset, adjustments: store.adjustments(for: asset))
          }
        } label: {
          Label("잘라내기…", systemImage: "crop")
        }
        if store.currentAdjustments.effectiveCrop != nil {
          Button("자르기 해제") { store.updateAdjustments { $0.crop = nil } }
        }
      }
      HStack {
        Button { store.rotateCounterclockwise() } label: {
          Label("왼쪽 90°", systemImage: "rotate.left")
        }
        Button { store.rotateClockwise() } label: {
          Label("오른쪽 90°", systemImage: "rotate.right")
        }
      }
    }
    .controlSize(.small)
    .disabled(store.currentAsset == nil)
  }

  private var exportControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("다른 형식으로 저장", systemImage: "square.and.arrow.up")
        .font(.system(size: 12, weight: .semibold))

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
    HStack(alignment: .top, spacing: 10) {
      Text(L10n.text(title))
        .foregroundStyle(.secondary)
        .frame(width: 80, alignment: .leading)
      Text(value)
        .multilineTextAlignment(.leading)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.system(size: 11))
    .fixedSize(horizontal: false, vertical: true)
  }

  private func adjustmentSlider(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    suffix: String = ""
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(L10n.text(title))
        Spacer()
        Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))) + suffix)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Slider(value: value, in: range)
        .accessibilityLabel(L10n.text(title))
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
      return L10n.format("1/%d초", max(1, Int((1 / seconds).rounded())))
    }
    return L10n.format("%@초", decimal(seconds))
  }

  private func decimal(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...2)))
  }

  private func orientationDescription(_ value: Int) -> String {
    switch value {
    case 1: L10n.text("정방향")
    case 2: L10n.text("좌우 반전")
    case 3: "180°"
    case 4: L10n.text("상하 반전")
    case 5: L10n.text("좌우 반전 + 90°")
    case 6: "90°"
    case 7: L10n.text("좌우 반전 + 270°")
    case 8: "270°"
    default: "\(value)"
    }
  }
}
