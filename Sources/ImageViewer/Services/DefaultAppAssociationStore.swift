import AppKit
import Foundation
import UniformTypeIdentifiers

/// 설정 화면에서 한 번에 선택할 수 있도록 같은 계열의 확장자와 UTI를 묶습니다.
struct DefaultImageFormat: Identifiable, Hashable, Sendable {
  let id: String
  let titleKey: String
  let filenameExtensions: [String]
  let typeIdentifiers: [String]

  var title: String { L10n.text(titleKey) }

  var extensionsDescription: String {
    filenameExtensions.map { ".\($0)" }.joined(separator: " · ")
  }

  /// 일부 Image I/O 형식은 디코더 UTI를 제공하지만 UniformTypeIdentifiers의
  /// 정적 데이터베이스에는 없을 수 있습니다. 그 경우에도 같은 식별자의 가져온
  /// 타입을 만들어 Launch Services에 정확한 연결 요청을 전달합니다.
  var contentTypes: [UTType] {
    typeIdentifiers.map { identifier in
      UTType(identifier) ?? UTType(importedAs: identifier, conformingTo: .image)
    }
  }

  static let all: [Self] = [
    Self(
      id: "jpeg", titleKey: "JPEG 이미지", filenameExtensions: ["jpg", "jpeg", "jpe", "jfif"],
      typeIdentifiers: ["public.jpeg"]),
    Self(
      id: "png", titleKey: "PNG / APNG 이미지", filenameExtensions: ["png", "apng"],
      typeIdentifiers: ["public.png"]),
    Self(
      id: "gif", titleKey: "GIF 이미지", filenameExtensions: ["gif"],
      typeIdentifiers: ["com.compuserve.gif"]),
    Self(
      id: "tiff", titleKey: "TIFF 이미지", filenameExtensions: ["tif", "tiff"],
      typeIdentifiers: ["public.tiff"]),
    Self(
      id: "bmp", titleKey: "BMP 이미지", filenameExtensions: ["bmp", "dib"],
      typeIdentifiers: ["com.microsoft.bmp"]),
    Self(
      id: "heif", titleKey: "HEIC / HEIF 이미지",
      filenameExtensions: ["heic", "heics", "heif", "hif"],
      typeIdentifiers: ["public.heic", "public.heics", "public.heif"]),
    Self(
      id: "webp", titleKey: "WebP 이미지", filenameExtensions: ["webp"],
      typeIdentifiers: ["org.webmproject.webp"]),
    Self(
      id: "avif", titleKey: "AVIF 이미지", filenameExtensions: ["avif", "avifs"],
      typeIdentifiers: ["public.avif", "public.avis", "public.avci"]),
    Self(
      id: "jpeg-xl", titleKey: "JPEG XL 이미지", filenameExtensions: ["jxl"],
      typeIdentifiers: ["public.jpeg-xl"]),
    Self(
      id: "jpeg-2000", titleKey: "JPEG 2000 이미지", filenameExtensions: ["jp2", "j2k", "jpf", "jpx"],
      typeIdentifiers: ["public.jpeg-2000"]),
    Self(
      id: "photoshop", titleKey: "Photoshop 이미지", filenameExtensions: ["psd", "psb"],
      typeIdentifiers: ["com.adobe.photoshop-image"]),
    Self(
      id: "openexr", titleKey: "OpenEXR 이미지", filenameExtensions: ["exr"],
      typeIdentifiers: ["com.ilm.openexr-image"]),
    Self(
      id: "hdr", titleKey: "Radiance HDR 이미지", filenameExtensions: ["hdr", "rgbe"],
      typeIdentifiers: ["public.radiance"]),
    Self(
      id: "tga", titleKey: "TGA 이미지", filenameExtensions: ["tga", "targa"],
      typeIdentifiers: ["com.truevision.tga-image"]),
    Self(
      id: "dds", titleKey: "DDS 이미지", filenameExtensions: ["dds"],
      typeIdentifiers: ["com.microsoft.dds"]),
    Self(
      id: "icons", titleKey: "아이콘 및 커서", filenameExtensions: ["ico", "cur", "icns"],
      typeIdentifiers: ["com.microsoft.ico", "com.microsoft.cur", "com.apple.icns"]),
    Self(
      id: "netpbm", titleKey: "Netpbm 이미지",
      filenameExtensions: ["pnm", "pbm", "pgm", "ppm", "pfm"], typeIdentifiers: ["public.pbm"]),
    Self(
      id: "svg", titleKey: "SVG 이미지", filenameExtensions: ["svg", "svgz"],
      typeIdentifiers: ["public.svg-image"]),
    Self(
      id: "textures", titleKey: "텍스처 이미지", filenameExtensions: ["ktx", "ktx2", "astc", "pvr"],
      typeIdentifiers: ["org.khronos.ktx", "org.khronos.ktx2", "org.khronos.astc", "public.pvr"]),
    Self(
      id: "raw", titleKey: "카메라 RAW 이미지",
      filenameExtensions: ["raw", "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf"],
      typeIdentifiers: rawTypeIdentifiers),
    Self(
      id: "legacy", titleKey: "기타 레거시 이미지", filenameExtensions: ["pict", "sgi", "mpo", "atx"],
      typeIdentifiers: ["com.apple.pict", "com.sgi.sgi-image", "public.mpo-image", "com.apple.atx"]),
    Self(
      id: "qoi", titleKey: "QOI 이미지", filenameExtensions: ["qoi"],
      typeIdentifiers: ["org.openimageviewer.qoi"]),
    Self(
      id: "pcx", titleKey: "PCX 이미지", filenameExtensions: ["pcx"],
      typeIdentifiers: ["org.openimageviewer.pcx"]),
  ]

