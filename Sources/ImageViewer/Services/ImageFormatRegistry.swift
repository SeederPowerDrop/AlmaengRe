import ImageIO
import UniformTypeIdentifiers

/// 운영체제가 지원하는 코덱과 앱 자체 코덱을 한곳에서 관리합니다.
///
/// Image I/O의 지원 목록은 macOS 버전에 따라 늘어나므로 하드코딩한 UTI 대신
/// 런타임에 조회합니다. 확장자 집합은 폴더 스캔을 빠르게 하기 위한 1차 필터입니다.
enum ImageFormatRegistry {
  static let readableTypeIdentifiers: Set<String> = {
    let identifiers = CGImageSourceCopyTypeIdentifiers() as NSArray
    return Set(identifiers.compactMap { $0 as? String })
  }()

  static let writableTypeIdentifiers: Set<String> = {
    let identifiers = CGImageDestinationCopyTypeIdentifiers() as NSArray
    return Set(identifiers.compactMap { $0 as? String })
  }()

  /// macOS 15의 Image I/O와 자체 QOI/PCX 디코더가 실제로 시도할 수 있는 확장자입니다.
  static let knownExtensions: Set<String> = [
    "jpg", "jpeg", "jpe", "jfif", "png", "apng", "gif", "webp",
    "heic", "heif", "heics", "hif", "avif", "avifs", "jxl",
    "jp2", "j2k", "jpf", "jpx", "tif", "tiff", "bmp", "dib",
    "ico", "cur", "icns", "tga", "targa", "dds", "exr", "hdr",
    "rgbe", "pnm", "pbm", "pgm", "ppm", "pfm", "psd", "psb",
    "svg", "svgz", "qoi", "pcx", "ktx", "ktx2", "astc", "pvr",
    "sgi", "rgb", "rgba", "bw", "pict", "pic", "mpo",
    "raw", "dng", "cr2", "cr3", "crw", "nef", "nefx", "nrw",
    "arw", "sr2", "srf", "orf", "rw2", "raf", "pef", "iiq",
    "3fr", "fff", "rwl", "x3f", "erf", "mrw", "mos", "kdc",
    "dcr", "mef", "bay", "cap",
  ]

  static func canAttemptToDecode(_ url: URL) -> Bool {
    guard !url.hasDirectoryPath else { return false }

    if knownExtensions.contains(url.pathExtension.lowercased()) {
      return true
    }

    let values = try? url.resourceValues(forKeys: [.contentTypeKey])
    return values?.contentType?.conforms(to: .image) == true
  }

  static var nativeFormatNames: [String] {
    readableTypeIdentifiers
      .compactMap { UTType($0)?.preferredFilenameExtension }
      .map { $0.uppercased() }
      .sorted()
  }
}
