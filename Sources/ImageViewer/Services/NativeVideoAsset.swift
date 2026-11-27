@preconcurrency import AVFoundation
import VideoToolbox

/// Use the system's optional VP9 decoder before AVFoundation inspects an asset.
/// Registration is process-wide. Swift's static initialization makes concurrent
/// metadata, thumbnail and player requests share one registration, without a
/// codec probe, extra worker or converted copy for each file.
enum NativeVideoAsset {
  private static let registered: Void = {
    VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
  }()

  static func make(url: URL, preciseTiming: Bool = false) -> AVURLAsset {
    _ = registered
    return AVURLAsset(url: url, options: preciseTiming
      ? [AVURLAssetPreferPreciseDurationAndTimingKey: true] : nil)
  }
}
