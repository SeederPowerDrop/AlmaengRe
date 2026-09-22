import CoreGraphics
import CoreML
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct AIUpscalingResult: @unchecked Sendable {
  let sourceURL: URL
  let sourceVersion: ImageFileVersion
  let original: CGImage
  let image: CGImage
}

/// One actor owns the model and executes one bounded tile at a time. Inference
/// never runs on the UI actor; no image is uploaded or downloaded at runtime.
actor AIUpscalingService {
  private var model: MLModel?
  private var compiledURL: URL?
  private let modelURL: URL?
  private let usesCPUOnly: Bool

  init(modelURL: URL? = AIUpscalingService.bundledModelURL(), usesCPUOnly: Bool = false) {
    self.modelURL = modelURL
    self.usesCPUOnly = usesCPUOnly
  }

  deinit {
    if let compiledURL { try? FileManager.default.removeItem(at: compiledURL) }
  }

  nonisolated static func bundledModelURL() -> URL? {
    for bundle in [Bundle.main, Bundle.module] {
      if let url = bundle.url(forResource: "QuickSRNetSmall2x", withExtension: "mlmodel",
        subdirectory: "AIModels") ?? bundle.url(forResource: "QuickSRNetSmall2x", withExtension: "mlmodel")
      { return url }
    }
    return nil
  }

  func upscale(_ frame: RenderedFrame, sourceURL: URL, sourceVersion: ImageFileVersion,
    progress: @Sendable (Double) -> Void = { _ in }) throws -> AIUpscalingResult
  {
    try Task.checkCancellation()
    let width = frame.image.width
    let height = frame.image.height
    let size = try AIUpscalingPolicy.outputSize(width: width, height: height)
    _ = try loadModel()
    let source = try Self.rgbaPixels(frame.image)
    var output = [UInt8](repeating: 0, count: size.width * size.height * 4)
    let tileSize = AIUpscalingPolicy.tileSize
    let contentSize = AIUpscalingPolicy.tileContentSize
    let halo = AIUpscalingPolicy.halo
    let tileOutputSize = tileSize * 2
    let plane = tileSize * tileSize
    let xTiles = (width + contentSize - 1) / contentSize
    let yTiles = (height + contentSize - 1) / contentSize
    var completed = 0

    for originY in stride(from: 0, to: height, by: contentSize) {
      for originX in stride(from: 0, to: width, by: contentSize) {
        try Task.checkCancellation()
        try autoreleasepool {
          let input = try MLMultiArray(shape: [1, 3, NSNumber(value: tileSize), NSNumber(value: tileSize)],
            dataType: .float32)
          let inputPointer = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
          for y in 0..<tileSize {
            let sourceY = min(max(originY + y - halo, 0), height - 1)
            for x in 0..<tileSize {
              let sourceX = min(max(originX + x - halo, 0), width - 1)
              let offset = (sourceY * width + sourceX) * 4
              let alpha = Float(source[offset + 3])
              for channel in 0..<3 {
                // Core Graphics uses premultiplied RGBA; the model expects RGB.
                inputPointer[channel * plane + y * tileSize + x] = alpha > 0
                  ? min(1, Float(source[offset + channel]) / alpha) : 0
              }
            }
          }
          let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)])
          let prediction = try predict(features)
          guard let values = prediction.featureValue(for: "upscaled")?.multiArrayValue,
            values.dataType == .float32, values.shape.map(\.intValue) == [1, 3, tileOutputSize, tileOutputSize]
          else { throw AIUpscalingError.invalidModelOutput }
          let pointer = values.dataPointer.bindMemory(to: Float.self, capacity: values.count)
          let strides = values.strides.map(\.intValue)
          let copyWidth = min(contentSize, width - originX) * 2
          let copyHeight = min(contentSize, height - originY) * 2
          for y in 0..<copyHeight {
            for x in 0..<copyWidth {
              let outputX = originX * 2 + x
              let outputY = originY * 2 + y
              let alpha = Self.interpolatedAlpha(source, width: width, height: height,
                outputX: outputX, outputY: outputY)
              let offset = (outputY * size.width + outputX) * 4
              for channel in 0..<3 {
                let value = pointer[channel * strides[1] + (y + halo * 2) * strides[2]
                  + (x + halo * 2) * strides[3]]
                guard value.isFinite else { throw AIUpscalingError.invalidModelOutput }
                output[offset + channel] = UInt8((min(max(value, 0), 1) * alpha).rounded())
              }
              output[offset + 3] = UInt8(alpha.rounded())
            }
          }
        }
        completed += 1
        progress(Double(completed) / Double(xTiles * yTiles))
      }
    }
    try Task.checkCancellation()
    let data = Data(output) as CFData
    guard let provider = CGDataProvider(data: data),
      let image = CGImage(width: size.width, height: size.height, bitsPerComponent: 8,
        bitsPerPixel: 32, bytesPerRow: size.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: Self.bitmapInfo,
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw AIUpscalingError.pixelConversionFailed }
    return AIUpscalingResult(sourceURL: sourceURL, sourceVersion: sourceVersion,
      original: frame.image, image: image)
  }

  private func loadModel() throws -> MLModel {
    if let model { return model }
    guard let modelURL else { throw AIUpscalingError.modelUnavailable }
    let compiled = try MLModel.compileModel(at: modelURL)
    compiledURL = compiled
    let configuration = MLModelConfiguration()
    configuration.computeUnits = usesCPUOnly ? .cpuOnly : .all
    do {
      let result = try MLModel(contentsOf: compiled, configuration: configuration)
      model = result
      return result
    } catch {
      configuration.computeUnits = .cpuOnly
      let result = try MLModel(contentsOf: compiled, configuration: configuration)
      model = result
      return result
    }
  }

  private func predict(_ input: MLFeatureProvider) throws -> MLFeatureProvider {
    guard let model else { throw AIUpscalingError.modelUnavailable }
    do { return try model.prediction(from: input) }
    catch {
      guard !usesCPUOnly, let compiledURL else { throw error }
      let configuration = MLModelConfiguration()
      configuration.computeUnits = .cpuOnly
      let fallback = try MLModel(contentsOf: compiledURL, configuration: configuration)
      self.model = fallback
      return try fallback.prediction(from: input)
    }
  }

  private static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    .union(.byteOrder32Big)

  private static func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let success = pixels.withUnsafeMutableBytes { bytes in
      guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    guard success else { throw AIUpscalingError.pixelConversionFailed }
    return pixels
  }

  private static func interpolatedAlpha(_ source: [UInt8], width: Int, height: Int,
    outputX: Int, outputY: Int) -> Float
  {
    let x = Float(outputX) / 2 - 0.25
    let y = Float(outputY) / 2 - 0.25
    let x0 = Int(floor(x)), y0 = Int(floor(y))
    let fx = x - Float(x0), fy = y - Float(y0)
    func alpha(_ px: Int, _ py: Int) -> Float {
      Float(source[(min(max(py, 0), height - 1) * width + min(max(px, 0), width - 1)) * 4 + 3])
    }
    return (alpha(x0, y0) * (1 - fx) + alpha(x0 + 1, y0) * fx) * (1 - fy)
      + (alpha(x0, y0 + 1) * (1 - fx) + alpha(x0 + 1, y0 + 1) * fx) * fy
  }

  func savePNG(_ result: AIUpscalingResult, to destinationURL: URL) throws {
    guard !Self.sameFile(result.sourceURL, destinationURL) else { throw AIUpscalingError.sourceOverwrite }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { throw AIUpscalingError.saveFailed }
    CGImageDestinationAddImage(destination, result.image, [kCGImagePropertyOrientation: 1,
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFSoftware: "AlmaengRe · QuickSRNet Small 2x"]] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw AIUpscalingError.saveFailed }
    try Task.checkCancellation()
    guard !Self.sameFile(result.sourceURL, destinationURL) else { throw AIUpscalingError.sourceOverwrite }
    try (data as Data).write(to: destinationURL, options: .atomic)
  }

  private nonisolated static func sameFile(_ source: URL, _ destination: URL) -> Bool {
    if source.standardizedFileURL.resolvingSymlinksInPath()
      == destination.standardizedFileURL.resolvingSymlinksInPath() { return true }
    var first = stat(), second = stat()
    return source.resolvingSymlinksInPath().path.withCString { Darwin.lstat($0, &first) } == 0
      && destination.resolvingSymlinksInPath().path.withCString { Darwin.lstat($0, &second) } == 0
      && first.st_dev == second.st_dev && first.st_ino == second.st_ino
  }
}
