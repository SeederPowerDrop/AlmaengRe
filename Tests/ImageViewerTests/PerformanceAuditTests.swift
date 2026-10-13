@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

/// Bounded synthetic workloads only. RSS includes process-wide framework/test
/// activity and is diagnostic data, never a portable memory-leak threshold.
/// Run this suite in isolation when comparing PERFORMANCE_AUDIT log samples.
@Suite("합성 미디어 반복 작업의 자원 수명", .serialized)
@MainActor
struct PerformanceAuditTests {
  @Test("반복 재생·정지·탐색 후 플레이어와 항목을 해제한다", .timeLimit(.minutes(2)))
  func repeatedVideoPlaybackReleasesOwners() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let started = ProcessInfo.processInfo.systemUptime
    log("playback_start", started: started, fields: ["cycles": 8, "synthetic": true])
    var probes: [PlaybackLifetimeProbe] = []
    for cycle in 0..<8 {
      probes.append(try await playSeekAndStop(fixture.videoAsset))
      try await waitUntil {
        probes.allSatisfy { $0.state == nil && $0.player == nil && $0.item == nil }
      }
      log("playback_cycle", started: started, fields: [
        "cycle": cycle + 1, "liveStates": probes.filter { $0.state != nil }.count,
        "livePlayers": probes.filter { $0.player != nil }.count,
        "liveItems": probes.filter { $0.item != nil }.count,
      ])
    }
    #expect(probes.count == 8)
    #expect(probes.allSatisfy { $0.state == nil && $0.player == nil && $0.item == nil })
  }

  @Test("프레임·썸네일 반복 디코드와 캐시 비우기가 예산과 작업 수명을 지킨다", .timeLimit(.minutes(2)))
  func repeatedDecodeAndPurgeReleasesCaches() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let governor = makeGovernor()
    let probes = try await decodeCycles(fixture, governor: governor)
    try await waitUntil { probes.pipeline == nil && probes.thumbnails == nil }
    #expect(probes.pipeline == nil && probes.thumbnails == nil)
    let drained = await governor.stateSnapshot()
    #expect(drained.runningCount == 0 && drained.queuedCount == 0 && drained.waiterCount == 0)
  }

  @Test("대기 중 프레임·썸네일 요청을 반복 취소해도 슬롯과 대기자가 남지 않는다", .timeLimit(.minutes(2)))
  func cancelledPipelineRequestsDrainSharedQueue() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let governor = makeGovernor()
    let pipeline = ImagePipeline(governor: governor)
    let thumbnails = ThumbnailPipeline(governor: governor)
    let started = ProcessInfo.processInfo.systemUptime
    for cycle in 0..<6 {
      let gate = WorkGate()
      let namespace = UUID()
      let blockers = (0..<2).map { index in
        Task {
          try await governor.value(
            for: ImageResourceWorkKey(namespace: namespace, key: index), url: fixture.still
          ) { _ in await gate.wait(); return index }
        }
      }
      var requests: [Task<Void, any Error>] = []
      // Failure cleanup also releases non-cancellable gate operations. The gate
      // has a fixed lifetime even if an expectation fails before normal release.
      let safetyRelease = Task {
        try? await Task.sleep(for: .seconds(10))
        await gate.open()
      }
      defer {
        blockers.forEach { $0.cancel() }
        requests.forEach { $0.cancel() }
        safetyRelease.cancel()
        Task { await gate.open() }
      }
      try await waitUntilAsync { await governor.stateSnapshot().runningCount == 2 }
      for index in 0..<12 {
        requests.append(Task {
          switch index % 3 {
          case 0:
            _ = try await pipeline.renderFrame(url: fixture.still, maxPixelSize: 128 * (index + 1),
              adjustments: .identity, prefersHDR: false)
          case 1:
            _ = try await thumbnails.browsingThumbnail(for: fixture.stillAsset,
              maxPixelSize: 128 * (index + 1))
          default:
            _ = try await pipeline.renderFrame(url: fixture.video, maxPixelSize: 128 * (index + 1),
              adjustments: .identity, prefersHDR: false)
          }
        })
      }
      try await waitUntilAsync { await governor.stateSnapshot().waiterCount == 14 }
      let queued = await governor.stateSnapshot()
      #expect(queued.runningCount == 2 && queued.queuedCount > 0)
      requests.forEach { $0.cancel() }
      var cancelled = 0
      for request in requests {
        do { try await request.value }
        catch is CancellationError { cancelled += 1 }
      }
      #expect(cancelled == 12)
      let remaining = await governor.stateSnapshot()
      #expect(remaining.runningCount == 2 && remaining.queuedCount == 0 && remaining.waiterCount == 2)
      await gate.open()
      for blocker in blockers { _ = try await blocker.value }
      try await waitUntilAsync {
        let value = await governor.stateSnapshot()
        return value.runningCount == 0 && value.queuedCount == 0 && value.waiterCount == 0
      }
      log("cancel_cycle", started: started, fields: [
        "cycle": cycle + 1, "cancelledRequests": cancelled, "queuedBeforeCancel": queued.queuedCount,
        "runningAfterDrain": 0, "queuedAfterDrain": 0, "waitersAfterDrain": 0,
      ])
    }
  }

  private func playSeekAndStop(_ asset: ImageAsset) async throws -> PlaybackLifetimeProbe {
    let state = VideoPlaybackState()
    state.player.isMuted = true
    let monitor = Task { await state.monitor(asset) }
    defer { monitor.cancel(); state.stop() }
    try await waitUntil { state.player.currentItem?.status == .readyToPlay }
    let item = try #require(state.player.currentItem)
    let probe = PlaybackLifetimeProbe(state: state, item: item)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    item.add(output)
    state.togglePlayback()
    var decodedFrames = 0
    try await waitUntil {
      let time = state.player.currentTime()
      if output.hasNewPixelBuffer(forItemTime: time),
        output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil { decodedFrames += 1 }
      return time.seconds >= 0.12 && decodedFrames > 0
    }
    state.pause()
    #expect(state.player.rate == 0 && !state.isPlaying)
    #expect(abs(state.player.currentTime().seconds - state.currentSeconds) < 0.005)
    for target in [0.75, 1.25, 0.25] {
      state.seek(target)
      try await waitUntil { !state.isSeeking }
      #expect(abs(state.currentSeconds - target) < 0.001)
    }
    // Exercise cancellation while another native seek callback is outstanding.
    state.seek(1.5)
    state.stop()
    monitor.cancel()
    await monitor.value
    #expect(state.player.currentItem == nil && state.document == nil && !state.isSeeking)
    item.remove(output)
    return probe
  }

  private func decodeCycles(_ fixture: Fixture, governor: ImageResourceGovernor) async throws -> PipelineLifetimeProbe {
    let pipeline = ImagePipeline(governor: governor)
    let thumbnails = ThumbnailPipeline(governor: governor)
    let probe = PipelineLifetimeProbe(pipeline: pipeline, thumbnails: thumbnails)
    let started = ProcessInfo.processInfo.systemUptime
    let queueProbe = QueueProbe()
    let sampler = Task {
      while !Task.isCancelled {
        queueProbe.record(await governor.stateSnapshot())
        do { try await Task.sleep(for: .milliseconds(5)) }
        catch { return }
      }
    }
    defer { sampler.cancel() }
    log("decode_start", started: started, fields: ["cycles": 12, "synthetic": true])
    for cycle in 0..<12 {
      try await decodeBatch(fixture, pipeline: pipeline, thumbnails: thumbnails)
      let rendered = await pipeline.cacheSnapshot()
      let thumbnail = await thumbnails.cacheSnapshot()
      #expect(rendered.entryCount > 0 && rendered.byteCount <= rendered.byteLimit)
      #expect(thumbnail.entryCount > 0 && thumbnail.byteCount <= thumbnail.byteLimit)
      await pipeline.purgeCaches()
      await thumbnails.purgeCache()
      let emptyRendered = await pipeline.cacheSnapshot()
      let emptyThumbnail = await thumbnails.cacheSnapshot()
      #expect(emptyRendered.entryCount == 0 && emptyRendered.byteCount == 0)
      #expect(emptyThumbnail.entryCount == 0 && emptyThumbnail.byteCount == 0)
      try await waitUntilAsync {
        let value = await governor.stateSnapshot()
        return value.runningCount == 0 && value.queuedCount == 0 && value.waiterCount == 0
      }
      log("decode_cycle", started: started, fields: [
        "cycle": cycle + 1, "renderEntries": rendered.entryCount, "renderBytes": rendered.byteCount,
        "renderLimitBytes": rendered.byteLimit, "thumbnailEntries": thumbnail.entryCount,
        "thumbnailBytes": thumbnail.byteCount, "thumbnailLimitBytes": thumbnail.byteLimit,
        "renderBytesAfterPurge": emptyRendered.byteCount, "thumbnailBytesAfterPurge": emptyThumbnail.byteCount,
        "sampledMaximumRunning": queueProbe.maximumRunning, "sampledMaximumQueued": queueProbe.maximumQueued,
        "runningAfterDrain": 0, "queuedAfterDrain": 0, "waitersAfterDrain": 0,
      ])
    }
    sampler.cancel()
    await sampler.value
    #expect(queueProbe.maximumRunning <= 2)
    return probe
  }

  private func decodeBatch(_ fixture: Fixture, pipeline: ImagePipeline, thumbnails: ThumbnailPipeline) async throws {
    async let still = pipeline.renderFrame(url: fixture.still, maxPixelSize: 1_024,
      adjustments: .identity, prefersHDR: false)
    async let movie = pipeline.renderFrame(url: fixture.video, maxPixelSize: 512,
      adjustments: .identity, prefersHDR: false)
    async let smallStill = thumbnails.browsingThumbnail(for: fixture.stillAsset, maxPixelSize: 512)
    async let smallMovie = thumbnails.thumbnail(for: fixture.videoAsset, maxPixelSize: 256)
    let (frame, poster, thumbnail, movieThumbnail) = try await (still, movie, smallStill, smallMovie)
    #expect(max(frame.image.width, frame.image.height) <= 1_024)
    #expect(max(poster.image.width, poster.image.height) <= 512)
    #expect(max(thumbnail.width, thumbnail.height) <= 512)
    #expect(max(movieThumbnail.width, movieThumbnail.height) <= 256)
    let cachedFrame = try await pipeline.renderFrame(url: fixture.still, maxPixelSize: 1_024,
      adjustments: .identity, prefersHDR: false)
    let cachedThumbnail = try await thumbnails.browsingThumbnail(for: fixture.stillAsset, maxPixelSize: 512)
    #expect(frame.image === cachedFrame.image)
    #expect(thumbnail === cachedThumbnail)
  }

  private func makeGovernor() -> ImageResourceGovernor {
    ImageResourceGovernor(snapshot: ImageResourceSnapshot(physicalMemory: 16 * 1_024 * 1_024 * 1_024,
      activeProcessorCount: 8, appleSilicon: true), storageOverride: .internalSSD,
      maximumConcurrentLoadsOverride: 2)
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(predicate(), "Synthetic media lifecycle did not settle before its bounded deadline")
  }

  private func waitUntilAsync(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    let settled = await predicate()
    try #require(settled, "Synthetic work queue did not settle before its bounded deadline")
  }

  private func log(_ phase: String, started: TimeInterval, fields: [String: Any]) {
    var values = fields
    values["phase"] = phase
    values["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    if status == KERN_SUCCESS { values["rssBytes"] = UInt64(info.resident_size) }
    var usage = rusage()
    if getrusage(RUSAGE_SELF, &usage) == 0 { values["processPeakRSSBytes"] = usage.ru_maxrss }
    guard let encoded = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(Data("PERFORMANCE_AUDIT ".utf8) + encoded + Data("\n".utf8))
  }

  @MainActor private final class PlaybackLifetimeProbe {
    weak var state: VideoPlaybackState?
    weak var player: AVPlayer?
    weak var item: AVPlayerItem?
    init(state: VideoPlaybackState, item: AVPlayerItem) {
      self.state = state
      player = state.player
      self.item = item
    }
  }

  @MainActor private final class PipelineLifetimeProbe {
    weak var pipeline: ImagePipeline?
    weak var thumbnails: ThumbnailPipeline?
    init(pipeline: ImagePipeline, thumbnails: ThumbnailPipeline) {
      self.pipeline = pipeline
      self.thumbnails = thumbnails
    }
  }

  @MainActor private final class QueueProbe {
    var maximumRunning = 0
    var maximumQueued = 0
    func record(_ value: ImageWorkSchedulerState) {
      maximumRunning = max(maximumRunning, value.runningCount)
      maximumQueued = max(maximumQueued, value.queuedCount)
    }
  }

  private actor WorkGate {
    var opened = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
      guard !opened else { return }
      await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
      opened = true
      waiters.forEach { $0.resume() }
      waiters.removeAll()
    }
  }

  private struct Fixture: Sendable {
    let folder: URL
    let video: URL
    let still: URL
    var videoAsset: ImageAsset { ImageAsset(url: video, byteCount: nil, modificationDate: nil) }
    var stillAsset: ImageAsset { ImageAsset(url: still, byteCount: nil, modificationDate: nil) }
    func remove() { try? FileManager.default.removeItem(at: folder) }

    static func make() async throws -> Self {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-performance-\(UUID())")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
      let fixture = Self(folder: folder, video: folder.appendingPathComponent("movie.mov"),
        still: folder.appendingPathComponent("still.png"))
      do { try fixture.writeStill(); try await fixture.writeMovie() }
      catch { fixture.remove(); throw error }
      return fixture
    }

    private func writeStill() throws {
      let context = try #require(CGContext(data: nil, width: 2_048, height: 1_536,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.7, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 2_048, height: 1_536))
      context.setFillColor(CGColor(red: 0.8, green: 0.5, blue: 0.1, alpha: 1))
      context.fillEllipse(in: CGRect(x: 300, y: 200, width: 1_100, height: 900))
      let image = try #require(context.makeImage())
      let destination = try #require(CGImageDestinationCreateWithURL(still as CFURL,
        UTType.png.identifier as CFString, 1, nil))
      CGImageDestinationAddImage(destination, image, nil)
      try #require(CGImageDestinationFinalize(destination))
    }

    private func writeMovie() async throws {
      let writer = try AVAssetWriter(outputURL: video, fileType: .mov)
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
        AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false],
      ])
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
          kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
        ])
      try #require(writer.canAdd(input))
      writer.add(input)
      try #require(writer.startWriting())
      writer.startSession(atSourceTime: .zero)
      do {
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 640, 360,
          kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixels))
        base.assumingMemoryBound(to: UInt32.self).initialize(repeating: 0xFF_40_80_C0,
          count: CVPixelBufferGetBytesPerRow(pixels) * 360 / 4)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let deadline = ContinuousClock.now + .seconds(10)
        for frame in 0..<60 {
          while !input.isReadyForMoreMediaData, writer.status == .writing, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
          }
          try #require(input.isReadyForMoreMediaData)
          try #require(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 60, timescale: 30))
        await writer.finishWriting()
        try #require(writer.status == .completed)
      } catch { writer.cancelWriting(); throw error }
    }
  }
}
