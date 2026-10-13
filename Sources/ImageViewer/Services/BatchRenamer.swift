import Darwin
import Foundation

/// Stages every file before assigning final names, so swaps and case-only changes are safe.
actor BatchRenamer {
  private let moveFile: @Sendable (URL, URL) throws -> Void

  init(moveFile: @escaping @Sendable (URL, URL) throws -> Void = BatchRenamer.moveExclusively) {
    self.moveFile = moveFile
  }

  func apply(_ plan: BatchRenamePlan) throws -> [URL: URL] {
    guard plan.canApply else {
      throw BatchRenameError.invalidPlan(plan.issue ?? plan.entries.compactMap(\.issue).first ?? L10n.text("변경할 파일 이름이 없습니다."))
    }
    var checked = plan.entries
    BatchRenamePlanner.validateDestinations(&checked)
    for entry in checked {
      if let issue = entry.issue { throw BatchRenameError.invalidPlan(issue) }
      guard let expected = entry.sourceSnapshot,
        let actual = try? BatchRenameSourceSnapshot.capture(entry.sourceURL), expected == actual
      else {
        throw BatchRenameError.invalidPlan(L10n.format("미리보기 이후 원본 파일이 변경되었습니다. 목록을 다시 확인해 주세요: %@", entry.sourceURL.lastPathComponent))
      }
    }

    var directories: [URL: URL] = [:]
    var records: [MoveRecord] = []
    defer { for staging in directories.values { staging.withUnsafeFileSystemRepresentation { _ = rmdir($0!) } } }
    do {
      for entry in checked where entry.isChanged {
        let parent = entry.sourceURL.deletingLastPathComponent()
        let staging: URL
        if let existing = directories[parent] {
          staging = existing
        } else {
          staging = parent.appendingPathComponent(".imageviewer-rename-\(UUID().uuidString)", isDirectory: true)
          guard staging.withUnsafeFileSystemRepresentation({ mkdir($0!, 0o700) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: staging.path])
          }
          directories[parent] = staging
        }
        records.append(MoveRecord(entry: entry, stagingURL: staging.appendingPathComponent(entry.sourceURL.lastPathComponent)))
      }
      for index in records.indices {
        let record = records[index]
        guard try BatchRenameSourceSnapshot.capture(record.currentURL) == record.entry.sourceSnapshot else {
          throw BatchRenameError.invalidPlan(L10n.format("미리보기 이후 원본 파일이 변경되었습니다. 목록을 다시 확인해 주세요: %@", record.entry.sourceURL.lastPathComponent))
        }
        try moveFile(record.currentURL, record.stagingURL)
        records[index].currentURL = record.stagingURL
        try verifyIdentity(records[index])
      }
      for index in records.indices {
        try verifyIdentity(records[index])
        try moveFile(records[index].currentURL, records[index].entry.destinationURL)
        records[index].currentURL = records[index].entry.destinationURL
        try verifyIdentity(records[index])
      }
      return Dictionary(uniqueKeysWithValues: records.map { ($0.entry.sourceURL, $0.entry.destinationURL) })
    } catch {
      let reason = error.localizedDescription
      let unrestored = rollback(&records)
      if !unrestored.isEmpty {
        throw BatchRenameError.rollbackIncomplete(reason: reason, locations: unrestored.joined(separator: "\n"))
      }
      throw BatchRenameError.applyFailed(reason)
    }
  }

  /// RENAME_EXCL makes the final existence check atomic, including on case-insensitive volumes.
  nonisolated static func moveExclusively(_ source: URL, _ destination: URL) throws {
    let result = source.withUnsafeFileSystemRepresentation { sourcePath in
      destination.withUnsafeFileSystemRepresentation { destinationPath in
        renamex_np(sourcePath!, destinationPath!, UInt32(RENAME_EXCL))
      }
    }
    guard result == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
    }
  }

  private func verifyIdentity(_ record: MoveRecord) throws {
    guard let expected = record.entry.sourceSnapshot,
      expected.matchesAfterMove(try BatchRenameSourceSnapshot.capture(record.currentURL))
    else {
      throw BatchRenameError.invalidPlan(L10n.format("작업 중 파일이 변경되었습니다: %@", record.currentURL.path))
    }
  }

  private func rollback(_ records: inout [MoveRecord]) -> [String] {
    // Return committed files to staging first; directly restoring a cycle could occupy another original name.
    for index in records.indices {
      let record = records[index]
      guard samePath(record.currentURL, record.entry.destinationURL), !samePath(record.currentURL, record.entry.sourceURL) else { continue }
      do {
        try verifyIdentity(record)
        try moveFile(record.currentURL, record.stagingURL)
        records[index].currentURL = record.stagingURL
      } catch { /* Keep the original data at its known location for recovery. */ }
    }
    for index in records.indices {
      let record = records[index]
      guard samePath(record.currentURL, record.stagingURL) else { continue }
      do {
        try verifyIdentity(record)
        try moveFile(record.currentURL, record.entry.sourceURL)
        records[index].currentURL = record.entry.sourceURL
      } catch { /* Exclusive moves never replace an externally created file. */ }
    }
    return records.filter { !samePath($0.currentURL, $0.entry.sourceURL) }.map {
      "\($0.currentURL.path) → \($0.entry.sourceURL.path)"
    }
  }

  private func samePath(_ first: URL, _ second: URL) -> Bool {
    first.path.utf8.elementsEqual(second.path.utf8)
  }

  private struct MoveRecord {
    let entry: BatchRenameEntry
    let stagingURL: URL
    var currentURL: URL

    init(entry: BatchRenameEntry, stagingURL: URL) {
      self.entry = entry
      self.stagingURL = stagingURL
      currentURL = entry.sourceURL
    }
  }
}
