import AppKit
import SwiftUI

struct BatchExportView: View {
  @ObservedObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  private let urls: [URL]
  @State private var format: ExportFormat
  @State private var quality = 0.92
  @State private var resizeMode: ResizeMode = .original
  @State private var longestEdge = "1920"
  @State private var percentage = "50"
  @State private var destinationFolder: URL?
  @State private var items: [BatchExportItem] = []
  @State private var plannedFormat: ExportFormat?
  @State private var plannedFolder: URL?
  @State private var errorMessage: String?
  @State private var progress = 0
  @State private var result: BatchExportResult?
  @State private var exportTask: Task<Void, Never>?
  @State private var cancellationRequested = false
  @State private var watermark: WatermarkOptions = .disabled
  @State private var showsWatermarkEditor = false

  init(store: AppStore, startsWithWatermark: Bool = false) {
    self.store = store
    _showsWatermarkEditor = State(initialValue: startsWithWatermark)
    urls = store.batchAssets.map(\.url)
    _format = State(initialValue: ExportFormat.available.first ?? .jpeg)
    var draft = store.savedWatermarkOptions
    // Remember the design, but require an explicit choice for each new export.
    draft.isEnabled = false
    // Canvas consent belongs to the captured batch, not a later selection.
    draft.expandsCanvas = false
    _watermark = State(initialValue: draft)
  }

  private var previewKey: String {
    format.rawValue + "|" + (destinationFolder?.path ?? "")
  }

  private enum ResizeMode: CaseIterable, Identifiable {
    case original, longestEdge, percentage
    var id: Self { self }
    var title: String {
      switch self {
      case .original: BatchResizeL10n.text("크기 유지")
      case .longestEdge: BatchResizeL10n.text("긴 변 기준")
      case .percentage: BatchResizeL10n.text("비율 기준")
      }
    }
  }

  private var resizeOptions: BatchResizeOptions? {
    let options: BatchResizeOptions
    switch resizeMode {
    case .original: options = .original
    case .longestEdge:
      guard let value = Int(longestEdge) else { return nil }
      options = .longestEdge(value)
    case .percentage:
      guard let value = Double(percentage) else { return nil }
      options = .percentage(value)
    }
    return (try? options.dimensions(width: 1, height: 1)) == nil ? nil : options
  }

  var body: some View {
    Group {
      if showsWatermarkEditor {
        WatermarkEditorView(options: $watermark, asset: store.batchAssets.first,
          adjustments: store.batchAssets.first.map { store.adjustments(for: $0) } ?? .identity,
          pipeline: store.pipeline, close: { showsWatermarkEditor = false })
      } else {
        exportContents
      }
    }
    .interactiveDismissDisabled(exportTask != nil)
    .task(id: previewKey) { await updatePreview() }
    .onDisappear { exportTask?.cancel() }
    .onChange(of: watermark) { _, options in store.rememberWatermarkOptions(options) }
  }

