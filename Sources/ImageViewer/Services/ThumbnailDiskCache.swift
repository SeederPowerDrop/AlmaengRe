import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO

struct ThumbnailDiskCacheSnapshot: Sendable {
  /// Bounded indexed records; byteCount also includes undeletable files whose
  /// path metadata could not fit in that index.
  let entryCount: Int
  let byteCount: Int
  let byteLimit: Int
  let previewBytes: Int
  let exactBytes: Int
  let hits: UInt64
  let misses: UInt64
  /// False when access failures leave unknown bytes or conservative previous
  /// estimates. Do not present byteCount as a current measurement in that case.
  var isComplete: Bool = true
}

private final class ThumbnailDiskCacheScanStatus: @unchecked Sendable {
  private let lock = NSLock()
  private var incomplete = false
  func markIncomplete() { lock.withLock { incomplete = true } }
  var isIncomplete: Bool { lock.withLock { incomplete } }
}

/// A bounded cache of already generated thumbnails, never of source images.
/// PNG keeps the detached thumbnail's color profile and transparency lossless.
/// The actor serializes compression and disk access without spawning write tasks.
actor ThumbnailDiskCache {
  static let shared = ThumbnailDiskCache(directory:
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
      .appendingPathComponent("org.openimageviewer.ImageViewer/Thumbnails-v1", isDirectory: true))

  private enum Tier: String {
    case preview, exact
  }

  private struct Entry {
    let sourceHash: String
    let tier: Tier?
    let pixelSize: Int
    var byteCount: Int
    var lastAccess: Date
    var persistedLastAccess: Date?
    var isReadable = true
    var needsRemoval = false
  }

  // Also bound metadata when many unusually small PNGs fit inside the byte budget.
  private static let entriesPerTier = 8_192
  private static let maximumPixelSize = 4_096
  private static let persistedAccessInterval: TimeInterval = 60
  private static let deletionRetryInterval: TimeInterval = 5
  // Bump when thumbnail decoding/color handling changes in a way that invalidates pixels.
  private static let algorithmVersion = 1

  private let directory: URL
  private let previewByteLimit: Int
  private let exactByteLimit: Int
  private let entryLimit: Int
  private let files = FileManager.default
  private let now: @Sendable () -> Date
  private let persistAccessDate: @Sendable (URL, Date) throws -> Void
  private let removeDirectory: @Sendable (URL) throws -> Void
  private let removeFile: @Sendable (URL) throws -> Void
  private let readResourceValues: @Sendable (URL, Set<URLResourceKey>) throws -> URLResourceValues
  private var generation: UInt64 = 0
  private var didLoad = false
  private var entries: [String: Entry] = [:]
  private var sourceEntries: [String: Set<String>] = [:]
  private var previewBytes = 0
  private var exactBytes = 0
  private var previewCount = 0
  private var exactCount = 0
  private var otherBytes = 0
  // Failed removals beyond the bounded lookup index remain byte-accounted,
  // without retaining an unbounded dictionary of paths. A retry rescans them.
  private var unindexedPreviewBytes = 0
  private var unindexedExactBytes = 0
  private var unindexedOtherBytes = 0
  private var hasUnindexedFiles = false
  private var hasDeletionFailures = false
  private var isAccountingComplete = true
  private var clearsRemainingFiles = false
  private var lastDeletionAttempt: Date?
  private var hits: UInt64 = 0
  private var misses: UInt64 = 0

  init(directory: URL, previewByteLimit: Int = 128 * 1_024 * 1_024,
    exactByteLimit: Int = 384 * 1_024 * 1_024,
    persistAccessDate: @escaping @Sendable (URL, Date) throws -> Void = { url, date in
      try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }, now: @escaping @Sendable () -> Date = Date.init,
    removeDirectory: @escaping @Sendable (URL) throws -> Void = {
      try FileManager.default.removeItem(at: $0)
    }, removeFile: @escaping @Sendable (URL) throws -> Void = {
      try FileManager.default.removeItem(at: $0)
    }, maximumEntriesPerTier: Int? = nil,
    readResourceValues: @escaping @Sendable (URL, Set<URLResourceKey>) throws -> URLResourceValues = {
      try $0.resourceValues(forKeys: $1)
    }
  ) {
    self.directory = directory.standardizedFileURL
    self.previewByteLimit = max(0, previewByteLimit)
    self.exactByteLimit = max(0, exactByteLimit)
    entryLimit = min(Self.entriesPerTier, max(1, maximumEntriesPerTier ?? Self.entriesPerTier))
    self.now = now
    self.persistAccessDate = persistAccessDate
    self.removeDirectory = removeDirectory
    self.removeFile = removeFile
    self.readResourceValues = readResourceValues
  }

  /// Checks the small in-memory metadata index without opening or decoding PNGs.
  func contains(for key: ThumbnailCacheKey, allowsSmaller: Bool = false) -> Bool {
    loadIfNeeded()
    return !candidates(for: key, allowsSmaller: allowsSmaller).isEmpty
  }

  /// Exact requests only reuse exact thumbnails from an equal or larger bucket.
  /// Browsing may opt into a smaller bitmap and refine it after scrolling settles.
  func image(for key: ThumbnailCacheKey, allowsSmaller: Bool = false) -> CGImage? {
    loadIfNeeded()
    for identifier in candidates(for: key, allowsSmaller: allowsSmaller) {
      let url = directory.appendingPathComponent(identifier)
      let image: CGImage? = autoreleasepool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
          [kCGImageSourceShouldCache: false] as CFDictionary),
          CGImageSourceGetType(source) as String? == "public.png",
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
          width > 0, height > 0,
          width <= Self.maximumPixelSize, height <= Self.maximumPixelSize
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
          kCGImageSourceShouldCache: true,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
      }
      guard let image else {
        entries[identifier]?.isReadable = false
        remove(identifier)
        continue
      }
      recordAccess(identifier, at: url)
      hits &+= 1
      return image
    }
    misses &+= 1
    return nil
  }

  /// Failure leaves an existing entry intact and does not affect image display.
  func generationToken() -> UInt64 { generation }

  func store(_ image: CGImage, for key: ThumbnailCacheKey, generation: UInt64? = nil) {
    // A decoder or the second PNG tier can resume after Settings has cleared
    // the cache. Reject its old write before creating any folders or encoding.
    guard generation == nil || generation == self.generation else { return }
    loadIfNeeded()
    retryFailedRemovalsIfDue()
    // Do not create more files while earlier deletions are denied. This also
    // avoids repeatedly encoding PNGs on a full or read-only cache volume.
    guard !hasDeletionFailures, !hasUnindexedFiles else { return }
    let tier: Tier = key.isBrowsingPreview ? .preview : .exact
    guard limit(for: tier) > 0, key.pixelSize > 0,
      key.pixelSize <= Self.maximumPixelSize,
      image.width > 0, image.height > 0,
      image.width <= Self.maximumPixelSize, image.height <= Self.maximumPixelSize
    else { return }
    let sourceHash = sourceHash(for: key)
    let identifier = identifier(sourceHash: sourceHash, tier: tier, pixelSize: key.pixelSize)
    // Determine the real compressed cost before creating a file. Previously a
    // failed LRU removal could leave both old and newly written PNGs on disk.
    // Only this serial writer owns the temporary encoded buffer (at most 4096²).
    let encoded: NSMutableData? = autoreleasepool {
      let data = NSMutableData()
      guard let output = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
      else { return nil }
      CGImageDestinationAddImage(output, image, nil)
      return CGImageDestinationFinalize(output) ? data : nil
    }
    guard let encoded, encoded.length > 0, encoded.length <= limit(for: tier),
      reserveSpace(in: tier, bytes: encoded.length, replacing: identifier)
    else { return }
    let sourceDirectory = directory.appendingPathComponent(sourceHash, isDirectory: true)
    let temporary = sourceDirectory.appendingPathComponent("pending-\(UUID().uuidString).tmp")
    let destination = directory.appendingPathComponent(identifier)
    var committed = false
    defer {
      if !committed { discardTemporary(temporary, sourceHash: sourceHash) }
    }
    do {
      try files.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
      try encoded.write(to: temporary, options: [])
      let attributes = try files.attributesOfItem(atPath: temporary.path)
      guard let bytes = (attributes[.size] as? NSNumber)?.intValue,
        bytes > 0, bytes <= limit(for: tier)
      else { return }
      // Both files are in one directory, so rename replaces atomically. A crash
      // can leave a temporary PNG, but never a partially written live cache entry.
      guard Darwin.rename(temporary.path, destination.path) == 0 else { return }
      committed = true
      if entries[identifier] != nil { removeMetadata(identifier) }
      addMetadata(identifier, entry: Entry(sourceHash: sourceHash, tier: tier,
        pixelSize: key.pixelSize, byteCount: bytes, lastAccess: now(),
        persistedLastAccess: attributes[.modificationDate] as? Date))
    } catch {
      // Caches are optional, including on read-only/full disks.
    }
  }

  func snapshot() -> ThumbnailDiskCacheSnapshot {
    loadIfNeeded()
    retryFailedRemovalsIfDue()
    let (combinedLimit, overflow) = previewByteLimit.addingReportingOverflow(exactByteLimit)
    return ThumbnailDiskCacheSnapshot(entryCount: entries.count,
      byteCount: previewBytes + exactBytes + otherBytes + unindexedPreviewBytes
        + unindexedExactBytes + unindexedOtherBytes,
      byteLimit: overflow ? Int.max : combinedLimit,
      previewBytes: previewBytes + unindexedPreviewBytes,
      exactBytes: exactBytes + unindexedExactBytes, hits: hits, misses: misses,
      isComplete: isAccountingComplete)
  }

  @discardableResult
  func removeAll() -> Bool {
    generation &+= 1
    let removed: Bool
    do {
      try removeDirectory(directory)
      removed = true
    } catch {
      removed = Self.isMissingFile(error) && isConfirmedMissing(directory)
    }
    if removed { resetIndex() }
    isAccountingComplete = removed
    hits = 0
    misses = 0
    // A failed or partial deletion must not make Settings claim that the
    // remaining files occupy zero bytes. Rebuild their bounded metadata index.
    didLoad = removed
    clearsRemainingFiles = !removed
    hasDeletionFailures = !removed
    lastDeletionAttempt = removed ? nil : now()
    return removed
  }

  private func sourceHash(for key: ThumbnailCacheKey) -> String {
    let parts = [
      "thumbnail-algorithm-\(Self.algorithmVersion)",
      key.fileURL.standardizedFileURL.absoluteString,
      key.byteCount.map(String.init) ?? "unknown",
      key.modificationDate.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "unknown",
    ]
    // Length prefixes make this unambiguous even for unusual filenames.
    let identity = parts.map { "\($0.utf8.count):\($0)" }.joined()
    // Hash lookup is on every grid cache hit. Formatting each byte through
    // Foundation's printf machinery needlessly serializes many small restores.
    let digits: [UInt8] = Array("0123456789abcdef".utf8)
    var encoded: [UInt8] = []
    encoded.reserveCapacity(64)
    for byte in SHA256.hash(data: Data(identity.utf8)) {
      encoded.append(digits[Int(byte >> 4)])
      encoded.append(digits[Int(byte & 0x0f)])
    }
    return String(decoding: encoded, as: UTF8.self)
  }

  private func identifier(sourceHash: String, tier: Tier, pixelSize: Int) -> String {
    "\(sourceHash)/\(tier.rawValue)-\(pixelSize).png"
  }

  private func candidates(for key: ThumbnailCacheKey, allowsSmaller: Bool) -> [String] {
    let hash = sourceHash(for: key)
    guard let identifiers = sourceEntries[hash] else { return [] }
    let direct = identifier(sourceHash: hash,
      tier: key.isBrowsingPreview ? .preview : .exact, pixelSize: key.pixelSize)
    return identifiers.filter { identifier in
      guard let entry = entries[identifier], entry.isReadable else { return false }
      if allowsSmaller { return true }
      return (key.isBrowsingPreview || entry.tier == .exact) && entry.pixelSize >= key.pixelSize
    }.sorted { left, right in
      if left == direct { return right != direct }
      if right == direct { return false }
      guard let lhs = entries[left], let rhs = entries[right] else { return left < right }
      let lhsAdequate = lhs.pixelSize >= key.pixelSize
      let rhsAdequate = rhs.pixelSize >= key.pixelSize
      if lhsAdequate != rhsAdequate { return lhsAdequate }
      if lhs.pixelSize != rhs.pixelSize {
        return lhsAdequate ? lhs.pixelSize < rhs.pixelSize : lhs.pixelSize > rhs.pixelSize
      }
      if lhs.tier != rhs.tier { return lhs.tier == .exact }
      return left < right
    }
  }

  private func loadIfNeeded(retrying removals: Set<String> = [], unreadable: Set<String> = [],
    clearing: Bool = false) {
    guard !didLoad else { return }
    didLoad = true
    // Foundation can return a non-nil enumerator for a missing root and only
    // report ENOENT when iteration starts. A genuinely absent cache is empty,
    // not an unreadable directory with cleanup debt: admit its first write now.
    if isConfirmedMissing(directory) {
      resetIndex()
      isAccountingComplete = true
      hasDeletionFailures = false
      clearsRemainingFiles = false
      lastDeletionAttempt = nil
      return
    }
    let properties: [URLResourceKey] = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]
    let scanStatus = ThumbnailDiskCacheScanStatus()
    guard let enumerator = files.enumerator(at: directory,
      includingPropertiesForKeys: properties, options: [.skipsHiddenFiles],
      errorHandler: { _, _ in scanStatus.markIncomplete(); return true }) else {
      // A partial clear can also make the directory temporarily unreadable.
      // Keep its last known accounting until a later scan can reconcile it.
      hasUnindexedFiles = true
      hasDeletionFailures = true
      isAccountingComplete = false
      lastDeletionAttempt = now()
      return
    }
    let previousPreviewBytes = previewBytes + unindexedPreviewBytes
    let previousExactBytes = exactBytes + unindexedExactBytes
    let previousOtherBytes = otherBytes + unindexedOtherBytes
    let knownUnreadable = unreadable.union(entries.compactMap { $0.value.isReadable ? nil : $0.key })
    resetIndex()
    isAccountingComplete = true
    for case let url as URL in enumerator {
      let values: URLResourceValues
      do {
        values = try readResourceValues(url, Set(properties))
      } catch {
        if !Self.isMissingFile(error) { scanStatus.markIncomplete() }
        continue
      }
      // The enumerator resolves macOS aliases such as /var -> /private/var,
      // while standardizedFileURL can keep /var. Use its relative depth rather
      // than subtracting an absolute root's component count, or every persisted
      // source directory can be mistaken for an unexpected nested directory.
      let components = Array(url.pathComponents.suffix(enumerator.level))
      if values.isSymbolicLink == true {
        enumerator.skipDescendants()
        continue
      }
      if values.isDirectory == true {
        if components.count != 1 || !isSourceHash(components[0]) { enumerator.skipDescendants() }
        continue
      }
      guard components.count == 2, isSourceHash(components[0]),
        ["png", "tmp"].contains(url.pathExtension) else { continue }
      guard values.isRegularFile == true else {
        if values.isRegularFile == nil { scanStatus.markIncomplete() }
        continue
      }
      guard let bytes = values.fileSize, bytes >= 0 else {
        scanStatus.markIncomplete()
        continue
      }
      let identifier = components.joined(separator: "/")
      let name = url.deletingPathExtension().lastPathComponent.split(separator: "-")
      let tier = name.first.flatMap { Tier(rawValue: String($0)) }
      let pixels = name.count == 2 ? Int(name[1]) : nil
      let valid = url.pathExtension == "png" && name.count == 2 && tier != nil
        && (pixels ?? 0) > 0 && (pixels ?? 0) <= Self.maximumPixelSize
        && bytes > 0 && bytes <= (tier.map { limit(for: $0) } ?? 0)
        && !knownUnreadable.contains(identifier)
      let shouldDelete = !valid || clearing || removals.contains(identifier)
      if shouldDelete, deleteFile(at: url) { continue }
      trackRemainingFile(identifier, entry: Entry(sourceHash: components[0], tier: tier,
        pixelSize: pixels ?? 0, byteCount: bytes,
        lastAccess: values.contentModificationDate ?? .distantPast,
        persistedLastAccess: values.contentModificationDate,
        isReadable: valid, needsRemoval: shouldDelete || clearsRemainingFiles),
        removalAlreadyFailed: shouldDelete)
    }
    // Sort at most the bounded index once per tier, not once per discovered
    // file when a denied deletion leaves a large existing cache over budget.
    trim(.preview)
    trim(.exact)
    if scanStatus.isIncomplete {
      // Permissions can hide an entire source-hash directory during a partial
      // clear. Keep a conservative last-known floor rather than report zero
      // merely because enumeration could not inspect its remaining files.
      unindexedPreviewBytes += max(0, previousPreviewBytes - previewBytes - unindexedPreviewBytes)
      unindexedExactBytes += max(0, previousExactBytes - exactBytes - unindexedExactBytes)
      unindexedOtherBytes += max(0, previousOtherBytes - otherBytes - unindexedOtherBytes)
      hasUnindexedFiles = true
      hasDeletionFailures = true
      isAccountingComplete = false
      lastDeletionAttempt = now()
    }
  }

  private func isSourceHash(_ string: String) -> Bool {
    string.utf8.count == 64 && string.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }

  private func recordAccess(_ identifier: String, at url: URL) {
    let access = now()
    // Keep exact LRU order in this process, but avoid an APFS metadata write on
    // every PNG restore while quickly scrolling back through the same photos.
    entries[identifier]?.lastAccess = access
    if let persisted = entries[identifier]?.persistedLastAccess {
      let elapsed = access.timeIntervalSince(persisted)
      if elapsed >= 0, elapsed < Self.persistedAccessInterval { return }
    }
    do {
      try persistAccessDate(url, access)
      // A failed touch must remain eligible for retry on the next cache hit.
      // A backwards wall clock also touches immediately, resetting the window.
      entries[identifier]?.persistedLastAccess = access
    } catch {
      // Metadata persistence is optional; the decoded thumbnail is still valid.
    }
  }

  private func limit(for tier: Tier) -> Int {
    tier == .preview ? previewByteLimit : exactByteLimit
  }

  private func addMetadata(_ identifier: String, entry: Entry) {
    entries[identifier] = entry
    sourceEntries[entry.sourceHash, default: []].insert(identifier)
    if entry.tier == .preview {
      previewBytes += entry.byteCount
      previewCount += 1
    } else if entry.tier == .exact {
      exactBytes += entry.byteCount
      exactCount += 1
    } else {
      otherBytes += entry.byteCount
    }
  }

  private func removeMetadata(_ identifier: String) {
    guard let entry = entries.removeValue(forKey: identifier) else { return }
    sourceEntries[entry.sourceHash]?.remove(identifier)
    if sourceEntries[entry.sourceHash]?.isEmpty == true {
      sourceEntries.removeValue(forKey: entry.sourceHash)
    }
    if entry.tier == .preview {
      previewBytes -= entry.byteCount
      previewCount -= 1
    } else if entry.tier == .exact {
      exactBytes -= entry.byteCount
      exactCount -= 1
    } else {
      otherBytes -= entry.byteCount
    }
  }

  @discardableResult
  private func remove(_ identifier: String) -> Bool {
    let url = directory.appendingPathComponent(identifier)
    guard deleteFile(at: url) else {
      entries[identifier]?.needsRemoval = true
      // A corrupt or replaced file may now have a different size. Preserve its
      // actual remaining bytes instead of retaining the previous PNG's cost.
      if var entry = entries[identifier] {
        do {
          let values = try readResourceValues(url, [.fileSizeKey])
          if let bytes = values.fileSize, bytes >= 0 {
            removeMetadata(identifier)
            entry.byteCount = bytes
            addMetadata(identifier, entry: entry)
          } else {
            markAccountingIncomplete()
          }
        } catch {
          if Self.isMissingFile(error), isConfirmedMissing(url) {
            removeMetadata(identifier)
          } else {
            markAccountingIncomplete()
          }
        }
      }
      return false
    }
    removeMetadata(identifier)
    let sourceDirectory = directory.appendingPathComponent(identifier).deletingLastPathComponent()
    if sourceEntries[sourceDirectory.lastPathComponent] == nil {
      // Only remove an empty directory: the initial scan may not have indexed
      // its other buckets yet, and another process may be completing a write.
      _ = Darwin.rmdir(sourceDirectory.path)
    }
    return true
  }

  private func deleteFile(at url: URL) -> Bool {
    do {
      try removeFile(url)
      return true
    } catch {
      // Another process or a partial clear already reclaimed these bytes.
      if Self.isMissingFile(error), isConfirmedMissing(url) { return true }
      hasDeletionFailures = true
      lastDeletionAttempt = now()
      return false
    }
  }

  private func isConfirmedMissing(_ url: URL) -> Bool {
    do {
      _ = try files.attributesOfItem(atPath: url.path)
      return false
    } catch {
      return Self.isMissingFile(error)
    }
  }

  private static func isMissingFile(_ error: Error) -> Bool {
    var current = error as NSError
    // FileManager may wrap POSIX ENOENT in a Cocoa write error. Bound traversal
    // so even a malformed cyclic underlying-error chain cannot loop forever.
    for _ in 0..<4 {
      if current.domain == NSPOSIXErrorDomain, current.code == Int(ENOENT) { return true }
      if current.domain == NSCocoaErrorDomain,
        [CocoaError.Code.fileNoSuchFile.rawValue, CocoaError.Code.fileReadNoSuchFile.rawValue]
          .contains(current.code) { return true }
      guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
      current = underlying
    }
    return false
  }

  private func resetIndex() {
    entries.removeAll(keepingCapacity: false)
    sourceEntries.removeAll(keepingCapacity: false)
    previewBytes = 0
    exactBytes = 0
    otherBytes = 0
    previewCount = 0
    exactCount = 0
    unindexedPreviewBytes = 0
    unindexedExactBytes = 0
    unindexedOtherBytes = 0
    hasUnindexedFiles = false
  }

  private func trackRemainingFile(_ identifier: String, entry: Entry,
    removalAlreadyFailed: Bool = false) {
    let tierHasRoom = entry.tier == .preview ? previewCount < entryLimit
      : entry.tier == .exact ? exactCount < entryLimit : true
    if entries.count < entryLimit * 2, tierHasRoom {
      addMetadata(identifier, entry: entry)
      return
    }
    // Keep path metadata bounded even when a pathological directory contains
    // arbitrarily many undeletable PNGs or abandoned temporary files.
    if !removalAlreadyFailed, deleteFile(at: directory.appendingPathComponent(identifier)) { return }
    switch entry.tier {
    case .preview: unindexedPreviewBytes += entry.byteCount
    case .exact: unindexedExactBytes += entry.byteCount
    case nil: unindexedOtherBytes += entry.byteCount
    }
    hasUnindexedFiles = true
    hasDeletionFailures = true
  }

  private func discardTemporary(_ url: URL, sourceHash: String) {
    // An unsuccessful write can leave a partial file. Count it if cleanup is
    // denied; no later write is admitted until this cleanup debt is reclaimed.
    let bytes: Int?
    do {
      bytes = try readResourceValues(url, [.fileSizeKey]).fileSize
    } catch {
      if Self.isMissingFile(error), isConfirmedMissing(url) { return }
      if !deleteFile(at: url) { markAccountingIncomplete() }
      return
    }
    guard !deleteFile(at: url) else { return }
    guard let bytes, bytes >= 0 else {
      markAccountingIncomplete()
      return
    }
    let identifier = "\(sourceHash)/\(url.lastPathComponent)"
    trackRemainingFile(identifier, entry: Entry(sourceHash: sourceHash, tier: nil,
      pixelSize: 0, byteCount: max(0, bytes), lastAccess: now(),
      isReadable: false, needsRemoval: true), removalAlreadyFailed: true)
  }

  private func markAccountingIncomplete() {
    isAccountingComplete = false
    hasUnindexedFiles = true
    hasDeletionFailures = true
    lastDeletionAttempt = now()
  }

  private func retryFailedRemovalsIfDue() {
    guard hasDeletionFailures else { return }
    if let previous = lastDeletionAttempt {
      let elapsed = now().timeIntervalSince(previous)
      if elapsed >= 0, elapsed < Self.deletionRetryInterval { return }
    }
    lastDeletionAttempt = now()
    let pending = Set(entries.compactMap { $0.value.needsRemoval ? $0.key : nil })
    if hasUnindexedFiles {
      let unreadable = Set(entries.compactMap { $0.value.isReadable ? nil : $0.key })
      didLoad = false
      hasDeletionFailures = false
      loadIfNeeded(retrying: pending, unreadable: unreadable, clearing: clearsRemainingFiles)
    } else {
      hasDeletionFailures = false
      for identifier in pending { remove(identifier) }
      trim(.preview)
      trim(.exact)
    }
    hasDeletionFailures = hasDeletionFailures || hasUnindexedFiles
      || entries.values.contains { $0.needsRemoval }
    if !hasDeletionFailures { clearsRemainingFiles = false }
  }

  /// Reserve completed-file capacity before the temporary write and atomic
  /// replacement. A failed eviction leaves its accounting intact and rejects
  /// this new PNG; successful evictions may still free useful space.
  private func reserveSpace(in tier: Tier, bytes: Int, replacing identifier: String) -> Bool {
    func fits() -> Bool {
      let old = entries[identifier]
      let tierBytes = tier == .preview ? previewBytes : exactBytes
      let tierCount = tier == .preview ? previewCount : exactCount
      return tierBytes - (old?.byteCount ?? 0) <= limit(for: tier) - bytes
        && tierCount - (old == nil ? 0 : 1) < entryLimit
        && entries.count - (old == nil ? 0 : 1) < entryLimit * 2
    }
    if fits() { return true }
    let oldest = entries.filter { $0.value.tier == tier && $0.key != identifier }.sorted {
      if $0.value.lastAccess != $1.value.lastAccess { return $0.value.lastAccess < $1.value.lastAccess }
      return $0.key < $1.key
    }
    for (candidate, _) in oldest {
      guard !fits() else { break }
      remove(candidate)
    }
    return !hasDeletionFailures && fits()
  }

  private func trim(_ tier: Tier) {
    let bytes = tier == .preview ? previewBytes : exactBytes
    let count = tier == .preview ? previewCount : exactCount
    guard bytes > limit(for: tier) || count > entryLimit else { return }
    let oldest = entries.filter { $0.value.tier == tier }.sorted {
      if $0.value.lastAccess != $1.value.lastAccess { return $0.value.lastAccess < $1.value.lastAccess }
      return $0.key < $1.key
    }
    for (identifier, _) in oldest {
      let bytes = tier == .preview ? previewBytes : exactBytes
      let count = tier == .preview ? previewCount : exactCount
      guard bytes > limit(for: tier) || count > entryLimit else { break }
      remove(identifier)
    }
  }
}
