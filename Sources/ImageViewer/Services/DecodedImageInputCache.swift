import CoreGraphics
import Foundation

struct DecodedImageInputKey: Hashable, Sendable {
  let file: ImageFileVersion
  let frameIndex: Int
  let pixelSize: Int
  var geometry: DecodedImageGeometry? = nil
  var prefersHDR = false
}

struct DecodedImageGeometry: Hashable, Sendable {
  let quarterTurns: Int
  let flippedHorizontally: Bool
  let flippedVertically: Bool
  let crop: NormalizedCrop?

  init(_ adjustments: ImageAdjustments) {
    quarterTurns = adjustments.normalizedQuarterTurns
    flippedHorizontally = adjustments.isFlippedHorizontally
    flippedVertically = adjustments.isFlippedVertically
    crop = adjustments.effectiveCrop
  }
}

struct ImageDecodeReuseSnapshot: Sendable {
  let cache: ImageCacheSnapshot
  let decodedFrameCount: Int
  let reuseCount: Int
}

/// Only immutable decoded bitmaps enter this shared, byte-accounted store. Its
/// allowance is taken from the pipeline's existing budget, never added to it.
/// The short lock covers bookkeeping, not decoding or Core Image rendering.
final class DecodedImageInputCache: @unchecked Sendable {
  private let lock = NSLock()
  private var images = ImageCostCache<DecodedImageInputKey, CGImage>(costLimit: 0)
  private var generation: UInt64 = 0
  private var decodedFrameCount = 0
  private var reuseCount = 0

  func generationToken() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return generation
  }

  func canRetain(cost: Int, generation: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return generation == self.generation && cost > 0 && cost <= images.costLimit
  }

  func lookup(_ key: DecodedImageInputKey, generation: UInt64) -> CGImage? {
    lock.lock()
    defer { lock.unlock() }
    guard generation == self.generation else { return nil }
    let image = images.value(for: key)
    if image != nil { reuseCount += 1 }
    return image
  }

  func insert(_ image: CGImage, for key: DecodedImageInputKey, generation: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    decodedFrameCount += 1
    // A purge/pressure update can run while a synchronous RAW decode finishes.
    guard generation == self.generation else { return }
    images.insert(image, for: key, cost: image.bytesPerRow * image.height)
  }

  func setCostLimit(_ limit: Int) {
    lock.lock()
    defer { lock.unlock() }
    if limit < images.costLimit { generation &+= 1 }
    images.costLimit = max(0, limit)
  }

  func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    generation &+= 1
    images.removeAll()
  }

  func snapshot() -> ImageDecodeReuseSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return ImageDecodeReuseSnapshot(
      cache: ImageCacheSnapshot(entryCount: images.count, byteCount: images.totalCost,
        byteLimit: images.costLimit),
      decodedFrameCount: decodedFrameCount, reuseCount: reuseCount)
  }
}
