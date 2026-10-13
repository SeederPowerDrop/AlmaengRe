import Combine
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

/// Opt-in: IMAGEVIEWER_RAPID_BROWSING=1 swift test --filter ViewerRapidBrowsingIntegrationTests
/// Four synthetic 24 MP JPEGs share their bytes across 300 hard-linked paths.
/// This exercises real native decoders against a warm filesystem, not cold storage
/// or 300 distinct camera photos. Timing is diagnostic, not a real-photo speed guarantee.
@Suite("실제 디코더의 연속 빠른 탐색", .serialized)
struct ViewerRapidBrowsingIntegrationTests {
  private struct DeadlineExceeded: Error {}

  @MainActor
  private final class Observations {
    var phase = 0
    var firstVisibleAt: TimeInterval?
    var assetsByPhase: [Int: [Set<URL>]] = [:]
    var variantsByPhase: [Int: Set<Int>] = [:]
    var errors: [String] = []
    var emptyAfterFirstFrame = 0
    var hasShown: Set<Int> = []
    var sampledMaximumRunning = 0
    var sampledMaximumQueued = 0

    func record(_ presentation: ViewerFrameLoader.Presentation?, slot: Int, slotCount: Int) {
      guard let presentation else {
        if phase > 0, hasShown.contains(slot) { emptyAfterFirstFrame += 1 }
        return
      }
      hasShown.insert(slot)
      if firstVisibleAt == nil { firstVisibleAt = ProcessInfo.processInfo.systemUptime }
      guard phase > 0 else { return }
      var samples = assetsByPhase[phase] ?? Array(repeating: Set<URL>(), count: slotCount)
      samples[slot].insert(presentation.request.asset.url)
      assetsByPhase[phase] = samples
      let stem = presentation.request.asset.url.deletingPathExtension().lastPathComponent
      if let index = Int(stem.replacingOccurrences(of: "frame-", with: "")) {
        variantsByPhase[phase, default: []].insert(index % 4)
      }
    }

    func sample(_ state: ImageWorkSchedulerState) {
      sampledMaximumRunning = max(sampledMaximumRunning, state.runningCount)
      sampledMaximumQueued = max(sampledMaximumQueued, state.queuedCount)
    }
  }

  private func makeFixtures(in folder: URL) throws -> [ImageAsset] {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let colors: [(CGFloat, CGFloat, CGFloat)] = [
      (0.95, 0.75, 0.12), (0.04, 0.10, 0.20), (0.12, 0.72, 0.37), (0.78, 0.18, 0.38),
    ]
    var assets: [ImageAsset] = []
    for index in 0..<300 {
      let url = folder.appendingPathComponent(String(format: "frame-%03d.jpg", index))
      if index < 4 {
        try autoreleasepool {
          let width = index < 2 ? 6_000 : 4_000
          let height = index < 2 ? 4_000 : 6_000
          let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
          let color = colors[index]
          for row in stride(from: 0, to: height, by: 16) {
            let brightness = 0.65 + 0.35 * CGFloat(row) / CGFloat(height)
            context.setFillColor(CGColor(red: color.0 * brightness,
              green: color.1 * brightness, blue: color.2 * brightness, alpha: 1))
            context.fill(CGRect(x: 0, y: row, width: width, height: 16))
          }
          context.setFillColor(CGColor(gray: 1, alpha: 1))
          context.fill(CGRect(x: 200, y: 200, width: 300 + index * 200, height: 200))
          let image = try #require(context.makeImage())
          let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
          CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
          try #require(CGImageDestinationFinalize(destination))
        }
      } else {
        try FileManager.default.linkItem(at: assets[index % 4].url, to: url)
      }
      let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      assets.append(ImageAsset(url: url, byteCount: values.fileSize.map(Int64.init),
        modificationDate: values.contentModificationDate))
    }
    print("RAPID_BROWSING_FIXTURE pixels=24MP variants=4 paths=300 hardlinked=true warmSynthetic=true")
    return assets
  }

