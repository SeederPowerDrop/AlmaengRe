import Foundation

/// Reusable bitmap costs and compressed thumbnail files, not process-wide RAM
/// or source photo sizes. Reading this snapshot does not open original files.
struct ImageCacheUsage: Sendable {
  let memoryByteCount: Int
  let diskByteCount: Int
  /// A partial scan can retain known bytes, but cannot establish a total size.
  /// A disabled disk cache has a known zero cost.
  let isDiskUsageComplete: Bool

  init(rendered: ImageCacheSnapshot, thumbnails: ImageCacheSnapshot,
    disk: ThumbnailDiskCacheSnapshot?) {
    memoryByteCount = rendered.byteCount + thumbnails.byteCount
    diskByteCount = disk?.byteCount ?? 0
    isDiskUsageComplete = disk?.isComplete ?? true
  }

  var formattedMemorySize: String { Self.formattedBytes(memoryByteCount) }
  var formattedDiskSize: String { Self.formattedBytes(diskByteCount) }

  private static func formattedBytes(_ bytes: Int) -> String {
    // Keep the user's regional number format even when the UI language differs.
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }
}
