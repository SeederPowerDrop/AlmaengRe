import Darwin
import Foundation

struct BatchExportItem: Identifiable, Sendable {
  let sourceURL: URL
  let destinationURL: URL
  var destinationAsset: ImageAsset? = nil
  var destinationReference: PhotoMarkFileReference? = nil

  var id: URL { sourceURL }
}

struct BatchExportFailure: Sendable {
  let sourceURL: URL
  let message: String
}

struct BatchExportResult: Sendable {
  let completed: [BatchExportItem]
  let failures: [BatchExportFailure]
  let wasCancelled: Bool
}

enum BatchImageExportError: LocalizedError {
  case invalidFolder
  case nonFileURL
  case invalidExtension(ExportFormat)
  case invalidFilename
  case sourceOverwrite
  case filenameAlreadyExists(String)

  var errorDescription: String? {
    switch self {
    case .invalidFolder:
      L10n.text("변환한 파일을 저장할 폴더를 선택해 주세요.")
    case .nonFileURL:
      L10n.text("변환할 파일은 Mac의 로컬 파일이어야 합니다.")
    case .invalidExtension(let format):
      L10n.format("출력 파일의 확장자는 ‘.%@’이어야 합니다.", format.fileExtension)
    case .invalidFilename:
      L10n.text("출력 파일 이름이 올바르지 않거나 너무 깁니다.")
    case .sourceOverwrite:
      L10n.text("원본 파일을 덮어쓰는 변환은 허용되지 않습니다.")
    case .filenameAlreadyExists(let filename):
      L10n.format("같은 폴더에 ‘%@’ 파일이 이미 있습니다.", filename)
    }
  }
}