  @MainActor
  private func waitUntil(
    seconds: Int, governor: ImageResourceGovernor, observations: Observations,
    condition: @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !condition() {
      guard ContinuousClock.now < deadline else { throw DeadlineExceeded() }
      observations.sample(await governor.stateSnapshot())
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  @Test(
    "12ms 연속 입력과 역방향에서도 화면이 바뀌고 마지막 사진은 정밀 표시된다",
    .enabled(if: ProcessInfo.processInfo.environment["IMAGEVIEWER_RAPID_BROWSING"] == "1"),
    .timeLimit(.minutes(2)), arguments: [1, 10])
  @MainActor
  func sustainedNativeBrowsing(slotCount: Int) async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ImageViewerRapidBrowsing-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let assets = try makeFixtures(in: folder)
    let machine = ImageResourceSnapshot(
      physicalMemory: 16 * 1_024 * 1_024 * 1_024, activeProcessorCount: 8, appleSilicon: true)
    let governor = ImageResourceGovernor(
      mode: .comfortable, snapshot: machine, storageOverride: .internalSSD)
    let thumbnails = ThumbnailPipeline(governor: governor)
    let pipeline = ImagePipeline(governor: governor)
    let loaders = (0..<slotCount).map { _ in ViewerFrameLoader() }
    let observations = Observations()
    var subscriptions: Set<AnyCancellable> = []
    for (slot, loader) in loaders.enumerated() {
      loader.$presentation.sink { presentation in
        observations.record(presentation, slot: slot, slotCount: slotCount)
      }.store(in: &subscriptions)
      loader.$errorMessage.compactMap { $0 }.sink { message in
        observations.errors.append(message)
      }.store(in: &subscriptions)
    }
    defer {
      observations.phase = 0
      loaders.forEach { $0.stop() }
      subscriptions.removeAll()
    }

    let preview: ViewerFrameLoader.Preview = { request in
      let image = try await thumbnails.browsingThumbnail(for: request.asset, maxPixelSize: 512)
      return RenderedFrame(image: image, frameIndex: 0, frameCount: 1, duration: nil)
    }
    let render: ViewerFrameLoader.Render = { request, frameIndex in
      try await pipeline.renderFrame(url: request.asset.url, frameIndex: frameIndex,
        maxPixelSize: request.maxPixelSize, adjustments: request.adjustments,
        prefersHDR: request.prefersHDR)
    }
    let requestedPixels = 2_048
    let started = ProcessInfo.processInfo.systemUptime
    let sampler = Task { @MainActor in
      while !Task.isCancelled {
        observations.sample(await governor.stateSnapshot())
        do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
      }
    }
    defer { sampler.cancel() }

    for phase in 1...2 {
      observations.phase = phase
      let indices = phase == 1 ? Array(0..<150) : Array((0..<150).reversed())
      for index in indices {
        for (slot, loader) in loaders.enumerated() {
          let asset = assets[(index + slot * 17) % assets.count]
          loader.load(ViewerFrameRequest(asset: asset, maxPixelSize: requestedPixels,
            adjustments: .identity, prefersHDR: false), preview: preview, render: render)
        }
        try await Task.sleep(for: .milliseconds(12))
      }
      let counts = observations.assetsByPhase[phase]?.map(\.count) ?? []
      #expect(counts.count == slotCount)
      #expect(counts.allSatisfy { $0 >= 2 })
      #expect((observations.variantsByPhase[phase]?.count ?? 0) >= 2)
      print("RAPID_BROWSING_PROGRESS slots=\(slotCount) phase=\(phase) displayedPerSlot=\(counts)")
    }
    observations.phase = 0
    let inputStopped = ProcessInfo.processInfo.systemUptime
    // Full quality means the requested display resolution, not a 24 MP bitmap in every tile.
    try await waitUntil(seconds: 20, governor: governor, observations: observations) {
      loaders.enumerated().allSatisfy { slot, loader in
        guard let shown = loader.presentation else { return false }
        return shown.request.asset == assets[slot * 17]
          && max(shown.frame.image.width, shown.frame.image.height) == requestedPixels
          && shown.frame.sourcePixelSize != nil
      }
    }
    let refined = ProcessInfo.processInfo.systemUptime
    for (slot, loader) in loaders.enumerated() {
      let shown = try #require(loader.presentation)
      let landscape = (slot * 17) % 4 < 2
      #expect(shown.frame.sourcePixelSize == CGSize(
        width: landscape ? 6_000 : 4_000, height: landscape ? 4_000 : 6_000))
      #expect(loader.errorMessage == nil)
    }
    #expect(observations.errors.isEmpty)
    #expect(observations.emptyAfterFirstFrame == 0)

    loaders.forEach { $0.stop() }
    let drainDeadline = ContinuousClock.now.advanced(by: .seconds(10))
    var state = await governor.stateSnapshot()
    while state.runningCount != 0 || state.queuedCount != 0 || state.waiterCount != 0 {
      guard ContinuousClock.now < drainDeadline else { throw DeadlineExceeded() }
      observations.sample(state)
      try await Task.sleep(for: .milliseconds(5))
      state = await governor.stateSnapshot()
    }
    #expect(state.runningCount == 0 && state.queuedCount == 0 && state.waiterCount == 0)
    #expect(observations.sampledMaximumRunning <= 2)
    #expect(observations.sampledMaximumRunning > 0)
    // Each tile owns at most one preview and one refinement; obsolete key repeats
    // must never accumulate hundreds of queued native decode jobs.
    #expect(observations.sampledMaximumQueued <= slotCount * 2)
    print(String(format:
      "RAPID_BROWSING_TIMING slots=%d first=%.3fs input=%.3fs refinement=%.3fs sampledPeak=%d queuedPeak=%d drained=true",
      slotCount, (observations.firstVisibleAt ?? refined) - started,
      inputStopped - started, refined - inputStopped,
      observations.sampledMaximumRunning, observations.sampledMaximumQueued))
  }
}
