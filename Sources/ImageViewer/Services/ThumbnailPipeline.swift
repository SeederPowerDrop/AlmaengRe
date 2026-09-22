import Foundation
import ImageIO
import QuickLookThumbnailing

enum ThumbnailPipelineError: LocalizedError {
  case generationFailed(URL)

  var errorDescription: String? {
    switch self {
    case .generationFailed(let url):
      L10n.format("‘%@’의 빠른 미리보기를 만들지 못했습니다.", url.lastPathComponent)
    }
  }
}

private struct GeneratedThumbnail: @unchecked Sendable {
  let image: CGImage
}

/// Quick Look can report success with a completely transparent bitmap, notably for
/// some camera JPEGs at specific thumbnail sizes. Validate actual pixels before
/// caching that result, and repair it from the source within the same I/O job.
enum ThumbnailBitmapDecoder {
  struct Bitmap {
    let image: CGImage
    let hasVisiblePixels: Bool
  }

  static func validatedThumbnail(_ thumbnail: CGImage, sourceURL: URL, maxPixelSize: Int)
    throws -> CGImage
  {
    try Task.checkCancellation()
    if let bitmap = rasterized(thumbnail, maxPixelSize: maxPixelSize), bitmap.hasVisiblePixels {
      try Task.checkCancellation()
      return bitmap.image
    }

    try Task.checkCancellation()
    guard let source = CGImageSourceCreateWithURL(
      sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: min(4096, max(1, maxPixelSize)),
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary),
      let repaired = rasterized(decoded, maxPixelSize: maxPixelSize)
    else {
      // The view can now try its format-specific precise decoder. Never cache
      // the empty Quick Look result as a successful thumbnail.
      throw ThumbnailPipelineError.generationFailed(sourceURL)
    }
    try Task.checkCancellation()
    // An actually transparent source image is valid; only Quick Look's result
    // needs to be verified against the source before accepting transparency.
    return repaired.image
  }

  static func rasterized(_ image: CGImage, maxPixelSize: Int) -> Bitmap? {
    guard image.width > 0, image.height > 0 else { return nil }
    let limit = min(4096, max(1, maxPixelSize))
    let scale = min(1, Double(limit) / Double(max(image.width, image.height)))
    let width = max(1, Int((Double(image.width) * scale).rounded()))
    let height = max(1, Int((Double(image.height) * scale).rounded()))
    let bytesPerRow = width * 4
    // A detached, bounded 8-bit bitmap avoids retaining Quick Look's 16-bit
    // backing storage. Display P3 preserves wide-gamut camera thumbnails.
    guard let space = CGColorSpace(name: CGColorSpace.displayP3),
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: bytesPerRow, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue),
      let data = context.data
    else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = data.assumingMemoryBound(to: UInt8.self)
    var hasVisiblePixels = false
    for offset in stride(from: 3, to: bytesPerRow * height, by: 4) {
      if pixels[offset] != 0 {
        hasVisiblePixels = true
        break
      }
    }
    guard let result = context.makeImage() else { return nil }
    return Bitmap(image: result, hasVisiblePixels: hasVisiblePixels)
  }
}

/// 경로뿐 아니라 파일 버전 정보도 포함해 같은 위치의 이미지가 교체됐을 때
/// 앱 메모리 캐시에서 예전 썸네일을 반환하지 않게 합니다.
struct ThumbnailCacheKey: Hashable, Sendable {
  let fileURL: URL
  let byteCount: Int64?
  let modificationDate: Date?
  let pixelSize: Int

  init(asset: ImageAsset, pixelSize: Int) {
    fileURL = asset.url.standardizedFileURL
    byteCount = asset.byteCount
    modificationDate = asset.modificationDate
    self.pixelSize = pixelSize
  }

  var encoded: NSString {
    let sizePart = byteCount.map(String.init) ?? "unknown"
    let datePart =
      modificationDate.map {
        String($0.timeIntervalSinceReferenceDate.bitPattern)
      } ?? "unknown"
    return "\(fileURL.absoluteString)|\(sizePart)|\(datePart)|\(pixelSize)" as NSString
  }
}

