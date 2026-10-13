import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AIUpscalingStore: ObservableObject {
  @Published private(set) var sourceURL: URL?
  @Published private(set) var result: AIUpscalingResult?
  @Published private(set) var progress = 0.0
  @Published private(set) var isRunning = false
  @Published private(set) var isSaving = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var savedURL: URL?

  private let pipeline: ImagePipeline
  private let service: AIUpscalingService
  private var task: Task<Void, Never>?
  private var generation = UUID()

  init(pipeline: ImagePipeline, service: AIUpscalingService = AIUpscalingService()) {
    self.pipeline = pipeline
    self.service = service
  }

  func prepare(sourceURL: URL?) {
    if self.sourceURL == sourceURL {
      // Reopening the tool after replacing a file at the same path must not
      // present the previous file's enlargement as the current result.
      guard let result, ImageFileVersion(url: result.sourceURL) != result.sourceVersion else { return }
    }
    cancel()
    self.sourceURL = sourceURL
    result = nil
    savedURL = nil
    errorMessage = nil
    progress = 0
  }

  func start() {
    guard let sourceURL, !isRunning, !isSaving else { return }
    cancel()
    let ticket = generation
    let version = ImageFileVersion(url: sourceURL)
    let pipeline = pipeline
    let service = service
    result = nil
    savedURL = nil
    errorMessage = nil
    progress = 0
    isRunning = true
    task = Task { [weak self] in
      do {
        // Check dimensions before requesting a full-size decode, including files
        // with maliciously large headers and images too large for a 4x pixel count.
        let metadata = try await pipeline.metadata(for: sourceURL)
        _ = try AIUpscalingPolicy.outputSize(width: metadata.pixelWidth, height: metadata.pixelHeight)
        try Task.checkCancellation()
        let frame = try await pipeline.renderFrame(url: sourceURL, frameIndex: 0,
          maxPixelSize: nil, adjustments: .identity, prefersHDR: false)
        let output = try await service.upscale(frame, sourceURL: sourceURL, sourceVersion: version) { [weak self] value in
          Task { @MainActor [weak self] in
            guard let self, self.generation == ticket else { return }
            self.progress = max(self.progress, value)
          }
        }
        try Task.checkCancellation()
        guard let self, self.generation == ticket, self.sourceURL == sourceURL else { return }
        guard ImageFileVersion(url: sourceURL) == version else { throw AIUpscalingError.sourceChanged }
        self.result = output
        self.progress = 1
        self.isRunning = false
        self.task = nil
      } catch {
        guard let self, self.generation == ticket else { return }
        self.isRunning = false
        self.task = nil
        if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
      }
    }
  }

  func cancel() {
    generation = UUID()
    task?.cancel()
    task = nil
    isRunning = false
    isSaving = false
  }

  func chooseSaveDestination(
    preparePhotoMarks: @escaping @MainActor (URL) async throws -> PhotoMarkExportContext = { _ in .disabled }
  ) {
    guard let result, !isRunning, !isSaving else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.canCreateDirectories = true
    panel.title = L10n.text("AI 확대 사본 저장")
    panel.nameFieldStringValue = result.sourceURL.deletingPathExtension().lastPathComponent + "-AI-2x.png"
    panel.directoryURL = result.sourceURL.deletingLastPathComponent()
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    save(to: destination, preparePhotoMarks: preparePhotoMarks)
  }

  func save(to destination: URL,
    preparePhotoMarks: @escaping @MainActor (URL) async throws -> PhotoMarkExportContext = { _ in .disabled }
  ) {
    guard let result, !isRunning, !isSaving else { return }
    guard result.sourceURL == sourceURL, ImageFileVersion(url: result.sourceURL) == result.sourceVersion else {
      errorMessage = AIUpscalingError.sourceChanged.localizedDescription
      return
    }
    let ticket = generation
    let service = service
    errorMessage = nil
    isSaving = true
    task = Task { [weak self] in
      let access = destination.startAccessingSecurityScopedResource()
      defer { if access { destination.stopAccessingSecurityScopedResource() } }
      do {
        let classifications = try await preparePhotoMarks(result.sourceURL)
        try Task.checkCancellation()
        try await service.savePNG(result, to: destination)
        // Saving may commit just before the sheet closes. Persist that output's
        // captured classifications before discarding obsolete UI state.
        try await classifications.commit([BatchExportItem(sourceURL: result.sourceURL, destinationURL: destination)])
        guard let self, self.generation == ticket else { return }
        self.savedURL = destination
        self.isSaving = false
        self.task = nil
      } catch {
        guard let self, self.generation == ticket else { return }
        self.isSaving = false
        self.task = nil
        if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
      }
    }
  }
}
