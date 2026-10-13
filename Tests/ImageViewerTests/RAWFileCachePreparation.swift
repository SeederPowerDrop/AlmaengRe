import Darwin
import Foundation

/// Test-only, explicitly enabled preparation of the requested files' cached pages.
/// Descriptors and shared mappings are read-only; mapped image bytes are never
/// dereferenced. No file is written, truncated, renamed or removed. This observes
/// macOS file-page residency, not Quick Look, Image I/O or SSD-controller caches.
/// Run with all competing readers/writers closed: residency is a sequence of
/// snapshots and cannot prevent another process reading a file immediately after.
enum RAWFileCachePreparation {
  struct Report: Sendable {
    let requested: Bool
    let files: Int
    let totalPages: Int
    let residentPagesBefore: Int
    let residentPagesAfter: Int
    let metadataUnchangedFiles: Int
    let verifiedFiles: Int
    let errors: [String: Int]
    let metadataChangedFiles: Int
    let seconds: TimeInterval

    var osFilePagesVerifiedZero: Bool {
      requested && files > 0 && verifiedFiles == files && metadataUnchangedFiles == files
        && errors.isEmpty && metadataChangedFiles == 0 && residentPagesAfter == 0
    }

    var logFields: [String: Any] {
      ["requested": requested, "files": files, "totalPages": totalPages,
        "residentPagesBefore": residentPagesBefore, "residentPagesAfter": residentPagesAfter,
        "metadataUnchangedFiles": metadataUnchangedFiles, "verifiedFiles": verifiedFiles,
        "metadataChangedFiles": metadataChangedFiles, "errors": errors, "seconds": seconds,
        "osFilePagesVerifiedZero": osFilePagesVerifiedZero,
        "quicklookCacheCleared": false, "imageDecoderCachesCleared": false,
        "contentBytesRead": 0, "filesOpenedReadOnly": true]
    }
  }

  private enum Failure: Error { case filePagesNotVerifiedZero }
  private enum Pass { case evict, verify }
  private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let changeSeconds: Int
    let changeNanoseconds: Int

    init(_ metadata: stat) {
      device = metadata.st_dev
      inode = metadata.st_ino
      size = metadata.st_size
      modificationSeconds = metadata.st_mtimespec.tv_sec
      modificationNanoseconds = metadata.st_mtimespec.tv_nsec
      changeSeconds = metadata.st_ctimespec.tv_sec
      changeNanoseconds = metadata.st_ctimespec.tv_nsec
    }
  }
  private struct Statistics {
    var totalPages = 0
    var before = 0
    var after = 0
    var unchanged = 0
    var verified = 0
    var changed = 0
    var errors: [String: Int] = [:]

    mutating func error(_ operation: String, code: Int32 = errno) {
      errors["\(operation):\(code)", default: 0] += 1
    }
  }

  /// Returns an unverified report without touching files unless the environment
  /// opt-in is present. On opt-in, any syscall error or incomplete zero-residency
  /// verification throws after logging aggregate diagnostics without filenames.
  static func prepare(urls: [URL], phase: String) throws -> Report {
    let requested = ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_EVICT_FILE_PAGES"] == "1"
    let started = ProcessInfo.processInfo.systemUptime
    var seen = Set<URL>()
    let unique = urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
    var statistics = Statistics()
    if requested {
      var identities: [URL: FileIdentity] = [:]
      for url in unique {
        if let identity = visit(url, pass: .evict, expected: nil, statistics: &statistics) {
          identities[url] = identity
        }
      }
      // Do not infer the entire folder is still cold from the individual eviction
      // snapshots. Verify all selected files again after the eviction pass ends.
      for url in unique {
        guard let identity = identities[url] else { continue }
        _ = visit(url, pass: .verify, expected: identity, statistics: &statistics)
      }
    }
    let report = Report(requested: requested, files: unique.count,
      totalPages: statistics.totalPages, residentPagesBefore: statistics.before,
      residentPagesAfter: statistics.after, metadataUnchangedFiles: statistics.unchanged,
      verifiedFiles: statistics.verified, errors: statistics.errors,
      metadataChangedFiles: statistics.changed,
      seconds: ProcessInfo.processInfo.systemUptime - started)
    var fields = report.logFields
    fields["phase"] = phase
    if let encoded = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
      var line = Data("RAW_FILE_CACHE_PREPARATION ".utf8)
      line.append(encoded)
      line.append(0x0a)
      FileHandle.standardOutput.write(line)
    }
    if requested && !report.osFilePagesVerifiedZero { throw Failure.filePagesNotVerifiedZero }
    return report
  }

  private static func visit(_ url: URL, pass: Pass, expected: FileIdentity?,
    statistics: inout Statistics
  ) -> FileIdentity? {
    let descriptor = url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { statistics.error("open"); return nil }
    defer { if Darwin.close(descriptor) != 0 { statistics.error("close") } }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else { statistics.error("fstat"); return nil }
    guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_size >= 0,
      metadata.st_size <= off_t(Int.max) else { statistics.error("regular_file", code: EINVAL); return nil }
    let identity = FileIdentity(metadata)
    if let expected, expected != identity {
      statistics.changed += 1
      return nil
    }
    let length = Int(metadata.st_size)
    let pages = length == 0 ? 0 : (length - 1) / Int(getpagesize()) + 1
    if pass == .evict { statistics.totalPages += pages }
    if length > 0 {
      guard let mapping = mmap(nil, length, PROT_READ, MAP_SHARED, descriptor, 0),
        mapping != UnsafeMutableRawPointer(bitPattern: -1)
      else { statistics.error("mmap"); return nil }
      defer { if munmap(mapping, length) != 0 { statistics.error("munmap") } }
      // Only the kernel-written residency vector is examined, never the mapping.
      var vector = [CChar](repeating: 0, count: pages)
      let status = vector.withUnsafeMutableBufferPointer { buffer in
        mincore(mapping, length, buffer.baseAddress!)
      }
      guard status == 0 else { statistics.error("mincore"); return nil }
      let resident = vector.reduce(0) { $0 + (UInt8(bitPattern: $1) & 0x1 == 0 ? 0 : 1) }
      if pass == .evict {
        statistics.before += resident
        // A read-only mapping cannot dirty the image. MS_INVALIDATE alone is the
        // macOS operation validated on a synthetic warm file; never add write flags
        // or retry with writable mappings when a file cannot be invalidated.
        guard msync(mapping, length, MS_INVALIDATE) == 0 else {
          statistics.error("msync")
          return nil
        }
      } else { statistics.after += resident }
    }
    var after = stat(), pathMetadata = stat()
    guard fstat(descriptor, &after) == 0 else { statistics.error("fstat_after"); return nil }
    let pathStatus = url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return lstat(path, &pathMetadata)
    }
    guard pathStatus == 0 else { statistics.error("lstat_after"); return nil }
    guard identity == FileIdentity(after), identity == FileIdentity(pathMetadata) else {
      statistics.changed += 1
      return nil
    }
    if pass == .evict { statistics.unchanged += 1 }
    else { statistics.verified += 1 }
    return identity
  }
}
