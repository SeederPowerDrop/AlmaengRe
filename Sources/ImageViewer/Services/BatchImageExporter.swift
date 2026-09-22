import Darwin
import Foundation

struct BatchExportItem: Identifiable, Sendable {
  let sourceURL: URL
  let destinationURL: URL

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
    try validateFolder(destinationFolder)
    guard urls.allSatisfy(\.isFileURL) else {
      throw BatchImageExportError.nonFileURL
    }

    // 대소문자 구분 볼륨에서도 다른 Mac으로 옮길 때 충돌할 이름은 피합니다.
    var reservedNames = try existingNames(in: destinationFolder)
    let sourcePaths = Set(urls.map(pathKey))
    var seenSources = Set<URL>()
    var items: [BatchExportItem] = []
    for sourceURL in urls where seenSources.insert(sourceURL.standardizedFileURL).inserted {
      let stem = sourceURL.deletingPathExtension().lastPathComponent
      var number = 1
      while true {
        let suffix = number == 1 ? "" : "-\(number)"
        let filename = "\(stem)\(suffix).\(format.fileExtension)"
        try validateFilename(filename)
        let destinationURL = destinationFolder.appendingPathComponent(filename, isDirectory: false)
        let key = nameKey(filename)
        if !reservedNames.contains(key), !sourcePaths.contains(pathKey(destinationURL)) {
          reservedNames.insert(key)
          items.append(BatchExportItem(sourceURL: sourceURL, destinationURL: destinationURL))
          break
        }
        number += 1
      }
    }
    return items
  }

  func export(
    items: [BatchExportItem],
    format: ExportFormat,
    quality: Double,
    adjustments: [URL: ImageAdjustments],
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
          adjustments: adjustments[item.sourceURL] ?? .identity
        )
        try Task.checkCancellation()
        // 미리보기 뒤 추가된 파일이나 대소문자·유니코드 변형도 다시 검사합니다.
        try Self.validate(item, format: format, sourcePaths: sourcePaths)
        try Self.publish(temporaryURL, to: item.destinationURL)
        completed.append(item)
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
    Set(try FileManager.default.contentsOfDirectory(atPath: folder.path).map(nameKey))
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
