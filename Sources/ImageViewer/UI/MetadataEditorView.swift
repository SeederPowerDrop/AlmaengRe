import SwiftUI

private struct MetadataEditorAlert: Identifiable {
  let id = UUID()
  let message: String
}

/// i 정보 패널에서 여는 파일·TIFF·EXIF·GPS 편집 시트입니다.
struct MetadataEditorView: View {
  @ObservedObject var store: AppStore
  @Environment(\.dismiss) private var dismiss

  private let originalDraft: ImageMetadataEditDraft
  private let supportsEmbeddedMetadata: Bool
  @State private var draft: ImageMetadataEditDraft
  @State private var presentedAlert: MetadataEditorAlert?

  init(store: AppStore) {
    self.store = store
    let draft = ImageMetadataEditDraft(
      asset: store.currentAsset,
      metadata: store.currentMetadata
    )
    originalDraft = draft
    supportsEmbeddedMetadata = store.canEditCurrentEmbeddedMetadata
    _draft = State(initialValue: draft)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "info.circle.fill")
          .font(.title2)
        VStack(alignment: .leading, spacing: 2) {
          Text("이미지 정보 수정")
            .font(.headline)
          Text("계산된 이미지 속성은 그대로 두고 파일 및 표준 메타데이터를 수정합니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(18)

      Divider()

      Form {
        fileSection
        embeddedMetadataAvailability
        descriptionSection
          .disabled(!supportsEmbeddedMetadata)
        resolutionSection
          .disabled(!supportsEmbeddedMetadata)
        cameraSection
          .disabled(!supportsEmbeddedMetadata)
        locationSection
          .disabled(!supportsEmbeddedMetadata)
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Text("저장 전 임시 파일을 완성한 뒤 원본 경로를 교체합니다.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("취소", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button {
          save()
        } label: {
          if store.isSavingMetadata {
            ProgressView()
              .controlSize(.small)
          } else {
            Text("저장")
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(draft == originalDraft || store.isSavingMetadata)
      }
      .padding(16)
    }
    .frame(width: 640, height: 720)
    .interactiveDismissDisabled(store.isSavingMetadata)
    .alert(item: $presentedAlert) { alert in
      Alert(
        title: Text("정보를 저장할 수 없음"),
        message: Text(alert.message),
        dismissButton: .default(Text("확인"))
      )
    }
  }

  private var fileSection: some View {
    Section("파일") {
      TextField("파일 이름", text: $draft.filename)
      DatePicker(
        "수정일",
        selection: $draft.modificationDate,
        displayedComponents: [.date, .hourAndMinute]
      )
      Text("확장자를 바꾸려면 e 편집 패널의 ‘다른 형식으로 저장’을 사용하세요.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var embeddedMetadataAvailability: some View {
    if !supportsEmbeddedMetadata {
      Section {
        Label(
          "이 형식은 내장 메타데이터의 무손실 수정을 지원하지 않아 파일 이름과 수정일만 변경할 수 있습니다.",
          systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private var descriptionSection: some View {
    Section("설명 및 권리") {
      TextField("설명", text: $draft.imageDescription, axis: .vertical)
        .lineLimit(2...4)
      TextField("작성자", text: $draft.artist)
      TextField("저작권", text: $draft.copyright)
      TextField("소프트웨어", text: $draft.software)
      Text("값을 비우고 저장하면 해당 태그를 제거합니다.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var resolutionSection: some View {
    Section("해상도") {
      HStack {
        TextField("가로 DPI", text: $draft.dpiWidth)
        Text("×")
          .foregroundStyle(.secondary)
        TextField("세로 DPI", text: $draft.dpiHeight)
        Text("dpi")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var cameraSection: some View {
    Section("카메라 / EXIF") {
      TextField("제조사", text: $draft.cameraMake)
      TextField("카메라", text: $draft.cameraModel)
      TextField("렌즈", text: $draft.lensModel)
      TextField("촬영 시각", text: $draft.capturedAt)
      Text("예: 2025:11:30 12:10:00 또는 ISO 8601")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack {
        TextField("노출 시간(초)", text: $draft.exposureTime)
        TextField("조리개", text: $draft.aperture)
      }
      Text("노출 시간은 0.008 또는 1/125처럼 입력할 수 있습니다.")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack {
        TextField("ISO", text: $draft.iso)
        TextField("초점 거리(mm)", text: $draft.focalLength)
      }
    }
  }

  private var locationSection: some View {
    Section("촬영 위치") {
      Toggle("GPS 위치 정보 저장", isOn: $draft.includesLocation)

      if draft.includesLocation {
        HStack {
          TextField("위도 (-90~90)", text: $draft.latitude)
          TextField("경도 (-180~180)", text: $draft.longitude)
        }
        HStack {
          TextField("고도(m)", text: $draft.altitude)
          TextField("촬영 방향(°)", text: $draft.direction)
        }
      }

      Text("GPS를 끄고 저장하면 표준 EXIF/XMP 위치 태그를 제거합니다.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func save() {
    Task {
      do {
        try await store.saveMetadataEdits(draft, replacing: originalDraft)
        dismiss()
      } catch {
        presentedAlert = MetadataEditorAlert(
          message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        )
      }
    }
  }
}
