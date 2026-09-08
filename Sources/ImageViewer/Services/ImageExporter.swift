import CoreGraphics
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
  case destinationCreationFailed
  case finalizationFailed

  var errorDescription: String? {
    switch self {
    case .formatUnavailable(let format):
      L10n.format("이 macOS에서는 %@ 저장을 지원하지 않습니다.", format.title)
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
    guard ImageFormatRegistry.writableTypeIdentifiers.contains(format.typeIdentifier) else {
      throw ImageExportError.formatUnavailable(format)
    }

    let frame = try await pipeline.renderFrame(
      url: sourceURL,
      maxPixelSize: nil,
      adjustments: adjustments,
      prefersHDR: format == .heic || format == .avif || format == .jpegXL
    )

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

    // Image I/O가 원본 EXIF 회전을 다시 적용하지 않도록 픽셀 방향을 정규화합니다.
    properties[kCGImagePropertyOrientation] = 1
    if format.usesLossyQuality {
      properties[kCGImageDestinationLossyCompressionQuality] = max(0, min(1, quality))
    }

    CGImageDestinationAddImage(destination, frame.image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw ImageExportError.finalizationFailed
    }
  }
}
