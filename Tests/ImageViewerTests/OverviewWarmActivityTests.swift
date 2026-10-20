import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

private final class OverviewWarmActivityRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var options: [ProcessInfo.ActivityOptions] = []
  private var ended = 0

  var beginnings: [ProcessInfo.ActivityOptions] { lock.withLock { options } }
  var endCount: Int { lock.withLock { ended } }

  func begin(_ options: ProcessInfo.ActivityOptions) -> OverviewWarmActivity {
    lock.withLock { self.options.append(options) }
    return OverviewWarmActivity { [self] in lock.withLock { ended += 1 } }
  }
}

private actor OverviewWarmNativeGate {
  private var continuation: CheckedContinuation<Void, Never>?
  var isRunning: Bool { continuation != nil }

  func runIgnoringCancellation() async {
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

@Suite("몽땅보기 선로딩의 유한한 사용자 작업 수명")
struct OverviewWarmActivityTests {
  private func machine(cpu: Double? = 0.1) -> ImageResourceSnapshot {
    ImageResourceSnapshot(physicalMemory: 16 * 1_024 * 1_024 * 1_024,
      activeProcessorCount: 8, appleSilicon: true, isAppActive: false,
      cpuBusyFraction: cpu)
  }

  private func governor(snapshot: ImageResourceSnapshot? = nil,
    mode: ImageLoadingMode = .comfortable) -> ImageResourceGovernor {
    ImageResourceGovernor(mode: mode, snapshot: snapshot ?? machine(),
      storageOverride: .internalSSD, monitorsMemoryPressure: false)
  }

  private func fixture() throws -> (directory: URL, asset: ImageAsset) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("OverviewWarmActivity-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("source.png")
    let context = try #require(CGContext(data: nil, width: 512, height: 512,
      bitsPerComponent: 8, bytesPerRow: 512 * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
    let image = try #require(context.makeImage())
    let output = try #require(CGImageDestinationCreateWithURL(source as CFURL,
      "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(output, image, nil)
    #expect(CGImageDestinationFinalize(output))
    let properties = try FileManager.default.attributesOfItem(atPath: source.path)
    return (directory, ImageAsset(url: source,
      byteCount: try #require((properties[.size] as? NSNumber)?.int64Value),
      modificationDate: properties[.modificationDate] as? Date))
  }

  private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(await condition())
  }

  @Test("준비 완료까지 활동을 유지하고 캐시 적중에서는 새 활동이나 RAM 항목을 만들지 않는다")
  func completedPreparationAndCacheHitReleaseActivity() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let recorder = OverviewWarmActivityRecorder()
    let governor = governor()
    let disk = ThumbnailDiskCache(directory: fixture.directory.appendingPathComponent("cache"))
    let pipeline = ThumbnailPipeline(governor: governor, diskCache: disk,
      beginOverviewWarmActivity: { recorder.begin($0) })
    #expect(await pipeline.warmOverviewPreviews(assets: [fixture.asset]))
    try await waitUntil { recorder.endCount == 1 }
    #expect(recorder.beginnings == [.userInitiatedAllowingIdleSystemSleep])
    #expect(!recorder.beginnings[0].contains(.idleSystemSleepDisabled))
    #expect(!recorder.beginnings[0].contains(.idleDisplaySleepDisabled))
    #expect(!recorder.beginnings[0].contains(.latencyCritical))
    #expect(await disk.contains(for: ThumbnailCacheKey(asset: fixture.asset,
      pixelSize: 256, isBrowsingPreview: true)))
    #expect(await pipeline.cacheSnapshot().entryCount == 0)
    #expect(await pipeline.warmOverviewPreviews(assets: [fixture.asset]))
    #expect(recorder.beginnings.count == 1)
    #expect(recorder.endCount == 1)
  }

  @Test("위급 상태·저전력·느림 모드의 첫 보호 정지는 활동을 시작하지 않는다")
  func initialProtectionDoesNotAcquireActivity() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var critical = machine()
    critical.memoryPressure = .critical
    var lowPower = machine()
    lowPower.lowPowerMode = true
    var hot = machine()
    hot.thermal = .serious
    let cases: [(ImageResourceSnapshot, ImageLoadingMode)] = [
      (critical, .comfortable), (lowPower, .comfortable), (hot, .comfortable), (machine(), .slow),
    ]
    for (snapshot, mode) in cases {
      let recorder = OverviewWarmActivityRecorder()
      let disk = ThumbnailDiskCache(directory: fixture.directory.appendingPathComponent("cache"))
      let pipeline = ThumbnailPipeline(governor: governor(snapshot: snapshot, mode: mode),
        diskCache: disk, beginOverviewWarmActivity: { recorder.begin($0) })
      #expect(await pipeline.warmOverviewPreviews(assets: [fixture.asset]) == false)
      #expect(recorder.beginnings.isEmpty)
      #expect(recorder.endCount == 0)
    }
  }

  @Test("속도 조절 대기 중 취소하면 활동을 끝내고 원본 작업을 시작하지 않는다")
  func cancellationDuringPacingReleasesActivity() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let recorder = OverviewWarmActivityRecorder()
    let governor = governor(snapshot: machine(cpu: nil))
    let disk = ThumbnailDiskCache(directory: fixture.directory.appendingPathComponent("cache"))
    let pipeline = ThumbnailPipeline(governor: governor, diskCache: disk,
      beginOverviewWarmActivity: { recorder.begin($0) })
    let work = Task { await pipeline.warmOverviewPreviews(assets: [fixture.asset]) }
    try await waitUntil { recorder.beginnings.count == 1 }
    #expect(recorder.endCount == 0)
    work.cancel()
    #expect(await work.value == false)
    try await waitUntil { recorder.endCount == 1 }
    #expect(await disk.snapshot().entryCount == 0)
    #expect(await governor.stateSnapshot().runningCount == 0)
  }

  @MainActor
  @Test("몽땅보기를 떠나 선로딩을 중지하면 재시도 대기까지 활동을 붙잡지 않는다")
  func stoppingPreloaderReleasesAdmittedActivity() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let recorder = OverviewWarmActivityRecorder()
    let governor = governor(snapshot: machine(cpu: nil))
    let disk = ThumbnailDiskCache(directory: fixture.directory.appendingPathComponent("cache"))
    let pipeline = ThumbnailPipeline(governor: governor, diskCache: disk,
      beginOverviewWarmActivity: { recorder.begin($0) })
    let preloader = OverviewThumbnailPreloader(quietInterval: .zero)
    defer { preloader.stop(pipeline: pipeline) }
    preloader.update(assets: [fixture.asset], visibleIndices: [0], libraryRevision: UUID(),
      maxPixelSize: 768, pipeline: pipeline, preparesVisiblePreviews: true)
    try await waitUntil { recorder.beginnings.count == 1 }
    preloader.stop(pipeline: pipeline)
    try await waitUntil { recorder.endCount == 1 }
    #expect(!preloader.isPreparing)
    #expect(recorder.beginnings.count == 1)
    #expect(await disk.snapshot().entryCount == 0)
  }

  @Test("깨진 영상의 네이티브 디코딩 오류에서도 활동은 남지 않는다")
  func failedNativePreparationReleasesActivity() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let source = fixture.directory.appendingPathComponent("broken.mp4")
    try Data("invalid video fixture".utf8).write(to: source)
    let asset = ImageAsset(url: source, byteCount: 21, modificationDate: nil)
    let recorder = OverviewWarmActivityRecorder()
    let governor = governor()
    let disk = ThumbnailDiskCache(directory: fixture.directory.appendingPathComponent("cache"))
    let pipeline = ThumbnailPipeline(governor: governor, diskCache: disk,
      beginOverviewWarmActivity: { recorder.begin($0) })
    #expect(await pipeline.warmOverviewPreviews(assets: [asset]))
    try await waitUntil { recorder.endCount == 1 }
    #expect(recorder.beginnings == [.userInitiatedAllowingIdleSystemSleep])
    #expect(await disk.snapshot().entryCount == 0)
    #expect(await governor.stateSnapshot().runningCount == 0)
  }

  @Test("대기자 취소 뒤에도 끝나지 않은 네이티브 작업이 활동과 기존 작업 슬롯을 유지한다")
  func cancelledWaiterKeepsActivityUntilNativeWorkFinishes() async throws {
    let recorder = OverviewWarmActivityRecorder()
    let gate = OverviewWarmNativeGate()
    let governor = governor()
    let work = Task {
      let activity = recorder.begin(.userInitiatedAllowingIdleSystemSleep)
      defer { withExtendedLifetime(activity) {} }
      do {
        _ = try await governor.value(for: ImageResourceWorkKey(namespace: UUID(), key: 1),
          url: URL(fileURLWithPath: "/private/blocked-overview-activity.png"),
          priority: .idleThumbnail, workload: .overviewPreview) { [activity] _ in
            defer { withExtendedLifetime(activity) {} }
            await gate.runIgnoringCancellation()
            return true
          }
      } catch is CancellationError {
      } catch { Issue.record("Unexpected error: \(error)") }
    }
    try await waitUntil { await gate.isRunning }
    work.cancel()
    await work.value
    #expect(recorder.endCount == 0)
    #expect(await governor.stateSnapshot().runningCount == 1)
    await gate.release()
    try await waitUntil { recorder.endCount == 1 }
    #expect(await governor.stateSnapshot().runningCount == 0)
    #expect(recorder.beginnings.count == 1)
  }
}
