import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

@Suite("몽땅보기 화면 주변 미리 읽기")
struct OverviewThumbnailPreloaderTests {
  @MainActor
  @Test("폴더 전체 준비의 소유 작업은 utility 이상으로 진행하되 한 건씩 준비한다")
  func preparationOwnerMakesProgressAtUtilityPriority() async throws {
    let recorder = PreloadRecorder()
    let preloader = OverviewThumbnailPreloader(quietInterval: .zero)
    defer { preloader.stop(pipeline: recorder) }
    preloader.update(assets: assets(), visibleIndices: [0, 1], libraryRevision: UUID(),
      maxPixelSize: 768, pipeline: recorder)
    try await waitUntil { !preloader.isPreparing }
    let priorities = await recorder.warmTaskPriorities
    #expect(priorities.count == 38)
    #expect(priorities.allSatisfy { $0 >= .utility })
    #expect(await recorder.maximumRunningWarmups == 1)
  }

  @Test("지연 그리드가 생성한 화면 밖 셀은 보이는 범위에 넣지 않는다")
  func actualViewportIntersection() {
    let viewport = CGRect(x: 0, y: 0, width: 1_000, height: 600)
    #expect(OverviewThumbnailPreloadPlan.isVisible(
      CGRect(x: 20, y: -100, width: 200, height: 200), in: viewport))
    #expect(!OverviewThumbnailPreloadPlan.isVisible(
      CGRect(x: 20, y: 600, width: 200, height: 200), in: viewport))
    #expect(!OverviewThumbnailPreloadPlan.isVisible(
      CGRect(x: 20, y: -200, width: 200, height: 200), in: viewport))
    #expect(!OverviewThumbnailPreloadPlan.isVisible(.zero, in: viewport))
  }

  @Test("진행 방향 두 화면과 반대 방향 한 화면을 작은 미리보기로 먼저 준비한다")
  func forwardWindowAndDiskOrder() {
    let plan = OverviewThumbnailPreloadPlan.make(itemCount: 100,
      visibleIndices: Set(40..<50))
    #expect(plan.visibleIndices == Array(40..<50))
    #expect(plan.nearbyIndices == Array(50..<70) + Array((30..<40).reversed()))
    #expect(plan.backgroundIndices == Array(70..<100) + Array(0..<30))
    #expect(plan.direction == .forward)
    let all = plan.visibleIndices + plan.nearbyIndices + plan.backgroundIndices
    #expect(all.count == 100)
    #expect(Set(all) == Set(0..<100))
  }

  @Test("거꾸로 스크롤하면 앞쪽 두 화면을 먼저 준비한다")
  func reversingDirection() {
    let plan = OverviewThumbnailPreloadPlan.make(itemCount: 100,
      visibleIndices: Set(30..<40), previousVisibleIndices: Set(40..<50))
    #expect(plan.nearbyIndices == Array((10..<30).reversed()) + Array(40..<50))
    #expect(plan.backgroundIndices == Array((0..<10).reversed()) + Array((50..<100).reversed()))
    #expect(plan.direction == .backward)
    let stationary = OverviewThumbnailPreloadPlan.make(itemCount: 100,
      visibleIndices: Set(30..<40), previousVisibleIndices: Set(30..<40),
      previousDirection: plan.direction)
    #expect(stationary == plan)
  }

  @Test("폴더 양 끝과 필터 이후의 유효한 인덱스만 사용한다")
  func boundsAndFiltering() {
    let start = OverviewThumbnailPreloadPlan.make(itemCount: 5,
      visibleIndices: [-1, 0, 1, 99])
    #expect(start.visibleIndices == [0, 1])
    #expect(start.nearbyIndices == [2, 3, 4])
    #expect(start.backgroundIndices.isEmpty)
    let end = OverviewThumbnailPreloadPlan.make(itemCount: 5, visibleIndices: [4])
    #expect(end.nearbyIndices == [3])
    #expect(end.backgroundIndices == [0, 1, 2])
    #expect(OverviewThumbnailPreloadPlan.make(itemCount: 0,
      visibleIndices: [0]).backgroundIndices.isEmpty)
  }

  @MainActor
  @Test("조용한 구간에는 마지막 라이브러리와 크기만 준비한다")
  func coalescesLibraryAndSizeChanges() async throws {
    let recorder = PreloadRecorder()
    let preloader = OverviewThumbnailPreloader(quietInterval: .milliseconds(30))
    preloader.update(assets: assets(prefix: "old"), visibleIndices: [0, 1],
      libraryRevision: UUID(), maxPixelSize: 256, pipeline: recorder)
    preloader.update(assets: assets(prefix: "filtered"), visibleIndices: [0, 1],
      libraryRevision: UUID(), maxPixelSize: 1_024, pipeline: recorder)
    try await waitUntil { await recorder.warmCount > 0 }
    let requests = await recorder.warmAttempts
    #expect(!requests.isEmpty)
    #expect(requests.allSatisfy { $0.lastPathComponent.hasPrefix("filtered") })
    preloader.stop(pipeline: recorder)
    try await waitUntil { await recorder.protectedURLs.isEmpty }
  }

  @MainActor
  @Test("새 화면은 현재 한 건을 끝낸 뒤 채택하고 진행 중 디코딩을 취소하지 않는다")
  func adoptsPendingViewportAfterCurrentItem() async throws {
    let recorder = PreloadRecorder(blocksFirstWarmup: true)
    let preloader = OverviewThumbnailPreloader(quietInterval: .zero)
    defer {
      preloader.stop(pipeline: recorder)
      Task { await recorder.releaseFirstWarmup() }
    }
    let photos = assets()
    let revision = UUID()
    preloader.update(assets: photos, visibleIndices: [10, 11], libraryRevision: revision,
      maxPixelSize: 512, pipeline: recorder)
    try await waitUntil { await recorder.warmAttempts.count == 1 }
    preloader.update(assets: photos, visibleIndices: [20, 21], libraryRevision: revision,
      maxPixelSize: 512, pipeline: recorder)
    // Visible protection changes while the native operation still holds its
    // slot. It does not wait for the whole old offscreen plan to finish.
    try await waitUntil { await recorder.protectedURLs == [photos[20].url, photos[21].url] }
    #expect(await recorder.warmAttempts == [photos[12].url])
    await recorder.releaseFirstWarmup()
    try await waitUntil { await recorder.warmAttempts.count >= 2 }
    let requests = await recorder.warmAttempts
    #expect(requests[0] == photos[12].url)
    #expect(requests[1] == photos[22].url)
    #expect(await recorder.cancelledWarmups == 0)
    #expect(await recorder.maximumRunningWarmups == 1)
    preloader.stop(pipeline: recorder)
    try await waitUntil { await recorder.protectedURLs.isEmpty }
  }

  @MainActor
  @Test("필터·정렬 변경은 현재 한 건만 마친 뒤 새 결과에 필요한 준비만 이어간다")
  func filterChangeDropsOldPlanAfterCurrentItem() async throws {
    let recorder = PreloadRecorder(blocksFirstWarmup: true)
    let preloader = OverviewThumbnailPreloader(quietInterval: .zero)
    defer {
      preloader.stop(pipeline: recorder)
      Task { await recorder.releaseFirstWarmup() }
    }
    let photos = assets()
    preloader.update(assets: photos, visibleIndices: [0, 1], libraryRevision: UUID(),
      maxPixelSize: 768, pipeline: recorder)
    try await waitUntil { await recorder.warmAttempts.count == 1 }
    let filtered = Array(photos[20..<32].reversed())
    preloader.update(assets: filtered, visibleIndices: [0, 1], libraryRevision: UUID(),
      maxPixelSize: 768, pipeline: recorder)
    try await waitUntil {
      await recorder.protectedURLs == [filtered[0].url, filtered[1].url]
    }
    #expect(await recorder.warmAttempts == [photos[2].url])
    await recorder.releaseFirstWarmup()
    try await waitUntil { !preloader.isPreparing }
    let requests = await recorder.warmAttempts
    #expect(requests.first == photos[2].url)
    #expect(requests.dropFirst().first == filtered[2].url)
    #expect(Set(requests.dropFirst()) == Set(filtered.dropFirst(2).map(\.url)))
    #expect(requests.count == 1 + filtered.count - 2)
    #expect(await recorder.cancelledWarmups == 0)
    #expect(await recorder.maximumRunningWarmups == 1)
  }

  @MainActor
  @Test("크기 드래그 중에는 미루고 같은 크기로 끝나도 다시 시작한다")
  func resumesAfterSizeDrag() async throws {
    let recorder = PreloadRecorder()
    let preloader = OverviewThumbnailPreloader(quietInterval: .zero)
    let photos = assets()
    let revision = UUID()
    preloader.update(assets: photos, visibleIndices: [0, 1], libraryRevision: revision,
      maxPixelSize: 512, pipeline: recorder, defersLoading: true)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await recorder.warmAttempts.isEmpty)
    preloader.update(assets: photos, visibleIndices: [0, 1], libraryRevision: revision,
      maxPixelSize: 512, pipeline: recorder)
    try await waitUntil { await recorder.warmAttempts.count > 0 }
    preloader.stop(pipeline: recorder)
    try await waitUntil { await recorder.protectedURLs.isEmpty }
  }

  @MainActor
  @Test("표시 크기가 커도 화면 밖 항목은 작은 디스크 준비로 폴더 끝까지 진행한다")
  func offscreenPreparationStaysCompactAtLargeDisplaySizes() async throws {
    let recorder = PreloadRecorder()
    let preloader = OverviewThumbnailPreloader(quietInterval: .zero)
    preloader.update(assets: assets(), visibleIndices: [0, 1],
      libraryRevision: UUID(), maxPixelSize: 1_024, pipeline: recorder)
    try await waitUntil { await recorder.warmCount == 38 }
    #expect(await recorder.warmAcceptedURLs.count == 38)
    #expect(await recorder.maximumRunningWarmups == 1)
    preloader.stop(pipeline: recorder)
    try await waitUntil { await recorder.protectedURLs.isEmpty }
  }

  @MainActor
  @Test("일시 보호가 풀리면 같은 항목부터 재개하고 동시에 한 건만 준비한다")
  func resumesAfterTemporaryResourcePause() async throws {
    let recorder = PreloadRecorder(warmRejections: 3)
    let preloader = OverviewThumbnailPreloader(quietInterval: .zero, retryInterval: .milliseconds(5))
    let photos = assets()
    preloader.update(assets: photos, visibleIndices: [0, 1], libraryRevision: UUID(),
      maxPixelSize: 768, pipeline: recorder)
    try await waitUntil { !preloader.isPreparing }
    #expect(await recorder.warmCount == 38)
    #expect(await recorder.warmAttempts.prefix(4).allSatisfy { $0 == photos[2].url })
    #expect(await recorder.maximumRunningWarmups == 1)
    preloader.stop(pipeline: recorder)
  }

  @MainActor
  @Test("창이 가려져 보이는 셀이 없어져도 작은 디스크 준비는 폴더 끝까지 이어간다")
  func occlusionContinuesDiskOnlyPreparation() async throws {
    let recorder = PreloadRecorder(blocksFirstWarmup: true)
    let preloader = OverviewThumbnailPreloader(quietInterval: .zero)
    let photos = assets()
    let revision = UUID()
    defer {
      preloader.stop(pipeline: recorder)
      Task { await recorder.releaseFirstWarmup() }
    }
    preloader.update(assets: photos, visibleIndices: [0, 1], libraryRevision: revision,
      maxPixelSize: 768, pipeline: recorder)
    try await waitUntil { await recorder.warmAttempts.count == 1 }
    preloader.update(assets: photos, visibleIndices: [], libraryRevision: revision,
      maxPixelSize: 768, pipeline: recorder)
    await recorder.releaseFirstWarmup()
    try await waitUntil { !preloader.isPreparing }
    #expect(await recorder.protectedURLs.isEmpty)
    let warmURLs = await recorder.warmAcceptedURLs
    #expect(Set(warmURLs) == Set(photos.map(\.url)))
    #expect(await recorder.maximumRunningWarmups == 1)
  }

  @MainActor
  @Test("완전히 가려진 비활성 창도 현재 뷰포트부터 전체 작은 미리보기를 한 번씩 준비한다")
  func occludedViewportUsesSerialCompactPreparation() async throws {
    let recorder = PreloadRecorder()
    let preloader = OverviewThumbnailPreloader(quietInterval: .zero)
    defer { preloader.stop(pipeline: recorder) }
    let photos = assets()
    preloader.update(assets: photos, visibleIndices: [10, 11], libraryRevision: UUID(),
      maxPixelSize: 768, pipeline: recorder, preparesVisiblePreviews: true)
    try await waitUntil { !preloader.isPreparing }
    try await waitUntil { await recorder.protectedURLs == [photos[10].url, photos[11].url] }
    let requests = await recorder.warmAttempts
    #expect(Array(requests.prefix(3)) == [photos[10].url, photos[11].url, photos[12].url])
    #expect(requests.count == photos.count)
    #expect(Set(requests) == Set(photos.map(\.url)))
    #expect(await recorder.warmCount == photos.count)
    #expect(preloader.visibleIndices == [10, 11])
    #expect(await recorder.maximumRunningWarmups == 1)
  }

  @MainActor
  @Test("같은 뷰포트가 가려지면 기존 화면 밖 준비 이후 현재 뷰포트도 빠짐없이 준비한다")
  func enteringOcclusionRestartsPlanWithoutChangingViewport() async throws {
    let recorder = PreloadRecorder()
    let preloader = OverviewThumbnailPreloader(quietInterval: .zero)
    defer { preloader.stop(pipeline: recorder) }
    let photos = assets()
    let revision = UUID()
    preloader.update(assets: photos, visibleIndices: [0, 1], libraryRevision: revision,
      maxPixelSize: 768, pipeline: recorder)
    try await waitUntil { !preloader.isPreparing }
    #expect(await recorder.warmCount == photos.count - 2)
    let previousAttempts = await recorder.warmAttempts.count
    preloader.update(assets: photos, visibleIndices: [0, 1], libraryRevision: revision,
      maxPixelSize: 768, pipeline: recorder, preparesVisiblePreviews: true)
    try await waitUntil { !preloader.isPreparing }
    let allRequests = await recorder.warmAttempts
    let occludedRequests = Array(allRequests.dropFirst(previousAttempts))
    #expect(Array(occludedRequests.prefix(2)) == [photos[0].url, photos[1].url])
    #expect(occludedRequests.count == photos.count)
    #expect(Set(occludedRequests).count == photos.count)
    #expect(await recorder.warmCount == photos.count)
    #expect(preloader.visibleIndices == [0, 1])
  }

  @MainActor
  @Test("전경 복귀는 진행 중 한 건 뒤 숨겨진 뷰포트 준비를 멈추고 기존 주변 우선으로 돌아온다")
  func foregroundReturnAdoptsVisibleCellOwnershipAfterCurrentItem() async throws {
    let recorder = PreloadRecorder(blocksFirstWarmup: true)
    let preloader = OverviewThumbnailPreloader(quietInterval: .zero)
    defer {
      preloader.stop(pipeline: recorder)
      Task { await recorder.releaseFirstWarmup() }
    }
    let photos = assets()
    let revision = UUID()
    preloader.update(assets: photos, visibleIndices: [10, 11], libraryRevision: revision,
      maxPixelSize: 768, pipeline: recorder, preparesVisiblePreviews: true)
    try await waitUntil { await recorder.warmAttempts == [photos[10].url] }
    preloader.update(assets: photos, visibleIndices: [10, 11], libraryRevision: revision,
      maxPixelSize: 768, pipeline: recorder)
    #expect(await recorder.warmAttempts == [photos[10].url])
    await recorder.releaseFirstWarmup()
    try await waitUntil { !preloader.isPreparing }
    let requests = await recorder.warmAttempts
    #expect(Array(requests.prefix(2)) == [photos[10].url, photos[12].url])
    #expect(!requests.contains(photos[11].url))
    #expect(requests.count == photos.count - 1)
    #expect(Set(requests).count == requests.count)
    #expect(preloader.visibleIndices == [10, 11])
    #expect(await recorder.protectedURLs == [photos[10].url, photos[11].url])
    #expect(await recorder.cancelledWarmups == 0)
    #expect(await recorder.maximumRunningWarmups == 1)
  }

  @MainActor
  @Test("같은 폴더의 새 화면은 디스크 상태를 다시 확인하며 기존 픽셀은 다시 만들지 않는다")
  func diskMetadataIsRecheckedAcrossViewportChanges() async throws {
    let recorder = PreloadRecorder()
    let preloader = OverviewThumbnailPreloader(quietInterval: .zero)
    let photos = assets()
    let revision = UUID()
    preloader.update(assets: photos, visibleIndices: [0, 1], libraryRevision: revision,
      maxPixelSize: 768, pipeline: recorder)
    try await waitUntil { !preloader.isPreparing }
    preloader.update(assets: photos, visibleIndices: [5, 6], libraryRevision: revision,
      maxPixelSize: 768, pipeline: recorder)
    try await waitUntil { !preloader.isPreparing }
    preloader.update(assets: photos, visibleIndices: [0, 1], libraryRevision: revision,
      maxPixelSize: 768, pipeline: recorder)
    try await waitUntil { !preloader.isPreparing }
    let urls = await recorder.warmAcceptedURLs
    #expect(urls.count == photos.count)
    #expect(Set(urls).count == photos.count)
    #expect(await recorder.warmCount == photos.count)
    #expect(await recorder.warmAttempts.count > urls.count)
    preloader.stop(pipeline: recorder)
  }

  @MainActor
  @Test("작은 PNG가 준비된 폴더를 왕복해도 화면 밖 정밀 픽셀과 RAM 항목을 만들지 않는다")
  func warmFolderRevisitsDoNotCreateOffscreenPrecisionOrRAMEntries() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("OverviewCompactPreload-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = try #require(CGContext(data: nil, width: 512, height: 512,
      bitsPerComponent: 8, bytesPerRow: 512 * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
    let original = try #require(context.makeImage())
    let compact = try #require(ThumbnailBitmapDecoder.rasterized(original,
      maxPixelSize: 256)?.image)
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    var photos: [ImageAsset] = []
    for index in 0..<8 {
      let url = directory.appendingPathComponent("photo-\(index).png")
      let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
        "public.png" as CFString, 1, nil))
      CGImageDestinationAddImage(destination, original, nil)
      #expect(CGImageDestinationFinalize(destination))
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let asset = ImageAsset(url: url,
        byteCount: try #require((attributes[.size] as? NSNumber)?.int64Value),
        modificationDate: attributes[.modificationDate] as? Date)
      photos.append(asset)
      await disk.store(compact, for: ThumbnailCacheKey(asset: asset,
        pixelSize: 256, isBrowsingPreview: true))
    }
    let initialDisk = await disk.snapshot()
    let snapshot = ImageResourceSnapshot(physicalMemory: 16 * 1_024 * 1_024 * 1_024,
      activeProcessorCount: 8, appleSilicon: true, isAppActive: true,
      cpuBusyFraction: 0.1)
    let governor = ImageResourceGovernor(snapshot: snapshot, storageOverride: .internalSSD,
      monitorsMemoryPressure: false)
    let pipeline = ThumbnailPipeline(governor: governor, diskCache: disk)
    let preloader = OverviewThumbnailPreloader(quietInterval: .zero)
    defer { preloader.stop(pipeline: pipeline) }
    let revision = UUID()
    let viewports: [Set<Int>] = [[0, 1], [6, 7], [0, 1]]
    for visible in viewports {
      preloader.update(assets: photos, visibleIndices: visible, libraryRevision: revision,
        maxPixelSize: 1_536, pipeline: pipeline)
      try await waitUntil { !preloader.isPreparing }
    }
    let finalDisk = await disk.snapshot()
    #expect(finalDisk.entryCount == photos.count)
    #expect(finalDisk.byteCount == initialDisk.byteCount)
    #expect(finalDisk.exactBytes == 0)
    #expect(finalDisk.hits == 0) // Metadata coverage needs no PNG decoding either.
    #expect(await pipeline.cacheSnapshot().entryCount == 0)
    #expect(await governor.stateSnapshot().runningCount == 0)
    let coverage = await pipeline.overviewCachedAssetCounts(assets: photos, maxPixelSize: 1_536)
    #expect(coverage.preview == photos.count)
    #expect(coverage.exact == 0)
  }

  @MainActor
  @Test("같은 폴더에서 캐시를 비운 뒤 새 화면을 보면 작은 미리보기를 다시 준비한다")
  func cacheClearWithinSameLibraryRegeneratesOnNextViewport() async throws {
    let recorder = PreloadRecorder()
    let preloader = OverviewThumbnailPreloader(quietInterval: .zero)
    let photos = assets()
    let revision = UUID()
    preloader.update(assets: photos, visibleIndices: [0, 1], libraryRevision: revision,
      maxPixelSize: 768, pipeline: recorder)
    try await waitUntil { !preloader.isPreparing }
    #expect(await recorder.warmCount == 38)
    await recorder.clearDiskCache()
    preloader.update(assets: photos, visibleIndices: [5, 6], libraryRevision: revision,
      maxPixelSize: 768, pipeline: recorder)
    try await waitUntil { !preloader.isPreparing }
    #expect(await recorder.warmCount == 76)
    #expect(await recorder.warmAcceptedURLs.filter { $0 == photos[7].url }.count == 2)
    preloader.stop(pipeline: recorder)
  }

  @MainActor
  @Test("크기가 0인 파일 때문에 배경 디코딩을 시작하지 않는다")
  func emptyFilesAreSkippedWithoutDecoding() async throws {
    let recorder = PreloadRecorder()
    let preloader = OverviewThumbnailPreloader(quietInterval: .zero)
    let empty = (0..<5).map { ImageAsset(url: URL(fileURLWithPath: "/empty/\($0).dng"),
      byteCount: 0, modificationDate: nil) }
    preloader.update(assets: empty, visibleIndices: [0], libraryRevision: UUID(),
      maxPixelSize: 768, pipeline: recorder)
    try await waitUntil { !preloader.isPreparing }
    #expect(await recorder.warmAttempts.isEmpty)
    preloader.stop(pipeline: recorder)
  }

  @MainActor
  @Test("몽땅보기를 떠나면 남은 준비와 화면 보호를 해제한다")
  func stopsBackgroundWorkAndProtection() async throws {
    let recorder = PreloadRecorder(warmDelay: .seconds(2))
    let preloader = OverviewThumbnailPreloader(quietInterval: .zero)
    preloader.update(assets: assets(), visibleIndices: [0, 1],
      libraryRevision: UUID(), maxPixelSize: 512, pipeline: recorder)
    try await waitUntil { await recorder.warmCount == 1 }
    preloader.stop(pipeline: recorder)
    try await waitUntil {
      let isUnprotected = await recorder.protectedURLs.isEmpty
      let cancelled = await recorder.cancelledWarmups
      return isUnprotected && cancelled == 1
    }
    #expect(await recorder.warmCount == 1)
  }

  private func assets(prefix: String = "photo") -> [ImageAsset] {
    (0..<40).map { ImageAsset(url: URL(fileURLWithPath: "/test/\(prefix)-\($0).dng"),
      byteCount: 50_000_000, modificationDate: Date(timeIntervalSinceReferenceDate: 0)) }
  }

  @MainActor
  private func waitUntil(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(await condition())
  }
}

