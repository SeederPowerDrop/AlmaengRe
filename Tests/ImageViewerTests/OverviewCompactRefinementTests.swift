import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import Testing

@testable import ImageViewer

@Suite("몽땅보기 실제 셀의 빠른 표시와 정밀 보완", .serialized)
@MainActor
struct OverviewCompactRefinementTests {
  private enum Deadline: Error { case exceeded }

  private actor LookupSpy {
    private var counts: [URL: Int] = [:]
    private var blockedURL: URL?
    private var blockedCall = 0
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var isBlocked = false

    func block(_ url: URL, call: Int) { blockedURL = url; blockedCall = call }
    func classify(_ url: URL) async -> ImageStorageKind {
      counts[url, default: 0] += 1
      if blockedURL == url, counts[url] == blockedCall {
        isBlocked = true
        await withCheckedContinuation { pending = $0 }
        isBlocked = false
      }
      return .internalSSD
    }
    func count(for url: URL) -> Int { counts[url] ?? 0 }
    func release() { pending?.resume(); pending = nil }
  }

  private final class State: ObservableObject {
    @Published var asset: ImageAsset
    @Published var defersRefinement = true
    @Published var defersLoading = false
    @Published var width: CGFloat = 280
    @Published var pixels = 768
    @Published var adjustments = ImageAdjustments.identity
    var events: [ThumbnailBitmapStateEvent] = []
    init(asset: ImageAsset) { self.asset = asset }
  }

  private struct PreviewHost: View {
    @ObservedObject var state: State
    @ObservedObject var gate: OverviewRefinementGate
    let thumbnails: ThumbnailPipeline
    let renderer: ImagePipeline
    var reflectsGateDeferral = true
    var body: some View {
      ThumbnailImageView(asset: state.asset, thumbnailPipeline: thumbnails,
        pipeline: renderer, maxPixelSize: state.pixels, adjustments: state.adjustments,
        prefersPreciseImage: true, prefersCompactPreview: true,
        defersRefinement: state.defersRefinement || (reflectsGateDeferral && gate.isDeferring),
        overviewRefinementGate: gate,
        onBitmapStateApplied: { state.events.append($0) })
        .frame(width: state.width, height: 230)
    }
  }

  private struct OccludedCardHost: View {
    @ObservedObject var state: State
    let store: AppStore
    var body: some View {
      OverviewThumbnailCell(store: store, index: 0, asset: state.asset, size: 226.4,
        defersLoadingForOcclusion: state.defersLoading, defersRefinement: true,
        onBitmapStateApplied: { state.events.append($0) }).frame(width: 280)
    }
  }

  private var machine: ImageResourceSnapshot {
    ImageResourceSnapshot(physicalMemory: 16 * 1_024 * 1_024 * 1_024,
      activeProcessorCount: 8, appleSilicon: true, cpuBusyFraction: 0.1)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("OverviewCompactRefinementTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func fixture(in directory: URL, name: String = "photo", red: CGFloat = 0.2)
    throws -> (asset: ImageAsset, image: CGImage) {
    let context = try #require(CGContext(data: nil, width: 1_024, height: 768,
      bitsPerComponent: 8, bytesPerRow: 4_096, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: red, green: 0.35, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1_024, height: 768))
    let image = try #require(context.makeImage())
    let url = directory.appendingPathComponent("\(name).png")
    let output = try #require(CGImageDestinationCreateWithURL(url as CFURL,
      "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(output, image, nil)
    #expect(CGImageDestinationFinalize(output))
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let asset = ImageAsset(url: url,
      byteCount: try #require((attributes[.size] as? NSNumber)?.int64Value),
      modificationDate: attributes[.modificationDate] as? Date)
    return (asset, image)
  }

  private func seed(_ image: CGImage, for asset: ImageAsset, disk: ThumbnailDiskCache) async throws {
    let compact = try #require(ThumbnailBitmapDecoder.rasterized(image, maxPixelSize: 256)?.image)
    await disk.store(compact, for: ThumbnailCacheKey(asset: asset,
      pixelSize: 256, isBrowsingPreview: true))
  }

