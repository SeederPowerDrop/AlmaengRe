import AppKit
import SwiftUI

/// Review and operate on the captured selection, even if the library later refreshes.
struct BatchFileOperationSheet: View {
  @ObservedObject var store: AppStore
  let request: BatchFileOperationRequest
  @Environment(\.dismiss) private var dismiss

  @State private var destinationFolder: URL?
  @State private var securityScopedFolder: URL?
  @State private var plan: BatchFileOperationPlan?
  @State private var plannedFolder: URL?
  @State private var previewGeneration = UUID()
  @State private var isPlanning = false
  @State private var planningError: String?
  @State private var progress = 0
  @State private var result: BatchFileOperationResult?
  @State private var operationTask: Task<Void, Never>?
  @State private var cancellationRequested = false

  private var isRunning: Bool { operationTask != nil }
  private var operationKey: String {
    switch request.operation {
    case .copy: "copy"
    case .move: "move"
    case .trash: "trash"
    }
  }
  private var symbol: String {
    switch request.operation {
    case .copy: "doc.on.doc"
    case .move: "folder"
    case .trash: "trash"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        Label(FileOperationsL10n.text(operationKey + ".title"), systemImage: symbol)
          .font(.title2.bold())
        Spacer()
        Text(FileOperationsL10n.format("selected.count", request.assets.count))
          .foregroundStyle(.secondary).monospacedDigit()
      }

      if let result {
        resultView(result)
      } else {
        Text(FileOperationsL10n.text(operationKey + ".help"))
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        if request.operation != .trash { destinationPicker }

        HStack {
          Text(FileOperationsL10n.text("preview.title")).font(.headline)
          Spacer()
          if isPlanning { ProgressView().controlSize(.small) }
        }

        previewList

        if let planningError {
          Label(planningError, systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
      }

      Divider()
      footer
    }
    .padding(20)
    .frame(minWidth: 620, idealWidth: 700, maxWidth: 820, minHeight: 460, idealHeight: 560)
    .interactiveDismissDisabled(isRunning)
    .accessibilityIdentifier("fileOperation.sheet")
    .task(id: destinationFolder) { await updatePreview() }
    .onDisappear {
      operationTask?.cancel()
      securityScopedFolder?.stopAccessingSecurityScopedResource()
    }
  }

  private var destinationPicker: some View {
    HStack(spacing: 12) {
      Image(systemName: "folder.fill").font(.title2).foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        Text(FileOperationsL10n.text("destination.title")).font(.headline)
        Text(destinationFolder?.path ?? FileOperationsL10n.text("destination.none"))
          .font(.callout).foregroundStyle(.secondary)
          .lineLimit(2).truncationMode(.middle)
          .help(destinationFolder?.path ?? "")
          .accessibilityIdentifier("fileOperation.destination")
      }
      Spacer(minLength: 8)
      Button(FileOperationsL10n.text("destination.choose"), action: chooseDestination)
        .disabled(isRunning)
        .accessibilityIdentifier("fileOperation.chooseDestination")
    }
    .padding(12)
    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }

  @ViewBuilder
  private var previewList: some View {
    if let plan {
      Table(plan.entries) {
        TableColumn(FileOperationsL10n.text("preview.source")) { entry in
          Text(entry.displayName).lineLimit(1).truncationMode(.middle)
            .help(entry.sourceURL.path)
        }
        TableColumn(FileOperationsL10n.text("preview.destination")) { entry in
          if let destination = entry.destinationURL {
            Text(destination.lastPathComponent).lineLimit(1).truncationMode(.middle)
              .help(destination.path)
          } else {
            Label(FileOperationsL10n.text("trash.apply"), systemImage: "trash")
              .foregroundStyle(.secondary)
          }
        }
      }
      .opacity(isPlanning ? 0.5 : 1)
    } else {
      List(request.assets) { asset in
        Label(asset.filename, systemImage: asset.isVideo ? "film" : "photo")
          .lineLimit(1).truncationMode(.middle).help(asset.url.path)
      }
    }
  }