private actor PreloadRecorder: OverviewThumbnailPreloading {
  var protectedURLs: [URL] = []
  var warmTaskPriorities: [TaskPriority] = []
  // Count source-admitting misses, rather than repeated cache metadata probes.
  var warmCount = 0
  var warmAttempts: [URL] = []
  var warmAcceptedURLs: [URL] = []
  var maximumRunningWarmups = 0
  private var runningWarmups = 0
  private var remainingWarmRejections: Int
  private var diskCachedURLs: Set<URL> = []
  var cancelledWarmups = 0
  private let warmDelay: Duration
  private let blocksFirstWarmup: Bool
  private var firstWarmupRelease: CheckedContinuation<Void, Never>?
  private var firstWarmupWasReleased = false

  init(warmDelay: Duration = .zero, blocksFirstWarmup: Bool = false, warmRejections: Int = 0) {
    self.warmDelay = warmDelay
    self.blocksFirstWarmup = blocksFirstWarmup
    remainingWarmRejections = max(0, warmRejections)
  }

  func releaseFirstWarmup() {
    firstWarmupWasReleased = true
    firstWarmupRelease?.resume()
    firstWarmupRelease = nil
  }

  func clearDiskCache() { diskCachedURLs.removeAll() }

  func updateOverviewVisibleAssets(_ assets: [ImageAsset]) {
    protectedURLs = assets.map(\.url)
  }

  func warmOverviewPreviews(assets: [ImageAsset]) async -> Bool {
    warmTaskPriorities.append(Task.currentPriority)
    let isFirstWarmup = warmAttempts.isEmpty
    warmAttempts += assets.map(\.url)
    if remainingWarmRejections > 0 {
      remainingWarmRejections -= 1
      return false
    }
    let uncached = assets.map(\.url).filter { !diskCachedURLs.contains($0) }
    if uncached.isEmpty { return true }
    warmCount += uncached.count
    warmAcceptedURLs += uncached
    runningWarmups += 1
    maximumRunningWarmups = max(maximumRunningWarmups, runningWarmups)
    defer { runningWarmups -= 1 }
    do {
      if blocksFirstWarmup && isFirstWarmup && !firstWarmupWasReleased {
        // A synchronous source decode finishes before adopting a new viewport.
        await withCheckedContinuation { firstWarmupRelease = $0 }
      }
      try Task.checkCancellation()
      try await Task.sleep(for: warmDelay)
      diskCachedURLs.formUnion(uncached)
      return true
    } catch {
      cancelledWarmups += 1
      return false
    }
  }
}
