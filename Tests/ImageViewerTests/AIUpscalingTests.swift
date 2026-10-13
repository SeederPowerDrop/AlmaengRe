import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import ImageViewer

@Suite(.serialized)
struct AIUpscalingTests {
  @Test("AI output size rejects overflow, invalid headers and memory pressure")
  func dimensions() throws {
    let size = try AIUpscalingPolicy.outputSize(width: 2000, height: 1500, physicalMemory: 8_000_000_000)
    #expect(size.width == 4000 && size.height == 3000)
    #expect(throws: AIUpscalingError.self) { try AIUpscalingPolicy.outputSize(width: 0, height: 1) }
    #expect(throws: AIUpscalingError.self) { try AIUpscalingPolicy.outputSize(width: Int.max, height: 2) }
    #expect(throws: AIUpscalingError.self) { try AIUpscalingPolicy.outputSize(width: 10_000, height: 10_000) }
    #expect(throws: AIUpscalingError.self) {
      try AIUpscalingPolicy.outputSize(width: 2000, height: 1500, physicalMemory: 128_000_000)
    }
  }

  @Test("Bundled AI model is the verified learned checkpoint conversion")
  func bundledModelIdentity() throws {
    let url = try #require(AIUpscalingService.bundledModelURL())
    let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    #expect(hash == "0ea55c7669a8663356100c6a2dd45c2efe5d753141e868ec69390486c8c0f43a")
  }

  @Test("Packaged AI resources resolve without evaluating the SwiftPM fallback")
  func packagedModelDoesNotEvaluateFallback() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let appURL = directory.appendingPathComponent("Packaged.app")
    let contents = appURL.appendingPathComponent("Contents")
    let models = contents.appendingPathComponent("Resources/AIModels")
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let info: [String: String] = [
      "CFBundleIdentifier": "org.openimageviewer.tests.packaged-model.\(UUID().uuidString)",
      "CFBundlePackageType": "APPL",
      "CFBundleName": "Packaged"
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))
    let source = try #require(AIUpscalingService.bundledModelURL())
    let destination = models.appendingPathComponent("QuickSRNetSmall2x.mlmodel")
    try FileManager.default.copyItem(at: source, to: destination)
    let mainBundle = try #require(Bundle(url: appURL))
    var evaluatedFallback = false

    let resolved = AIUpscalingService.bundledModelURL(mainBundle: mainBundle, fallbackBundle: {
      evaluatedFallback = true
      return mainBundle
    })

    #expect(!evaluatedFallback)
    #expect(resolved?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath())
  }

  @Test("Missing model reports an error rather than interpolating a fake AI result")
  func missingModel() async throws {
    let source = URL(fileURLWithPath: "/tmp/ai-missing-source.png")
    let image = try fixture(width: 12, height: 10)
    let service = AIUpscalingService(modelURL: nil)
    await #expect(throws: AIUpscalingError.self) {
      try await service.upscale(RenderedFrame(image: image, frameIndex: 0, frameCount: 1, duration: nil),
        sourceURL: source, sourceVersion: ImageFileVersion(url: source))
    }
  }

  @Test("Real CPU inference spans tiles, preserves transparency and saves only a copy")
  func actualInferenceAndExport() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.png")
    let sourceData = Data("original bytes must survive".utf8)
    try sourceData.write(to: source)
    let original = try fixture(width: 123, height: 125)
    let service = AIUpscalingService(usesCPUOnly: true)
    let result = try await service.upscale(
      RenderedFrame(image: original, frameIndex: 0, frameCount: 1, duration: nil),
      sourceURL: source, sourceVersion: ImageFileVersion(url: source))
    #expect(result.image.width == 246)
    #expect(result.image.height == 250)
    #expect(result.image.colorSpace?.name == CGColorSpace.sRGB)
    let pixels = try #require(result.image.dataProvider?.data) as Data
    // The first three input columns are transparent; the last ones are opaque.
    #expect(pixels[3] == 0)
    #expect(pixels[(245 * 4) + 3] == 255)
    // Adjacent output pixels do not simply duplicate one input sample.
    var learnedDifferences = 0
    for y in 20..<220 {
      for x in stride(from: 20, to: 220, by: 2) {
        if pixels[(y * 246 + x) * 4] != pixels[(y * 246 + x + 1) * 4] { learnedDifferences += 1 }
      }
    }
    #expect(learnedDifferences > 100)
    await #expect(throws: AIUpscalingError.self) { try await service.savePNG(result, to: source) }
    let hardLink = directory.appendingPathComponent("alias.png")
    try FileManager.default.linkItem(at: source, to: hardLink)
    await #expect(throws: AIUpscalingError.self) { try await service.savePNG(result, to: hardLink) }
    let symlink = directory.appendingPathComponent("symlink.png")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
    await #expect(throws: AIUpscalingError.self) { try await service.savePNG(result, to: symlink) }
    #expect(try Data(contentsOf: source) == sourceData)
    let destination = directory.appendingPathComponent("source-AI-2x.png")
    try await service.savePNG(result, to: destination)
    let saved = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(saved, 0, nil))
    #expect(image.width == 246 && image.height == 250)
  }

  @Test("Cancelled inference cannot return a new image")
  func cancellation() async throws {
    let frame = RenderedFrame(image: try fixture(width: 10, height: 10),
      frameIndex: 0, frameCount: 1, duration: nil)
    let source = URL(fileURLWithPath: "/tmp/ai-cancel-source.png")
    let operation = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await AIUpscalingService(usesCPUOnly: true).upscale(frame,
        sourceURL: source, sourceVersion: ImageFileVersion(url: source))
    }
    await #expect(throws: CancellationError.self) { try await operation.value }
  }

  @MainActor
  @Test("Switching source invalidates in-flight AI work and clears stale UI state")
  func sourceReplacement() async {
    let store = AIUpscalingStore(pipeline: ImagePipeline())
    store.prepare(sourceURL: URL(fileURLWithPath: "/tmp/ai-old-source.png"))
    store.start()
    let next = URL(fileURLWithPath: "/tmp/ai-new-source.png")
    store.prepare(sourceURL: next)
    await Task.yield()
    #expect(store.sourceURL == next)
    #expect(store.result == nil)
    #expect(!store.isRunning)
    #expect(store.errorMessage == nil)
    #expect(store.progress == 0)
  }

  private func fixture(width: Int, height: Int) throws -> CGImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let offset = (y * width + x) * 4
        let alpha: UInt8 = x < 3 ? 0 : 255
        pixels[offset] = alpha == 0 ? 0 : UInt8((x * 11 + y * 7) % 256)
        pixels[offset + 1] = alpha == 0 ? 0 : UInt8((x * 5 + y * 13) % 256)
        pixels[offset + 2] = alpha == 0 ? 0 : UInt8((x * 17 + y * 3) % 256)
        pixels[offset + 3] = alpha
      }
    }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    return try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
      bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
  }
}