/// 비용 제한이 권고사항인 NSCache와 달리, 삽입 전에 실제 픽셀 바이트 예산을 지킵니다.
struct ThumbnailMemoryCache {
  private struct Entry {
    let image: CGImage
    let cost: Int
    var lastAccess: UInt64
  }

  private(set) var byteLimit: Int
  private var entries: [ThumbnailCacheKey: Entry] = [:]
  private var accessClock: UInt64 = 0
  private(set) var totalBytes = 0

  init(byteLimit: Int) {
    self.byteLimit = max(0, byteLimit)
  }

  mutating func image(for key: ThumbnailCacheKey) -> CGImage? {
    guard var entry = entries[key] else { return nil }
    accessClock &+= 1
    entry.lastAccess = accessClock
    entries[key] = entry
    return entry.image
  }

  mutating func insert(_ image: CGImage, for key: ThumbnailCacheKey) {
    let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
    guard !overflow, cost > 0, cost <= byteLimit else { return }
    if let previous = entries.removeValue(forKey: key) {
      totalBytes -= previous.cost
    }
    while totalBytes > byteLimit - cost,
      let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })
    {
      totalBytes -= oldest.value.cost
      entries.removeValue(forKey: oldest.key)
    }
    accessClock &+= 1
    entries[key] = Entry(image: image, cost: cost, lastAccess: accessClock)
    totalBytes += cost
  }

  mutating func setByteLimit(_ value: Int) {
    byteLimit = max(0, value)
    while totalBytes > byteLimit,
      let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })
    {
      totalBytes -= oldest.value.cost
      entries.removeValue(forKey: oldest.key)
    }
  }

  mutating func removeAll() {
    entries.removeAll(keepingCapacity: false)
    totalBytes = 0
  }
}

/// 취소와 네이티브 콜백이 경합해도 continuation은 한 번만 완료됩니다.
/// 네이티브 API가 취소 후 콜백을 생략해도 기다리는 작업을 즉시 해제합니다.
final class ThumbnailRequestCompletion<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, any Error>?
  private var result: Result<Value, any Error>?

  var isPending: Bool {
    lock.withLock { result == nil }
  }

  @discardableResult
  func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
    let existing = lock.withLock { () -> Result<Value, any Error>? in
      if let result { return result }
      self.continuation = continuation
      return nil
    }
    if let existing {
      continuation.resume(with: existing)
      return false
    }
    return true
  }

  @discardableResult
  func finish(_ result: Result<Value, any Error>) -> Bool {
    let outcome = lock.withLock { () -> (Bool, CheckedContinuation<Value, any Error>?) in
      guard self.result == nil else { return (false, nil) }
      self.result = result
      let continuation = self.continuation
      self.continuation = nil
      return (true, continuation)
    }
    outcome.1?.resume(with: result)
    return outcome.0
  }
}

/// 생성과 취소 호출의 순서를 직렬화합니다. 취소가 먼저 도착한 요청을 뒤늦게
/// 생성하지 않으며, 콜백은 이 큐와 무관하게 안전하게 완료할 수 있습니다.
private final class NativeThumbnailRequest: @unchecked Sendable {
  private static let submissionQueue = DispatchQueue(
    label: "ImageViewer.QuickLook.Submission", qos: .utility)

  private let request: QLThumbnailGenerator.Request
  private let url: URL
  private let submissionQoS: DispatchQoS.QoSClass
  private let completion = ThumbnailRequestCompletion<GeneratedThumbnail>()

  init(url: URL, pixelSize: Int) {
    self.url = url
    let priority = Task.currentPriority
    submissionQoS = priority >= .userInitiated ? .userInitiated
      : priority <= .background ? .background : .utility
    let scale: CGFloat = 2
    let pointSize = CGFloat(pixelSize) / scale
    request = QLThumbnailGenerator.Request(
      fileAt: url,
      size: CGSize(width: pointSize, height: pointSize),
      scale: scale,
      representationTypes: .thumbnail
    )
  }

