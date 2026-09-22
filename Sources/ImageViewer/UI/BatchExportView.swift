import AppKit
import SwiftUI

struct BatchExportView: View {
  @ObservedObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  private let urls: [URL]
  @State private var format: ExportFormat
  @State private var quality = 0.92
  @State private var destinationFolder: URL?
  @State private var items: [BatchExportItem] = []
  @State private var plannedFormat: ExportFormat?
  @State private var plannedFolder: URL?
  @State private var errorMessage: String?
  @State private var progress = 0
  @State private var result: BatchExportResult?
  @State private var exportTask: Task<Void, Never>?
  @State private var cancellationRequested = false

  init(store: AppStore) {
    self.store = store
    urls = store.selectedAssets.map(\.url)
    _format = State(initialValue: ExportFormat.available.first ?? .jpeg)
  }

  private var previewKey: String {
    format.rawValue + "|" + (destinationFolder?.path ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("형식 일괄 변환", systemImage: "photo.on.rectangle.angled")
          .font(.title2.bold())
        Spacer()
        Text(L10n.format("%d개 선택", urls.count)).foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Picker("저장 형식", selection: $format) {
            ForEach(ExportFormat.available) { item in Text(item.title).tag(item) }
          }.frame(width: 250)
          if format.usesLossyQuality {
            Text("품질")
            Slider(value: $quality, in: 0.1...1).frame(width: 180)
            Text("\(Int(quality * 100))%").monospacedDigit().frame(width: 44)
          }
        }
        HStack {
          Button("저장 폴더 선택…") { chooseDestination() }
          Text(destinationFolder?.path ?? L10n.text("저장할 폴더를 선택하세요."))
            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            .help(destinationFolder?.path ?? "")
        }
        Text("원본을 보존하고 현재 조정값을 적용한 새 파일을 만듭니다. 이름이 겹치면 번호를 붙입니다. 애니메이션·다중 페이지는 첫 프레임만 저장합니다.")
          .font(.caption).foregroundStyle(.secondary)
      }
      .disabled(exportTask != nil || result != nil)

      Divider()
      if let result {
        resultView(result)
      } else {
        Text("저장 미리보기").font(.headline)
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
          Text(errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
      }

      if exportTask != nil {
        ProgressView(value: Double(progress), total: Double(max(1, items.count)))
        Text(L10n.format("%d / %d개 처리", progress, items.count))
          .font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        if result != nil {
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
              || plannedFormat != format)
        }
      }
    }
    .padding(20)
    .frame(width: 740, height: 590)
    .interactiveDismissDisabled(exportTask != nil)
    .task(id: previewKey) { await updatePreview() }
  }

  private func resultView(_ result: BatchExportResult) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(result.wasCancelled ? L10n.text("변환 중지됨") : L10n.text("변환 작업 완료"),
        systemImage: result.wasCancelled ? "stop.circle" : "checkmark.circle")
        .font(.headline)
      Text(L10n.format("%d개 저장 · %d개 실패 · %d개 미처리", result.completed.count,
        result.failures.count, max(0, items.count - result.completed.count - result.failures.count)))
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
            Text(failure.sourceURL.lastPathComponent + " — " + failure.message)
              .font(.caption).foregroundStyle(.red).textSelection(.enabled)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      Text("완료된 파일은 저장 폴더에 남아 있습니다.")
        .font(.caption).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
      let preview = try await Task.detached(priority: .userInitiated) {
        try BatchImageExporter.plan(urls: urls, destinationFolder: folder, format: targetFormat)
      }.value
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
    guard !items.isEmpty, plannedFolder == destinationFolder, plannedFormat == format else { return }
    progress = 0
    cancellationRequested = false
    exportTask = Task {
      result = await store.convertSelectedFiles(items: items, format: format, quality: quality) {
        completed, _ in
        Task { @MainActor in progress = completed }
      }
      exportTask = nil
    }
  }
}
