import CoreGraphics
import CAlmaengCore
import Foundation

final class ImageMemoryPressureMonitor: @unchecked Sendable {
  private let source: any DispatchSourceMemoryPressure

  init(handler: @escaping @Sendable (UInt) -> Void) {
    source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
    source.setEventHandler { [weak self] in
      guard let self else { return }
      handler(self.source.data.rawValue)
    }
    source.resume()
  }

  deinit { source.cancel() }
}

/// Compressed file size is not a decoded bitmap's memory cost.
enum ImageLoadingPolicy {
  static let mebibyte = 1_024 * 1_024

  static var usesAppleSilicon: Bool {
    #if arch(arm64)
      true
    #else
      false
    #endif
  }

  /// M3/24 GiB measurements favor four reduced-size SDR decoders. Keep smaller
  /// Macs and the unbenchmarked Intel path conservative; leave CPU placement to QoS.
  static func decodeConcurrency(
    physicalMemory: UInt64, activeProcessorCount: Int, appleSilicon: Bool
  ) -> Int {
    Int(am_decode_concurrency(physicalMemory, Int64(activeProcessorCount), appleSilicon))
  }

  static func renderCacheBytes(physicalMemory: UInt64) -> Int {
    Int(am_render_cache_bytes(physicalMemory))
  }

  static func pixelBucket(_ value: Int) -> Int {
    Int(am_pixel_bucket(Int64(value)))
  }

  /// Reserve at most 128–256 MiB for the fitted page's output bitmaps, assuming
  /// square half-float HDR images. Codec workspace, layers and caches are separate.
  static func maximumTilePixels(itemCount: Int, physicalMemory: UInt64) -> Int {
    Int(am_maximum_tile_pixels(Int64(itemCount), physicalMemory))
  }

  static func requestedPixels(
    tileSize: CGSize, displayScale: CGFloat, zoom: CGFloat,
    actualPixels: Bool, itemCount: Int, physicalMemory: UInt64
  ) -> Int {
    Int(am_requested_pixels(Double(tileSize.width), Double(tileSize.height),
      Double(displayScale), Double(zoom), actualPixels, Int64(itemCount), physicalMemory))
  }

  static func previewPixels(for renderPixels: Int) -> Int {
    Int(am_preview_pixels(Int64(renderPixels)))
  }
}

struct ImageFileVersion: Hashable, Sendable {
  let url: URL
  let byteCount: Int?
  let modificationDate: Date?

  init(url: URL) {
    self.url = url.standardizedFileURL
    // A new URL avoids Foundation's previously cached resource values after replacement.
    let freshURL = URL(fileURLWithPath: self.url.path)
    let values = try? freshURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    byteCount = values?.fileSize
    modificationDate = values?.contentModificationDate
  }

  var encoded: NSString {
    "\(url.absoluteString)|\(byteCount ?? -1)|\(modificationDate?.timeIntervalSinceReferenceDate.bitPattern ?? 0)" as NSString
  }
}

/// A byte-accounted LRU, unlike NSCache's advisory totalCostLimit. Actor-owned.
struct ImageCostCache<Key: Hashable, Value> {
  private struct Entry {
    let value: Value
    let cost: Int
    var access: UInt64
  }
  private var entries: [Key: Entry] = [:]
  private var access: UInt64 = 0
  private(set) var totalCost = 0
  var costLimit: Int { didSet { trim() } }

  init(costLimit: Int) { self.costLimit = max(0, costLimit) }

  mutating func value(for key: Key) -> Value? {
    guard var entry = entries[key] else { return nil }
    access &+= 1
    entry.access = access
    entries[key] = entry
    return entry.value
  }

  mutating func insert(_ value: Value, for key: Key, cost: Int) {
    if let previous = entries.removeValue(forKey: key) { totalCost -= previous.cost }
    guard cost > 0, cost <= costLimit else { return }
    access &+= 1
    entries[key] = Entry(value: value, cost: cost, access: access)
    totalCost += cost
    trim()
  }

  mutating func removeAll() {
    entries.removeAll(keepingCapacity: false)
    totalCost = 0
  }

  private mutating func trim() {
    while totalCost > max(0, costLimit),
      let oldest = entries.min(by: { $0.value.access < $1.value.access })
    {
      totalCost -= oldest.value.cost
      entries.removeValue(forKey: oldest.key)
    }
  }
}
