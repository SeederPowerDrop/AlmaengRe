import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

@Suite("고급 비파괴 이미지 편집")
struct AdvancedImageEditingTests {
  @Test("이전 설정에 없던 고급 조정은 기본값이며 전체 설정이 왕복 저장된다")
  func adjustmentCodableAndIdentity() throws {
    let legacy = try JSONDecoder().decode(ImageAdjustments.self,
      from: Data(#"{"exposure":0.5}"#.utf8))
    #expect(legacy.shadows == 0 && legacy.blackPoint == 0 && legacy.whites == 0)
    #expect(legacy.toneCurves.isIdentity && legacy.colorMixer.isIdentity)
    #expect(legacy.texture == 0 && legacy.clarity == 0 && legacy.dehaze == 0)
    #expect(legacy.filmLook == .none && legacy.filmStrength == 1)
    let partial = try JSONDecoder().decode(ImageAdjustments.self,
      from: Data(#"{"toneCurves":{"red":{"values":[0,0.1,0.5,0.9,1]}},"colorMixer":{}}"#.utf8))
    #expect(partial.toneCurves.rgb.isIdentity && partial.toneCurves.green.isIdentity)
    #expect(!partial.toneCurves.red.isIdentity && partial.colorMixer.isIdentity)
    for effect in Effect.allCases {
      var adjustments = effect.adjustments
      #expect(!adjustments.isIdentity)
      #expect(Set([ImageAdjustments.identity, adjustments]).count == 2)
      let encoded = try JSONEncoder().encode(adjustments)
      #expect(try JSONDecoder().decode(ImageAdjustments.self, from: encoded) == adjustments)
      adjustments.reset()
      #expect(adjustments.isIdentity)
    }
    var zeroStrength = ImageAdjustments()
    zeroStrength.filmLook = .tealOrange
    zeroStrength.filmStrength = 0
    #expect(zeroStrength.isIdentity)
  }

  @Test("톤 커브는 제어점을 통과하고 잘못된 값과 HDR 영역을 안전하게 처리한다")
  func curveInterpolationAndBounds() {
    let curve = ImageToneCurve.strongContrast
    for index in 0..<5 {
      #expect(abs(curve.output(at: Double(index) / 4) - curve.values[index]) < 0.000001)
    }
    #expect(curve.output(at: 2) == 2)
    #expect(curve.output(at: -0.25) == -0.25)
    #expect(ImageToneCurve(values: [.nan]).isIdentity)
    var invalid = ImageToneCurve(values: [.nan, -.infinity, 4, -1, .infinity])
    #expect(invalid.normalizedValues == [0, 0.25, 1, 0, 1])
    invalid.setValue(0.4, at: 9)
    #expect(invalid.values.count == 5)
    invalid.setValue(0.8, at: 2)
    #expect(invalid.normalizedValues[2] == 0.8)
  }

  @Test("새 조정은 실제 픽셀을 바꾸며 크기와 반투명 알파를 유지한다",
    arguments: Effect.allCases.filter { $0 != .shadows })
  func effectsChangePixels(effect: Effect) throws {
    let input = try fixtureImage()
    let before = pixels(input)
    let output = AdvancedImageProcessor.apply(effect.adjustments, to: input)
    #expect(output.extent == input.extent)
    let after = pixels(output)
    var totalDifference: Double = 0
    for index in stride(from: 0, to: after.count, by: 4) {
      for channel in 0..<3 {
        totalDifference += abs(Double(after[index + channel]) - Double(before[index + channel]))
      }
    }
    let meanDifference: Double = totalDifference / Double(64 * 48 * 3)
    #expect(meanDifference > 0.00001)
    #expect(after.allSatisfy { $0.isFinite })
    for index in stride(from: 3, to: after.count, by: 4) {
      #expect(abs(after[index] - before[index]) < 0.002)
    }
  }

  @Test("빨강 채널 커브는 초록과 파랑 채널을 보존한다")
  func channelCurveDoesNotModifyOtherChannels() throws {
    let input = try fixtureImage()
    let before = pixels(input)
    var edits = ImageAdjustments()
    edits.toneCurves.red = .strongContrast
    let after = pixels(AdvancedImageProcessor.apply(edits, to: input))
    for index in stride(from: 0, to: after.count, by: 4) {
      #expect(abs(after[index + 1] - before[index + 1]) < 0.002)
      #expect(abs(after[index + 2] - before[index + 2]) < 0.002)
    }
  }

  @Test("빨강 믹서는 파란 픽셀과 무채색 픽셀을 바꾸지 않는다")
  func mixerProtectsOtherColors() {
    var edits = ImageAdjustments()
    edits.colorMixer[.red] = ColorMixerValues(hue: 25, saturation: -0.8, lightness: 0.5)
    for color in [CIColor(red: 0.1, green: 0.2, blue: 0.8),
      CIColor(red: 0.4, green: 0.4, blue: 0.4)] {
      let input = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
      let before = pixels(input)
      let after = pixels(AdvancedImageProcessor.apply(edits, to: input))
      #expect(zip(before, after).allSatisfy { abs($0 - $1) < 0.002 })
    }
  }

  @Test("필름룩 강도 0은 원본과 같고 HDR 하이라이트를 유지한다")
  func filmStrengthAndHDR() {
    // CIColor's default sRGB color space clamps extended values. Supply real,
    // premultiplied floating-point pixels in extended linear sRGB instead.
    let hdrPixels = Array(repeating: [Float(1.5), Float(1.08), Float(0.72), Float(0.6)],
      count: 64 * 48).flatMap { $0 }
    let input = hdrPixels.withUnsafeBytes {
      CIImage(bitmapData: Data($0), bytesPerRow: 64 * 4 * MemoryLayout<Float>.size,
        size: CGSize(width: 64, height: 48), format: .RGBAf,
        colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
    }
    let before = pixels(input)
    #expect(before[0] > 1)
    #expect(before[0] / before[3] > 2)
    for look in ImageFilmLook.allCases {
      var edits = ImageAdjustments()
      edits.filmLook = look
      edits.filmStrength = 0
      #expect(pixels(AdvancedImageProcessor.apply(edits, to: input)) == before)
      edits.filmStrength = 1
      edits.toneCurves.rgb = .strongContrast
      let after = pixels(AdvancedImageProcessor.apply(edits, to: input))
      #expect(after.allSatisfy { $0.isFinite })
      #expect(after[0] > after[3])
      #expect(abs(after[3] - before[3]) < 0.002)
    }
  }

  @Test("범위를 벗어난 조정값은 유한한 출력으로 제한된다")
  func malformedValuesStayFinite() throws {
    var edits = ImageAdjustments()
    edits.blackPoint = .nan; edits.whites = .infinity; edits.dehaze = -.infinity
    edits.texture = 100; edits.clarity = 100
    edits.toneCurves.blue.values = [.nan, -100, 0.3, 100, .infinity]
    edits.colorMixer[.red] = ColorMixerValues(hue: .nan, saturation: .infinity, lightness: -100)
    edits.filmLook = .coolNight; edits.filmStrength = .infinity
    let output = pixels(AdvancedImageProcessor.apply(edits, to: try fixtureImage()))
    #expect(output.allSatisfy { $0.isFinite })
  }

  @Test("그림자 보정과 모든 고급 편집은 미리보기 및 내보내기에 동일하게 적용된다")
  func pipelineAndExportAgree() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imageviewer-advanced-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.png")
    let output = directory.appendingPathComponent("exported.png")
    let ciImage = try fixtureImage()
    let cgImage = try #require(CIContext().createCGImage(ciImage, from: ciImage.extent,
      format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
    let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL,
      UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, cgImage, nil)
    #expect(CGImageDestinationFinalize(destination))
    let originalData = try Data(contentsOf: source)
    let pipeline = ImagePipeline()
    let before = try await pipeline.renderFrame(url: source, maxPixelSize: nil,
      adjustments: .identity, prefersHDR: false)
    let shadows = try await pipeline.renderFrame(url: source, maxPixelSize: nil,
      adjustments: Effect.shadows.adjustments, prefersHDR: false)
    let beforePixels = pixels(CIImage(cgImage: before.image))
    let shadowPixels = pixels(CIImage(cgImage: shadows.image))
    #expect(zip(beforePixels, shadowPixels).contains { abs($0 - $1) > 0.002 })
    var edits = ImageAdjustments()
    edits.shadows = 0.5; edits.blackPoint = 0.2; edits.whites = 0.2
    edits.toneCurves.rgb = .mediumContrast
    edits.colorMixer[.red] = ColorMixerValues(hue: 15, saturation: -0.2, lightness: 0.3)
    edits.texture = 0.4; edits.clarity = 0.3; edits.dehaze = 0.2
    edits.filmLook = .tealOrange; edits.filmStrength = 0.6
    let preview = try await pipeline.renderFrame(url: source, maxPixelSize: nil,
      adjustments: edits, prefersHDR: false)
    try await ImageExporter(pipeline: pipeline).export(sourceURL: source, destinationURL: output,
      format: .png, quality: 1, adjustments: edits)
    let exported = try #require(CIImage(contentsOf: output))
    #expect(exported.extent == CGRect(x: 0, y: 0, width: 64, height: 48))
    let previewPixels = pixels(CIImage(cgImage: preview.image))
    let exportPixels = pixels(exported)
    #expect(zip(previewPixels, exportPixels).allSatisfy { abs($0 - $1) < 0.012 })
    #expect(try Data(contentsOf: source) == originalData)
  }

  enum Effect: CaseIterable, Sendable {
    case shadows, blackPoint, whites, rgbCurve, redCurve, greenCurve, blueCurve
    case mixerHue, mixerSaturation, mixerLightness, texture, clarity, dehaze
    case tealOrange, faded, coolNight
    var adjustments: ImageAdjustments {
      var edits = ImageAdjustments()
      switch self {
      case .shadows: edits.shadows = 0.8
      case .blackPoint: edits.blackPoint = 0.7
      case .whites: edits.whites = 0.7
      case .rgbCurve: edits.toneCurves.rgb = .strongContrast
      case .redCurve: edits.toneCurves.red = .strongContrast
      case .greenCurve: edits.toneCurves.green = .strongContrast
      case .blueCurve: edits.toneCurves.blue = .strongContrast
      case .mixerHue: edits.colorMixer[.red] = ColorMixerValues(hue: 25)
      case .mixerSaturation: edits.colorMixer[.red] = ColorMixerValues(saturation: -0.7)
      case .mixerLightness: edits.colorMixer[.red] = ColorMixerValues(lightness: 0.7)
      case .texture: edits.texture = 1
      case .clarity: edits.clarity = 1
      case .dehaze: edits.dehaze = 0.8
      case .tealOrange: edits.filmLook = .tealOrange
      case .faded: edits.filmLook = .faded
      case .coolNight: edits.filmLook = .coolNight
      }
      return edits
    }
  }

  private func fixtureImage() throws -> CIImage {
    var values: [Float] = []
    for y in 0..<48 {
      for x in 0..<64 {
        let alpha: Float = x < 32 ? 0.45 : 0.9
        let texture: Float = (x + y) % 3 == 0 ? 0.02 : -0.02
        values += [(0.04 + Float(x) * 0.008 + texture) * alpha,
          (0.02 + Float(y) * 0.005 + texture) * alpha,
          (0.015 + Float(x % 17) * 0.003) * alpha, alpha]
      }
    }
    return values.withUnsafeBytes {
      CIImage(bitmapData: Data($0), bytesPerRow: 64 * 4 * MemoryLayout<Float>.size,
        size: CGSize(width: 64, height: 48), format: .RGBAf,
        colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
    }
  }

  private func pixels(_ image: CIImage) -> [Float] {
    var result = [Float](repeating: 0, count: 64 * 48 * 4)
    CIContext(options: [.cacheIntermediates: false]).render(image, toBitmap: &result,
      rowBytes: 64 * 4 * MemoryLayout<Float>.size,
      bounds: CGRect(x: 0, y: 0, width: 64, height: 48), format: .RGBAf,
      colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
    return result
  }
}
