import Foundation

/// Immutable offsets and scalar metadata; no bitmap or borrowed C pointers.
final class RustQuerySnapshot: @unchecked Sendable {
  let source: [ImageAsset]
  let input: RustQueryInput
  // Count the shared source buffer too: a later COW edit can keep it resident.
  var retainedBytes: Int { input.byteCount + source.count * MemoryLayout<ImageAsset>.stride }
  init(source: [ImageAsset], input: RustQueryInput) { self.source = source; self.input = input }

  func matches(_ assets: [ImageAsset]) -> Bool {
    guard source.count == assets.count else { return false }
    let sameBuffer = source.withUnsafeBufferPointer { first in
      assets.withUnsafeBufferPointer { first.baseAddress == $0.baseAddress }
    }
    // Retaining the source enforces COW on mutations, including same-path EXIF
    // edits. Equal reconstructed arrays may reuse the same immutable input too.
    return sameBuffer || source == assets
  }
}

/// One shared metadata allowance for the ordinary viewer and both A/B panes.
/// Entries replace previous collections and compete for this byte limit.
final class RustQueryReusePool: @unchecked Sendable {
  private struct Entry { let snapshot: RustQuerySnapshot; var visit: UInt64 }
  private let lock = NSLock()
  let byteLimit: Int
  private var entries: [UUID: Entry] = [:]
  private var clock: UInt64 = 0
  private var enabled = true

  init(byteLimit: Int = Int(min(64 * 1024 * 1024,ProcessInfo.processInfo.physicalMemory / 256))) {
    self.byteLimit = max(0,byteLimit)
  }

  var retainedBytes: Int {
    lock.lock(); defer { lock.unlock() }
    return entries.values.reduce(0) { $0 + $1.snapshot.retainedBytes }
  }

  func setReuseAllowed(_ allowed: Bool) {
    lock.lock(); defer { lock.unlock() }
    enabled = allowed
    if !allowed { entries.removeAll() }
  }

  fileprivate func lookup(_ owner: UUID) -> RustQuerySnapshot? {
    lock.lock(); defer { lock.unlock() }
    guard enabled, var entry = entries[owner] else { return nil }
    clock &+= 1; entry.visit = clock; entries[owner] = entry
    return entry.snapshot
  }

  fileprivate func remove(_ owner: UUID) {
    lock.lock(); defer { lock.unlock() }
    entries.removeValue(forKey: owner)
  }

  fileprivate func store(_ snapshot: RustQuerySnapshot, owner: UUID) {
    lock.lock(); defer { lock.unlock() }
    entries.removeValue(forKey: owner)
    guard enabled, snapshot.retainedBytes <= byteLimit else { return }
    var bytes = entries.values.reduce(0) { $0 + $1.snapshot.retainedBytes }
    while bytes + snapshot.retainedBytes > byteLimit,
      let victim = entries.min(by: { $0.value.visit < $1.value.visit }) {
      bytes -= victim.value.snapshot.retainedBytes
      entries.removeValue(forKey: victim.key)
    }
    clock &+= 1; entries[owner] = Entry(snapshot: snapshot,visit: clock)
  }
}

final class RustQuerySession: @unchecked Sendable {
  struct Request { let revision: UInt64; let snapshot: RustQuerySnapshot? }
  private let lock = NSLock()
  private let owner = UUID()
  private let pool: RustQueryReusePool
  private var revision: UInt64 = 0
  private let minimumCount = 256

  init(pool: RustQueryReusePool = RustQueryReusePool()) { self.pool = pool }
  deinit { pool.remove(owner) }

  func begin(_ source: [ImageAsset]) -> Request {
    lock.lock()
    revision &+= 1
    let ticket = revision
    if source.count < minimumCount {
      pool.remove(owner); lock.unlock()
      return Request(revision: ticket,snapshot: nil)
    }
    let snapshot = pool.lookup(owner)
    lock.unlock()
    // Equality on a reconstructed large list must not block a main-thread reset.
    let matches = snapshot?.matches(source) == true
    lock.lock(); defer { lock.unlock() }
    guard ticket == revision else { return Request(revision: ticket,snapshot: nil) }
    if !matches { pool.remove(owner) }
    return Request(revision: ticket,snapshot: matches ? snapshot : nil)
  }

  func remember(_ input: RustQueryInput, source: [ImageAsset], request: Request) {
    guard source.count >= minimumCount, !Task.isCancelled else { return }
    lock.lock(); defer { lock.unlock() }
    guard request.revision == revision else { return }
    pool.store(RustQuerySnapshot(source: source,input: input),owner: owner)
  }

  func reset() {
    lock.lock(); defer { lock.unlock() }
    revision &+= 1; pool.remove(owner)
  }
}