  func value() async throws -> GeneratedThumbnail {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        guard completion.install(continuation) else { return }
        Self.submissionQueue.async(qos: DispatchQoS(qosClass: submissionQoS, relativePriority: 0),
          flags: .enforceQoS) { [self] in
          guard completion.isPending else { return }
          QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            [completion, url] representation, error in
            if let image = representation?.cgImage {
              completion.finish(.success(GeneratedThumbnail(image: image)))
            } else {
              completion.finish(.failure(error ?? ThumbnailPipelineError.generationFailed(url)))
            }
          }
        }
      }
    } onCancel: {
      guard self.completion.finish(.failure(CancellationError())) else { return }
      Self.submissionQueue.async { [self] in
        QLThumbnailGenerator.shared.cancel(request)
      }
    }
  }
}

/// Quick Look shares the same app-wide I/O budget as precise image decoding.
actor ThumbnailPipeline {
  private struct WorkKey: Hashable, Sendable {
    let thumbnail: ThumbnailCacheKey
    let generation: UInt64
  }

  private var cache = ThumbnailMemoryCache(byteLimit: 0)
  private let governor: ImageResourceGovernor
  private let namespace = UUID()
  private let cacheClientID = UUID()
  private var cacheGeneration: UInt64 = 0
  private var resourceRevision: UInt64 = 0
  private var registeredCacheClient = false

  init(governor: ImageResourceGovernor? = nil) {
    self.governor = governor ?? ImageResourceGovernor()
  }

  func thumbnail(
    for asset: ImageAsset, maxPixelSize: Int, priority: ImageWorkPriority = .visible
  ) async throws -> CGImage {
    try Task.checkCancellation()
    await registerCacheClientIfNeeded()
    let url = asset.url
    if url.pathExtension.lowercased() == "qoi" || url.pathExtension.lowercased() == "pcx" {
      throw ThumbnailPipelineError.generationFailed(url)
    }
    let pixelSize = Self.pixelBucket(maxPixelSize)
    let key = ThumbnailCacheKey(asset: asset, pixelSize: pixelSize)
    if let cached = cache.image(for: key) { return cached }

    let generation = cacheGeneration
    let generated = try await governor.value(
      for: ImageResourceWorkKey(namespace: namespace,
        key: WorkKey(thumbnail: key, generation: generation)),
      url: url, priority: priority
    ) { _ in
      let request = NativeThumbnailRequest(url: url, pixelSize: pixelSize)
      let generated = try await request.value()
      let image = try ThumbnailBitmapDecoder.validatedThumbnail(
        generated.image, sourceURL: url, maxPixelSize: pixelSize)
      return GeneratedThumbnail(image: image)
    }
    try Task.checkCancellation()
    if cacheGeneration == generation { cache.insert(generated.image, for: key) }
    return generated.image
  }

  func prefetch(assets: [ImageAsset], maxPixelSize: Int) async {
    guard let first = assets.first else { return }
    let initial = await governor.limits(for: first.url)
    guard initial.permitsSpeculation else { return }
    do {
      try await Task.sleep(for: .milliseconds(initial.prefetchDelayMilliseconds))
      for (index, asset) in assets.prefix(initial.prefetchCount).enumerated() {
        try Task.checkCancellation()
        let current = await governor.limits(for: asset.url)
        guard current.permitsSpeculation, index < current.prefetchCount else { return }
        _ = try? await thumbnail(for: asset, maxPixelSize: maxPixelSize, priority: .prefetch)
      }
    } catch {
      // Mode, foreground state or navigation changed during the quiet interval.
    }
  }

  func purgeCache() {
    cacheGeneration &+= 1
    cache.removeAll()
  }

  private func registerCacheClientIfNeeded() async {
    guard !registeredCacheClient else { return }
    registeredCacheClient = true
    await governor.registerCacheClient(id: cacheClientID) { [weak self] update in
      await self?.applyResourceLimits(update)
    }
  }

  private func applyResourceLimits(_ update: ImageResourceUpdate) {
    guard update.revision >= resourceRevision else { return }
    resourceRevision = update.revision
    if update.limits.thumbnailCacheBytes < cache.byteLimit { purgeCache() }
    cache.setByteLimit(update.limits.thumbnailCacheBytes)
  }

  private static func pixelBucket(_ value: Int) -> Int {
    let clamped = min(4_096, max(96, value))
    return ((clamped + 127) / 128) * 128
  }
}