/// 한 장씩 변환하고, 완성된 파일만 원본과 겹치지 않는 경로에 공개합니다.
actor BatchImageExporter {
  private let exporter: ImageExporter

  init(pipeline: ImagePipeline) {
    exporter = ImageExporter(pipeline: pipeline)
  }

  static func plan(
    urls: [URL],
    destinationFolder: URL,
    format: ExportFormat
  ) throws -> [BatchExportItem] {
    try Task.checkCancellation()
    try validateFolder(destinationFolder)
    guard urls.allSatisfy(\.isFileURL) else {
      throw BatchImageExportError.nonFileURL
    }

    // 대소문자 구분 볼륨에서도 다른 Mac으로 옮길 때 충돌할 이름은 피합니다.
    var reservedNames = try existingNames(in: destinationFolder)
    let sourcePaths = try Set(urls.map { url in
      try Task.checkCancellation()
      return pathKey(url)
    })
    var seenSources = Set<URL>()
    // A burst or a set of albums can contain thousands of identically named photos.
    // Resume after the last allocated suffix instead of probing 1...N for each one.
    var nextNumbers: [String: Int] = [:]
    var items: [BatchExportItem] = []
    for sourceURL in urls where seenSources.insert(sourceURL.standardizedFileURL).inserted {
      try Task.checkCancellation()
      let stem = sourceURL.deletingPathExtension().lastPathComponent
      let stemKey = nameKey(stem)
      var number = nextNumbers[stemKey] ?? 1
      while true {
        try Task.checkCancellation()
        let suffix = number == 1 ? "" : "-\(number)"
        let filename = "\(stem)\(suffix).\(format.fileExtension)"
        try validateFilename(filename)
        let destinationURL = destinationFolder.appendingPathComponent(filename, isDirectory: false)
        let key = nameKey(filename)
        if !reservedNames.contains(key), !sourcePaths.contains(pathKey(destinationURL)) {
          reservedNames.insert(key)
          items.append(BatchExportItem(sourceURL: sourceURL, destinationURL: destinationURL))
          nextNumbers[stemKey] = number + 1
          break
        }
        number += 1
      }
    }
    return items
  }

  /// Cancellation of a dismissed or superseded SwiftUI preview must reach its worker.
  /// Awaiting an unstructured task's value alone does not cancel that task.
  static func planInBackground(
    urls: [URL], destinationFolder: URL, format: ExportFormat
  ) async throws -> [BatchExportItem] {
    try Task.checkCancellation()
    let worker = Task.detached(priority: .userInitiated) {
      try plan(urls: urls, destinationFolder: destinationFolder, format: format)
    }
    return try await withTaskCancellationHandler {
      let items = try await worker.value
      try Task.checkCancellation()
      return items
    } onCancel: {
      worker.cancel()
    }
  }

  func export(
    items: [BatchExportItem],
    format: ExportFormat,
    quality: Double,
    resize: BatchResizeOptions = .original,
    watermark: WatermarkOptions = .disabled,
    adjustments: [URL: ImageAdjustments],
    photoMarkSourceURLs: Set<URL> = [],
    progress: @Sendable (Int, Int) -> Void
  ) async -> BatchExportResult {
    var completed: [BatchExportItem] = []
    var failures: [BatchExportFailure] = []
    var wasCancelled = false
    let sourcePaths = Set(items.map { Self.pathKey($0.sourceURL) })
    progress(0, items.count)

    for item in items {
      if Task.isCancelled {
        wasCancelled = true
        break
      }
      do {
        try Self.validate(item, format: format, sourcePaths: sourcePaths)
        let temporaryURL = try Self.makeTemporaryFile(in: item.destinationURL.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        try await exporter.export(
          sourceURL: item.sourceURL,
          destinationURL: temporaryURL,
          format: format,
          quality: quality,
          adjustments: adjustments[item.sourceURL] ?? .identity,
          resize: resize,
          watermark: watermark
        )
        try Task.checkCancellation()
        // 미리보기 뒤 추가된 파일이나 대소문자·유니코드 변형도 다시 검사합니다.
        try Self.validate(item, format: format, sourcePaths: sourcePaths)
        try Self.publish(temporaryURL, to: item.destinationURL)
        completed.append(photoMarkSourceURLs.contains(item.sourceURL.standardizedFileURL)
          ? Self.captureCompletedItem(item) : item)
      } catch is CancellationError {
        wasCancelled = true
        break
      } catch {
        failures.append(BatchExportFailure(sourceURL: item.sourceURL, message: error.localizedDescription))
      }
      progress(completed.count + failures.count, items.count)
    }

    return BatchExportResult(
      completed: completed,
      failures: failures,
      wasCancelled: wasCancelled || Task.isCancelled
    )
  }

  private static func validate(
    _ item: BatchExportItem,
    format: ExportFormat,
    sourcePaths: Set<String>
  ) throws {
    guard item.sourceURL.isFileURL, item.destinationURL.isFileURL else {
      throw BatchImageExportError.nonFileURL
    }
    let filename = item.destinationURL.lastPathComponent
    try validateFilename(filename)
    guard nameKey(item.destinationURL.pathExtension) == nameKey(format.fileExtension) else {
      throw BatchImageExportError.invalidExtension(format)
    }
    guard !sourcePaths.contains(pathKey(item.destinationURL)) else {
      throw BatchImageExportError.sourceOverwrite
    }
    let folder = item.destinationURL.deletingLastPathComponent()
    try validateFolder(folder)
    guard try !existingNames(in: folder).contains(nameKey(filename)) else {
      throw BatchImageExportError.filenameAlreadyExists(filename)
    }
  }

  /// Capture identity immediately after publication, before another export can
  /// fail because a removable destination disappeared. Only opt-in, marked
  /// sources need a bookmark; the usual export does no extra tracking work.
  static func captureCompletedItem(_ item: BatchExportItem) -> BatchExportItem {
    guard let snapshot = try? BatchFileOperationSourceSnapshot.capture(item.destinationURL),
      let identity = PhotoMarkFileIdentity.read(item.destinationURL) else { return item }
    let asset = ImageAsset(url: item.destinationURL, byteCount: snapshot.size,
      modificationDate: Date(timeIntervalSince1970: Double(snapshot.modifiedSeconds)
        + Double(snapshot.modifiedNanoseconds) / 1_000_000_000),
      creationDate: Date(timeIntervalSince1970: Double(identity.birthSeconds)
        + Double(identity.birthNanoseconds) / 1_000_000_000), photoMarkIdentity: identity.key)
    guard let reference = PhotoMarkFileReference.capture(for: asset),
      (try? BatchFileOperationSourceSnapshot.capture(item.destinationURL)) == snapshot else { return item }
    return BatchExportItem(sourceURL: item.sourceURL, destinationURL: item.destinationURL,
      destinationAsset: asset, destinationReference: reference)
  }

  private static func validateFolder(_ folder: URL) throws {
    guard folder.isFileURL,
      (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    else {
      throw BatchImageExportError.invalidFolder
    }
  }

  private static func validateFilename(_ filename: String) throws {
    guard !filename.isEmpty, filename != ".", filename != "..",
      !filename.contains("/"), !filename.contains("\0"), filename.utf8.count <= 255
    else {
      throw BatchImageExportError.invalidFilename
    }
  }

  private static func existingNames(in folder: URL) throws -> Set<String> {
    try Set(FileManager.default.contentsOfDirectory(atPath: folder.path).map { filename in
      try Task.checkCancellation()
      return nameKey(filename)
    })
  }

  private static func nameKey(_ name: String) -> String {
    name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .precomposedStringWithCanonicalMapping
  }

  private static func pathKey(_ url: URL) -> String {
    nameKey(url.standardizedFileURL.resolvingSymlinksInPath().path)
  }

  private static func makeTemporaryFile(in folder: URL) throws -> URL {
    let template = folder.appendingPathComponent(".imageviewer-convert-XXXXXX").path
    var buffer = Array(template.utf8CString)
    let descriptor = mkstemp(&buffer)
    guard descriptor >= 0 else { throw currentPOSIXError() }
    close(descriptor)
    let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    return URL(fileURLWithPath: path)
  }

  private static func publish(_ temporaryURL: URL, to destinationURL: URL) throws {
    // 존재 검사와 일반 이동 사이의 경합까지 막도록 OS의 배타적 이동을 사용합니다.
    // 같은 폴더 안에서 완성된 파일을 공개하며 기존 파일을 교체하지 않습니다.
    guard renamex_np(temporaryURL.path, destinationURL.path, UInt32(RENAME_EXCL)) == 0 else {
      if errno == EEXIST {
        throw BatchImageExportError.filenameAlreadyExists(destinationURL.lastPathComponent)
      }
      throw currentPOSIXError()
    }
  }

  private static func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
