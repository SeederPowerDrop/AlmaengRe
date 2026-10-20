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
/// some camera JPEGs at specific thumbnail sizes, or an opaque black bitmap for
/// RAW files without embedded previews. Verify suspect results against the source
/// before caching them, within the same bounded I/O job.
enum ThumbnailBitmapDecoder {
  struct Bitmap {
    let image: CGImage
    let hasVisiblePixels: Bool
    let hasNonBlackPixels: Bool
  }

  /// RAW browsing uses only an embedded preview here: never start a full sensor
  /// decode to obtain a small first bitmap. Missing previews retain the native fallback.
  static func browsingThumbnail(sourceURL: URL, maxPixelSize: Int) throws -> CGImage? {
    try directThumbnail(sourceURL: sourceURL, maxPixelSize: min(1_024, maxPixelSize),
      allowsUndersizedPreview: true)
  }

  /// Cheap preparation never asks ImageIO to synthesize a missing preview.
  /// The bound must be met by real pixels; a smaller embedded image falls back
  /// to the existing precise decoder under its separate, conservative pacing.
  static func embeddedOverviewThumbnail(sourceURL: URL, maxPixelSize: Int = 256) throws -> CGImage? {
    try Task.checkCancellation()
    let requested = min(4_096, max(96, maxPixelSize))
    return try autoreleasepool {
      guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary),
        let embedded = try embeddedThumbnail(in: source, maxPixelSize: requested),
        max(embedded.width, embedded.height) >= requested else { return nil }
      // CopyPropertiesAtIndex is unnecessary here: there is no source-size
      // generation branch, and the embedded decoder has applied orientation.
      try Task.checkCancellation()
      return rasterized(embedded, maxPixelSize: requested)?.image
    }
  }

  /// Visible thumbnails use an embedded preview when it has enough pixels. A RAW
  /// without one goes straight to the source thumbnail decoder: Quick Look can
  /// return a black bitmap that would otherwise require this same decode anyway.
  /// Browsing-only previews remain embedded-only for RAW. All source work stays
  /// inside the shared governor's bounded worker slot.
  static func directThumbnail(sourceURL: URL, maxPixelSize: Int,
    allowsUndersizedPreview: Bool = false
  ) throws -> CGImage? {
    try Task.checkCancellation()
    let extensionName = sourceURL.pathExtension.lowercased()
    let isCameraRAW = ImageFormatRegistry.cameraRAWExtensions.contains(extensionName)
    guard isCameraRAW || ["jpg", "jpeg", "png", "heic", "heif", "hif", "webp", "gif", "avif", "bmp"]
      .contains(extensionName)
    else { return nil }
    return try autoreleasepool {
      guard let source = CGImageSourceCreateWithURL(
        sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
      else { return nil }
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
      let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
      let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
      let requested = min(4_096, max(96, maxPixelSize))
      let sourcePixels = max(width, height)
      let limit = sourcePixels > 0 ? min(sourcePixels, requested) : requested
      try Task.checkCancellation()
      var image = try embeddedThumbnail(in: source, maxPixelSize: limit)
      let hasEnoughPixels = image.map { max($0.width, $0.height) >= limit } ?? false
      if image == nil || (!allowsUndersizedPreview && !hasEnoughPixels) {
        guard !isCameraRAW || !allowsUndersizedPreview else { return nil }
        try Task.checkCancellation()
        image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: limit,
          kCGImageSourceShouldCacheImmediately: true,
          kCGImageSourceShouldAllowFloat: false,
        ] as CFDictionary)
      }
      try Task.checkCancellation()
      guard let image, let bitmap = rasterized(image, maxPixelSize: requested) else { return nil }
      try Task.checkCancellation()
      return bitmap.image
    }
  }

  /// This operation never generates missing previews. Keep the flags together so
  /// a format-specific caller cannot accidentally opt a RAW file into a full decode.
  static func embeddedThumbnail(in source: CGImageSource, maxPixelSize: Int) throws -> CGImage? {
    try Task.checkCancellation()
    let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
      kCGImageSourceCreateThumbnailFromImageAlways: false,
      kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: min(4_096, max(1, maxPixelSize)),
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceShouldAllowFloat: false,
    ] as CFDictionary)
    try Task.checkCancellation()
    return image
  }

  static func validatedThumbnail(_ thumbnail: CGImage, sourceURL: URL, maxPixelSize: Int)
    throws -> CGImage
  {
    try Task.checkCancellation()
    let isCameraRAW = ImageFormatRegistry.cameraRAWExtensions.contains(
      sourceURL.pathExtension.lowercased())
    if let bitmap = rasterized(thumbnail, maxPixelSize: maxPixelSize), bitmap.hasVisiblePixels,
      !isCameraRAW || bitmap.hasNonBlackPixels
    {
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
    // Truly black RAWs and transparent source images are valid. The source decode
    // is authoritative; do not treat darkness as an error or alter its pixels.
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
    var hasNonBlackPixels = false
    for offset in stride(from: 0, to: bytesPerRow * height, by: 4) {
      if pixels[offset + 3] != 0 {
        hasVisiblePixels = true
        if pixels[offset] != 0 || pixels[offset + 1] != 0 || pixels[offset + 2] != 0 {
          hasNonBlackPixels = true
          break
        }
      }
    }
    guard let result = context.makeImage() else { return nil }
    return Bitmap(image: result, hasVisiblePixels: hasVisiblePixels,
      hasNonBlackPixels: hasNonBlackPixels)
  }
}

