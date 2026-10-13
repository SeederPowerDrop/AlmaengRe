@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Testing

@testable import ImageViewer

@Suite("영상 첫 화면과 크기 읽기")
struct VideoMediaReaderTests {
  @Test("QuickTime qt 확장자를 스캔하고 실제 영상을 디코딩한다")
  func quickTimeAlias() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("clip.qt")
    try await writeMovie(to: url, transform: .identity)
    let scanned = try RustImageEngine.scan(folder: folder, includesVideos: true)
    #expect(scanned.count == 1 && scanned.first?.isVideo == true)
    let poster = try await VideoMediaReader.posterFrame(for: url, maxPixelSize: 48)
    #expect(poster.image.width == 48 && poster.image.height == 32)
  }

  @Test("영상 회전을 반영한 정보와 크기 제한 poster를 두 이미지 파이프라인에서 제공한다")
  func rotatedMoviePosterAndMetadata() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("portrait.mov")
    try await writeMovie(to: url, transform: CGAffineTransform(rotationAngle: .pi / 2))
    let pipeline = ImagePipeline(maxConcurrentDecodes: 1)
    let metadata = try await pipeline.metadata(for: url)
    #expect(metadata.pixelWidth == 64 && metadata.pixelHeight == 96)
    #expect(metadata.frameCount == 1 && metadata.location == nil)
    let frame = try await pipeline.renderFrame(url: url, maxPixelSize: 48,
      adjustments: .identity, prefersHDR: false)
    #expect(frame.frameCount == 1 && frame.frameIndex == 0 && frame.duration == nil)
    #expect(frame.sourcePixelSize?.width.rounded() == 64 && frame.sourcePixelSize?.height.rounded() == 96)
    #expect(frame.image.height > frame.image.width)
    let thumbnails = ThumbnailPipeline()
    let asset = ImageAsset(url: url, byteCount: nil, modificationDate: nil)
    let thumbnail = try await thumbnails.thumbnail(for: asset, maxPixelSize: 128)
    #expect(max(thumbnail.width, thumbnail.height) <= 128)
    #expect(thumbnail.height > thumbnail.width)
    let preview = try await thumbnails.browsingThumbnail(for: asset, maxPixelSize: 128)
    #expect(max(preview.width, preview.height) <= 128)
    #expect(preview.height > preview.width)
    let directlyBounded = try await VideoMediaReader.posterFrame(for: url, maxPixelSize: 48)
    #expect(max(directlyBounded.image.width, directlyBounded.image.height) <= 48)
  }

  @Test("첫 프레임이 0초보다 늦게 시작하는 영상도 poster를 만든다")
  func movieWithNoFrameAtExactZero() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("delayed-first-frame.mov")
    try await writeMovie(to: url, transform: .identity,
      firstTimestamp: CMTime(value: 1, timescale: 20))
    let exact = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    exact.requestedTimeToleranceBefore = .zero
    exact.requestedTimeToleranceAfter = .zero
    var missingExactFrame = false
    do { _ = try await exact.image(at: .zero) }
    catch {
      let error = error as NSError
      missingExactFrame = error.domain == AVFoundationErrorDomain
        && error.code == AVError.Code.noImageAtTime.rawValue
    }
    #expect(missingExactFrame, "The fixture must exercise a valid movie with no exact frame at zero")
    let poster = try await VideoMediaReader.posterFrame(for: url, maxPixelSize: 48)
    #expect(poster.image.width == 48 && poster.image.height == 32)
    #expect(poster.sourcePixelSize == CGSize(width: 96, height: 64))
  }

  @Test("영상이 사진 원본 내보내기나 이미지 보정으로 조용히 변환되지 않는다")
  func imageOnlyOperationsRejectVideo() async throws {
    let url = URL(fileURLWithPath: "/not-opened-video-\(UUID()).mp4")
    let pipeline = ImagePipeline()
    await #expect(throws: (any Error).self) {
      try await pipeline.renderFrame(url: url, maxPixelSize: nil, adjustments: .identity, prefersHDR: false)
    }
    var adjustments = ImageAdjustments.identity
    adjustments.exposure = 1
    await #expect(throws: (any Error).self) {
      try await pipeline.renderFrame(url: url, maxPixelSize: 512, adjustments: adjustments, prefersHDR: false)
    }
  }

  @Test("확장자가 지원 목록에 있어도 손상된 영상은 런타임에서 거부한다")
  func invalidMovieAndPrecancelledWork() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("broken.mp4")
    try Data("not a movie".utf8).write(to: url)
    await #expect(throws: (any Error).self) { try await VideoMediaReader.metadata(for: url) }
    await #expect(throws: (any Error).self) { try await VideoMediaReader.posterFrame(for: url, maxPixelSize: 128) }
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await #expect(throws: CancellationError.self) {
        try await VideoMediaReader.posterFrame(for: url, maxPixelSize: 128)
      }
    }
    await task.value
  }

  private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("video-reader-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
  }

  /// A tiny, synthetic local video avoids user media and external codec tools.
  private func writeMovie(to url: URL, transform: CGAffineTransform, firstTimestamp: CMTime = .zero) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: 96,
      AVVideoHeightKey: 64,
    ])
    input.transform = transform
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 96,
        kCVPixelBufferHeightKey as String: 64,
      ])
    try #require(writer.canAdd(input))
    writer.add(input)
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    try #require(CVPixelBufferCreate(kCFAllocatorDefault, 96, 64,
      kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
    for y in 0..<64 {
      for x in 0..<96 {
        let offset = y * rowBytes + x * 4
        base[offset] = 30
        base[offset + 1] = 80
        base[offset + 2] = 200
        base[offset + 3] = 255
      }
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    let deadline = ContinuousClock.now + .seconds(10)
    for frame in 0..<2 {
      while !input.isReadyForMoreMediaData, writer.status == .writing, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      try #require(input.isReadyForMoreMediaData)
      try #require(adaptor.append(pixels, withPresentationTime: CMTimeAdd(firstTimestamp, CMTime(value: Int64(frame), timescale: 10))))
    }
    writer.endSession(atSourceTime: CMTimeAdd(firstTimestamp, CMTime(value: 2, timescale: 10)))
    input.markAsFinished()
    await writer.finishWriting()
    try #require(writer.status == .completed, "\(String(describing: writer.error))")
  }
}
