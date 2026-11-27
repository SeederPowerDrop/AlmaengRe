import CoreImage
import CoreVideo
import IOSurface
import Metal

/// Immutable after the render task completes. The cache owns the texture, not
/// the source RAW graph, and charges Metal's actual allocation against its
/// existing input allowance. Never reused as a writable render destination.
final class MetalWorkingImage: @unchecked Sendable {
  let image: CIImage
  let byteCount: Int
  let kernelSeconds: Double
  let compileSeconds: Double
  private let texture: any MTLTexture
  private let surface: IOSurface

  fileprivate init(image: CIImage, texture: any MTLTexture, surface: IOSurface, info: CIRenderInfo) {
    self.image = image
    self.texture = texture
    self.surface = surface
    byteCount = max(IOSurfaceGetAllocSize(surface), texture.allocatedSize)
    kernelSeconds = info.kernelExecutionTime
    compileSeconds = info.kernelCompileTime
  }
}

/// One lazily created renderer per existing decoder, retaining its command queue.
/// SDR identity images bypass this object. Older systems and other GPUs keep
/// the previous automatic Core Image path and Float32 CGImage input fallback.
final class MetalImageRenderer {
  private final class Device: @unchecked Sendable {
    static let shared = Device()
    let value = MTLCreateSystemDefaultDevice()
  }

  let context: CIContext
  private let device: (any MTLDevice)?
  private let queue: (any MTLCommandQueue)?

  init(usesMetal: Bool = true) {
    let options: [CIContextOption: Any] = [
      .cacheIntermediates: false, .highQualityDownsample: true,
      .name: "ImageViewer Core Image Decoder",
    ]
    if #available(macOS 15.0, *), usesMetal,
      let device = Device.shared.value, device.hasUnifiedMemory,
      device.supportsFamily(.apple7),
      let queue = device.makeCommandQueue()
    {
      queue.label = "ImageViewer image rendering"
      self.device = device
      self.queue = queue
      context = CIContext(mtlCommandQueue: queue, options: options)
    } else {
      device = nil
      queue = nil
      context = CIContext(options: options)
    }
  }

  func workingImage(_ bitmap: CGImage, canRetain: (Int) -> Bool) throws -> MetalWorkingImage? {
    try Task.checkCancellation()
    // A typed raster boundary preserves CGImage's crop phase, alpha and Float32
    // precision exactly. Rendering arbitrary cropped CI recipes into a texture
    // does not always match CGImage's rasterization, even at an integral extent.
    guard let device, bitmap.bitsPerComponent == 32, bitmap.bitmapInfo.contains(.floatComponents),
      bitmap.width > 0, bitmap.height > 0,
      bitmap.width <= 16_384, bitmap.height <= 16_384 else { return nil }
    let width = bitmap.width, height = bitmap.height
    let extent = CGRect(x: 0, y: 0, width: width, height: height)
    let input = CIImage(cgImage: bitmap)
    // Dimension bounds make arithmetic safe before touching Metal. Check again
    // after allocation: IOSurface/Metal may align storage beyond width*16.
    guard canRetain(width * height * 16) else { return nil }
    let row = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 16)
    guard let surface = IOSurfaceCreate([
      kIOSurfaceWidth: width, kIOSurfaceHeight: height,
      kIOSurfaceBytesPerElement: 16, kIOSurfaceBytesPerRow: row,
      kIOSurfacePixelFormat: kCVPixelFormatType_128RGBAFloat,
      kIOSurfaceAllocSize: row * height,
    ] as CFDictionary), canRetain(IOSurfaceGetAllocSize(surface)) else { return nil }
    // macOS 15 cannot set CIImage headroom after texture initialization. An
    // IOSurface attachment carries it through the documented CIImage surface
    // initializer, including the explicit SDR/unknown cases. Set it once per
    // immutable working plane, never on every adjustment or display update.
    if #available(macOS 15.0, *) {
      IOSurfaceSetValue(surface, kIOSurfaceContentHeadroom, NSNumber(value: input.contentHeadroom))
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
      width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0),
      canRetain(max(IOSurfaceGetAllocSize(surface), texture.allocatedSize)) else { return nil }
    let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    // A caller-owned command buffer forces the entire RAW graph into one buffer.
    // Let CI split work using its own queue, preserving its memory scheduling.
    let destination = CIRenderDestination(ioSurface: surface)
    destination.colorSpace = space
    destination.alphaMode = .premultiplied
    destination.isClamped = false
    destination.isDithered = false
    let task = try context.startTask(toRender: input, from: extent, to: destination, at: .zero)
    // Publish only fully written, immutable pixels; cancellation/purge cannot
    // expose a texture still being modified by the GPU to another decoder.
    let info = try task.waitUntilCompleted()
    try Task.checkCancellation()
    var result = CIImage(ioSurface: surface, options: [.colorSpace: space])
    if #available(macOS 16.0, *) {
      result = result.settingContentHeadroom(input.contentHeadroom)
        .settingContentAverageLightLevel(input.contentAverageLightLevel)
    } else if #available(macOS 15.0, *), result.contentHeadroom != input.contentHeadroom {
      return nil
    }
    return MetalWorkingImage(image: result, texture: texture, surface: surface, info: info)
  }
}
