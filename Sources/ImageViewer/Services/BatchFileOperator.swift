import Darwin
import Foundation

/// Processes only the immutable selection confirmed by the user. A failed item never
/// rolls back successful items, and neither copy nor move replaces an existing file.
actor BatchFileOperator {
  typealias TrashFile = @Sendable (URL) throws -> URL?
  typealias MoveFile = @Sendable (URL, URL) throws -> Void
  typealias CopyFile = @Sendable (URL, URL) throws -> Void
  typealias FlushFile = @Sendable (URL) throws -> Void

  private let trashFile: TrashFile
  private let moveFile: MoveFile
  private let copyFile: CopyFile
  private let flushFile: FlushFile
  private let flushDirectory: FlushFile

  init(trashFile: @escaping TrashFile = BatchFileOperator.moveToTrash,
    moveFile: @escaping MoveFile = BatchFileOperator.moveExclusively,
    copyFile: @escaping CopyFile = BatchFileOperator.copyExclusively,
    flushFile: @escaping FlushFile = BatchFileOperator.flushDurably,
    flushDirectory: @escaping FlushFile = BatchFileOperator.flushDirectoryDurably) {
    self.trashFile = trashFile
    self.moveFile = moveFile
    self.copyFile = copyFile
    self.flushFile = flushFile
    self.flushDirectory = flushDirectory
  }

  func execute(_ plan: BatchFileOperationPlan,
    progress: @Sendable (Int, Int) -> Void = { _, _ in }) async -> BatchFileOperationResult {
    var completed: [BatchFileOperationEntry] = []
    var failures: [BatchFileOperationFailure] = []
    var wasCancelled = false
    progress(0, plan.entries.count)
    for entry in plan.entries {
      do {
        try Task.checkCancellation()
        try verifySource(entry)
        let completedEntry: BatchFileOperationEntry
        switch plan.operation {
        case .trash:
          // No permanent-delete fallback: failure leaves the original where it is.
          completedEntry = entry.completing(at: try trashFile(entry.sourceURL))
        case .copy, .move:
          try verifyDestination(plan)
          completedEntry = try transfer(entry, plan: plan)
        }
        completed.append(completedEntry)
      } catch is CancellationError {
        wasCancelled = true
        break
      } catch {
        failures.append(BatchFileOperationFailure(sourceURL: entry.sourceURL,
          message: error.localizedDescription))
      }
      progress(completed.count + failures.count, plan.entries.count)
      await Task.yield()
    }
    if Task.isCancelled, completed.count + failures.count < plan.entries.count { wasCancelled = true }
    return BatchFileOperationResult(completed: completed, failures: failures, wasCancelled: wasCancelled)
  }

  private func transfer(_ entry: BatchFileOperationEntry,
    plan: BatchFileOperationPlan) throws -> BatchFileOperationEntry {
    guard let folder = plan.destinationFolder, let predicted = entry.destinationURL else {
      throw BatchFileOperationError.invalidPlan(FileOperationsL10n.text("error.destinationFolder"))
    }
    var destination = predicted
    var requiresExclusiveCopy = false
    if plan.operation == .move {
      // A same-volume rename can commit immediately. Capture the original's
      // stable identity/bookmark first in case the device disconnects just after.
      let originalCapture = Self.captureFile(entry.sourceURL, expected: entry.sourceSnapshot)
      while true {
        try Task.checkCancellation()
        try verifySource(entry)
        try verifyDestination(plan)
        do {
          try moveFile(entry.sourceURL, destination)
          let captured = Self.captureFile(destination, expected: entry.sourceSnapshot)
            ?? originalCapture.map { asset, reference in
              (asset.replacingURL(destination), PhotoMarkFileReference(sourceURL: destination,
                entryPath: reference.entryPath, bookmark: reference.bookmark,
                fileNumber: reference.fileNumber, birthSeconds: reference.birthSeconds,
                birthNanoseconds: reference.birthNanoseconds, volumeUUID: reference.volumeUUID))
            }
          return entry.completing(at: destination, asset: captured?.0, reference: captured?.1)
        } catch {
          if isPOSIX(error, EEXIST) || (error as NSError).code == NSFileWriteFileExistsError {
            destination = try nextDestination(for: entry, in: folder)
          } else if isUnsupportedExclusiveRename(error) {
            requiresExclusiveCopy = true
            break
          } else if isPOSIX(error, EXDEV) {
            break
          } else {
            throw error
          }
        }
      }
    }

    // Copy to an exclusive staging file, verify the source again, then publish.
    // Cross-volume moves remove the source only after durable publication.
    let stagingDirectory = folder.appendingPathComponent(".almaeng-transfer-\(UUID().uuidString)",
      isDirectory: true)
    try verifySource(entry)
    try verifyDestination(plan)
    // Only clean up a directory that this operation successfully created. A rare
    // collision must never make cleanup remove somebody else's existing item.
    try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: stagingDirectory) }
    if !requiresExclusiveCopy {
      requiresExclusiveCopy = try !Self.supportsExclusiveRename(in: stagingDirectory)
    }
    let staging: URL
    let stagedSnapshot: BatchFileOperationSourceSnapshot
    if requiresExclusiveCopy {
      // exFAT cannot rename exclusively. Detect that before copying so a large
      // file needs only its own size of free space, not a second complete copy.
      staging = entry.sourceURL
      stagedSnapshot = entry.sourceSnapshot
    } else {
      staging = stagingDirectory.appendingPathComponent("payload")
      try copyFile(entry.sourceURL, staging)
      try Task.checkCancellation()
      try verifySource(entry)
      // Surface delayed writes before publication on removable media.
      try flushFile(staging)
      stagedSnapshot = try BatchFileOperationSourceSnapshot.capture(staging)
      guard stagedSnapshot.size == entry.sourceSnapshot.size else {
        throw BatchFileOperationPlanner.posixError(staging, code: EIO)
      }
    }
    var expectedPublishedSnapshot = stagedSnapshot
    while true {
      try Task.checkCancellation()
      try verifyDestination(plan)
      do {
        if requiresExclusiveCopy {
          // exFAT cannot perform RENAME_EXCL. Never fall back to plain rename,
          // which could overwrite another file that arrived after planning.
          expectedPublishedSnapshot = try publishByExclusiveCopy(staging, to: destination,
            expectedSource: stagedSnapshot)
        } else {
          do {
            try Self.moveExclusively(staging, destination)
          } catch {
            guard isUnsupportedExclusiveRename(error) else { throw error }
            expectedPublishedSnapshot = try publishByExclusiveCopy(staging, to: destination,
              expectedSource: stagedSnapshot)
          }
        }
        break
      } catch {
        guard isPOSIX(error, EEXIST) else { throw error }
        destination = try nextDestination(for: entry, in: folder)
      }
    }
    do {
      // Once published, finish this item even if cancellation arrives. Returning
      // its committed result lets AppStore preserve the destination's marks.
      try verifyDestination(plan)
      try flushDirectory(folder)
      try verifyDestination(plan)
      let published = try BatchFileOperationSourceSnapshot.capture(destination)
      guard published.device == expectedPublishedSnapshot.device,
        published.inode == expectedPublishedSnapshot.inode,
        published.size == expectedPublishedSnapshot.size,
        published.modifiedSeconds == expectedPublishedSnapshot.modifiedSeconds,
        published.modifiedNanoseconds == expectedPublishedSnapshot.modifiedNanoseconds else {
        throw BatchFileOperationError.invalidPlan(FileOperationsL10n.text("error.destinationChanged"))
      }
      guard let (asset, reference) = Self.captureFile(destination, expected: published) else {
        throw BatchFileOperationPlanner.posixError(destination, code: EIO)
      }
      let completed = entry.completing(at: destination, asset: asset, reference: reference)
      if plan.operation == .move {
        try verifySource(entry)
        guard entry.sourceURL.withUnsafeFileSystemRepresentation({ unlink($0!) }) == 0 else {
          throw BatchFileOperationPlanner.posixError(entry.sourceURL)
        }
      }
      return completed
    } catch {
      // The published copy is deliberately kept when finalization fails. Never
      // roll it back or touch the source after a durability/identity failure.
      throw BatchFileOperationError.invalidPlan(FileOperationsL10n.format("error.copyKept",
        destination.path, error.localizedDescription))
    }
  }

  private static func captureFile(_ url: URL, expected: BatchFileOperationSourceSnapshot)
    -> (ImageAsset, PhotoMarkFileReference)? {
    guard let actual = try? BatchFileOperationSourceSnapshot.capture(url),
      actual.device == expected.device, actual.inode == expected.inode,
      actual.size == expected.size, actual.modifiedSeconds == expected.modifiedSeconds,
      actual.modifiedNanoseconds == expected.modifiedNanoseconds,
      let identity = PhotoMarkFileIdentity.read(url) else { return nil }
    let asset = ImageAsset(url: url, byteCount: actual.size,
      modificationDate: Date(timeIntervalSince1970: Double(actual.modifiedSeconds)
        + Double(actual.modifiedNanoseconds) / 1_000_000_000),
      creationDate: Date(timeIntervalSince1970: Double(identity.birthSeconds)
        + Double(identity.birthNanoseconds) / 1_000_000_000), photoMarkIdentity: identity.key)
    guard let reference = PhotoMarkFileReference.capture(for: asset),
      (try? BatchFileOperationSourceSnapshot.capture(url)) == actual else { return nil }
    return (asset, reference)
  }

  private static func supportsExclusiveRename(in directory: URL) throws -> Bool {
    let source = directory.appendingPathComponent("rename-probe")
    let target = directory.appendingPathComponent("rename-probe-done")
    let descriptor = source.withUnsafeFileSystemRepresentation {
      Darwin.open($0!, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
    }
    guard descriptor >= 0 else { throw BatchFileOperationPlanner.posixError(source) }
    Darwin.close(descriptor)
    defer {
      try? FileManager.default.removeItem(at: source)
      try? FileManager.default.removeItem(at: target)
    }
    do {
      try moveExclusively(source, target)
      return true
    } catch {
      let nsError = error as NSError
      if nsError.domain == NSPOSIXErrorDomain,
        nsError.code == Int(ENOTSUP) || nsError.code == Int(EOPNOTSUPP) { return false }
      throw error
    }
  }

  /// On filesystems without exclusive rename, own the destination with O_EXCL
  /// and retain its descriptor through copying. A failed/cancelled copy removes
  /// only that same object; the selected original is untouched throughout.
  private func publishByExclusiveCopy(_ source: URL, to destination: URL,
    expectedSource: BatchFileOperationSourceSnapshot) throws -> BatchFileOperationSourceSnapshot {
    try Task.checkCancellation()
    let sourceDescriptor = source.withUnsafeFileSystemRepresentation {
      Darwin.open($0!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard sourceDescriptor >= 0 else { throw BatchFileOperationPlanner.posixError(source) }
    defer { Darwin.close(sourceDescriptor) }
    guard try BatchFileOperationSourceSnapshot.capture(source) == expectedSource else {
      throw BatchFileOperationError.invalidPlan(FileOperationsL10n.text("error.sourceChanged"))
    }
    let descriptor = destination.withUnsafeFileSystemRepresentation {
      Darwin.open($0!, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    }
    guard descriptor >= 0 else { throw BatchFileOperationPlanner.posixError(destination) }
    var completed = false
    defer {
      if !completed {
        var owned = stat()
        if fstat(descriptor, &owned) == 0,
          let atPath = try? BatchFileOperationPlanner.fileInfo(destination),
          atPath.st_dev == owned.st_dev, atPath.st_ino == owned.st_ino {
          _ = destination.withUnsafeFileSystemRepresentation { unlink($0!) }
        }
      }
      Darwin.close(descriptor)
    }
    try Self.performCancellableCopy(to: destination) { state in
      fcopyfile(sourceDescriptor, descriptor, state, copyfile_flags_t(COPYFILE_ALL))
    }
    try Task.checkCancellation()
    guard try BatchFileOperationSourceSnapshot.capture(source) == expectedSource else {
      throw BatchFileOperationError.invalidPlan(FileOperationsL10n.text("error.sourceChanged"))
    }
    try flushFile(destination)
    var owned = stat()
    guard fstat(descriptor, &owned) == 0 else { throw BatchFileOperationPlanner.posixError(destination) }
    let published = try BatchFileOperationSourceSnapshot.capture(destination)
    guard published.device == owned.st_dev, published.inode == owned.st_ino,
      published.size == expectedSource.size else {
      throw BatchFileOperationError.invalidPlan(FileOperationsL10n.text("error.destinationChanged"))
    }
    completed = true
    return published
  }

  private func nextDestination(for entry: BatchFileOperationEntry, in folder: URL) throws -> URL {
    var occupied = try Set(FileManager.default.contentsOfDirectory(atPath: folder.path)
      .map(BatchFileOperationPlanner.nameKey))
    return folder.appendingPathComponent(BatchFileOperationPlanner.availableName(entry.displayName,
      occupiedNames: &occupied))
  }

  private func verifySource(_ entry: BatchFileOperationEntry) throws {
    guard try BatchFileOperationSourceSnapshot.capture(entry.sourceURL) == entry.sourceSnapshot else {
      throw BatchFileOperationError.invalidPlan(FileOperationsL10n.text("error.sourceChanged"))
    }
  }

  private func verifyDestination(_ plan: BatchFileOperationPlan) throws {
    guard let folder = plan.destinationFolder,
      try BatchFileOperationDirectorySnapshot.capture(folder) == plan.destinationSnapshot else {
      throw BatchFileOperationError.invalidPlan(FileOperationsL10n.text("error.destinationChanged"))
    }
  }

  private func isPOSIX(_ error: any Error, _ code: Int32) -> Bool {
    let nsError = error as NSError
    return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(code)
  }

  private func isUnsupportedExclusiveRename(_ error: any Error) -> Bool {
    isPOSIX(error, ENOTSUP) || isPOSIX(error, EOPNOTSUPP)
  }

  static func moveExclusively(_ source: URL, _ destination: URL) throws {
    let result = source.withUnsafeFileSystemRepresentation { sourcePath in
      destination.withUnsafeFileSystemRepresentation { destinationPath in
        renamex_np(sourcePath!, destinationPath!, UInt32(RENAME_EXCL))
      }
    }
    guard result == 0 else { throw BatchFileOperationPlanner.posixError(destination) }
  }

  static func copyExclusively(_ source: URL, _ destination: URL) throws {
    try performCancellableCopy(to: destination) { state in
      source.withUnsafeFileSystemRepresentation { sourcePath in
        destination.withUnsafeFileSystemRepresentation { destinationPath in
          copyfile(sourcePath!, destinationPath!, state,
            copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC))
        }
      }
    }
  }

  private static func performCancellableCopy(to destination: URL,
    _ body: (copyfile_state_t) -> Int32) throws {
    try Task.checkCancellation()
    guard let state = copyfile_state_alloc() else {
      throw BatchFileOperationPlanner.posixError(destination, code: ENOMEM)
    }
    defer { copyfile_state_free(state) }
    // copyfile calls this synchronously for each data write (and metadata
    // progress), so Swift's current task remains available in the callback.
    let callback: copyfile_callback_t = { _, stage, _, _, _, _ in
      // CONTINUE on COPYFILE_ERR asks copyfile to retry indefinitely. Preserve
      // its original errno instead so full/unplugged/read-only media fail safely.
      if Task.isCancelled {
        // Data progress sets ECANCELED itself; metadata callbacks keep errno.
        errno = ECANCELED
        return COPYFILE_QUIT
      }
      return stage == COPYFILE_ERR ? COPYFILE_QUIT : COPYFILE_CONTINUE
    }
    guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB),
      unsafeBitCast(callback, to: UnsafeRawPointer.self)) == 0 else {
      throw BatchFileOperationPlanner.posixError(destination)
    }
    let result = body(state)
    guard result == 0 else {
      let code = errno
      if code == ECANCELED { throw CancellationError() }
      throw BatchFileOperationPlanner.posixError(destination, code: code)
    }
  }

  static func flushDurably(_ file: URL) throws {
    try flushDurably(file, directory: false)
  }

  static func flushDirectoryDurably(_ directory: URL) throws {
    try flushDurably(directory, directory: true)
  }

  private static func flushDurably(_ url: URL, directory: Bool) throws {
    let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0)
    let descriptor = url.withUnsafeFileSystemRepresentation { Darwin.open($0!, flags) }
    guard descriptor >= 0 else { throw BatchFileOperationPlanner.posixError(url) }
    defer { Darwin.close(descriptor) }
    while fsync(descriptor) != 0 {
      let code = errno
      if code == EINTR { continue }
      throw BatchFileOperationPlanner.posixError(url, code: code)
    }
    // fsync is required on every filesystem. F_FULLFSYNC additionally asks the
    // drive to commit its own cache; only unsupported-command errors fall back
    // to the successful fsync. I/O, unplugging and space errors remain failures.
    while fcntl(descriptor, F_FULLFSYNC) != 0 {
      let code = errno
      if code == EINTR { continue }
      if code == ENOTSUP || code == EOPNOTSUPP || code == EINVAL { return }
      throw BatchFileOperationPlanner.posixError(url, code: code)
    }
  }

  static func moveToTrash(_ source: URL) throws -> URL? {
    var resultingURL: NSURL?
    try FileManager.default.trashItem(at: source, resultingItemURL: &resultingURL)
    return resultingURL as URL?
  }
}
