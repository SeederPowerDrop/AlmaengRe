@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

@Suite("영상 프레임·구간 저장", .serialized)
struct VideoExporterTests {
  @Test("합성 영상의 재생 정보와 요청한 시각의 PNG 프레임을 읽는다")
  func metadataAndExactFrame() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try await fixture.makeVideo()
    let original = try Data(contentsOf: fixture.video)
    let document = try await VideoDocument.load(url: fixture.video)
    #expect(document.isPlayable && document.isExportable)
    #expect(!document.hasAudio && !document.hasProtectedContent)
    #expect(document.pixelWidth == 160 && document.pixelHeight == 96)
    #expect(abs(document.durationSeconds - 2) < 0.01)
    #expect(abs(document.nominalFrameRate - 12) < 0.01)
    let destination = fixture.root.appendingPathComponent("frame.png")
    let result = try await VideoExporter().extractFrame(from: fixture.video,
      at: CMTime(value: 15, timescale: 12), to: destination)
    #expect(abs(result.requestedTimeSeconds - 1.25) < 0.000_001)
    #expect(abs(result.actualTimeSeconds - 1.25) < 0.000_001)
    #expect(result.pixelWidth == 160 && result.pixelHeight == 96)
    let imageSource = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
    #expect(image.width == 160 && image.height == 96)
    let pixel = try centerPixel(image)
    // The second second of the fixture is green; its first second is red.
    #expect(pixel.green > 150 && pixel.red < 100)
    #expect(try Data(contentsOf: fixture.video) == original)
    #expect(try fixture.stagingDirectories().isEmpty)
  }

  @Test("MP4·MOV에 선택 구간만 저장하고 작은 영상을 확대하지 않는다", arguments: VideoContainer.allCases)
  func trimmedContainers(container: VideoContainer) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try await fixture.makeVideo()
    let original = try Data(contentsOf: fixture.video)
    let destination = fixture.root.appendingPathComponent("trimmed." + container.fileExtension)
    let result = try await VideoExporter().export(from: fixture.video,
      range: VideoTimeRange(start: 0.5, end: 1.25), to: destination,
      options: VideoExportOptions(container: container, preset: .hd1080))
    #expect(abs(result.durationSeconds - 0.75) <= 1.0 / 12 + 0.005)
    #expect(result.pixelWidth == 160 && result.pixelHeight == 96)
    #expect(result.byteCount > 0)
    let output = try await VideoDocument.load(url: destination)
    #expect(output.isPlayable)
    #expect(abs(output.durationSeconds - result.durationSeconds) < 0.001)
    #expect(try Data(contentsOf: fixture.video) == original)
    #expect(try fixture.stagingDirectories().isEmpty)
  }

  @Test("해상도 프리셋은 큰 원본을 비율을 유지해 줄인다")
  func resolutionPresetReducesDimensions() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try await fixture.makeVideo(width: 960, height: 540)
    let destination = fixture.root.appendingPathComponent("smaller.mp4")
    let result = try await VideoExporter().export(from: fixture.video,
      range: VideoTimeRange(start: 0, end: 2), to: destination,
      options: VideoExportOptions(container: .mp4, preset: .sd480))
    #expect(result.pixelWidth <= 640 && result.pixelHeight <= 480)
    #expect(result.pixelWidth < 960 && result.pixelHeight < 540)
    #expect(abs(Double(result.pixelWidth) / Double(result.pixelHeight) - 16.0 / 9) < 0.02)
    #expect(abs(result.durationSeconds - 2) <= 1.0 / 12 + 0.005)
    #expect(try fixture.stagingDirectories().isEmpty)
  }

  @Test("원본·하드링크·기존 결과를 덮어쓰지 않고 잘못된 범위도 출력 없이 거절한다")
  func protectsSourcesAndExistingFiles() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try await fixture.makeVideo()
    let original = try Data(contentsOf: fixture.video)
    let exporter = VideoExporter()
    let range = VideoTimeRange(start: 0, end: 1)
    await #expect(throws: VideoProcessingError.sourceOverwrite) {
      try await exporter.export(from: fixture.video, range: range, to: fixture.video,
        options: VideoExportOptions(container: .mov))
    }
    let linked = fixture.root.appendingPathComponent("linked.mp4")
    try FileManager.default.linkItem(at: fixture.video, to: linked)
    await #expect(throws: VideoProcessingError.sourceOverwrite) {
      try await exporter.export(from: fixture.video, range: range, to: linked)
    }
    let existing = fixture.root.appendingPathComponent("existing.mp4")
    let sentinel = Data("existing output must be preserved".utf8)
    try sentinel.write(to: existing)
    await #expect(throws: VideoProcessingError.destinationExists) {
      try await exporter.export(from: fixture.video, range: range, to: existing)
    }
    let frame = fixture.root.appendingPathComponent("existing.png")
    try sentinel.write(to: frame)
    await #expect(throws: VideoProcessingError.destinationExists) {
      try await exporter.extractFrame(from: fixture.video, at: 0.5, to: frame)
    }
    let rejected = fixture.root.appendingPathComponent("rejected.mp4")
    for invalid in [VideoTimeRange(start: -1, end: 1), VideoTimeRange(start: 1, end: 1),
      VideoTimeRange(start: 0, end: 3), VideoTimeRange(start: .nan, end: 1)] {
      await #expect(throws: VideoProcessingError.invalidRange) {
        try await exporter.export(from: fixture.video, range: invalid, to: rejected)
      }
    }
    let endFrame = fixture.root.appendingPathComponent("past-end.png")
    await #expect(throws: VideoProcessingError.invalidFrameTime) {
      try await exporter.extractFrame(from: fixture.video, at: 2.0, to: endFrame)
    }
    #expect(!FileManager.default.fileExists(atPath: rejected.path))
    #expect(!FileManager.default.fileExists(atPath: endFrame.path))
    #expect(try Data(contentsOf: existing) == sentinel)
    #expect(try Data(contentsOf: frame) == sentinel)
    #expect(try Data(contentsOf: fixture.video) == original)
    #expect(try fixture.stagingDirectories().isEmpty)
  }

  @Test("내보내기 준비 후 새 동명 파일이 생겨도 보존하고 임시 파일을 정리한다")
  func destinationRacePreservesConcurrentFile() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try await fixture.makeVideo()
    let destination = fixture.root.appendingPathComponent("raced.mp4")
    let sentinel = Data("created while export was starting".utf8)
    await #expect(throws: VideoProcessingError.destinationExists) {
      try await VideoExporter().export(from: fixture.video,
        range: VideoTimeRange(start: 0, end: 1), to: destination) { value in
        if value == 0 { try? sentinel.write(to: destination, options: .withoutOverwriting) }
      }
    }
    #expect(try Data(contentsOf: destination) == sentinel)
    #expect(try fixture.stagingDirectories().isEmpty)
  }

  @Test("시작 직전 취소는 출력과 준비된 임시 폴더를 지우고 원본을 보존한다")
  func cancellationCleansStagingAndPreservesSource() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try await fixture.makeVideo()
    let original = try Data(contentsOf: fixture.video)
    let destination = fixture.root.appendingPathComponent("cancelled.mp4")
    let ready = AsyncStream<Void>.makeStream()
    let gate = DispatchSemaphore(value: 0)
    let task = Task {
      defer { ready.continuation.finish() }
      return try await VideoExporter().export(from: fixture.video,
        range: VideoTimeRange(start: 0, end: 2), to: destination) { value in
        if value == 0 {
          ready.continuation.yield(())
          ready.continuation.finish()
          // A bounded test gate puts cancellation exactly after staging exists
          // and before the session starts, covering the start/cancel race.
          _ = gate.wait(timeout: .now() + 5)
        }
      }
    }
    var iterator = ready.stream.makeAsyncIterator()
    _ = await iterator.next()
    #expect(try !fixture.stagingDirectories().isEmpty)
    task.cancel()
    gate.signal()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try fixture.stagingDirectories().isEmpty)
    #expect(try Data(contentsOf: fixture.video) == original)
  }

  private func centerPixel(_ image: CGImage) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
    var pixels = [UInt8](repeating: 0, count: 4)
    let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
        bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
      return true
    }
    try #require(rendered)
    return (pixels[0], pixels[1], pixels[2])
  }

  private struct Fixture: Sendable {
    let root: URL
    let video: URL

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("VideoExporterTests-\(UUID())")
      video = root.appendingPathComponent("synthetic.mov")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func stagingDirectories() throws -> [String] {
      try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".almaeng-video-") }
    }

    func makeVideo(width: Int = 160, height: Int = 96) async throws {
      let writer = try AVAssetWriter(outputURL: video, fileType: .mov)
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: 2_000_000,
          AVVideoMaxKeyFrameIntervalKey: 12,
          AVVideoAllowFrameReorderingKey: false,
        ],
      ])
      input.expectsMediaDataInRealTime = false
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
          kCVPixelBufferWidthKey as String: width,
          kCVPixelBufferHeightKey as String: height,
          kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
      try #require(writer.canAdd(input))
      writer.add(input)
      try #require(writer.startWriting())
      writer.startSession(atSourceTime: .zero)
      do {
        let pool = try #require(adaptor.pixelBufferPool)
        for frame in 0..<24 {
          var attempts = 0
          while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            attempts += 1
            try #require(attempts < 2_000 && writer.status == .writing)
            try await Task.sleep(for: .milliseconds(5))
          }
          var pixelBuffer: CVPixelBuffer?
          try #require(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess)
          let buffer = try #require(pixelBuffer)
          CVPixelBufferLockBaseAddress(buffer, [])
          let base = try #require(CVPixelBufferGetBaseAddress(buffer))
          let color: UInt32 = frame < 12 ? 0xFF_E8_18_10 : 0xFF_18_E8_10
          base.assumingMemoryBound(to: UInt32.self).initialize(repeating: color,
            count: CVPixelBufferGetBytesPerRow(buffer) * height / 4)
          CVPixelBufferUnlockBaseAddress(buffer, [])
          try #require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 24, timescale: 12))
        await writer.finishWriting()
        try #require(writer.status == .completed)
      } catch {
        writer.cancelWriting()
        throw error
      }
    }
  }
}
