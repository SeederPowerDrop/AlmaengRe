import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

@Suite("편집 미리보기 히스토그램")
struct ImageHistogramTests {
  @Test("원색과 검정·흰색을 RGB 256구간 및 가중 휘도로 집계한다")
  func primaryColors() async throws {
    let frame = try frame(pixels: [
      [0, 0, 0, 255], [255, 255, 255, 255], [255, 0, 0, 255],
      [0, 255, 0, 255], [0, 0, 255, 255],
    ])
    let histogram = try await ImageHistogramAnalyzer().analyze(frame)
    #expect(histogram.red.count == 256)
    #expect(histogram.green.count == 256)
    #expect(histogram.blue.count == 256)
    #expect(histogram.luminance.count == 256)
    #expect(histogram.sampleWeight == 5)
    #expect(histogram.red[0] == 3 && histogram.red[255] == 2)
    #expect(histogram.green[0] == 3 && histogram.green[255] == 2)
    #expect(histogram.blue[0] == 3 && histogram.blue[255] == 2)
    #expect(histogram.luminance[0] == 1)
    #expect(histogram.luminance[255] == 1)
    #expect(histogram.luminance[54] == 1)
    #expect(histogram.luminance[182] == 1)
    #expect(histogram.luminance[18] == 1)
    #expect(histogram.blackPercentage == 20)
    #expect(histogram.whitePercentage == 20)
    #expect(histogram.luminance.reduce(0, +) == histogram.sampleWeight)
  }

  @Test("반투명 RGB를 복원해 알파 가중하고 숨겨진 투명 색은 제외한다")
  func transparency() async throws {
    let frame = try frame(pixels: [
      [255, 255, 255, 128], [255, 0, 0, 255], [0, 0, 255, 0],
    ])
    let histogram = try await ImageHistogramAnalyzer().analyze(frame)
    let alpha = 128.0 / 255
    #expect(abs(histogram.sampleWeight - (1 + alpha)) < 0.00001)
    #expect(histogram.red[255] == 1 + alpha)
    #expect(histogram.green[255] == alpha)
    #expect(histogram.green[0] == 1)
    #expect(histogram.blue[255] == alpha)
    #expect(histogram.whiteWeight == alpha)
    #expect(histogram.blackWeight == 0)
    #expect(histogram.luminance[255] == alpha)
    #expect(histogram.red[128] == 0)
    #expect(histogram.luminance.reduce(0, +) == histogram.sampleWeight)
  }

  @Test("완전 투명 이미지는 빈 히스토그램이며 비율은 유한한 0이다")
  func transparentImage() async throws {
    let histogram = try await ImageHistogramAnalyzer().analyze(
      frame(pixels: [[255, 0, 255, 0], [0, 0, 0, 0]]))
    #expect(histogram.isEmpty)
    #expect(histogram.blackPercentage == 0)
    #expect(histogram.whitePercentage == 0)
    #expect(histogram.red.allSatisfy { $0 == 0 })
  }

  @Test("큰 입력 프레임도 512픽셀 이내 작업 공간에서 분석한다")
  func boundedAnalysis() async throws {
    let context = try #require(CGContext(data: nil, width: 2048, height: 1024,
      bitsPerComponent: 8, bytesPerRow: 2048 * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1024))
    let frame = RenderedFrame(image: try #require(context.makeImage()),
      frameIndex: 0, frameCount: 1, duration: nil)
    let histogram = try await ImageHistogramAnalyzer().analyze(frame)
    #expect(histogram.sampleWeight == 512 * 256)
    #expect(histogram.blackPercentage == 100)
    #expect(histogram.red[0] == histogram.sampleWeight)
  }

  @Test("분석 시작 전에 취소한 요청은 결과를 반환하지 않는다")
  func cancelledAnalysis() async throws {
    let frame = try frame(pixels: [[255, 255, 255, 255]])
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await ImageHistogramAnalyzer().analyze(frame)
    }
    do {
      _ = try await task.value
      Issue.record("취소된 분석은 완료되면 안 됩니다.")
    } catch is CancellationError {
      // Expected: cancellation is checked before allocating the scratch pixel buffer.
    }
  }

  @Test("파일·수정 시각·보정 변경 및 이전 세대 결과가 새 요청과 섞이지 않는다")
  func requestIdentityAndGeneration() {
    let url = URL(fileURLWithPath: "/tmp/histogram-source.png")
    let original = ImageHistogramRequest(
      asset: ImageAsset(url: url, byteCount: 10, modificationDate: Date(timeIntervalSince1970: 1)),
      adjustments: .identity)
    var brighter = ImageAdjustments.identity
    brighter.brightness = 0.4
    let changed = ImageHistogramRequest(asset: original.asset, adjustments: brighter)
    let replaced = ImageHistogramRequest(
      asset: ImageAsset(url: url, byteCount: 10, modificationDate: Date(timeIntervalSince1970: 2)),
      adjustments: .identity)
    #expect(original != changed)
    #expect(original != replaced)
    var gate = LatestRequestGate<ImageHistogramRequest>()
    let oldGeneration = gate.begin(original)
    let newGeneration = gate.begin(changed)
    #expect(!gate.accepts(oldGeneration, for: original))
    #expect(gate.accepts(newGeneration, for: changed))
    let returnedGeneration = gate.begin(original)
    #expect(!gate.accepts(oldGeneration, for: original))
    #expect(gate.accepts(returnedGeneration, for: original))
    gate.invalidate()
    #expect(!gate.accepts(returnedGeneration, for: original))
  }

  @Test("실제 파이프라인은 파일의 현재 보정값을 반영한 SDR 히스토그램을 만든다")
  func editedPreviewHistogram() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("histogram-\(UUID()).png")
    defer { try? FileManager.default.removeItem(at: url) }
    let original = try frame(pixels: [[64, 64, 64, 255]])
    let destination = try #require(CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, original.image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let asset = ImageAsset(url: url, byteCount: nil, modificationDate: nil)
    let pipeline = ImagePipeline(maxConcurrentDecodes: 1)
    let analyzer = ImageHistogramAnalyzer()
    let unedited = try await analyzer.histogram(
      for: ImageHistogramRequest(asset: asset, adjustments: .identity), pipeline: pipeline)
    var adjustments = ImageAdjustments.identity
    adjustments.exposure = 2
    let edited = try await analyzer.histogram(
      for: ImageHistogramRequest(asset: asset, adjustments: adjustments), pipeline: pipeline)
    let uneditedMean = zip(unedited.luminance.indices, unedited.luminance)
      .reduce(0.0) { $0 + Double($1.0) * $1.1 } / unedited.sampleWeight
    let editedMean = zip(edited.luminance.indices, edited.luminance)
      .reduce(0.0) { $0 + Double($1.0) * $1.1 } / edited.sampleWeight
    #expect(editedMean > uneditedMean + 30)
    #expect(edited.sampleWeight == unedited.sampleWeight)
  }

  private func frame(pixels: [[UInt8]]) throws -> RenderedFrame {
    let data = Data(pixels.flatMap { $0 })
    let provider = try #require(CGDataProvider(data: data as CFData))
    let image = try #require(CGImage(width: pixels.count, height: 1,
      bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels.count * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue
        | CGImageAlphaInfo.last.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    return RenderedFrame(image: image, frameIndex: 0, frameCount: 1, duration: nil)
  }
}