  private func window<Content: View>(hosting root: Content) -> (NSHostingView<Content>, NSWindow) {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 340, height: 300),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    host.layoutSubtreeIfNeeded()
    return (host, window)
  }

  private func wait(in host: NSView, until condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      host.layoutSubtreeIfNeeded()
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw Deadline.exceeded
  }

  private func settle(_ host: NSView, passes: Int = 3) async throws {
    for _ in 0..<passes {
      try await Task.sleep(for: .milliseconds(15))
      host.layoutSubtreeIfNeeded()
    }
  }

  @Test("실제 셀은 256px를 먼저 적용하고 이동 중 원본을 읽지 않으며 조용해지면 768px로 보완한다")
  func compactFirstThenQuietRefinementWithoutRepeatingCacheRead() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try fixture(in: directory)
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    try await seed(fixture.image, for: fixture.asset, disk: disk)
    let spy = LookupSpy()
    let governor = ImageResourceGovernor(snapshot: machine,
      storageResolver: { await spy.classify($0) }, monitorsMemoryPressure: false)
    let thumbnails = ThumbnailPipeline(governor: governor, diskCache: disk)
    let renderer = ImagePipeline(governor: governor)
    await thumbnails.setCachedPreviewDiagnosticPhase("native_cell")
    let state = State(asset: fixture.asset)
    let gate = OverviewRefinementGate()
    let (host, nativeWindow) = window(hosting: PreviewHost(state: state, gate: gate,
      thumbnails: thumbnails, renderer: renderer))
    defer {
      gate.stop()
      nativeWindow.orderOut(nil); nativeWindow.contentView = nil; nativeWindow.close()
    }
    try await wait(in: host) { !state.events.isEmpty }
    #expect(state.events.first?.pixelWidth == 256)
    #expect(state.events.first?.isRefinement == false)
    #expect(await spy.count(for: fixture.asset.url) == 1)

    gate.viewportMoved(to: .zero)
    gate.viewportMoved(to: CGPoint(x: 0, y: -1))
    state.defersRefinement = false
    for step in 1...5 {
      gate.viewportMoved(to: CGPoint(x: 0, y: -CGFloat(step * 20)))
      state.width = step.isMultiple(of: 2) ? 270 : 280
      try await settle(host, passes: 1)
      #expect(state.events.count == 1)
      #expect(await spy.count(for: fixture.asset.url) == 1)
    }
    try await wait(in: host) { state.events.contains(where: \.isRefinement) }
    #expect(state.events.last?.pixelWidth == 768)
    #expect(state.events.last?.isRefinement == true)
    let requests = await thumbnails.cachedPreviewDiagnosticsSnapshot()
    #expect(requests.count == 1, "Ending a quiet interval must not restore the compact PNG again")
  }

  @Test("느린 이전 보완 뒤 사진·편집·크기가 바뀌면 새 셀을 덮지 않는다")
  func changedEditedRequestRejectsLatePreviousRefinement() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try fixture(in: directory, name: "first")
    let second = try fixture(in: directory, name: "second", red: 0.8)
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    try await seed(first.image, for: first.asset, disk: disk)
    try await seed(second.image, for: second.asset, disk: disk)
    let spy = LookupSpy()
    await spy.block(first.asset.url, call: 2)
    defer { Task { await spy.release() } }
    let governor = ImageResourceGovernor(snapshot: machine,
      storageResolver: { await spy.classify($0) }, monitorsMemoryPressure: false)
    let thumbnails = ThumbnailPipeline(governor: governor, diskCache: disk)
    let state = State(asset: first.asset)
    let gate = OverviewRefinementGate()
    let (host, nativeWindow) = window(hosting: PreviewHost(state: state, gate: gate,
      thumbnails: thumbnails, renderer: ImagePipeline(governor: governor)))
    defer {
      gate.stop()
      nativeWindow.orderOut(nil); nativeWindow.contentView = nil; nativeWindow.close()
    }
    try await wait(in: host) { !state.events.isEmpty }
    state.defersRefinement = false
    try await wait(in: host) { await spy.isBlocked }
    state.defersRefinement = true
    state.asset = second.asset
    state.pixels = 512
    state.adjustments.brightness = 0.2
    try await wait(in: host) { state.events.contains { $0.assetURL == second.asset.url } }
    #expect(state.events.last?.pixelWidth == 256)
    #expect(await spy.count(for: second.asset.url) > 0,
      "Edited first pixels must render their adjustments instead of displaying the unedited PNG")
    await spy.release()
    try await settle(host)
    #expect(state.events.filter { $0.assetURL == first.asset.url }.count == 1)
    state.defersRefinement = false
    try await wait(in: host) {
      state.events.contains { $0.assetURL == second.asset.url && $0.isRefinement }
    }
    #expect(state.events.last?.assetURL == second.asset.url)
    #expect(state.events.last?.pixelWidth == 512)
  }

  @Test("새 셀은 상위 Bool 전달이 늦어도 현재 native motion을 확인하고 quiet 뒤 현재 사진만 정밀 보완한다")
  func freshCellsUseLiveGateBeforePublishedDeferralArrives() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try fixture(in: directory, name: "first")
    let second = try fixture(in: directory, name: "second", red: 0.75)
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    try await seed(first.image, for: first.asset, disk: disk)
    try await seed(second.image, for: second.asset, disk: disk)
    let spy = LookupSpy()
    let governor = ImageResourceGovernor(snapshot: machine,
      storageResolver: { await spy.classify($0) }, monitorsMemoryPressure: false)
    let state = State(asset: first.asset)
    state.defersRefinement = false
    let gate = OverviewRefinementGate(quietInterval: .milliseconds(100))
    gate.liveScrollBegan()
    let (host, nativeWindow) = window(hosting: PreviewHost(state: state, gate: gate,
      thumbnails: ThumbnailPipeline(governor: governor, diskCache: disk),
      renderer: ImagePipeline(governor: governor), reflectsGateDeferral: false))
    defer {
      gate.stop()
      nativeWindow.orderOut(nil); nativeWindow.contentView = nil; nativeWindow.close()
    }
    try await wait(in: host) { state.events.contains { $0.assetURL == first.asset.url } }
    try await settle(host, passes: 5)
    #expect(state.events.allSatisfy { !$0.isRefinement && $0.pixelWidth == 256 })
    #expect(await spy.count(for: first.asset.url) == 1)
    state.asset = second.asset
    try await wait(in: host) { state.events.contains { $0.assetURL == second.asset.url } }
    try await settle(host, passes: 5)
    #expect(state.events.allSatisfy { !$0.isRefinement && $0.pixelWidth == 256 })
    #expect(await spy.count(for: second.asset.url) == 1)
    gate.liveScrollEnded()
    try await wait(in: host) { state.events.contains { $0.assetURL == second.asset.url && $0.isRefinement } }
    #expect(state.events.last?.pixelWidth == 768)
    #expect(!state.events.contains { $0.assetURL == first.asset.url && $0.isRefinement })
  }

  @Test("정밀 작업이 대기하는 사이 다시 움직이면 전파가 늦어도 늦은 비트맵을 적용하지 않는다")
  func renewedMotionRejectsAlreadyAdmittedRefinement() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try fixture(in: directory)
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    try await seed(fixture.image, for: fixture.asset, disk: disk)
    let spy = LookupSpy()
    await spy.block(fixture.asset.url, call: 2)
    defer { Task { await spy.release() } }
    let governor = ImageResourceGovernor(snapshot: machine,
      storageResolver: { await spy.classify($0) }, monitorsMemoryPressure: false)
    let state = State(asset: fixture.asset)
    state.defersRefinement = false
    let gate = OverviewRefinementGate(quietInterval: .milliseconds(100), requiresVisibleMembership: true)
    gate.updateVisibleAssets([fixture.asset.url])
    let (host, nativeWindow) = window(hosting: PreviewHost(state: state, gate: gate,
      thumbnails: ThumbnailPipeline(governor: governor, diskCache: disk),
      renderer: ImagePipeline(governor: governor), reflectsGateDeferral: false))
    defer {
      gate.stop()
      nativeWindow.orderOut(nil); nativeWindow.contentView = nil; nativeWindow.close()
    }
    try await wait(in: host) { await spy.isBlocked }
    gate.liveScrollBegan()
    gate.updateVisibleAssets([])
    await spy.release()
    try await settle(host, passes: 8)
    #expect(state.events.count == 1)
    #expect(state.events.first?.pixelWidth == 256)
    gate.liveScrollEnded()
    try await wait(in: host) { !gate.isDeferring }
    try await settle(host, passes: 4)
    #expect(!state.events.contains { $0.isRefinement }, "A retained offscreen card must stay compact")
    gate.updateVisibleAssets([fixture.asset.url])
    try await wait(in: host) { state.events.contains(where: \.isRefinement) }
    #expect(state.events.last?.pixelWidth == 768)
  }

  @Test("일반 썸네일은 이미 충분한 최종 캐시를 얻었으면 같은 이미지를 다시 조회·적용하지 않는다")
  func ordinaryFinalCacheIsAppliedOnce() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try fixture(in: directory)
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    let exact = try #require(ThumbnailBitmapDecoder.rasterized(fixture.image, maxPixelSize: 768)?.image)
    await disk.store(exact, for: ThumbnailCacheKey(asset: fixture.asset, pixelSize: 768))
    let governor = ImageResourceGovernor(snapshot: machine, storageOverride: .internalSSD,
      monitorsMemoryPressure: false)
    let state = State(asset: fixture.asset)
    let (host, nativeWindow) = window(hosting: ThumbnailImageView(asset: fixture.asset,
      thumbnailPipeline: ThumbnailPipeline(governor: governor, diskCache: disk),
      pipeline: ImagePipeline(governor: governor), maxPixelSize: 768,
      onBitmapStateApplied: { state.events.append($0) }).frame(width: 280, height: 230))
    defer { nativeWindow.orderOut(nil); nativeWindow.contentView = nil; nativeWindow.close() }
    try await wait(in: host) { !state.events.isEmpty }
    try await settle(host, passes: 8)
    #expect(state.events.count == 1)
    #expect(state.events.first?.pixelWidth == 768)
    #expect(await disk.snapshot().hits == 1)
  }

  @Test("가려진 카드의 첫 디코드는 선로더에 맡기고 복귀 후 받은 비트맵은 다시 가려져도 재조회하지 않는다")
  func occludedCardDefersInitialWorkAndReusesAcceptedPixels() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try fixture(in: directory)
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    try await seed(fixture.image, for: fixture.asset, disk: disk)
    let suite = "OverviewOccludedCard.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: directory.appendingPathComponent("marks.sqlite"), thumbnailDiskCache: disk)
    await store.thumbnailPipeline.setCachedPreviewDiagnosticPhase("occluded_card")
    let state = State(asset: fixture.asset)
    state.defersLoading = true
    let (host, nativeWindow) = window(hosting: OccludedCardHost(state: state, store: store))
    defer { nativeWindow.orderOut(nil); nativeWindow.contentView = nil; nativeWindow.close() }
    try await settle(host, passes: 8)
    #expect(state.events.isEmpty)
    #expect(await store.thumbnailPipeline.cachedPreviewDiagnosticsSnapshot().isEmpty)
    #expect(await disk.snapshot().hits == 0)
    state.defersLoading = false
    try await wait(in: host) { !state.events.isEmpty }
    #expect(state.events.first?.pixelWidth == 256)
    #expect(await store.thumbnailPipeline.cachedPreviewDiagnosticsSnapshot().count == 1)
    let firstHits = await disk.snapshot().hits
    state.defersLoading = true
    try await settle(host, passes: 4)
    state.defersLoading = false
    try await settle(host, passes: 8)
    #expect(state.events.count == 1)
    #expect(await store.thumbnailPipeline.cachedPreviewDiagnosticsSnapshot().count == 1)
    #expect(await disk.snapshot().hits == firstHits)
  }

  @Test("폴더가 바뀌어도 가시 인덱스가 같으면 새 URL의 최종 정밀 보완을 재개한다")
  func folderChangeWithSameVisibleIndicesRefinesNewURLs() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstFolder = directory.appendingPathComponent("first", isDirectory: true)
    let secondFolder = directory.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
    let first = try fixture(in: firstFolder)
    let second = try fixture(in: secondFolder, red: 0.8)
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    try await seed(first.image, for: first.asset, disk: disk)
    try await seed(second.image, for: second.asset, disk: disk)
    let suite = "OverviewCompactFolderChange.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: directory.appendingPathComponent("marks.sqlite"), thumbnailDiskCache: disk)
    store.thumbnailSize = 226.4
    store.openFolderFromTree(firstFolder)
    let preloader = OverviewThumbnailPreloader()
    var events: [ThumbnailBitmapStateEvent] = []
    let (host, nativeWindow) = window(hosting: OverviewView(store: store,
      thumbnailPreloader: preloader,
      refinementGate: OverviewRefinementGate(requiresVisibleMembership: true, observesWindowVisibility: false),
      onBitmapStateApplied: { events.append($0) })
      .environment(\.displayScale, 2))
    defer {
      nativeWindow.orderOut(nil); nativeWindow.contentView = nil; nativeWindow.close()
      preloader.stop(pipeline: store.thumbnailPipeline)
    }
    try await wait(in: host) { !store.isLoading && !store.isFiltering && store.assets.count == 1 }
    store.returnToOverview()
    try await wait(in: host) { events.contains { $0.assetURL == first.asset.url && $0.isRefinement } }
    let firstVisible = preloader.visibleIndices
    try #require(firstVisible == [0])
    store.openFolderFromTree(secondFolder)
    try await wait(in: host) { !store.isLoading && !store.isFiltering && store.assets.first?.url == second.asset.url }
    store.returnToOverview()
    try await wait(in: host) { events.contains { $0.assetURL == second.asset.url && $0.isRefinement } }
    #expect(preloader.visibleIndices == firstVisible)
    #expect(events.last?.assetURL == second.asset.url)
    #expect((events.last?.pixelWidth ?? 0) >= 512)

    // Metadata-backed sorting enriches ImageAsset while retaining this exact
    // file/card. Neither it nor a matching filter should blank the accepted
    // bitmap or start another thumbnail lookup.
    let completedEvents = events.count
    await store.thumbnailPipeline.setCachedPreviewDiagnosticPhase("same_card_metadata_filter")
    store.libraryQuery.sort = .widthAscending
    try await wait(in: host) {
      !store.isFiltering && store.assets.first?.sortMetadata?.pixelWidth == 1_024
    }
    try await settle(host, passes: 8)
    store.libraryQuery.searchText = second.asset.filename
    try await wait(in: host) { !store.isFiltering && store.assets.count == 1 }
    try await settle(host, passes: 8)
    store.libraryQuery.searchText = ""
    try await wait(in: host) { !store.isFiltering && store.assets.count == 1 }
    try await settle(host, passes: 8)
    #expect(events.count == completedEvents)
    #expect(await store.thumbnailPipeline.cachedPreviewDiagnosticsSnapshot().isEmpty)
    #expect(preloader.visibleIndices == firstVisible)
    #expect(store.currentAsset?.url == second.asset.url)
  }

  @Test("번호를 다시 켜면 기존 비트맵 크기로 배치하며 썸네일을 다시 읽지 않는다")
  func enablingNumbersReusesExistingBitmapGeometry() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try fixture(in: directory)
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    try await seed(fixture.image, for: fixture.asset, disk: disk)
    let suite = "OverviewCompactNumbers.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: directory.appendingPathComponent("marks.sqlite"), thumbnailDiskCache: disk)
    store.showsOverviewNumbers = false
    var events: [ThumbnailBitmapStateEvent] = []
    let (host, nativeWindow) = window(hosting:
      OverviewThumbnailCell(store: store, index: 0, asset: fixture.asset, size: 160,
        defersRefinement: true, onBitmapStateApplied: { events.append($0) }).frame(width: 240))
    defer { nativeWindow.orderOut(nil); nativeWindow.contentView = nil; nativeWindow.close() }
    try await wait(in: host) { !events.isEmpty }
    try await settle(host)
    let withoutNumbers = host.fittingSize.height
    let hits = await disk.snapshot().hits
    store.showsOverviewNumbers = true
    try await settle(host, passes: 5)
    #expect(abs(host.fittingSize.height - withoutNumbers) <= 1,
      "The existing landscape bitmap fits the badge inside, without an extra loading row")
    #expect(events.count == 1)
    #expect(await disk.snapshot().hits == hits)
  }

  @Test("몽땅보기만 작은 PNG를 우선하고 일반 캐시 요청은 기존 정밀 크기를 유지한다")
  func compactPreferenceIsExplicitAndDoesNotAffectExactSemantics() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try fixture(in: directory)
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    try await seed(fixture.image, for: fixture.asset, disk: disk)
    let exact = try #require(ThumbnailBitmapDecoder.rasterized(fixture.image, maxPixelSize: 768)?.image)
    await disk.store(exact, for: ThumbnailCacheKey(asset: fixture.asset, pixelSize: 768))
    let governor = ImageResourceGovernor(snapshot: machine, storageOverride: .internalSSD,
      monitorsMemoryPressure: false)
    let overview = ThumbnailPipeline(governor: governor, diskCache: disk)
    #expect(await overview.cachedPreview(for: fixture.asset, maxPixelSize: 768,
      prefersCompact: true)?.width == 256)
    #expect(try await overview.thumbnail(for: fixture.asset, maxPixelSize: 768).width == 768)
    let ordinary = ThumbnailPipeline(governor: governor, diskCache: disk)
    #expect(await ordinary.cachedPreview(for: fixture.asset, maxPixelSize: 768)?.width == 768)
  }
}
