import CoreImage
import Foundation
import Metal
import Testing

@testable import ImageViewer

@Suite("Metal 작업 이미지의 정밀도·한도·수명", .serialized)
struct MetalWorkingImageTests {
  private var linear: CGColorSpace { CGColorSpace(name: CGColorSpace.extendedLinearSRGB)! }

  @Test("Float32·음수·HDR·알파·이동·분수 크롭이 기존 정밀 입력과 일치한다",
    arguments: [0, 1, 2, 3, 4])
  func precisionAndFractionalBounds(shape: Int) throws {
    guard supportsAppleGPU else { return }
    let renderer = MetalImageRenderer()
    var source = makeImage()
    if shape == 1 { source = source.transformed(by: CGAffineTransform(translationX: -9, y: 13)) }
    if shape == 2 { source = source.cropped(to: CGRect(x: 0, y: 0, width: 72.5, height: 50.25)) }
    if shape == 3 || shape == 4 {
      source = source.cropped(to: CGRect(x: 0.25, y: 0.5, width: 72.5, height: 50.25))
      if shape == 3 { source = source.transformed(by: CGAffineTransform(translationX: -9, y: 13)) }
    }
    let extent = source.extent.integral
    let bitmap = try #require(renderer.context.createCGImage(source, from: extent,
      format: .RGBAf, colorSpace: linear))
    let plane = try #require(try renderer.workingImage(bitmap, canRetain: { $0 <= 2 * 1_024 * 1_024 }))
    let transform = CGAffineTransform(translationX: extent.minX, y: extent.minY)
    let actual = plane.image.transformed(by: transform).cropped(to: source.extent)
    let expected = CIImage(cgImage: bitmap).transformed(by: transform).cropped(to: source.extent)
    let value = try pixels(actual.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.7]),
      renderer: renderer)
    let reference = try pixels(expected.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.7]),
      renderer: renderer)
    #expect(value.count == reference.count)
    #expect(value.allSatisfy(\.isFinite) && reference.allSatisfy(\.isFinite))
    let maximum = zip(value,reference).enumerated().max { abs($0.element.0-$0.element.1) < abs($1.element.0-$1.element.1) }!
    print("METAL_SYNTHETIC_PARITY shape=\(shape) max=\(abs(maximum.element.0-maximum.element.1))")
    #expect(zip(value, reference).allSatisfy { abs($0-$1) <= 0.000_1 })
    #expect(value.max()! > 1 && value.min()! < 0)
    #expect(plane.byteCount > 0 && plane.byteCount <= 2 * 1_024 * 1_024)
    #expect(plane.kernelSeconds.isFinite && plane.kernelSeconds >= 0)
    if #available(macOS 15.0, *) {
      #expect(plane.image.contentHeadroom == CIImage(cgImage: bitmap).contentHeadroom)
    }
    if #available(macOS 16.0, *) {
      #expect(plane.image.contentAverageLightLevel == CIImage(cgImage: bitmap).contentAverageLightLevel)
    }
  }

  @Test("실제 Metal 할당을 기존 예산에 포함하고 비우기·이전 세대를 보존하지 않는다")
  func budgetGenerationAndLifetime() throws {
    guard supportsAppleGPU else { return }
    let renderer = MetalImageRenderer()
    let cache = DecodedImageInputCache()
    cache.setCostLimit(2 * 1_024 * 1_024)
    let generation = cache.generationToken()
    let key = DecodedImageInputKey(file: ImageFileVersion(url: URL(fileURLWithPath: "/synthetic-metal.dng")),
      frameIndex: 0, pixelSize: 73, geometry: DecodedImageGeometry(.identity), prefersHDR: true)
    var plane: MetalWorkingImage? = try #require(try renderer.workingImage(raster(renderer),
      canRetain: { cache.canRetain(cost: $0, generation: generation) }))
    weak var weakPlane = plane
    let cost = try #require(plane).byteCount
    cache.insert(try #require(plane), for: key, generation: generation)
    plane = nil
    #expect(weakPlane != nil)
    #expect(cache.snapshot().cache.byteCount == cost)
    #expect(cache.lookupWorkingImage(key, generation: generation) != nil)
    #expect(cache.snapshot().metalPreparedCount == 1 && cache.snapshot().metalReuseCount == 1)
    cache.removeAll()
    #expect(cache.snapshot().cache.byteCount == 0 && weakPlane == nil)
    #expect(cache.lookupWorkingImage(key, generation: generation) == nil)
    // A completed older render must not adopt a newly opened cache generation.
    let late = try #require(try renderer.workingImage(raster(renderer), canRetain: { _ in true }))
    cache.insert(late, for: key, generation: generation)
    #expect(cache.snapshot().cache.byteCount == 0)
    cache.setCostLimit(0)
    #expect(try renderer.workingImage(raster(renderer), canRetain: {
      cache.canRetain(cost: $0, generation: cache.generationToken())
    }) == nil)
  }

  @Test("예산 거절·낮은 정밀도·비활성 Metal은 GPU 작업 이미지를 만들지 않는다")
  func rejectsUnneededAllocations() throws {
    let renderer = MetalImageRenderer()
    #expect(try renderer.workingImage(raster(renderer), canRetain: { _ in false }) == nil)
    let eightBit = try #require(renderer.context.createCGImage(makeImage(), from: makeImage().extent,
      format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
    #expect(try renderer.workingImage(eightBit, canRetain: { _ in true }) == nil)
    let automatic = MetalImageRenderer(usesMetal: false)
    #expect(try automatic.workingImage(raster(automatic), canRetain: { _ in true }) == nil)
    #expect(automatic.context.createCGImage(makeImage(), from: makeImage().extent,
      format: .RGBAf, colorSpace: linear) != nil)
  }

  @Test("이미 취소된 렌더 요청은 새 Metal 이미지나 캐시를 만들지 않는다")
  func precancelled() async {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      let renderer = MetalImageRenderer()
      #expect(throws: CancellationError.self) {
        try renderer.workingImage(raster(renderer), canRetain: { _ in true })
      }
    }
    await task.value
  }

  @Test("명시적인 HDR 헤드룸도 Metal 입력에 보존한다")
  func explicitHeadroom() throws {
    guard supportsAppleGPU else { return }
    if #available(macOS 15.0, *) {
      let renderer = MetalImageRenderer()
      let base = try raster(renderer)
      let tagged = try #require(CGImageCreateCopyWithContentHeadroom(4, base))
      let prepared = try renderer.workingImage(tagged, canRetain: { _ in true })
      #expect(CIImage(cgImage: tagged).contentHeadroom == 4)
      if #available(macOS 16.0, *) {
        let plane = try #require(prepared)
        #expect(plane.image.contentHeadroom == 4)
      } else if ProcessInfo.processInfo.environment["RAW_METAL_REQUIRED"] == "1" {
        let plane = try #require(prepared, "Required Metal validation fell back on a tagged HDR image")
        #expect(plane.image.contentHeadroom == 4)
      } else if let plane = prepared {
        #expect(plane.image.contentHeadroom == 4)
      }
    }
  }

  private func makeImage() -> CIImage {
    var values: [Float] = []
    for y in 0..<53 {
      for x in 0..<77 {
        let alpha: Float = x % 3 == 0 ? 0.5 : 1
        values += [Float(x-38)/20 * alpha, Float(y+1)/10 * alpha,
          Float((x+y)%11)/10 * alpha, alpha]
      }
    }
    let data = values.withUnsafeBytes { Data($0) }
    return CIImage(bitmapData: data, bytesPerRow: 77 * 16,
      size: CGSize(width: 77, height: 53), format: .RGBAf, colorSpace: linear)
  }

  private var supportsAppleGPU: Bool {
    guard #available(macOS 15.0, *) else { return false }
    guard let device = MTLCreateSystemDefaultDevice() else { return false }
    return device.hasUnifiedMemory && device.supportsFamily(.apple7)
  }

  private func raster(_ renderer: MetalImageRenderer) throws -> CGImage {
    try #require(renderer.context.createCGImage(makeImage(), from: makeImage().extent,
      format: .RGBAf, colorSpace: linear))
  }

  private func pixels(_ image: CIImage, renderer: MetalImageRenderer) throws -> [Float] {
    let output = try #require(renderer.context.createCGImage(image, from: image.extent.integral,
      format: .RGBAf, colorSpace: linear))
    let context = try #require(CGContext(data: nil, width: output.width, height: output.height,
      bitsPerComponent: 32, bytesPerRow: output.width * 16, space: linear,
      bitmapInfo: CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setBlendMode(.copy)
    context.draw(output, in: CGRect(x: 0, y: 0, width: output.width, height: output.height))
    return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: Float.self),
      count: output.width * output.height * 4))
  }
}
