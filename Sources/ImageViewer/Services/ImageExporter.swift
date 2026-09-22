import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
  case jpeg
  case png
  case heic
  case tiff
  case webp
  case avif
  case jpegXL

  var id: Self { self }

  var title: String {
    switch self {
    case .jpeg: "JPEG"
    case .png: "PNG"
    case .heic: "HEIC"
    case .tiff: "TIFF"
    case .webp: "WebP"
    case .avif: "AVIF"
    case .jpegXL: "JPEG XL"
    }
  }

  var fileExtension: String {
    switch self {
    case .jpeg: "jpg"
    case .jpegXL: "jxl"
    default: rawValue
    }
  }

  var typeIdentifier: String {
    switch self {
    case .jpeg: UTType.jpeg.identifier
    case .png: UTType.png.identifier
    case .heic: UTType.heic.identifier
    case .tiff: UTType.tiff.identifier
    case .webp: "org.webmproject.webp"
    case .avif: "public.avif"
    case .jpegXL: "public.jpeg-xl"
    }
  }

  var usesLossyQuality: Bool {
    switch self {
    case .jpeg, .heic, .webp, .avif, .jpegXL: true
    case .png, .tiff: false
    }
  }

  static var available: [ExportFormat] {
    allCases.filter { ImageFormatRegistry.writableTypeIdentifiers.contains($0.typeIdentifier) }
  }
}

enum ImageExportError: LocalizedError {
  case formatUnavailable(ExportFormat)
  case sourceOverwrite
  case destinationCreationFailed
  case finalizationFailed

  var errorDescription: String? {
    switch self {
    case .formatUnavailable(let format):
      L10n.format("이 macOS에서는 %@ 저장을 지원하지 않습니다.", format.title)
    case .sourceOverwrite: L10n.text("원본 파일을 덮어쓰는 변환은 허용되지 않습니다.")
    case .destinationCreationFailed: L10n.text("출력 파일을 만들 수 없습니다.")
    case .finalizationFailed: L10n.text("이미지 파일 저장을 마무리하지 못했습니다.")
    }
  }
}

/// 화면 보정과 동일한 파이프라인을 원본 해상도로 적용한 뒤 새 파일로 저장합니다.
actor ImageExporter {
  private let pipeline: ImagePipeline

  init(pipeline: ImagePipeline) {
    self.pipeline = pipeline
  }

  func export(
    sourceURL: URL,
    destinationURL: URL,
    format: ExportFormat,
    quality: Double,
    adjustments: ImageAdjustments
  ) async throws {
    guard !refersToSameFile(sourceURL, destinationURL) else {
      throw ImageExportError.sourceOverwrite
    }
    guard ImageFormatRegistry.writableTypeIdentifiers.contains(format.typeIdentifier) else {
      throw ImageExportError.formatUnavailable(format)
    }

    let frame = try await pipeline.renderFrame(
      url: sourceURL,
      maxPixelSize: nil,
      adjustments: adjustments,
      prefersHDR: format == .heic || format == .avif || format == .jpegXL
    )

    // 정밀 렌더를 기다리는 동안 저장 경로의 링크가 달라졌을 수도 있어 쓰기 직전 다시 확인합니다.
    guard !refersToSameFile(sourceURL, destinationURL) else {
      throw ImageExportError.sourceOverwrite
    }
    guard
      let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL,
        format.typeIdentifier as CFString,
        1,
        nil
      )
    else {
      throw ImageExportError.destinationCreationFailed
    }

    var properties: [CFString: Any] = [:]
    if let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    {
      properties = sourceProperties
    }

    // 보정 결과는 이미 올바른 방향의 픽셀이므로 원본의 방향·치수를 재사용하지 않습니다.
    properties[kCGImagePropertyOrientation] = 1
    properties[kCGImagePropertyPixelWidth] = frame.image.width
    properties[kCGImagePropertyPixelHeight] = frame.image.height
    var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    exif[kCGImagePropertyExifPixelXDimension] = frame.image.width
    exif[kCGImagePropertyExifPixelYDimension] = frame.image.height
    properties[kCGImagePropertyExifDictionary] = exif
    if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
      tiff[kCGImagePropertyTIFFOrientation] = 1
      properties[kCGImagePropertyTIFFDictionary] = tiff
    }
    // 원본 미리보기와 픽셀 형식 정보 대신 새 이미지로부터 메타데이터를 만듭니다.
    properties.removeValue(forKey: kCGImagePropertyThumbnailImages)
    properties.removeValue(forKey: kCGImagePropertyDepth)
    properties.removeValue(forKey: kCGImagePropertyColorModel)
    properties.removeValue(forKey: kCGImagePropertyProfileName)
    properties.removeValue(forKey: kCGImagePropertyHasAlpha)
    if format.usesLossyQuality {
      properties[kCGImageDestinationLossyCompressionQuality] = max(0, min(1, quality))
    }

    CGImageDestinationAddImage(destination, frame.image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw ImageExportError.finalizationFailed
    }
  }

  private func refersToSameFile(_ sourceURL: URL, _ destinationURL: URL) -> Bool {
    let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
    let destination = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
    if source == destination { return true }

    // 경로가 다른 하드 링크와 대소문자 별칭도 파일시스템의 실제 파일 식별자로 비교합니다.
    var sourceInfo = stat()
    var destinationInfo = stat()
    let sourceResult = source.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.lstat(path, &sourceInfo)
    }
    let destinationResult = destination.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.lstat(path, &destinationInfo)
    }
    return sourceResult == 0 && destinationResult == 0
      && sourceInfo.st_dev == destinationInfo.st_dev && sourceInfo.st_ino == destinationInfo.st_ino
  }
}
