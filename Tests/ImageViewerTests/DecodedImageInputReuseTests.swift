import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

@Suite("디코드 입력 재사용의 품질과 수명", .serialized)
struct DecodedImageInputReuseTests {
  private var machine: ImageResourceSnapshot {
    ImageResourceSnapshot(physicalMemory: 16 * 1_024 * 1_024 * 1_024,
      activeProcessorCount: 8, appleSilicon: true)
  }

  @Test("색상·회전 조정은 입력을 재사용하고 크롭 크기는 구별하며 기존 출력과 일치한다")
  func editedPixelsMatchUncachedDecode() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("working.tiff")
    try writeTIFF(url, width: 1_024, height: 768)
    let pipeline = makePipeline()
    let reference = makePipeline(reusesInputs: false)
    let identity = try await pipeline.renderFrame(url: url, maxPixelSize: 512,
      adjustments: .identity, prefersHDR: false)
    #expect(identity.image.colorSpace?.name == CGColorSpace.sRGB)
    var value = ImageAdjustments.identity
    value.exposure = 0.7
    var cases = [value]
    value.brightness = 0.12
    cases.append(value)
    value.contrast = 1.18
    cases.append(value)
    value.temperature = 18
    cases.append(value)
    value.vibrance = 0.22
    cases.append(value)
    value.quarterTurns = 1
    cases.append(value)
    value.crop = NormalizedCrop(x: 0.125, y: 0.25, width: 0.5, height: 0.5)
    cases.append(value)
    for adjustments in cases {
      let actual = try await pipeline.renderFrame(url: url, maxPixelSize: 512,
        adjustments: adjustments, prefersHDR: false)
      let expected = try await reference.renderFrame(url: url, maxPixelSize: 512,
        adjustments: adjustments, prefersHDR: false)
      try expectSamePixels(actual, expected)
    }
    let reuse = await pipeline.decodeReuseSnapshot()
    #expect(reuse.decodedFrameCount == 2)
    #expect(reuse.reuseCount >= 6)
    #expect(reuse.cache.entryCount == 2)
    #expect(reuse.cache.byteCount > 0 && reuse.cache.byteCount <= reuse.cache.byteLimit)
    let combined = await pipeline.cacheSnapshot()
    let limits = await pipelineGovernorLimits()
    #expect(combined.byteLimit == limits.renderCacheBytes)
    #expect(combined.byteCount <= combined.byteLimit)
    await pipeline.purgeCaches()
    await reference.purgeCaches()
  }

  @Test("같은 파일의 픽셀·ICC·치수를 교체하면 이전 입력을 사용하지 않는다")
  func replacementPreservesNewProfileAndPixels() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("replacement.tiff")
    try writeTIFF(url, width: 1_024, height: 768)
    let pipeline = makePipeline()
    let initial = try await pipeline.renderFrame(url: url, maxPixelSize: 512,
      adjustments: .identity, prefersHDR: false)
    #expect(initial.image.colorSpace?.name == CGColorSpace.sRGB)
    try writeTIFF(url, width: 600, height: 400, usesP3: true, alternateColors: true)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
      ofItemAtPath: url.path)
    let current = try await pipeline.renderFrame(url: url, maxPixelSize: 512,
      adjustments: .identity, prefersHDR: false)
    #expect(current.image.colorSpace?.name == CGColorSpace.displayP3)
    #expect(current.sourcePixelSize == CGSize(width: 600, height: 400))
    #expect(current.image !== initial.image)
    var adjustments = ImageAdjustments.identity
    adjustments.exposure = 0.4
    let actual = try await pipeline.renderFrame(url: url, maxPixelSize: 512,
      adjustments: adjustments, prefersHDR: false)
    let reference = makePipeline(reusesInputs: false)
    let expected = try await reference.renderFrame(url: url, maxPixelSize: 512,
      adjustments: adjustments, prefersHDR: false)
    try expectSamePixels(actual, expected)
    let reuse = await pipeline.decodeReuseSnapshot()
    #expect(reuse.decodedFrameCount == 2 && reuse.reuseCount >= 1)
    await pipeline.purgeCaches()
    await reference.purgeCaches()
  }

  @Test("HDR 화면 입력은 원래 정밀도로 재사용하고 원본 크기 내보내기는 재사용을 우회한다")
  func hdrAndOriginalSizeRemainPrecise() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("quality.tiff")
    try writeTIFF(url, width: 1_024, height: 768, usesP3: true)
    let pipeline = makePipeline()
    let reference = makePipeline(reusesInputs: false)
    var adjustments = ImageAdjustments.identity
    adjustments.exposure = 1.3
    _ = try await pipeline.renderFrame(url: url, maxPixelSize: 512,
      adjustments: adjustments, prefersHDR: false)
    let beforeHDR = await pipeline.decodeReuseSnapshot()
    let hdr = try await pipeline.renderFrame(url: url, maxPixelSize: 512,
      adjustments: adjustments, prefersHDR: true)
    let expectedHDR = try await reference.renderFrame(url: url, maxPixelSize: 512,
      adjustments: adjustments, prefersHDR: true)
    #expect(hdr.image.bitsPerComponent >= 16 && hdr.image.bitmapInfo.contains(.floatComponents))
    #expect(hdr.image.colorSpace?.name == CGColorSpace.extendedLinearDisplayP3)
    try expectSamePixels(hdr, expectedHDR)
    let afterHDR = await pipeline.decodeReuseSnapshot()
    #expect(afterHDR.decodedFrameCount == beforeHDR.decodedFrameCount)
    #expect(afterHDR.reuseCount > beforeHDR.reuseCount)

    let original = try await pipeline.renderFrame(url: url, maxPixelSize: nil,
      adjustments: adjustments, prefersHDR: true)
    let expectedOriginal = try await reference.renderFrame(url: url, maxPixelSize: nil,
      adjustments: adjustments, prefersHDR: true)
    #expect(original.image.width == 1_024 && original.image.height == 768)
    #expect(original.image.bitsPerComponent >= 16)
    try expectSamePixels(original, expectedOriginal)
    let afterOriginal = await pipeline.decodeReuseSnapshot()
    #expect(afterOriginal.decodedFrameCount == afterHDR.decodedFrameCount)
    #expect(afterOriginal.reuseCount == afterHDR.reuseCount)
    #expect(afterOriginal.cache.byteCount == afterHDR.cache.byteCount)
    await pipeline.purgeCaches()
    await reference.purgeCaches()
  }

  @Test("캐시 비우기와 심각한 메모리 압박은 입력과 출력 보유량을 함께 없앤다")
  func purgeAndPressureReleaseInputs() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("pressure.tiff")
    try writeTIFF(url, width: 1_024, height: 768)
    let governor = ImageResourceGovernor(mode: .comfortable, snapshot: machine, storageOverride: .internalSSD)
    let pipeline = ImagePipeline(governor: governor)
    var adjustments = ImageAdjustments.identity
    adjustments.exposure = 0.4
    _ = try await pipeline.renderFrame(url: url, maxPixelSize: 512,
      adjustments: adjustments, prefersHDR: false)
    #expect(await pipeline.decodeReuseSnapshot().cache.byteCount > 0)
    await pipeline.purgeCaches()
    #expect(await pipeline.decodeReuseSnapshot().cache.byteCount == 0)
    #expect(await pipeline.cacheSnapshot().byteCount == 0)

    _ = try await pipeline.renderFrame(url: url, maxPixelSize: 512,
      adjustments: adjustments, prefersHDR: false)
    #expect(await pipeline.decodeReuseSnapshot().cache.byteCount > 0)
    var pressure = machine
    pressure.memoryPressure = .critical
    await governor.update(pressure)
    let limits = await governor.limits(for: url)
    #expect(limits.renderCacheBytes == 0)
    #expect(await pipeline.decodeReuseSnapshot().cache.byteCount == 0)
    #expect(await pipeline.decodeReuseSnapshot().cache.byteLimit == 0)
    #expect(await pipeline.cacheSnapshot().byteCount == 0)
    adjustments.exposure = 0.8
    let uncached = try await pipeline.renderFrame(url: url, maxPixelSize: 512,
      adjustments: adjustments, prefersHDR: false)
    #expect(uncached.image.width > 0)
    #expect(await pipeline.cacheSnapshot().byteCount == 0)
    #expect(await pipeline.decodeReuseSnapshot().cache.byteCount == 0)
    await pipeline.purgeCaches()
  }

  @Test("캐시 비우기 전에 대기하던 요청은 새 입력 캐시를 읽거나 다시 채우지 않는다",
    arguments: [false, true])
  func delayedAdmissionCannotRepopulatePurgedInputs(populateNewGeneration: Bool) async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("admission.tiff")
    try writeTIFF(url, width: 1_024, height: 768, usesP3: true)
    let gate = DecodedInputStorageAdmissionGate()
    let governor = ImageResourceGovernor(mode: .comfortable, snapshot: machine,
      storageResolver: { _ in await gate.resolve() })
    let pipeline = ImagePipeline(governor: governor)
    let reference = makePipeline(reusesInputs: false)
    let adjustments: ImageAdjustments = {
      var value = ImageAdjustments.identity
      value.exposure = 0.8
      return value
    }()
    let load: @Sendable () async throws -> RenderedFrame = {
      try await pipeline.renderFrame(url: url, maxPixelSize: 512,
        adjustments: adjustments, prefersHDR: false)
    }
    let delayed = Task { try await load() }
    defer {
      delayed.cancel()
      Task { await gate.release() }
    }
    // The request has captured its file/cache generation but is not yet admitted
    // to the decoder. No elapsed-time assumption or native decode timing is needed.
    await gate.waitUntilBlocked()
    await pipeline.purgeCaches()
    #expect(await pipeline.cacheSnapshot().entryCount == 0)

    let retained: RenderedFrame?
    if populateNewGeneration {
      retained = try await load()
      #expect(await pipeline.decodeReuseSnapshot().cache.entryCount > 0)
    } else {
      retained = nil
    }
    let beforeInputs = await pipeline.decodeReuseSnapshot()
    let beforeCombined = await pipeline.cacheSnapshot()
    await gate.release()
    let resumed = try await delayed.value
    let expected = try await reference.renderFrame(url: url, maxPixelSize: 512,
      adjustments: adjustments, prefersHDR: false)
    try expectSamePixels(resumed, expected)

    // An older request still returns usable pixels, but cannot adopt the new
    // generation merely because its first decoder lookup happened after purge.
    let afterInputs = await pipeline.decodeReuseSnapshot()
    let afterCombined = await pipeline.cacheSnapshot()
    #expect(afterInputs.cache.entryCount == beforeInputs.cache.entryCount)
    #expect(afterInputs.cache.byteCount == beforeInputs.cache.byteCount)
    #expect(afterInputs.reuseCount == beforeInputs.reuseCount)
    #expect(afterCombined.entryCount == beforeCombined.entryCount)
    #expect(afterCombined.byteCount == beforeCombined.byteCount)

    // Requests created after purge must still retain and reuse their inputs.
    let current = try await load()
    if let retained { #expect(current.image === retained.image) }
    #expect(await pipeline.decodeReuseSnapshot().cache.entryCount > 0)
    var nextAdjustment = adjustments
    nextAdjustment.brightness = 0.1
    let beforeReuse = await pipeline.decodeReuseSnapshot().reuseCount
    _ = try await pipeline.renderFrame(url: url, maxPixelSize: 512,
      adjustments: nextAdjustment, prefersHDR: false)
    #expect(await pipeline.decodeReuseSnapshot().reuseCount > beforeReuse)
    await pipeline.purgeCaches()
    await reference.purgeCaches()
  }

  private func makePipeline(reusesInputs: Bool = true) -> ImagePipeline {
    let governor = ImageResourceGovernor(mode: .comfortable, snapshot: machine, storageOverride: .internalSSD)
    return ImagePipeline(governor: governor, reusesDecodedInputs: reusesInputs)
  }

  private func pipelineGovernorLimits() async -> ImageResourceLimits {
    let governor = ImageResourceGovernor(mode: .comfortable, snapshot: machine, storageOverride: .internalSSD)
    return await governor.limits(for: URL(fileURLWithPath: "/tmp/fixture.tiff"))
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("decoded-input-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func writeTIFF(_ url: URL, width: Int, height: Int,
    usesP3: Bool = false, alternateColors: Bool = false) throws
  {
    let space = try #require(CGColorSpace(name: usesP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    for row in 0..<4 {
      for column in 0..<4 {
        let red = CGFloat(alternateColors ? 4 - column : column + 1) / 5
        let green = CGFloat(row + 1) / 5
        let blue = CGFloat((row + column) % 4 + 1) / 5
        context.setFillColor(CGColor(colorSpace: space, components: [red, green, blue, 0.9])!)
        context.fill(CGRect(x: column * width / 4, y: row * height / 4,
          width: width / 4, height: height / 4))
      }
    }
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
      UTType.tiff.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
  }

  private func expectSamePixels(_ actual: RenderedFrame, _ expected: RenderedFrame) throws {
    #expect(actual.image.width == expected.image.width && actual.image.height == expected.image.height)
    #expect(actual.image.bitsPerComponent == expected.image.bitsPerComponent)
    #expect(actual.image.colorSpace?.name == expected.image.colorSpace?.name)
    #expect(actual.sourcePixelSize == expected.sourcePixelSize)
    let actualPixels = try floatPixels(actual.image)
    let expectedPixels = try floatPixels(expected.image)
    try #require(actualPixels.count == expectedPixels.count)
    #expect(actualPixels.allSatisfy { $0.isFinite })
    #expect(expectedPixels.allSatisfy { $0.isFinite })
    let maximumDifference = zip(actualPixels, expectedPixels).reduce(Float.zero) { max($0, abs($1.0 - $1.1)) }
    #expect(maximumDifference <= 0.000_1, "Input reuse changed rendered pixel values")
  }

  private func floatPixels(_ image: CGImage) throws -> [Float] {
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 32, bytesPerRow: image.width * 4 * MemoryLayout<Float>.size,
      space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let pixels = try #require(context.data).assumingMemoryBound(to: Float.self)
    return Array(UnsafeBufferPointer(start: pixels, count: image.width * image.height * 4))
  }
}

/// Only the first storage lookup waits. A newer generation can be rendered while
/// the older request remains suspended before admission to the shared scheduler.
private actor DecodedInputStorageAdmissionGate {
  private var lookupCount = 0
  private var blocked: CheckedContinuation<Void, Never>?
  private var observer: CheckedContinuation<Void, Never>?

  func resolve() async -> ImageStorageKind {
    lookupCount += 1
    if lookupCount == 1 {
      await withCheckedContinuation { continuation in
        blocked = continuation
        observer?.resume()
        observer = nil
      }
    }
    return .internalSSD
  }

  func waitUntilBlocked() async {
    if blocked != nil { return }
    await withCheckedContinuation { observer = $0 }
  }

  func release() {
    blocked?.resume()
    blocked = nil
  }
}