  private static let rawTypeIdentifiers = [
    "public.camera-raw-image", "com.adobe.raw-image", "com.canon.cr2-raw-image",
    "com.canon.cr3-raw-image", "com.canon.crw-raw-image", "com.canon.tif-raw-image",
    "com.dxo.raw-image", "com.epson.raw-image", "com.fuji.raw-image",
    "com.hasselblad.3fr-raw-image", "com.hasselblad.fff-raw-image",
    "com.kodak.raw-image", "com.konicaminolta.raw-image", "com.leafamerica.raw-image",
    "com.leica.raw-image", "com.leica.rwl-raw-image", "com.nikon.nefx-raw-image",
    "com.nikon.nrw-raw-image", "com.nikon.raw-image", "com.olympus.or-raw-image",
    "com.olympus.raw-image", "com.olympus.sr-raw-image", "com.panasonic.raw-image",
    "com.panasonic.rw2-raw-image", "com.pentax.raw-image", "com.phaseone.raw-image",
    "com.samsung.raw-image", "com.sony.arw-raw-image", "com.sony.axr-raw-image",
    "com.sony.raw-image", "com.sony.sr2-raw-image",
  ]
}

enum DefaultAppCoverage: Equatable, Sendable {
  case none
  case partial
  case all
}

enum DefaultAppAssociationError: LocalizedError {
  case noSelection
  case applicationBundleRequired
  case noSupportedContentTypes
  case someTypesFailed(successCount: Int, failureCount: Int)

  var errorDescription: String? {
    switch self {
    case .noSelection:
      L10n.text("연결할 이미지 형식을 하나 이상 선택해 주세요.")
    case .applicationBundleRequired:
      L10n.text("기본 앱 연결은 배포된 이미지뷰어.app을 실행했을 때 사용할 수 있습니다.")
    case .noSupportedContentTypes:
      L10n.text("이 macOS에서 연결할 수 있는 이미지 형식을 찾지 못했습니다.")
    case .someTypesFailed(let successCount, let failureCount):
      L10n.format("%d개 연결에 성공했고 %d개 연결에 실패했습니다.", successCount, failureCount)
    }
  }
}

