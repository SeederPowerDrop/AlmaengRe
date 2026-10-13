import Darwin
import Foundation

enum BatchFileOperation: String, Identifiable, Sendable {
  case copy, move, trash
  var id: Self { self }
}

struct BatchFileOperationEntry: Identifiable, Sendable {
  var id: URL { sourceURL }
  let sourceURL: URL
  let destinationURL: URL?
  let sourceSnapshot: BatchFileOperationSourceSnapshot
  let displayName: String
  /// Captured while the committed destination is still accessible. A later
  /// removable-volume failure must not lose the completed file's classifications.
  let destinationAsset: ImageAsset?
  let destinationReference: PhotoMarkFileReference?

  init(sourceURL: URL, destinationURL: URL?, sourceSnapshot: BatchFileOperationSourceSnapshot,
    displayName: String, destinationAsset: ImageAsset? = nil,
    destinationReference: PhotoMarkFileReference? = nil) {
    self.sourceURL = sourceURL
    self.destinationURL = destinationURL
    self.sourceSnapshot = sourceSnapshot
    self.displayName = displayName
    self.destinationAsset = destinationAsset
    self.destinationReference = destinationReference
  }

  func completing(at destinationURL: URL?, asset: ImageAsset? = nil,
    reference: PhotoMarkFileReference? = nil) -> Self {
    Self(sourceURL: sourceURL, destinationURL: destinationURL,
      sourceSnapshot: sourceSnapshot, displayName: displayName,
      destinationAsset: asset, destinationReference: reference)
  }
}

struct BatchFileOperationPlan: Sendable {
  let operation: BatchFileOperation
  let entries: [BatchFileOperationEntry]
  let destinationFolder: URL?
  let destinationSnapshot: BatchFileOperationDirectorySnapshot?
  // Archive extraction must remain alive while the picker, preview or operation is open.
  let retainedAssets: [ImageAsset]
}

struct BatchFileOperationFailure: Identifiable, Sendable {
  var id: URL { sourceURL }
  let sourceURL: URL
  let message: String
}

struct BatchFileOperationResult: Sendable {
  let completed: [BatchFileOperationEntry]
  let failures: [BatchFileOperationFailure]
  let wasCancelled: Bool
}

enum BatchFileOperationError: LocalizedError {
  case invalidPlan(String)
  var errorDescription: String? {
    switch self { case .invalidPlan(let message): message }
  }
}

/// File identity and nanosecond modification/change times are checked again just before I/O.
struct BatchFileOperationSourceSnapshot: Equatable, Sendable {
  let device: Int32
  let inode: UInt64
  let size: Int64
  let modifiedSeconds: Int
  let modifiedNanoseconds: Int
  let changedSeconds: Int
  let changedNanoseconds: Int

  static func capture(_ url: URL) throws -> Self {
    let info = try BatchFileOperationPlanner.fileInfo(url)
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
      throw BatchFileOperationError.invalidPlan(FileOperationsL10n.text("error.regularFile"))
    }
    return Self(device: info.st_dev, inode: info.st_ino, size: info.st_size,
      modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
      changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
  }
}

struct BatchFileOperationDirectorySnapshot: Equatable, Sendable {
  let device: Int32
  let inode: UInt64

  static func capture(_ url: URL) throws -> Self {
    let info = try BatchFileOperationPlanner.fileInfo(url)
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
      throw BatchFileOperationError.invalidPlan(FileOperationsL10n.text("error.destinationFolder"))
    }
    return Self(device: info.st_dev, inode: info.st_ino)
  }
}

enum BatchFileOperationPlanner {
  static func plan(assets: [ImageAsset], operation: BatchFileOperation,
    destinationFolder: URL? = nil) throws -> BatchFileOperationPlan {
    try Task.checkCancellation()
    guard !assets.isEmpty else {
      throw BatchFileOperationError.invalidPlan(FileOperationsL10n.text("error.emptySelection"))
    }
    guard operation == .copy || !assets.contains(where: \.isReadOnly) else {
      throw BatchFileOperationError.invalidPlan(FileOperationsL10n.text("error.archiveReadOnly"))
    }
    let destination: URL?
    let destinationSnapshot: BatchFileOperationDirectorySnapshot?
    var occupiedNames = Set<String>()
    if operation == .trash {
      destination = nil
      destinationSnapshot = nil
    } else {
      guard let destinationFolder else {
        throw BatchFileOperationError.invalidPlan(FileOperationsL10n.text("error.destinationFolder"))
      }
      let folder = destinationFolder.standardizedFileURL
      destinationSnapshot = try BatchFileOperationDirectorySnapshot.capture(folder)
      destination = folder
      occupiedNames = try Set(FileManager.default.contentsOfDirectory(atPath: folder.path).map(nameKey))
      try Task.checkCancellation()
    }
    var seen = Set<URL>()
    var entries: [BatchFileOperationEntry] = []
    for asset in assets {
      try Task.checkCancellation()
      let source = asset.url.standardizedFileURL
      guard seen.insert(source).inserted else { continue }
      let snapshot = try BatchFileOperationSourceSnapshot.capture(source)
      // A selection may outlive the file that was originally displayed at this
      // path. Archive identities describe their container, not the extracted file.
      if asset.archiveOrigin == nil, let displayedIdentity = asset.photoMarkIdentity {
        guard PhotoMarkFileIdentity.read(source)?.key == displayedIdentity,
          try BatchFileOperationSourceSnapshot.capture(source) == snapshot else {
          throw BatchFileOperationError.invalidPlan(FileOperationsL10n.text("error.sourceChanged"))
        }
      }
      if operation == .move,
        try BatchFileOperationDirectorySnapshot.capture(source.deletingLastPathComponent()) == destinationSnapshot {
        throw BatchFileOperationError.invalidPlan(FileOperationsL10n.text("error.sameFolder"))
      }
      let target = destination.map {
        let name = availableName(asset.filename, occupiedNames: &occupiedNames)
        return $0.appendingPathComponent(name)
      }
      entries.append(BatchFileOperationEntry(sourceURL: source, destinationURL: target,
        sourceSnapshot: snapshot, displayName: asset.filename))
    }
    return BatchFileOperationPlan(operation: operation, entries: entries,
      destinationFolder: destination, destinationSnapshot: destinationSnapshot, retainedAssets: assets)
  }

  static func fileInfo(_ url: URL) throws -> stat {
    guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
    var info = stat()
    guard url.withUnsafeFileSystemRepresentation({ lstat($0!, &info) }) == 0 else {
      throw posixError(url)
    }
    return info
  }

  static func posixError(_ url: URL, code: Int32 = errno) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
  }

  static func nameKey(_ name: String) -> String {
    name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive,
      locale: Locale(identifier: "en_US_POSIX"))
  }

  static func availableName(_ original: String, occupiedNames: inout Set<String>) -> String {
    var name = original
    let ext = (original as NSString).pathExtension
    let stem = (original as NSString).deletingPathExtension
    var suffix = 2
    while !occupiedNames.insert(nameKey(name)).inserted {
      name = stem + " (\(suffix))" + (ext.isEmpty ? "" : "." + ext)
      suffix += 1
    }
    return name
  }
}