/// 경로뿐 아니라 파일 버전 정보도 포함해 같은 위치의 이미지가 교체됐을 때
/// 앱 메모리 캐시에서 예전 썸네일을 반환하지 않게 합니다.
struct ThumbnailCacheKey: Hashable, Sendable {
  struct SourceVersion: Hashable, Sendable {
    let url: URL
    let byteCount: Int64?
    let modificationDate: Date?
  }
  let fileURL: URL
  let byteCount: Int64?
  let modificationDate: Date?
  let pixelSize: Int
  let isBrowsingPreview: Bool

  var sourceVersion: SourceVersion {
    SourceVersion(url: fileURL, byteCount: byteCount, modificationDate: modificationDate)
  }

  init(asset: ImageAsset, pixelSize: Int, isBrowsingPreview: Bool = false) {
    fileURL = asset.url.standardizedFileURL
    byteCount = asset.byteCount
    modificationDate = asset.modificationDate
    self.pixelSize = pixelSize
    self.isBrowsingPreview = isBrowsingPreview
  }

  var encoded: NSString {
    let sizePart = byteCount.map(String.init) ?? "unknown"
    let datePart =
      modificationDate.map {
        String($0.timeIntervalSinceReferenceDate.bitPattern)
      } ?? "unknown"
    return "\(fileURL.absoluteString)|\(sizePart)|\(datePart)|\(pixelSize)|\(isBrowsingPreview)" as NSString
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
  // First-pixel requests inspect only this file version's few size variants,
  // rather than scanning every other photo in the bounded bitmap cache.
  private var sourceEntries: [ThumbnailCacheKey.SourceVersion: Set<ThumbnailCacheKey>] = [:]
  private var accessClock: UInt64 = 0
  private var visibleSources: Set<ThumbnailCacheKey.SourceVersion> = []
  private(set) var totalBytes = 0
  var count: Int { entries.count }

  init(byteLimit: Int) {
    self.byteLimit = max(0, byteLimit)
  }

  mutating func image(for key: ThumbnailCacheKey) -> CGImage? {
    // Returning from a viewer/map or reducing grid size should reuse a detailed
    // thumbnail instead of sending the same RAW file through Quick Look again.
    // Undersized browsing previews must never satisfy an exact-quality request.
    let selected: ThumbnailCacheKey
    if entries[key] != nil {
      selected = key
    } else if !key.isBrowsingPreview, let larger = sourceEntries[key.sourceVersion]?.filter({ candidate in
      if !candidate.isBrowsingPreview { return candidate.pixelSize >= key.pixelSize }
      // A browsing preview can be undersized, so its requested bucket is not
      // evidence of quality. Its actual pixels can still cover a smaller map
      // marker or filmstrip, without decoding the same RAW a second time.
      guard let image = entries[candidate]?.image else { return false }
      return max(image.width, image.height) >= key.pixelSize
    }).min(by: { $0.pixelSize < $1.pixelSize }) {
      selected = larger
    } else {
      return nil
    }
    guard var entry = entries[selected] else { return nil }
    accessClock &+= 1
    entry.lastAccess = accessClock
    entries[selected] = entry
    return entry.image
  }

  /// While browsing, an already decoded bitmap is more useful than waiting for an
  /// exact size. Match the complete file version so replacements never show stale pixels.
  mutating func browsingImage(for key: ThumbnailCacheKey) -> CGImage? {
    if let exact = image(for: key) { return exact }
    guard let matching = sourceEntries[key.sourceVersion] else { return nil }
    let selected = matching.lazy.filter { $0.pixelSize >= key.pixelSize }
      .min { $0.pixelSize < $1.pixelSize }
      ?? matching.max { $0.pixelSize < $1.pixelSize }
    guard let selected else { return nil }
    return image(for: selected)
  }

  mutating func protectVisibleAssets(_ assets: [ImageAsset]) {
    visibleSources = Set(assets.map { ThumbnailCacheKey(asset: $0, pixelSize: 128).sourceVersion })
  }

  mutating func insert(_ image: CGImage, for key: ThumbnailCacheKey,
    isSpeculative: Bool = false) {
    let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
    guard !overflow, cost > 0, cost <= byteLimit else { return }
    if isSpeculative {
      let protectedBytes = entries.filter { $0.key != key && visibleSources.contains($0.key.sourceVersion) }
        .values.reduce(0) { $0 + $1.cost }
      guard protectedBytes <= byteLimit - cost else { return }
    }
    remove(key)
    while totalBytes > byteLimit - cost,
      let oldest = evictionCandidate()
    {
      remove(oldest.key)
    }
    accessClock &+= 1
    entries[key] = Entry(image: image, cost: cost, lastAccess: accessClock)
    sourceEntries[key.sourceVersion, default: []].insert(key)
    totalBytes += cost
  }

  mutating func setByteLimit(_ value: Int) {
    byteLimit = max(0, value)
    while totalBytes > byteLimit,
      let oldest = evictionCandidate()
    {
      remove(oldest.key)
    }
  }

  private func evictionCandidate() -> Dictionary<ThumbnailCacheKey, Entry>.Element? {
    // A returning grid inserts many small bitmaps. Find the two oldest choices
    // in one pass without allocating a filtered dictionary for every eviction.
    var oldest: Dictionary<ThumbnailCacheKey, Entry>.Element?
    var oldestUnprotected: Dictionary<ThumbnailCacheKey, Entry>.Element?
    for candidate in entries {
      if oldest == nil || candidate.value.lastAccess < oldest!.value.lastAccess {
        oldest = candidate
      }
      if !visibleSources.contains(candidate.key.sourceVersion),
        oldestUnprotected == nil || candidate.value.lastAccess < oldestUnprotected!.value.lastAccess {
        oldestUnprotected = candidate
      }
    }
    return oldestUnprotected ?? oldest
  }

  private mutating func remove(_ key: ThumbnailCacheKey) {
    guard let previous = entries.removeValue(forKey: key) else { return }
    totalBytes -= previous.cost
    sourceEntries[key.sourceVersion]?.remove(key)
    if sourceEntries[key.sourceVersion]?.isEmpty == true {
      sourceEntries.removeValue(forKey: key.sourceVersion)
    }
  }

  mutating func removeAll() {
    entries.removeAll(keepingCapacity: false)
    sourceEntries.removeAll(keepingCapacity: false)
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

struct OverviewCachedAssetCounts: Sendable {
  let preview: Int
  let exact: Int
  let total: Int
}

struct CachedPreviewDiagnosticRecord: Sendable {
  let phase: String
  let assetURL: URL
  let elapsedSeconds: Double
  let cacheHit: Bool
  let cancelled: Bool
}

/// Quick Look shares the same app-wide I/O budget as precise image decoding.
actor ThumbnailPipeline {
  private struct WorkKey: Hashable, Sendable {
    let thumbnail: ThumbnailCacheKey
    let generation: UInt64
  }

  private var cache = ThumbnailMemoryCache(byteLimit: 0)
  private let governor: ImageResourceGovernor
  private let diskCache: ThumbnailDiskCache?
  private let beginOverviewWarmActivity: @Sendable (ProcessInfo.ActivityOptions) -> OverviewWarmActivity
  private let namespace = UUID()
  private let browsingNamespace = UUID()
  private let cachedPreviewNamespace = UUID()
  private let warmingNamespace = UUID()
  private let cacheClientID = UUID()
  private var cacheGeneration: UInt64 = 0
  private var resourceRevision: UInt64 = 0
  private var registeredCacheClient = false
  private var cachedPreviewDiagnosticPhase: String?
  private var cachedPreviewDiagnosticRecords: [CachedPreviewDiagnosticRecord] = []

  init(governor: ImageResourceGovernor? = nil, diskCache: ThumbnailDiskCache? = .shared,
    beginOverviewWarmActivity: @escaping @Sendable (ProcessInfo.ActivityOptions) -> OverviewWarmActivity = {
      OverviewWarmActivity.begin(options: $0)
    }) {
    self.governor = governor ?? ImageResourceGovernor()
    self.diskCache = diskCache
    self.beginOverviewWarmActivity = beginOverviewWarmActivity
  }

  /// Small, promptly scheduled frames let fast navigation keep presenting images.
  /// Sharing the thumbnail cache preserves the same strict app-wide byte budget.
  func browsingThumbnail(for asset: ImageAsset, maxPixelSize: Int = 512,
    preciseRAWFallbackPixelSize: Int? = nil
  ) async throws -> CGImage {
    try Task.checkCancellation()
    if asset.isAudio {
      return try AudioMediaPreview.frame(for: asset.url, maxPixelSize: maxPixelSize).image
    }
    await registerCacheClientIfNeeded()
    let url = asset.url
    if ["qoi", "pcx"].contains(url.pathExtension.lowercased()) {
      throw ThumbnailPipelineError.generationFailed(url)
    }
    let pixelSize = Self.pixelBucket(min(1_024, maxPixelSize))
    let fallbackPixelSize = preciseRAWFallbackPixelSize.flatMap { requested -> Int? in
      guard ImageFormatRegistry.cameraRAWExtensions.contains(asset.fileExtension) else { return nil }
      return Self.pixelBucket(min(1_024, max(pixelSize, requested)))
    }
    // An embedded camera preview may be smaller than the requested bound. Keep
    // that result distinct from exact-quality thumbnails used by the overview.
    let key = ThumbnailCacheKey(asset: asset, pixelSize: pixelSize, isBrowsingPreview: true)
    if let cached = cache.browsingImage(for: key) { return cached }
    let generation = cacheGeneration
    let generated = try await governor.value(
      for: ImageResourceWorkKey(namespace: browsingNamespace,
        key: WorkKey(thumbnail: key, generation: generation)),
      url: url, priority: .interactivePreview
    ) { _ in
      if let cached = await self.cachedThumbnail(for: key, generation: generation) { return cached }
      if let cached = await self.restoreFromDisk(for: key, generation: generation,
        allowsSmaller: true) { return cached }
      if asset.isVideo {
        let frame = try await VideoMediaReader.posterFrame(for: url, maxPixelSize: pixelSize)
        return try await self.remember(frame.image, for: key, generation: generation)
      }
      if let image = try ThumbnailBitmapDecoder.browsingThumbnail(
        sourceURL: url, maxPixelSize: pixelSize)
      {
        return try await self.remember(image, for: key, generation: generation)
      }
      if let fallbackPixelSize {
        // No embedded first bitmap exists. An opted-in unedited SDR overview
        // cell will need this same source decode at display size after quiet.
        // Prepare it once inside the existing worker slot, then return compact
        // pixels while the normal refinement task reuses the precise cache.
        let exactKey = ThumbnailCacheKey(asset: asset, pixelSize: fallbackPixelSize)
        var exact = await self.cachedThumbnail(for: exactKey, generation: generation)?.image
        if exact == nil {
          exact = await self.restoreFromDisk(for: exactKey, generation: generation)?.image
        }
        if exact == nil {
          do {
            if let image = try ThumbnailBitmapDecoder.directThumbnail(
              sourceURL: url, maxPixelSize: fallbackPixelSize) {
              exact = try await self.remember(image, for: exactKey, generation: generation).image
            }
          } catch is CancellationError { throw CancellationError() } catch {
            // Preserve Quick Look and its validated source repair below.
          }
        }
        if let exact, let compact = try await self.compactBrowsingResult(exact,
          for: key, generation: generation) { return compact }
      }
      try Task.checkCancellation()
      let request = NativeThumbnailRequest(url: url, pixelSize: pixelSize)
      let generated = try await request.value()
      let image = try ThumbnailBitmapDecoder.validatedThumbnail(
        generated.image, sourceURL: url, maxPixelSize: pixelSize)
      return try await self.remember(image, for: key, generation: generation)
    }
    try Task.checkCancellation()
    return generated.image
  }

  func thumbnail(
    for asset: ImageAsset, maxPixelSize: Int, priority: ImageWorkPriority = .visible,
    waitsForStableVisibility: Bool = false, retainsInMemory: Bool = true
  ) async throws -> CGImage {
    try Task.checkCancellation()
    if asset.isAudio {
      return try AudioMediaPreview.frame(for: asset.url, maxPixelSize: maxPixelSize).image
    }
    await registerCacheClientIfNeeded()
    let url = asset.url
    if url.pathExtension.lowercased() == "qoi" || url.pathExtension.lowercased() == "pcx" {
      throw ThumbnailPipelineError.generationFailed(url)
    }
    let pixelSize = Self.pixelBucket(maxPixelSize)
    let key = ThumbnailCacheKey(asset: asset, pixelSize: pixelSize)
    if let cached = cache.image(for: key) { return cached }

    // ImageIO's synchronous RAW decoder cannot be interrupted once it starts.
    // Let transient grid/map cells disappear before admitting their work. Cached
    // pixels and the selected photo's interactive preview remain immediate.
    let hasDiskImage = await diskCache?.contains(for: key) ?? false
    if waitsForStableVisibility && !hasDiskImage
      && ImageFormatRegistry.cameraRAWExtensions.contains(asset.fileExtension) {
      try await Task.sleep(for: .milliseconds(100))
      try Task.checkCancellation()
      if let cached = cache.image(for: key) { return cached }
    }

    let generation = cacheGeneration
    let generated = try await governor.value(
      for: ImageResourceWorkKey(namespace: namespace,
        key: WorkKey(thumbnail: key, generation: generation)),
      url: url, priority: priority
    ) { _ in
      if let cached = await self.cachedThumbnail(for: key, generation: generation) { return cached }
      if let cached = await self.restoreFromDisk(for: key, generation: generation,
        retainsInMemory: retainsInMemory, isSpeculative: priority <= .prefetch) { return cached }
      if asset.isVideo {
        let frame = try await VideoMediaReader.posterFrame(for: url, maxPixelSize: pixelSize)
        return try await self.remember(frame.image, for: key, generation: generation,
          retainsInMemory: retainsInMemory, isSpeculative: priority <= .prefetch)
      }
      if let image = try ThumbnailBitmapDecoder.directThumbnail(
        sourceURL: url, maxPixelSize: pixelSize)
      {
        return try await self.remember(image, for: key, generation: generation,
          retainsInMemory: retainsInMemory, isSpeculative: priority <= .prefetch)
      }
      let request = NativeThumbnailRequest(url: url, pixelSize: pixelSize)
      let generated = try await request.value()
      let image = try ThumbnailBitmapDecoder.validatedThumbnail(
        generated.image, sourceURL: url, maxPixelSize: pixelSize)
      return try await self.remember(image, for: key, generation: generation,
        retainsInMemory: retainsInMemory, isSpeculative: priority <= .prefetch)
    }
    try Task.checkCancellation()
    if retainsInMemory, cacheGeneration == generation {
      cache.insert(generated.image, for: key, isSpeculative: priority <= .prefetch)
    }
    return generated.image
  }

  /// The governor may suspend during storage classification after the initial
  /// cache miss. Recheck on worker entry, and publish before that job releases its
  /// slot, so a late identical request cannot decode and replace the same bitmap.
  private func cachedThumbnail(for key: ThumbnailCacheKey, generation: UInt64) -> GeneratedThumbnail? {
    guard cacheGeneration == generation else { return nil }
    let image = key.isBrowsingPreview ? cache.browsingImage(for: key) : cache.image(for: key)
    return image.map { GeneratedThumbnail(image: $0) }
  }

  private func compactBrowsingResult(_ exact: CGImage, for key: ThumbnailCacheKey,
    generation: UInt64) throws -> GeneratedThumbnail? {
    try Task.checkCancellation()
    guard let compact = ThumbnailBitmapDecoder.rasterized(exact,
      maxPixelSize: key.pixelSize)?.image else { return nil }
    try Task.checkCancellation()
    if cacheGeneration == generation { cache.insert(compact, for: key) }
    // remember(exact) already persisted both tiers; do not encode/write the
    // same compact PNG again merely to return its smaller first bitmap.
    return GeneratedThumbnail(image: compact)
  }

  private func remember(_ image: CGImage, for key: ThumbnailCacheKey, generation: UInt64,
    retainsInMemory: Bool = true, isSpeculative: Bool = false)
    async throws -> GeneratedThumbnail
  {
    try Task.checkCancellation()
    if cacheGeneration == generation {
      if retainsInMemory { cache.insert(image, for: key, isSpeculative: isSpeculative) }
      let diskGeneration = await diskCache?.generationToken()
      guard cacheGeneration == generation else { return GeneratedThumbnail(image: image) }
      // Await one serial disk writer inside the governed job. No unbounded write queue.
      await diskCache?.store(image, for: key, generation: diskGeneration)
      // Keep a compact copy in its own tier as well. Otherwise a long tour could
      // evict an old detailed entry before that photo ever received a small preview.
      if cacheGeneration == generation, diskCache != nil, !key.isBrowsingPreview,
        let compact = ThumbnailBitmapDecoder.rasterized(image, maxPixelSize: 256)?.image {
        let compactKey = ThumbnailCacheKey(asset: ImageAsset(url: key.fileURL,
          byteCount: key.byteCount, modificationDate: key.modificationDate),
          pixelSize: 256, isBrowsingPreview: true)
        await diskCache?.store(compact, for: compactKey, generation: diskGeneration)
      }
    }
    try Task.checkCancellation()
    return GeneratedThumbnail(image: image)
  }

  private func restoreFromDisk(for key: ThumbnailCacheKey, generation: UInt64,
    allowsSmaller: Bool = false, retainsInMemory: Bool = true,
    isSpeculative: Bool = false) async -> GeneratedThumbnail? {
    guard !Task.isCancelled, let image = await diskCache?.image(for: key, allowsSmaller: allowsSmaller),
      !Task.isCancelled else { return nil }
    if retainsInMemory, cacheGeneration == generation {
      // A smaller fallback must never masquerade as an exact-quality result.
      let restoredKey = allowsSmaller ? ThumbnailCacheKey(
        asset: ImageAsset(url: key.fileURL, byteCount: key.byteCount,
          modificationDate: key.modificationDate), pixelSize: max(image.width, image.height),
        isBrowsingPreview: true) : key
      cache.insert(image, for: restoredKey, isSpeculative: isSpeculative)
    }
    return GeneratedThumbnail(image: image)
  }

  /// Cache-only first pixels for returning grid cells. A miss never reads the RAW.
  func cachedPreview(for asset: ImageAsset, maxPixelSize: Int,
    prefersCompact: Bool = false) async -> CGImage? {
    // Capture before the first await: an outbound request that completes after
    // the next phase starts must still be attributed to its original viewport.
    guard let phase = cachedPreviewDiagnosticPhase else {
      return await cachedPreviewImage(for: asset, maxPixelSize: maxPixelSize,
        prefersCompact: prefersCompact)
    }
    let started = ProcessInfo.processInfo.systemUptime
    let image = await cachedPreviewImage(for: asset, maxPixelSize: maxPixelSize,
      prefersCompact: prefersCompact)
    let record = CachedPreviewDiagnosticRecord(phase: phase, assetURL: asset.url,
      elapsedSeconds: max(0, ProcessInfo.processInfo.systemUptime - started),
      cacheHit: image != nil, cancelled: Task.isCancelled)
    if cachedPreviewDiagnosticRecords.count >= 4_096 {
      cachedPreviewDiagnosticRecords.removeFirst(cachedPreviewDiagnosticRecords.count - 4_095)
    }
    cachedPreviewDiagnosticRecords.append(record)
    return image
  }

  /// Enables optional pipeline-return timing without decoding, drawing, or
  /// changing scheduling. Nil disables new records; in-flight phases remain intact.
  func setCachedPreviewDiagnosticPhase(_ phase: String?) {
    cachedPreviewDiagnosticPhase = phase
  }

  /// Timing ends when the pipeline returns a bitmap, not when the screen paints.
  /// Clear at measurement start; changing phases deliberately retains prior records.
  func cachedPreviewDiagnosticsSnapshot(clear: Bool = false) -> [CachedPreviewDiagnosticRecord] {
    let result = cachedPreviewDiagnosticRecords
    if clear { cachedPreviewDiagnosticRecords.removeAll(keepingCapacity: true) }
    return result
  }

  private func cachedPreviewImage(for asset: ImageAsset, maxPixelSize: Int,
    prefersCompact: Bool) async -> CGImage? {
    await registerCacheClientIfNeeded()
    let key = ThumbnailCacheKey(asset: asset, pixelSize: Self.pixelBucket(maxPixelSize))
    if let image = cache.browsingImage(for: key) { return image }
    // Overview first pixels use the compact PNG when one exists. Returning a
    // larger bitmap already in RAM remains free; only disk restore preference
    // changes, leaving viewer/map exact-quality lookups untouched.
    let lookupKey = prefersCompact ? ThumbnailCacheKey(asset: asset,
      pixelSize: min(256, key.pixelSize), isBrowsingPreview: true) : key
    guard await diskCache?.contains(for: lookupKey, allowsSmaller: true) == true else { return nil }
    let generation = cacheGeneration
    let result = try? await governor.value(for: ImageResourceWorkKey(namespace: cachedPreviewNamespace,
      key: WorkKey(thumbnail: lookupKey, generation: generation)), url: asset.url,
      priority: .interactivePreview, workload: .cachedThumbnail) { _ in
        if let cached = await self.cachedBrowsingThumbnail(for: key, generation: generation) {
          return cached
        }
        return await self.restoreFromDisk(for: lookupKey, generation: generation, allowsSmaller: true)
      }
    return result?.image
  }

  private func cachedBrowsingThumbnail(for key: ThumbnailCacheKey,
    generation: UInt64) -> GeneratedThumbnail? {
    guard cacheGeneration == generation else { return nil }
    return cache.browsingImage(for: key).map { GeneratedThumbnail(image: $0) }
  }

  /// A warm navigation destination can overtake an older source decode. This
  /// lookup never restores disk data, classifies storage, or admits decoder work.
  func cachedMemoryPreview(for asset: ImageAsset, maxPixelSize: Int) -> CGImage? {
    cache.browsingImage(for: ThumbnailCacheKey(asset: asset,
      pixelSize: Self.pixelBucket(maxPixelSize)))
  }

  func updateOverviewVisibleAssets(_ assets: [ImageAsset]) {
    cache.protectVisibleAssets(assets)
  }

  @discardableResult
  func prefetchOverview(assets: [ImageAsset], maxPixelSize: Int, retainsInMemory: Bool,
    waitsForQuietInterval: Bool = true) async -> Bool {
    guard let first = assets.first else { return true }
    let limits = await governor.limits(for: first.url)
    guard limits.permitsSpeculation else { return false }
    do {
      if waitsForQuietInterval {
        try await Task.sleep(for: .milliseconds(max(250, limits.prefetchDelayMilliseconds)))
      }
      for asset in assets {
        try Task.checkCancellation()
        guard await governor.limits(for: asset.url).permitsSpeculation else { return false }
        do {
          _ = try await thumbnail(for: asset, maxPixelSize: maxPixelSize, priority: .prefetch,
            retainsInMemory: retainsInMemory)
        } catch is CancellationError { return false } catch { /* Skip unsupported/broken media. */ }
      }
      return true
    } catch { return false }
  }

  @discardableResult
  func warmOverviewPreviews(assets: [ImageAsset]) async -> Bool {
    guard let diskCache else { return false }
    await registerCacheClientIfNeeded()
    for asset in assets {
      guard !Task.isCancelled else {
        return false
      }
      let key = ThumbnailCacheKey(asset: asset, pixelSize: 256, isBrowsingPreview: true)
      // An existing detailed disk image also covers the compact tier: no duplicate decode.
      if await diskCache.contains(for: key, allowsSmaller: true) { continue }
      if asset.isAudio || ["qoi", "pcx"].contains(asset.fileExtension) { continue }
      let generation = cacheGeneration
      var activity: OverviewWarmActivity?
      // A protected retry or already-prepared item holds no activity. An
      // admitted item includes its adaptive sleep, and permits system idle sleep.
      defer { withExtendedLifetime(activity) {} }
      do {
        if !asset.isVideo {
          guard let delay = await governor.overviewWarmDelay(for: asset.url, workKind: .embeddedPreview)
          else { return false }
          try Task.checkCancellation()
          activity = beginOverviewWarmActivity(.userInitiatedAllowingIdleSystemSleep)
          try await Task.sleep(for: .milliseconds(delay))
          let prepared = try await governor.value(for: ImageResourceWorkKey(namespace: warmingNamespace,
            key: WorkKey(thumbnail: key, generation: generation)), url: asset.url,
            priority: .idleThumbnail, workload: .overviewPreview) { [activity] _ in
              // Cancelling a waiter cannot interrupt synchronous ImageIO. Keep
              // the lease until the governed native operation actually returns.
              defer { withExtendedLifetime(activity) {} }
              if await diskCache.contains(for: key, allowsSmaller: true) { return true }
              let workStarted = ProcessInfo.processInfo.systemUptime
              let cpuStarted = OverviewWarmCPUCost.processCPUSeconds()
              let image = try ThumbnailBitmapDecoder.embeddedOverviewThumbnail(sourceURL: asset.url)
              if let image {
                _ = try await self.remember(image, for: key, generation: generation, retainsInMemory: false)
              }
              let cpuFinished = OverviewWarmCPUCost.processCPUSeconds()
              let workCost = OverviewWarmCPUCost.embeddedCostSeconds(
                wallSeconds: ProcessInfo.processInfo.systemUptime - workStarted,
                cpuBefore: cpuStarted, cpuAfter: cpuFinished)
              await self.governor.recordOverviewWarmDuration(
                workCost, for: asset.url, workKind: .embeddedPreview)
              return image != nil
            }
          if prepared { continue }
        }
        guard let delay = await governor.overviewWarmDelay(for: asset.url, workKind: .sourceFallback)
        else { return false }
        try Task.checkCancellation()
        if activity == nil {
          activity = beginOverviewWarmActivity(.userInitiatedAllowingIdleSystemSleep)
        }
        try await Task.sleep(for: .milliseconds(delay))
        _ = try await governor.value(for: ImageResourceWorkKey(namespace: warmingNamespace,
          key: WorkKey(thumbnail: key, generation: generation)), url: asset.url,
          priority: .idleThumbnail, workload: .overviewPreview) { [activity] _ in
            defer { withExtendedLifetime(activity) {} }
            if await diskCache.contains(for: key, allowsSmaller: true) { return true }
            let workStarted = ProcessInfo.processInfo.systemUptime
            let image: CGImage
            if asset.isVideo {
              image = try await VideoMediaReader.posterFrame(for: asset.url, maxPixelSize: 256).image
            } else if let direct = try ThumbnailBitmapDecoder.directThumbnail(
              sourceURL: asset.url, maxPixelSize: 256) {
              image = direct
            } else {
              let native = try await NativeThumbnailRequest(url: asset.url, pixelSize: 256).value()
              image = try ThumbnailBitmapDecoder.validatedThumbnail(native.image,
                sourceURL: asset.url, maxPixelSize: 256)
            }
            _ = try await self.remember(image, for: key, generation: generation, retainsInMemory: false)
            await self.governor.recordOverviewWarmDuration(
              ProcessInfo.processInfo.systemUptime - workStarted, for: asset.url, workKind: .sourceFallback)
            return true
          }
      } catch is CancellationError { return false } catch { /* Continue past broken media. */ }
    }
    return true
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

  /// Explicit Settings action reclaims persisted previews as well. Ordinary
  /// library changes and memory pressure use the RAM-only operation above.
  @discardableResult
  func purgeAllCaches() async -> Bool {
    purgeCache()
    return await diskCache?.removeAll() ?? true
  }

  func cacheSnapshot() -> ImageCacheSnapshot {
    ImageCacheSnapshot(entryCount: cache.count, byteCount: cache.totalBytes,
      byteLimit: cache.byteLimit)
  }

  /// Persisted disk coverage only: consults versioned thumbnail metadata without
  /// reading source files, decoding PNGs, or counting RAM-only cache entries.
  /// Preview includes any cached size; exact requires the requested bucket or larger.
  func overviewCachedAssetCounts(assets: [ImageAsset], maxPixelSize: Int) async
    -> OverviewCachedAssetCounts {
    guard let diskCache else { return OverviewCachedAssetCounts(preview: 0, exact: 0, total: 0) }
    let pixels = Self.pixelBucket(maxPixelSize)
    var preview = 0
    var exact = 0
    for asset in assets {
      let key = ThumbnailCacheKey(asset: asset, pixelSize: pixels)
      if await diskCache.contains(for: key, allowsSmaller: true) { preview += 1 }
      if await diskCache.contains(for: key) { exact += 1 }
    }
    return OverviewCachedAssetCounts(preview: preview, exact: exact, total: assets.count)
  }

  func diskCacheSnapshot() async -> ThumbnailDiskCacheSnapshot? {
    await diskCache?.snapshot()
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
    // Ordinary shrinking evicts only the oldest entries. Losing focus must not
    // discard every already decoded thumbnail. Critical pressure still invalidates work.
    if update.limits.thumbnailCacheBytes == 0 { purgeCache() }
    cache.setByteLimit(update.limits.thumbnailCacheBytes)
  }

  private static func pixelBucket(_ value: Int) -> Int {
    let clamped = min(4_096, max(96, value))
    return ((clamped + 127) / 128) * 128
  }
}