  private func resultView(_ result: BatchFileOperationResult) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(FileOperationsL10n.text("result.title"),
        systemImage: result.wasCancelled ? "stop.circle" :
          (result.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle"))
        .font(.headline)
      Text(FileOperationsL10n.format("result.summary", result.completed.count, result.failures.count))
        .monospacedDigit()
      if result.wasCancelled {
        Text(FileOperationsL10n.text("result.cancelled"))
          .font(.callout).foregroundStyle(.secondary)
        Text(FileOperationsL10n.format("result.remaining",
          max(0, request.assets.count - result.completed.count - result.failures.count)))
          .font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
      List {
        ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
          VStack(alignment: .leading, spacing: 4) {
            Label(sourceName(for: failure.sourceURL), systemImage: "exclamationmark.circle")
              .lineLimit(1).truncationMode(.middle)
            Text(failure.message).font(.caption).textSelection(.enabled)
          }
          .foregroundStyle(.red).padding(.vertical, 3)
        }
        ForEach(result.completed) { entry in
          VStack(alignment: .leading, spacing: 3) {
            Label(entry.displayName, systemImage: "checkmark.circle.fill")
              .lineLimit(1).truncationMode(.middle)
            if request.operation != .trash, let destination = entry.destinationURL {
              Text(destination.path).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
          }
          .padding(.vertical, 3)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var footer: some View {
    HStack(spacing: 12) {
      if isRunning {
        VStack(alignment: .leading, spacing: 5) {
          Text(cancellationRequested ? FileOperationsL10n.text("progress.stopping") :
            FileOperationsL10n.format("progress", progress, request.assets.count))
            .font(.caption).foregroundStyle(.secondary)
          ProgressView(value: Double(progress), total: Double(max(1, request.assets.count)))
        }
        Spacer(minLength: 12)
        Button(FileOperationsL10n.text("action.stop")) {
          cancellationRequested = true
          operationTask?.cancel()
        }
        .disabled(cancellationRequested)
        .accessibilityIdentifier("fileOperation.stop")
      } else if result != nil {
        Spacer()
        Button(FileOperationsL10n.text("action.close")) { dismiss() }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("fileOperation.close")
      } else {
        Spacer()
        Button(FileOperationsL10n.text("action.cancel"), role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(FileOperationsL10n.text(operationKey + ".apply"),
          role: request.operation == .trash ? .destructive : nil, action: apply)
          .keyboardShortcut(.defaultAction)
          .disabled(isPlanning || planningError != nil || plan == nil || plannedFolder != destinationFolder)
          .accessibilityIdentifier("fileOperation.apply")
      }
    }
  }

  private func sourceName(for url: URL) -> String {
    request.assets.first(where: { $0.url == url })?.filename ?? url.lastPathComponent
  }

  private func chooseDestination() {
    let panel = NSOpenPanel()
    panel.title = FileOperationsL10n.text("destination.title")
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = destinationFolder
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    securityScopedFolder?.stopAccessingSecurityScopedResource()
    securityScopedFolder = folder.startAccessingSecurityScopedResource() ? folder : nil
    destinationFolder = folder
  }

  private func updatePreview() async {
    guard result == nil, !isRunning else { return }
    let generation = UUID()
    previewGeneration = generation
    defer {
      if previewGeneration == generation { isPlanning = false }
    }
    plan = nil
    plannedFolder = nil
    planningError = nil
    guard request.operation == .trash || destinationFolder != nil else { return }
    isPlanning = true
    let folder = destinationFolder
    let assets = request.assets
    let operation = request.operation
    do {
      let worker = Task.detached(priority: .userInitiated) {
        try BatchFileOperationPlanner.plan(assets: assets, operation: operation, destinationFolder: folder)
      }
      let preview = try await withTaskCancellationHandler {
        try await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard !Task.isCancelled, previewGeneration == generation else { return }
      plan = preview
      plannedFolder = folder
    } catch {
      guard !Task.isCancelled, previewGeneration == generation else { return }
      planningError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
  }

  private func apply() {
    guard let plan, !isPlanning, !isRunning, result == nil, planningError == nil,
      plannedFolder == destinationFolder else { return }
    progress = 0
    cancellationRequested = false
    operationTask = Task {
      result = await store.performFileOperation(plan) { completed, _ in
        Task { @MainActor in progress = completed }
      }
      operationTask = nil
    }
  }
}
