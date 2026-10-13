import Foundation

enum PhotoMarkExportError: LocalizedError {
  case unavailableOutput(URL)

  var errorDescription: String? {
    switch self {
    case .unavailableOutput(let url):
      PhotoMarkL10n.text("storage.error") + "\n" + url.lastPathComponent + "\n"
        + CocoaError(.fileReadNoSuchFile).localizedDescription
    }
  }
}

/// Captures only classification values for one export operation, never pixels.
/// Keeping this snapshot independent of the current selection also protects
/// long-running exports when a sheet closes or its caller is cancelled.
struct PhotoMarkExportContext: Sendable {
  let marks: [URL: Set<PhotoMarkSlot>]
  let sources: [URL: ImageAsset]
  let store: PhotoMarkStore?

  static let disabled = PhotoMarkExportContext(marks: [:], sources: [:], store: nil)

  @MainActor
  func commit(_ completed: [BatchExportItem]) async throws {
    guard let store, !marks.isEmpty, !completed.isEmpty else { return }
    // A batch may have been cancelled after publishing some files. Those files
    // still need their database writes, so use an uncancelled reconciliation.
    try await Task { @MainActor in
      let markedItems = completed.filter { marks[$0.sourceURL.standardizedFileURL]?.isEmpty == false }
      guard !markedItems.isEmpty else { return }
      let access = ImageLibraryAccess(markedItems.map(\.destinationURL))
      defer { withExtendedLifetime(access) {} }
      var unavailableOutput: URL?
      for item in markedItems {
        let sourceURL = item.sourceURL.standardizedFileURL
        let captured: BatchExportItem
        if item.destinationAsset != nil, item.destinationReference != nil {
          captured = item
        } else {
          // Single-image, AI and motion exports reach this path. Capture each
          // separately so one missing output cannot discard other saved files.
          captured = await Task.detached { BatchImageExporter.captureCompletedItem(item) }.value
        }
        guard let output = captured.destinationAsset, let reference = captured.destinationReference,
          let source = sources[sourceURL] else {
          unavailableOutput = unavailableOutput ?? item.destinationURL
          continue
        }
        await store.commitTransferredMarks(marks[sourceURL] ?? [], from: source,
          to: output, reference: reference, moving: false)
      }
      await store.flushAsync()
      guard store.isReady else {
        throw PhotoMarkPersistenceError(message: store.errorMessage ?? PhotoMarkL10n.text("storage.error"))
      }
      if let unavailableOutput { throw PhotoMarkExportError.unavailableOutput(unavailableOutput) }
    }.value
  }
}

extension AppStore {
  @MainActor
  func prepareExportPhotoMarks(for sourceAssets: [ImageAsset]) async throws -> PhotoMarkExportContext {
    guard photoMarkPreferences.inheritOnExport else { return .disabled }
    await photoMarks.waitUntilReady()
    try Task.checkCancellation()
    guard photoMarks.isReady else {
      throw PhotoMarkPersistenceError(message: photoMarks.errorMessage ?? PhotoMarkL10n.text("storage.error"))
    }
    var marks: [URL: Set<PhotoMarkSlot>] = [:]
    var sources: [URL: ImageAsset] = [:]
    for asset in sourceAssets {
      let classifications = photoMarks.marks(for: asset)
      if !classifications.isEmpty {
        marks[asset.url.standardizedFileURL] = classifications
        sources[asset.url.standardizedFileURL] = asset
      }
    }
    return PhotoMarkExportContext(marks: marks, sources: sources, store: photoMarks)
  }

  /// Resolve the captured source, including archive identity, rather than the
  /// photo that happens to be focused when an AI or batch save starts.
  @MainActor
  func prepareExportPhotoMarks(sourceURLs: [URL]) async throws -> PhotoMarkExportContext {
    guard photoMarkPreferences.inheritOnExport else { return .disabled }
    let requested = Set(sourceURLs.map(\.standardizedFileURL))
    var known: [URL: ImageAsset] = [:]
    for asset in allAssets where requested.contains(asset.url.standardizedFileURL) {
      known[asset.url.standardizedFileURL] = asset
    }
    for asset in batchAssets where requested.contains(asset.url.standardizedFileURL) {
      known[asset.url.standardizedFileURL] = asset
    }
    var sources = sourceURLs.compactMap { known[$0.standardizedFileURL] }
    let missing = sourceURLs.filter { known[$0.standardizedFileURL] == nil }
    if !missing.isEmpty {
      do { sources += try await ImageLibrary().assets(from: missing, includesVideos: true) }
      catch is CancellationError { throw CancellationError() }
      catch {
        // Let the exporter report an unavailable source per file. One stale
        // source must not prevent the rest of a valid batch from being saved.
      }
    }
    return try await prepareExportPhotoMarks(for: sources)
  }
}
