import CoreGraphics
import CoreImage
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
  let metalPreparedCount: Int
  let metalReuseCount: Int
  let metalKernelSeconds: Double
  let metalCompileSeconds: Double
}

/// Only immutable decoded inputs enter this shared, byte-accounted store. Its
/// allowance is taken from the pipeline's existing budget, never added to it.
/// The short lock covers bookkeeping, not decoding or Core Image rendering.
final class DecodedImageInputCache: @unchecked Sendable {
  private enum Input {
    case bitmap(CGImage)
    case metal(MetalWorkingImage)
  }
  private let lock = NSLock()
  private var images = ImageCostCache<DecodedImageInputKey, Input>(costLimit: 0)
  private var generation: UInt64 = 0
  private var decodedFrameCount = 0
  private var reuseCount = 0
  private var metalPreparedCount = 0
  private var metalReuseCount = 0
  private var metalKernelSeconds = 0.0
  private var metalCompileSeconds = 0.0

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
    guard case .bitmap(let image) = images.value(for: key) else { return nil }
    reuseCount += 1
    return image
  }

  func lookupWorkingImage(_ key: DecodedImageInputKey, generation: UInt64) -> CIImage? {
    lock.lock()
    guard generation == self.generation, let input = images.value(for: key) else {
      lock.unlock()
      return nil
    }
    reuseCount += 1
    if case .metal = input { metalReuseCount += 1 }
    lock.unlock()
    switch input {
    case .bitmap(let image): return CIImage(cgImage: image)
    case .metal(let working): return working.image
    }
  }

  func insert(_ image: CGImage, for key: DecodedImageInputKey, generation: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    decodedFrameCount += 1
    // A purge/pressure update can run while a synchronous RAW decode finishes.
    guard generation == self.generation else { return }
    images.insert(.bitmap(image), for: key, cost: image.bytesPerRow * image.height)
  }

  func insert(_ image: MetalWorkingImage, for key: DecodedImageInputKey, generation: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    decodedFrameCount += 1
    metalPreparedCount += 1
    metalKernelSeconds += image.kernelSeconds
    metalCompileSeconds += image.compileSeconds
    guard generation == self.generation else { return }
    images.insert(.metal(image), for: key, cost: image.byteCount)
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
      decodedFrameCount: decodedFrameCount, reuseCount: reuseCount,
      metalPreparedCount: metalPreparedCount, metalReuseCount: metalReuseCount,
      metalKernelSeconds: metalKernelSeconds, metalCompileSeconds: metalCompileSeconds)
  }
}