  private var exportContents: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label(BatchResizeL10n.text("일괄 변환 · 크기 변경"), systemImage: "photo.on.rectangle.angled")
          .font(ViewerUIMetrics.font(.title2).bold())
        Spacer()
        Text(L10n.format("%d개 선택", urls.count)).foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Picker("저장 형식", selection: $format) {
            ForEach(ExportFormat.available) { item in Text(item.title).tag(item) }
          }.viewerFrame(width: 250)
          if format.usesLossyQuality {
            Text("품질")
            Slider(value: $quality, in: 0.1...1).viewerFrame(width: 180)
            Text("\(Int(quality * 100))%").monospacedDigit().viewerFrame(width: 44)
          }
        }
        HStack {
          Picker(BatchResizeL10n.text("이미지 크기"), selection: $resizeMode) {
            ForEach(ResizeMode.allCases) { mode in Text(mode.title).tag(mode) }
          }.viewerFrame(width: 250)
          if resizeMode == .longestEdge {
            TextField(BatchResizeL10n.text("픽셀"), text: $longestEdge).viewerFrame(width: 90)
              .textFieldStyle(.roundedBorder)
            Text(BatchResizeL10n.text("픽셀"))
          } else if resizeMode == .percentage {
            TextField("%", text: $percentage).viewerFrame(width: 90)
              .textFieldStyle(.roundedBorder)
            Text("%")
          }
          Spacer()
          Button(BatchResizeL10n.text("용량 줄이기 설정")) {
            format = .jpeg
            quality = 0.75
            resizeMode = .longestEdge
            longestEdge = "1920"
          }.disabled(!ExportFormat.available.contains(.jpeg))
        }
        Text(BatchResizeL10n.text("현재 조정·자르기 후의 비율을 유지해 줄이며, 작은 이미지는 확대하지 않습니다."))
          .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
        Text(BatchResizeL10n.text("용량 줄이기는 JPEG·긴 변 1920픽셀·품질 75%로 설정합니다. 결과 용량은 사진마다 다르며 더 커질 수도 있습니다."))
          .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
        if resizeOptions == nil {
          Text(BatchResizeL10n.text("긴 변은 1~65536픽셀, 비율은 1~100%로 입력하세요."))
            .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.red)
        }
        HStack {
          Button(WatermarkL10n.text("configure")) { showsWatermarkEditor = true }
          Text(WatermarkL10n.text(watermark.isEnabled ? "summary.on" : "summary.off"))
            .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
          Spacer()
          if watermark.isEnabled {
            Button(WatermarkL10n.text("disable")) { watermark.isEnabled = false }
          }
        }
        HStack {
          Button("저장 폴더 선택…") { chooseDestination() }
          Text(destinationFolder?.path ?? L10n.text("저장할 폴더를 선택하세요."))
            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            .help(destinationFolder?.path ?? "")
        }
        Text("원본을 보존하고 현재 조정값을 적용한 새 파일을 만듭니다. 이름이 겹치면 번호를 붙입니다. 애니메이션·다중 페이지는 첫 프레임만 저장합니다.")
          .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
      }
      .disabled(exportTask != nil || result != nil)

      Divider()
      if let result {
        resultView(result)
      } else {
        Text("저장 미리보기").font(ViewerUIMetrics.font(.headline))
        Table(items) {
          TableColumn("현재 이름") { item in
            Text(item.sourceURL.lastPathComponent)
              .lineLimit(1).truncationMode(.middle).help(item.sourceURL.path)
          }
          TableColumn("저장할 이름") { item in
            Text(item.destinationURL.lastPathComponent)
              .lineLimit(1).truncationMode(.middle).help(item.destinationURL.path)
          }
        }
        if let errorMessage {
          Text(errorMessage).font(ViewerUIMetrics.font(.caption)).foregroundStyle(.red).textSelection(.enabled)
        }
      }

      if exportTask != nil {
        ProgressView(value: Double(progress), total: Double(max(1, items.count)))
        Text(L10n.format("%d / %d개 처리", progress, items.count))
          .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        if let result {
          Button(BatchResizeL10n.text("완료한 파일 공유…")) {
            FileSharingService.shared.share(urls: result.completed.map(\.destinationURL))
          }.disabled(result.completed.isEmpty)
          Button("저장 폴더 보기") {
            if let destinationFolder { NSWorkspace.shared.open(destinationFolder) }
          }
          Button("완료") { dismiss() }.keyboardShortcut(.defaultAction)
        } else if exportTask != nil {
          Button(cancellationRequested ? L10n.text("중지하는 중…") : L10n.text("변환 중지")) {
            cancellationRequested = true
            exportTask?.cancel()
          }.disabled(cancellationRequested)
        } else {
          Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
          Button("변환 시작") { startExport() }
            .keyboardShortcut(.defaultAction)
            .disabled(items.isEmpty || errorMessage != nil || plannedFolder != destinationFolder
              || plannedFormat != format || resizeOptions == nil)
        }
      }
    }
    .viewerPadding(20)
    .viewerFrame(width: 780, height: 730)
  }

  private func resultView(_ result: BatchExportResult) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(result.wasCancelled ? L10n.text("변환 중지됨") : L10n.text("변환 작업 완료"),
        systemImage: result.wasCancelled ? "stop.circle" : "checkmark.circle")
        .font(ViewerUIMetrics.font(.headline))
      Text(L10n.format("%d개 저장 · %d개 실패 · %d개 미처리", result.completed.count,
        result.failures.count, max(0, items.count - result.completed.count - result.failures.count)))
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
            Text(failure.sourceURL.lastPathComponent + " — " + failure.message)
              .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.red).textSelection(.enabled)
          }
        }.viewerFrame(maxWidth: .infinity, alignment: .leading)
      }
      Text("완료된 파일은 저장 폴더에 남아 있습니다.")
        .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
    }.viewerFrame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func chooseDestination() {
    let panel = NSOpenPanel()
    panel.title = L10n.text("변환한 파일을 저장할 폴더")
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK { destinationFolder = panel.url }
  }

  private func updatePreview() async {
    items = []
    errorMessage = nil
    plannedFolder = nil
    plannedFormat = nil
    guard let folder = destinationFolder else { return }
    let targetFormat = format
    do {
      let preview = try await BatchImageExporter.planInBackground(
        urls: urls, destinationFolder: folder, format: targetFormat)
      guard !Task.isCancelled else { return }
      items = preview
      plannedFolder = folder
      plannedFormat = targetFormat
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
  }

  private func startExport() {
    guard !items.isEmpty, plannedFolder == destinationFolder, plannedFormat == format,
      let resize = resizeOptions else { return }
    progress = 0
    cancellationRequested = false
    exportTask = Task {
      result = await store.convertSelectedFiles(items: items, format: format, quality: quality,
        resize: resize, watermark: watermark) {
        completed, _ in
        Task { @MainActor in progress = completed }
      }
      exportTask = nil
    }
  }
}
