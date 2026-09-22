import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

@Suite("비파괴 이미지 편집")
struct ImageEditingTests {
  @Test("이전 보정 JSON과 빈 JSON은 신규 편집값의 기본값을 유지한다")
  func legacyAdjustmentsDecode() throws {
    let legacy = Data("""
      {"brightness":0.2,"contrast":1.3,"saturation":0.8,"highlights":-0.2,
       "isInverted":true,"quarterTurns":3}
      """.utf8)
    let decoded = try JSONDecoder().decode(ImageAdjustments.self, from: legacy)
    #expect(decoded.brightness == 0.2)
    #expect(decoded.contrast == 1.3)
    #expect(decoded.saturation == 0.8)
    #expect(decoded.highlights == -0.2)
    #expect(decoded.isInverted)
    #expect(decoded.normalizedQuarterTurns == 3)
    #expect(decoded.sharpness == 0)
    #expect(decoded.noiseReduction == 0)
    #expect(decoded.hue == 0)
    #expect(decoded.temperature == 0)
    #expect(decoded.vibrance == 0)
    #expect(decoded.exposure == 0)
    #expect(decoded.crop == nil)
    #expect(try JSONDecoder().decode(ImageAdjustments.self, from: Data("{}".utf8)) == .identity)
  }

  @Test("각 새 편집값은 기본 상태와 캐시 키를 구별하고 초기화할 수 있다")
  func identityAndReset() throws {
    for effect in EditEffect.allCases {
      var adjustments = effect.adjustments
      #expect(!adjustments.isIdentity)
      #expect(Set([ImageAdjustments.identity, adjustments]).count == 2)
      #expect(try JSONDecoder().decode(ImageAdjustments.self,
        from: JSONEncoder().encode(adjustments)) == adjustments)
      adjustments.reset()
      #expect(adjustments == .identity)
      #expect(adjustments.isIdentity)
    }
    var cropped = ImageAdjustments()
    cropped.crop = NormalizedCrop(x: 0.125, y: 0.25, width: 0.5, height: 0.5)
    #expect(!cropped.isIdentity)
    #expect(try JSONDecoder().decode(ImageAdjustments.self,
      from: JSONEncoder().encode(cropped)) == cropped)
    cropped.reset()
    #expect(cropped.crop == nil)
    #expect(cropped.isIdentity)
  }

  @Test("잘라낸 영역은 회전과 역회전 후 같은 원본 위치로 돌아간다")
  func cropRotationRoundTrip() throws {
    // 이진수로 정확히 표현되는 좌표를 사용해 부동소수점 반올림에 의존하지 않습니다.
    let original = NormalizedCrop(x: 0.125, y: 0.25, width: 0.5, height: 0.25)
    var adjustments = ImageAdjustments()
    adjustments.crop = original
    adjustments.rotateClockwise()
    #expect(adjustments.normalizedQuarterTurns == 1)
    #expect(adjustments.crop == NormalizedCrop(x: 0.5, y: 0.125, width: 0.25, height: 0.5))
    adjustments.rotateCounterclockwise()
    #expect(adjustments.normalizedQuarterTurns == 0)
    #expect(adjustments.crop == original)
    for _ in 0..<4 { adjustments.rotateClockwise() }
    #expect(adjustments.crop == original)
    #expect(adjustments.normalizedQuarterTurns == 0)
    for _ in 0..<4 { adjustments.rotateCounterclockwise() }
    #expect(adjustments.crop == original)
    #expect(adjustments.normalizedQuarterTurns == 0)
  }

  @Test("전체 영역 자르기는 무보정이고 작은 영역도 최소 한 픽셀을 남긴다")
  func cropPixelBounds() {
    var full = ImageAdjustments()
    full.crop = .full
    #expect(full.isIdentity)
    #expect(full.effectiveCrop == nil)
    let small = NormalizedCrop(x: 0.999, y: 0.999, width: 0.0001, height: 0.0001)
      .pixelRect(in: CGSize(width: 64, height: 32))
    #expect(small.width >= 1)
    #expect(small.height >= 1)
    #expect(small.minX >= 0 && small.maxX <= 64)
    #expect(small.minY >= 0 && small.maxY <= 32)
    let crop = NormalizedCrop(x: 0.25, y: 0.125, width: 0.5, height: 0.25)
    #expect(crop.pixelRect(in: CGSize(width: 80, height: 64))
      == CGRect(x: 20, y: 8, width: 40, height: 16))
    #expect(crop.coreImageRect(in: CGRect(x: 10, y: 20, width: 80, height: 64))
      == CGRect(x: 30, y: 60, width: 40, height: 16))
  }

  @Test("자르기 영역을 멀리 이동해도 크기를 유지하며 사진 경계에서 멈춘다")
  func cropMovementBounds() {
    let crop = NormalizedCrop(x: 0.125, y: 0.25, width: 0.5, height: 0.25)
    #expect(CropSelectionGeometry.move(crop, by: CGSize(width: -10, height: 10))
      == NormalizedCrop(x: 0, y: 0.75, width: 0.5, height: 0.25))
    #expect(CropSelectionGeometry.move(crop, by: CGSize(width: 10, height: -10))
      == NormalizedCrop(x: 0.5, y: 0, width: 0.5, height: 0.25))
    #expect(CropSelectionGeometry.move(crop, by: CGSize(width: 0.125, height: 0.125))
      == NormalizedCrop(x: 0.25, y: 0.375, width: 0.5, height: 0.25))
  }

  @Test("모서리 크기 변경은 반대 모서리를 고정하며 선택 비율을 유지한다")
  func cropCornerResizeAndRatio() {
    let crop = NormalizedCrop(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    #expect(CropSelectionGeometry.resize(crop, corner: .topLeft,
      by: CGSize(width: 0.125, height: -0.125), ratio: nil)
      == NormalizedCrop(x: 0.375, y: 0.125, width: 0.375, height: 0.625))
    #expect(CropSelectionGeometry.resize(crop, corner: .bottomRight,
      by: CGSize(width: 10, height: 10), ratio: nil)
      == NormalizedCrop(x: 0.25, y: 0.25, width: 0.75, height: 0.75))
    let resized = CropSelectionGeometry.resize(crop, corner: .bottomRight,
      by: CGSize(width: 10, height: 10), ratio: 2)
    #expect(resized.x == 0.25 && resized.y == 0.25)
    #expect(resized.width / resized.height == 2)
    #expect(resized.x + resized.width <= 1 && resized.y + resized.height <= 1)
    #expect(CropSelectionGeometry.fit(crop, ratio: 2)
      == NormalizedCrop(x: 0.25, y: 0.375, width: 0.5, height: 0.25))
    let ratios: [Double?] = [nil, 2]
    for delta in [CGSize(width: -0.5, height: 0), CGSize(width: 0, height: -0.5),
      CGSize(width: -0.5, height: -0.5)]
    {
      for ratio in ratios {
        let crossing = CropSelectionGeometry.resize(crop, corner: .bottomRight,
          by: delta, ratio: ratio)
        #expect(!crossing.isFullImage)
        #expect(crossing.width > 0 && crossing.height > 0)
        #expect(crossing.x >= 0 && crossing.y >= 0)
        #expect(crossing.x + crossing.width <= 1 && crossing.y + crossing.height <= 1)
        if let ratio { #expect(abs(crossing.width / crossing.height - ratio) < 0.000_001) }
      }
    }
  }

  @Test("역방향 드래그와 화면 바깥 드래그도 정상 영역과 고정 비율로 변환한다")
  func cropReverseDrawing() {
    let start = CGPoint(x: 0.875, y: 0.75)
    let end = CGPoint(x: 0.125, y: 0.25)
    #expect(CropSelectionGeometry.draw(from: start, to: end, ratio: nil)
      == NormalizedCrop(x: 0.125, y: 0.25, width: 0.75, height: 0.5))
    let fixed = CropSelectionGeometry.draw(from: start, to: end, ratio: 2)
    #expect(fixed.width / fixed.height == 2)
    #expect(fixed.x + fixed.width == start.x && fixed.y + fixed.height == start.y)
    let outside = CropSelectionGeometry.draw(from: start, to: CGPoint(x: 2, y: -2), ratio: 0.5)
    #expect(outside.width / outside.height == 0.5)
    #expect(outside.x >= 0 && outside.y >= 0)
    #expect(outside.x + outside.width <= 1 && outside.y + outside.height <= 1)
    for corner in [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)] {
      let coincident = CropSelectionGeometry.draw(from: corner, to: corner, ratio: nil)
      #expect(!coincident.isFullImage)
      #expect(coincident.width > 0 && coincident.height > 0)
      #expect(coincident.x >= 0 && coincident.y >= 0)
      #expect(coincident.x + coincident.width <= 1 && coincident.y + coincident.height <= 1)
    }
  }

  @Test("자르기 창을 연 뒤 사진을 바꾸거나 제거해도 다른 사진에는 적용하지 않는다")
  @MainActor
  func cropTargetsCapturedAsset() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writePNG(url: directory.appendingPathComponent("first.png"),
      width: 96, height: 64, pattern: .quadrants)
    try writePNG(url: directory.appendingPathComponent("second.png"),
      width: 96, height: 64, pattern: .texture)
    let store = AppStore(monitorsSystemResources: false)
    store.open(urls: [directory])
    try await waitForLoad(store)
    try #require(store.assets.count == 2)
    let capturedAsset = store.assets[0]
    let otherAsset = store.assets[1]
    store.select(index: 1)
    let crop = NormalizedCrop(x: 0.125, y: 0.25, width: 0.5, height: 0.5)
    store.applyCrop(crop, to: capturedAsset)
    #expect(store.currentAsset == otherAsset)
    #expect(store.adjustments(for: capturedAsset).crop == crop)
    #expect(store.currentAdjustments.isIdentity)
    // 시트의 초안을 만든 뒤 사진이 회전되어도 동일한 원본 영역을 적용합니다.
    store.select(index: 0)
    store.rotateClockwise()
    store.select(index: 1)
    store.applyCrop(crop, to: capturedAsset, relativeToQuarterTurns: 0)
    #expect(store.currentAsset == otherAsset)
    #expect(store.adjustments(for: capturedAsset).normalizedQuarterTurns == 1)
    #expect(store.adjustments(for: capturedAsset).crop == crop.rotatedClockwise())
    #expect(store.currentAdjustments.isIdentity)
    try FileManager.default.removeItem(at: capturedAsset.url)
    store.open(urls: [directory])
    try await waitForLoad(store)
    #expect(store.assets == [otherAsset])
    store.applyCrop(.full, to: capturedAsset, relativeToQuarterTurns: 0)
    #expect(store.adjustments(for: capturedAsset).crop == crop.rotatedClockwise())
    #expect(store.currentAdjustments.isIdentity)
  }

  @Test("잘라내기는 화면의 좌상단 기준이며 시계 회전한 픽셀 방향과 일치한다")
  func cropAndRotationPixelOrientation() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("quadrants.png")
    try writePNG(url: url, width: 384, height: 256, pattern: .quadrants)
    let pipeline = ImagePipeline()
    var topLeft = ImageAdjustments()
    topLeft.crop = NormalizedCrop(x: 0, y: 0, width: 0.5, height: 0.5)
    let originalCrop = try await pipeline.renderFrame(url: url, maxPixelSize: nil,
      adjustments: topLeft, prefersHDR: false)
    #expect(originalCrop.image.width == 192)
    #expect(originalCrop.image.height == 128)
    #expect(originalCrop.sourcePixelSize == CGSize(width: 192, height: 128))
    let red = try averageColor(originalCrop.image)
    #expect(red.r > red.g + 100 && red.r > red.b + 100)

    // 직접 회전 상태를 설정하면 회전된 사진의 좌상단(원본의 파랑)을 선택합니다.
    var rotatedTopLeft = topLeft
    rotatedTopLeft.quarterTurns = 1
    let blueFrame = try await pipeline.renderFrame(url: url, maxPixelSize: nil,
      adjustments: rotatedTopLeft, prefersHDR: false)
    #expect(blueFrame.image.width == 128)
    #expect(blueFrame.image.height == 192)
    let blue = try averageColor(blueFrame.image)
    #expect(blue.b > blue.r + 100 && blue.b > blue.g + 100)

    // 회전 동작은 기존 선택을 함께 이동시켜 원본의 빨강 영역을 보존합니다.
    topLeft.rotateClockwise()
    let preserved = try await pipeline.renderFrame(url: url, maxPixelSize: nil,
      adjustments: topLeft, prefersHDR: false)
    #expect(preserved.image.width == 128)
    #expect(preserved.image.height == 192)
    let preservedRed = try averageColor(preserved.image)
    #expect(preservedRed.r > preservedRed.g + 100 && preservedRed.r > preservedRed.b + 100)
  }

  @Test("각 보정은 실제 픽셀을 바꾸며 이미지 크기와 불투명도를 유지한다",
    arguments: EditEffect.allCases)
  func individualEffectsRender(effect: EditEffect) async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("color-and-noise.png")
    try writePNG(url: url, width: 96, height: 64, pattern: .texture)
    let pipeline = ImagePipeline()
    let baseline = try await pipeline.renderFrame(url: url, maxPixelSize: nil,
      adjustments: .identity, prefersHDR: false)
    let edited = try await pipeline.renderFrame(url: url, maxPixelSize: nil,
      adjustments: effect.adjustments, prefersHDR: false)
    #expect(edited.image.width == 96)
    #expect(edited.image.height == 64)
    let before = try rgbaPixels(baseline.image)
    let after = try rgbaPixels(edited.image)
    let changed = zip(before, after).enumerated().reduce(0.0) { result, entry in
      entry.offset % 4 == 3 ? result : result + abs(Double(entry.element.0) - Double(entry.element.1))
    } / Double(96 * 64 * 3)
    // 색공간·GPU별 반올림을 허용하되 필터가 연결되지 않은 경우를 검출합니다.
    #expect(changed > 0.05)
    #expect(stride(from: 3, to: after.count, by: 4).allSatisfy { after[$0] >= 254 })
  }

  @Test("최대·최소 보정을 함께 적용해도 HDR 결과가 유한하다", arguments: [-1.0, 1.0])
  func extremeAdjustmentsStayFinite(direction: Double) async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("extremes.png")
    try writePNG(url: url, width: 96, height: 64, pattern: .texture)
    var adjustments = ImageAdjustments()
    adjustments.exposure = direction * 4
    adjustments.temperature = direction * 100
    adjustments.hue = direction * 180
    adjustments.vibrance = direction
    adjustments.sharpness = 2
    adjustments.noiseReduction = 1
    let frame = try await ImagePipeline().renderFrame(url: url, maxPixelSize: 256,
      adjustments: adjustments, prefersHDR: true)
    #expect(frame.image.width == 96)
    #expect(frame.image.height == 64)
    let values = try floatingPointPixels(frame.image)
    #expect(values.allSatisfy { $0.isFinite })
    #expect(stride(from: 3, to: values.count, by: 4).allSatisfy { abs(values[$0] - 1) < 0.01 })
  }

  @Test("미리보기와 PNG 내보내기는 같은 자르기를 적용하며 원본 바이트를 보존한다")
  func previewAndExportAgree() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.png")
    let destination = directory.appendingPathComponent("edited.png")
    try writePNG(url: source, width: 768, height: 512, pattern: .quadrants)
    let originalBytes = try Data(contentsOf: source)
    var adjustments = ImageAdjustments()
    adjustments.crop = NormalizedCrop(x: 0, y: 0, width: 0.5, height: 0.5)
    adjustments.rotateClockwise()
    adjustments.exposure = 0.25
    let pipeline = ImagePipeline()
    let preview = try await pipeline.renderFrame(url: source, maxPixelSize: 256,
      adjustments: adjustments, prefersHDR: false)
    try await ImageExporter(pipeline: pipeline).export(sourceURL: source,
      destinationURL: destination, format: .png, quality: 1, adjustments: adjustments)
    let outputSource = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
    let output = try #require(CGImageSourceCreateImageAtIndex(outputSource, 0, nil))
    #expect(output.width == 256)
    #expect(output.height == 384)
    #expect(preview.sourcePixelSize == CGSize(width: 256, height: 384))
    let previewAspect = Double(preview.image.width) / Double(preview.image.height)
    #expect(abs(previewAspect - Double(output.width) / Double(output.height)) < 0.02)
    let small = try averageColor(preview.image)
    let full = try averageColor(output)
    #expect(small.r > small.g + 100 && full.r > full.g + 100)
    #expect(abs(small.r - full.r) < 10)
    #expect(abs(small.g - full.g) < 10)
    #expect(abs(small.b - full.b) < 10)
    #expect(try Data(contentsOf: source) == originalBytes)
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil)
      as? [CFString: Any])
    #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 256)
    #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 384)
    #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
  }

  @Test("원본 자체와 심볼릭·하드 링크로 내보내기를 요청해도 원본을 덮어쓰지 않는다")
  func exportRejectsOriginalAndAliases() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("original.png")
    let symbolicLink = directory.appendingPathComponent("symbolic.png")
    let hardLink = directory.appendingPathComponent("hard.png")
    try writePNG(url: source, width: 96, height: 64, pattern: .texture)
    try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: source)
    try FileManager.default.linkItem(at: source, to: hardLink)
    let originalBytes = try Data(contentsOf: source)
    let exporter = ImageExporter(pipeline: ImagePipeline())
    for destination in [source, symbolicLink, hardLink] {
      do {
        try await exporter.export(sourceURL: source, destinationURL: destination,
          format: .png, quality: 1, adjustments: EditEffect.exposure.adjustments)
        Issue.record("원본과 동일한 파일을 내보내기 대상으로 허용했습니다.")
      } catch ImageExportError.sourceOverwrite {
        // 파일 내용이 바뀌기 전에 명시적인 원본 보호 오류가 발생해야 합니다.
      }
      #expect(try Data(contentsOf: source) == originalBytes)
      #expect(try Data(contentsOf: destination) == originalBytes)
    }
  }

  enum EditEffect: CaseIterable, Sendable {
    case brightness, contrast, saturation, highlights, exposure, hue, temperature, vibrance
    case sharpness, noiseReduction

    var adjustments: ImageAdjustments {
      var value = ImageAdjustments()
      switch self {
      case .brightness: value.brightness = 0.2
      case .contrast: value.contrast = 1.5
      case .saturation: value.saturation = 0.2
      case .highlights: value.highlights = -0.8
      case .exposure: value.exposure = 1
      case .hue: value.hue = 90
      case .temperature: value.temperature = 80
      case .vibrance: value.vibrance = 0.8
      case .sharpness: value.sharpness = 1.5
      case .noiseReduction: value.noiseReduction = 1
      }
      return value
    }
  }

  private enum Pattern { case quadrants, texture }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imageviewer-editing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
  }

  @MainActor
  private func waitForLoad(_ store: AppStore) async throws {
    for _ in 0..<200 {
      if !store.isLoading { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!store.isLoading)
    try #require(!store.assets.isEmpty)
  }

  private func writePNG(url: URL, width: Int, height: Int, pattern: Pattern) throws {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let channels: [Int]
        switch pattern {
        case .quadrants:
          switch (x < width / 2, y < height / 2) {
          case (true, true): channels = [225, 25, 25]
          case (false, true): channels = [25, 225, 25]
          case (true, false): channels = [25, 25, 225]
          case (false, false): channels = [225, 225, 25]
          }
        case .texture:
          let noise = (x * 17 + y * 29 + x * y) % 17 - 8
          let edge = x > width / 2 ? 25 : 0
          channels = [
            55 + x * 120 / width + noise,
            60 + y * 90 / height + noise + edge,
            95 + x * 60 / width + noise,
          ]
        }
        for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = UInt8(channels[channel]) }
      }
    }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
      bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
      UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
  }

  private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data)
    return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
      count: image.width * image.height * 4))
  }

  private func averageColor(_ image: CGImage) throws -> (r: Double, g: Double, b: Double) {
    let pixels = try rgbaPixels(image)
    let count = Double(image.width * image.height)
    var sums = (r: 0.0, g: 0.0, b: 0.0)
    for index in stride(from: 0, to: pixels.count, by: 4) {
      sums.r += Double(pixels[index])
      sums.g += Double(pixels[index + 1])
      sums.b += Double(pixels[index + 2])
    }
    return (sums.r / count, sums.g / count, sums.b / count)
  }

  private func floatingPointPixels(_ image: CGImage) throws -> [Float] {
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 32, bytesPerRow: image.width * 4 * MemoryLayout<Float>.size,
      space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data)
    return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
      count: image.width * image.height * 4))
  }
}