/// macOS의 공식 NSWorkspace API로 사용자가 고른 콘텐츠 타입만 기본 앱으로 연결합니다.
@MainActor
final class DefaultAppAssociationStore: ObservableObject {
  @Published var selectedFormatIDs: Set<String> {
    didSet {
      UserDefaults.standard.set(Array(selectedFormatIDs).sorted(), forKey: Self.selectionKey)
    }
  }
  @Published private(set) var defaultTypeIdentifiers: Set<String> = []
  @Published private(set) var isApplying = false
  @Published private(set) var statusMessage: String?

  let formats = DefaultImageFormat.all

  private static let selectionKey = "ImageViewer.DefaultFormatSelection.v1"

  init() {
    selectedFormatIDs = Set(
      UserDefaults.standard.stringArray(forKey: Self.selectionKey) ?? []
    )
    refresh()
  }

  func isSelected(_ format: DefaultImageFormat) -> Bool {
    selectedFormatIDs.contains(format.id)
  }

  func setSelected(_ selected: Bool, format: DefaultImageFormat) {
    if selected {
      selectedFormatIDs.insert(format.id)
    } else {
      selectedFormatIDs.remove(format.id)
    }
  }

  func selectAll() {
    selectedFormatIDs = Set(formats.map(\.id))
  }

  func clearSelection() {
    selectedFormatIDs.removeAll()
  }

  func coverage(for format: DefaultImageFormat) -> DefaultAppCoverage {
    let matchCount = format.typeIdentifiers.filter(defaultTypeIdentifiers.contains).count
    if matchCount == 0 { return .none }
    return matchCount == format.typeIdentifiers.count ? .all : .partial
  }

  func refresh() {
    let identifiers = Set(formats.flatMap(\.typeIdentifiers))
    defaultTypeIdentifiers = Set(identifiers.filter(isCurrentApplicationDefault))
  }

  func applySelected() async throws {
    let selectedFormats = formats.filter { selectedFormatIDs.contains($0.id) }
    guard !selectedFormats.isEmpty else {
      throw DefaultAppAssociationError.noSelection
    }

    let applicationURL = Bundle.main.bundleURL
    guard applicationURL.pathExtension.lowercased() == "app" else {
      throw DefaultAppAssociationError.applicationBundleRequired
    }

    let contentTypes = selectedFormats.flatMap(\.contentTypes)
    guard !contentTypes.isEmpty else {
      throw DefaultAppAssociationError.noSupportedContentTypes
    }

    isApplying = true
    statusMessage = nil
    defer { isApplying = false }

    var successCount = 0
    var failureCount = 0
    for contentType in contentTypes {
      do {
        try await setDefaultApplication(applicationURL, for: contentType)
        successCount += 1
      } catch {
        failureCount += 1
      }
    }

    refresh()
    guard failureCount == 0 else {
      throw DefaultAppAssociationError.someTypesFailed(
        successCount: successCount,
        failureCount: failureCount
      )
    }
    statusMessage = L10n.format("선택한 %d개 이미지 형식을 이미지뷰어에 연결했습니다.", selectedFormats.count)
  }

  private func isCurrentApplicationDefault(_ identifier: String) -> Bool {
    let type = UTType(identifier) ?? UTType(importedAs: identifier, conformingTo: .image)
    guard let defaultURL = NSWorkspace.shared.urlForApplication(toOpen: type) else {
      return false
    }

    let currentIdentifier = Bundle.main.bundleIdentifier
    if let currentIdentifier,
      Bundle(url: defaultURL)?.bundleIdentifier == currentIdentifier
    {
      return true
    }
    return defaultURL.resolvingSymlinksInPath().standardizedFileURL
      == Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
  }

  private func setDefaultApplication(_ applicationURL: URL, for contentType: UTType) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpen: contentType) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: ())
        }
      }
    }
  }
}
