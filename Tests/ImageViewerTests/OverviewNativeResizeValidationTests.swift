import AppKit
import ImageIO
import SwiftUI
import Testing

@testable import ImageViewer

@Suite("몽땅보기 최종 비트맵 크기 승계와 resize 측정", .serialized)
@MainActor
struct OverviewNativeResizeValidationTests {
  @Test("충분한 최종 픽셀은 작은 크기와 이전 크기로 돌아올 때 승계한다")
  func adequateFinalBitmapCanFollowDisplaySizeChanges() {
    let asset = ImageAsset(url: URL(fileURLWithPath: "/tmp/resize-final.png"),
      byteCount: 1_024, modificationDate: Date(timeIntervalSinceReferenceDate: 1))
    let previous = request(asset, pixels: 1_024)
    for pixels in [128, 512, 768, 1_024] {
      #expect(ThumbnailFinalBitmapReuse.canAdopt(previous: previous,
        current: request(asset, pixels: pixels), pixelWidth: 1_024, pixelHeight: 768,
        previousIsFinal: true))
    }
    #expect(!ThumbnailFinalBitmapReuse.canAdopt(previous: previous,
      current: request(asset, pixels: 1_152), pixelWidth: 1_024, pixelHeight: 768, previousIsFinal: true))
    #expect(!ThumbnailFinalBitmapReuse.canAdopt(previous: previous,
      current: request(asset, pixels: 512), pixelWidth: 1_024, pixelHeight: 768, previousIsFinal: false))
  }

  @Test("SDR·빠른 미리보기는 새 정밀·HDR·편집·원본 버전 요청으로 승계되지 않는다")
  func adoptionNeverPromotesPreviewIntoNewQualityRequirements() {
    let asset = ImageAsset(url: URL(fileURLWithPath: "/tmp/resize-quality.png"),
      byteCount: 1_024, modificationDate: Date(timeIntervalSinceReferenceDate: 1))
    let fast = ThumbnailRequest(asset: asset, maxPixelSize: 1_024,
      adjustments: .identity, prefersHDR: false, prefersPreciseImage: false)
    #expect(!ThumbnailFinalBitmapReuse.canAdopt(previous: fast,
      current: request(asset, pixels: 512), pixelWidth: 1_024, pixelHeight: 768, previousIsFinal: true))
    var adjustments = ImageAdjustments.identity
    adjustments.brightness = 0.25
    let changed = [
      ThumbnailRequest(asset: asset, maxPixelSize: 512, adjustments: .identity,
        prefersHDR: true, prefersPreciseImage: true),
      ThumbnailRequest(asset: asset, maxPixelSize: 512, adjustments: adjustments,
        prefersHDR: false, prefersPreciseImage: true),
      request(ImageAsset(url: asset.url, byteCount: 2_048, modificationDate: asset.modificationDate), pixels: 512),
    ]
    for current in changed {
      #expect(!ThumbnailFinalBitmapReuse.canAdopt(previous: request(asset, pixels: 1_024),
        current: current, pixelWidth: 1_024, pixelHeight: 768, previousIsFinal: true))
    }
  }

  @Test("실제 셀은 큰 최종 비트맵을 줄였다가 되돌려도 compact 재조회·추가 렌더 없이 유지한다")
  func hostedFinalBitmapSurvivesShrinkAndReturnWithoutNewApplications() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("OverviewResizeReuse.\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = try #require(CGContext(data: nil, width: 1_024, height: 768,
      bitsPerComponent: 8, bytesPerRow: 4_096, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1_024, height: 768))
    let image = try #require(context.makeImage())
    let url = directory.appendingPathComponent("synthetic.png")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let asset = ImageAsset(url: url, byteCount: (attributes[.size] as? NSNumber)?.int64Value,
      modificationDate: attributes[.modificationDate] as? Date)
    let disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    let compact = try #require(ThumbnailBitmapDecoder.rasterized(image, maxPixelSize: 256)?.image)
    await disk.store(compact, for: ThumbnailCacheKey(asset: asset, pixelSize: 256, isBrowsingPreview: true))
    let snapshot = ImageResourceSnapshot(physicalMemory: 16 * 1_024 * 1_024 * 1_024,
      activeProcessorCount: 8, appleSilicon: true, cpuBusyFraction: 0.1)
    let governor = ImageResourceGovernor(snapshot: snapshot, storageOverride: .internalSSD, monitorsMemoryPressure: false)
    let thumbnails = ThumbnailPipeline(governor: governor, diskCache: disk)
    let state = ResizeState()
    _ = NSApplication.shared
    let host = NSHostingView(rootView: Harness(state: state, asset: asset,
      thumbnails: thumbnails, renderer: ImagePipeline(governor: governor)))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 340, height: 300),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    let deadline = ContinuousClock.now + .seconds(8)
    while !state.events.contains(where: { $0.isRefinement && $0.pixelWidth >= 768 }) {
      try #require(ContinuousClock.now < deadline)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
    let applications = state.events.count
    await thumbnails.setCachedPreviewDiagnosticPhase("resize_adoption")
    for size in [512, 640, 768] {
      state.pixels = size
      for _ in 0..<6 {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(state.events.count == applications)
    }
    #expect(await thumbnails.cachedPreviewDiagnosticsSnapshot().filter { $0.phase == "resize_adoption" }.isEmpty)
    let work = await governor.stateSnapshot()
    #expect(work.runningCount == 0 && work.queuedCount == 0)
  }

  @Test("resize 보고서는 tracking 실패를 성공으로 표시하지 않고 수치만 왕복 직렬화한다")
  func resizeReportRoundTripPreservesTruthfulScope() throws {
    var report = OverviewNativeResizeReport()
    report.status = "failed"; report.failurePhase = "native_slider_tracking_did_not_change_binding"
    var step = OverviewNativeResizeStep(); step.requestedSize = 480; step.nativeTrackingSucceeded = false
    report.steps = [step]
    let decoded = try JSONDecoder().decode(OverviewNativeResizeReport.self, from: JSONEncoder().encode(report))
    #expect(decoded.status == "failed")
    #expect(!decoded.fullNativeTrackingSucceeded)
    #expect(!decoded.steps[0].nativeTrackingSucceeded)
    #expect(decoded.bitmapScope.contains("no_direct_inspection"))
  }

  private func request(_ asset: ImageAsset, pixels: Int) -> ThumbnailRequest {
    ThumbnailRequest(asset: asset, maxPixelSize: pixels, adjustments: .identity,
      prefersHDR: false, prefersPreciseImage: true)
  }
  private final class ResizeState: ObservableObject {
    @Published var pixels = 768
    var events: [ThumbnailBitmapStateEvent] = []
  }
  private struct Harness: View {
    @ObservedObject var state: ResizeState
    let asset: ImageAsset
    let thumbnails: ThumbnailPipeline
    let renderer: ImagePipeline
    var body: some View {
      ThumbnailImageView(asset: asset, thumbnailPipeline: thumbnails, pipeline: renderer,
        maxPixelSize: state.pixels, prefersPreciseImage: true, prefersCompactPreview: true,
        onBitmapStateApplied: { state.events.append($0) }).frame(width: 300, height: 230)
    }
  }
}
