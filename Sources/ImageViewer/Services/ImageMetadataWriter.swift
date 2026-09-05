import Foundation
import ImageIO

enum ImageMetadataWriterError: LocalizedError {
  case noCurrentImage
  case sourceUnavailable(URL)
  case filenameAlreadyExists(String)
  case embeddedMetadataUnsupported(URL)
  case metadataFieldUnsupported(String)
  case metadataWriteFailed(String)

  var errorDescription: String? {
    switch self {
    case .noCurrentImage:
      "편집할 이미지가 선택되지 않았습니다."
    case .sourceUnavailable(let url):
      "‘\(url.lastPathComponent)’ 파일을 읽을 수 없습니다."
    case .filenameAlreadyExists(let filename):
      "같은 폴더에 ‘\(filename)’ 파일이 이미 있습니다."
    case .embeddedMetadataUnsupported(let url):
      "‘.\(url.pathExtension.lowercased())’ 형식은 내장 메타데이터를 안전하게 수정할 수 없습니다. 파일 이름과 수정일만 바꿀 수 있습니다."
    case .metadataFieldUnsupported(let field):
      "이 이미지 형식은 ‘\(field)’ 메타데이터 기록을 지원하지 않습니다."
    case .metadataWriteFailed(let message):
      "메타데이터를 저장하지 못했습니다. \(message)"
    }
  }
}

/// Image I/O의 무손실 복사 API로 픽셀 스트림은 그대로 두고 메타데이터만 교체합니다.
actor ImageMetadataWriter {
  static func supportsEmbeddedMetadata(typeIdentifier: String?) -> Bool {
    guard let typeIdentifier else { return false }
    let identifiers = CGImageDestinationCopyTypeIdentifiers() as NSArray
    return identifiers.contains(typeIdentifier)
  }

  func apply(
    _ update: ImageMetadataUpdate,
    replacing original: ImageMetadataUpdate,
    to sourceURL: URL
  ) throws -> URL {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: sourceURL.path) else {
      throw ImageMetadataWriterError.sourceUnavailable(sourceURL)
    }

    let destinationURL = sourceURL.deletingLastPathComponent()
      .appendingPathComponent(update.filename, isDirectory: false)
    let isRenaming = destinationURL.path != sourceURL.path
    if isRenaming, fileManager.fileExists(atPath: destinationURL.path) {
      throw ImageMetadataWriterError.filenameAlreadyExists(update.filename)
    }

    if update.metadata != original.metadata {
      try replaceEmbeddedMetadata(
        at: sourceURL,
        original: original.metadata,
        updated: update.metadata
      )
    }

    if isRenaming {
      try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    do {
      try fileManager.setAttributes(
        [.modificationDate: update.modificationDate],
        ofItemAtPath: destinationURL.path
      )
    } catch {
      // 이름 변경에는 성공했지만 날짜 기록이 실패하면 가능한 경우 원래 이름으로
      // 되돌립니다. 어느 경로에서도 이미지 데이터 자체를 삭제하지 않습니다.
      if isRenaming, !fileManager.fileExists(atPath: sourceURL.path) {
        try? fileManager.moveItem(at: destinationURL, to: sourceURL)
      }
      throw error
    }

    return destinationURL
  }

  private func replaceEmbeddedMetadata(
    at sourceURL: URL,
    original: EditableImageMetadata,
    updated: EditableImageMetadata
  ) throws {
    let fileManager = FileManager.default
    let temporaryURL = sourceURL.deletingLastPathComponent()
      .appendingPathComponent(
        ".imageviewer-metadata-\(UUID().uuidString).\(sourceURL.pathExtension)",
        isDirectory: false
      )
    defer { try? fileManager.removeItem(at: temporaryURL) }

    try encodeMetadataCopy(
      sourceURL: sourceURL,
      destinationURL: temporaryURL,
      original: original,
      updated: updated
    )

    // 임시 파일 생성이 완전히 성공한 뒤에만 원본 경로를 교체합니다.
    _ = try fileManager.replaceItemAt(
      sourceURL,
      withItemAt: temporaryURL,
      backupItemName: nil,
      options: []
    )
  }

  private func encodeMetadataCopy(
    sourceURL: URL,
    destinationURL: URL,
    original: EditableImageMetadata,
    updated: EditableImageMetadata
  ) throws {
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let type = CGImageSourceGetType(source)
    else {
      throw ImageMetadataWriterError.sourceUnavailable(sourceURL)
    }
    guard
      Self.supportsEmbeddedMetadata(typeIdentifier: type as String),
      let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL,
        type,
        CGImageSourceGetCount(source),
        nil
      )
    else {
      throw ImageMetadataWriterError.embeddedMetadataUnsupported(sourceURL)
    }

    let metadata =
      CGImageSourceCopyMetadataAtIndex(source, 0, nil)
      .flatMap(CGImageMetadataCreateMutableCopy)
      ?? CGImageMetadataCreateMutable()
    try applyChanges(to: metadata, original: original, updated: updated)

    var options: [CFString: Any] = [
      kCGImageDestinationMetadata: metadata
    ]
    if original.location != nil, updated.location == nil {
      options[kCGImageMetadataShouldExcludeGPS] = true
    }
    if #available(macOS 14.1, *) {
      // HEIF/HEIC의 HDR gain map도 픽셀 스트림과 함께 보존합니다.
      options[kCGImageDestinationPreserveGainMap] = true
    }

    var unmanagedError: Unmanaged<CFError>?
    guard
      CGImageDestinationCopyImageSource(
        destination,
        source,
        options as CFDictionary,
        &unmanagedError
      )
    else {
      let message =
        unmanagedError?.takeRetainedValue().localizedDescription
        ?? "Image I/O가 이 형식의 무손실 메타데이터 복사를 거부했습니다."
      throw ImageMetadataWriterError.metadataWriteFailed(message)
    }
  }

  private func applyChanges(
    to metadata: CGMutableImageMetadata,
    original: EditableImageMetadata,
    updated: EditableImageMetadata
  ) throws {
    try updateValue(
      original.imageDescription,
      updated.imageDescription,
      in: metadata,
      dictionary: kCGImagePropertyTIFFDictionary,
      property: kCGImagePropertyTIFFImageDescription,
      field: "설명"
    ) { $0 as NSString }
    try updateValue(
      original.copyright,
      updated.copyright,
      in: metadata,
      dictionary: kCGImagePropertyTIFFDictionary,
      property: kCGImagePropertyTIFFCopyright,
      field: "저작권"
    ) { $0 as NSString }
    try updateValue(
      original.cameraMake,
      updated.cameraMake,
      in: metadata,
      dictionary: kCGImagePropertyTIFFDictionary,
      property: kCGImagePropertyTIFFMake,
      field: "카메라 제조사"
    ) { $0 as NSString }
    try updateValue(
      original.cameraModel,
      updated.cameraModel,
      in: metadata,
      dictionary: kCGImagePropertyTIFFDictionary,
      property: kCGImagePropertyTIFFModel,
      field: "카메라 모델"
    ) { $0 as NSString }
    try updateValue(
      original.lensModel,
      updated.lensModel,
      in: metadata,
      dictionary: kCGImagePropertyExifDictionary,
      property: kCGImagePropertyExifLensModel,
      field: "렌즈"
    ) { $0 as NSString }
    try updateValue(
      original.software,
      updated.software,
      in: metadata,
      dictionary: kCGImagePropertyTIFFDictionary,
      property: kCGImagePropertyTIFFSoftware,
      field: "소프트웨어"
    ) { $0 as NSString }
    try updateValue(
      original.artist,
      updated.artist,
      in: metadata,
      dictionary: kCGImagePropertyTIFFDictionary,
      property: kCGImagePropertyTIFFArtist,
      field: "작성자"
    ) { $0 as NSString }

    if original.capturedAt != updated.capturedAt {
      try setOrRemove(
        updated.capturedAt,
        in: metadata,
        dictionary: kCGImagePropertyExifDictionary,
        property: kCGImagePropertyExifDateTimeOriginal,
        field: "촬영 시각"
      ) { $0 as NSString }
      try setOrRemove(
        updated.capturedAt,
        in: metadata,
        dictionary: kCGImagePropertyTIFFDictionary,
        property: kCGImagePropertyTIFFDateTime,
        field: "촬영 시각"
      ) { $0 as NSString }
    }

    try updateValue(
      original.exposureTime,
      updated.exposureTime,
      in: metadata,
      dictionary: kCGImagePropertyExifDictionary,
      property: kCGImagePropertyExifExposureTime,
      field: "노출 시간"
    ) { self.rationalString($0) }
    try updateValue(
      original.aperture,
      updated.aperture,
      in: metadata,
      dictionary: kCGImagePropertyExifDictionary,
      property: kCGImagePropertyExifFNumber,
      field: "조리개"
    ) { self.rationalString($0) }
    try updateValue(
      original.iso,
      updated.iso,
      in: metadata,
      dictionary: kCGImagePropertyExifDictionary,
      property: kCGImagePropertyExifISOSpeedRatings,
      field: "ISO"
    ) { [NSNumber(value: $0)] as NSArray }
    try updateValue(
      original.focalLength,
      updated.focalLength,
      in: metadata,
      dictionary: kCGImagePropertyExifDictionary,
      property: kCGImagePropertyExifFocalLength,
      field: "초점 거리"
    ) { self.rationalString($0) }

    if original.dpiWidth != updated.dpiWidth || original.dpiHeight != updated.dpiHeight {
      try setOrRemove(
        updated.dpiWidth,
        in: metadata,
        dictionary: kCGImagePropertyTIFFDictionary,
        property: kCGImagePropertyTIFFXResolution,
        field: "가로 DPI"
      ) { self.rationalString($0) }
      try setOrRemove(
        updated.dpiHeight,
        in: metadata,
        dictionary: kCGImagePropertyTIFFDictionary,
        property: kCGImagePropertyTIFFYResolution,
        field: "세로 DPI"
      ) { self.rationalString($0) }
      try setOrRemove(
        updated.dpiWidth == nil ? nil : 2,
        in: metadata,
        dictionary: kCGImagePropertyTIFFDictionary,
        property: kCGImagePropertyTIFFResolutionUnit,
        field: "DPI 단위"
      ) { NSNumber(value: $0) }
    }

    if original.location != updated.location {
      try replaceLocation(in: metadata, with: updated.location)
    }
  }

  private func replaceLocation(
    in metadata: CGMutableImageMetadata,
    with location: ImageLocation?
  ) throws {
    let properties: [(CFString, String)] = [
      (kCGImagePropertyGPSLatitude, "위도"),
      (kCGImagePropertyGPSLatitudeRef, "위도 방향"),
      (kCGImagePropertyGPSLongitude, "경도"),
      (kCGImagePropertyGPSLongitudeRef, "경도 방향"),
      (kCGImagePropertyGPSAltitude, "고도"),
      (kCGImagePropertyGPSAltitudeRef, "고도 기준"),
      (kCGImagePropertyGPSImgDirection, "촬영 방향"),
      (kCGImagePropertyGPSImgDirectionRef, "촬영 방향 기준"),
    ]

    guard let location else {
      for (property, field) in properties {
        try removeValue(
          from: metadata,
          dictionary: kCGImagePropertyGPSDictionary,
          property: property,
          field: field
        )
      }
      return
    }

    try setValue(
      NSNumber(value: abs(location.latitude)),
      in: metadata,
      dictionary: kCGImagePropertyGPSDictionary,
      property: kCGImagePropertyGPSLatitude,
      field: "위도"
    )
    try setValue(
      (location.latitude < 0 ? "S" : "N") as NSString,
      in: metadata,
      dictionary: kCGImagePropertyGPSDictionary,
      property: kCGImagePropertyGPSLatitudeRef,
      field: "위도 방향"
    )
    try setValue(
      NSNumber(value: abs(location.longitude)),
      in: metadata,
      dictionary: kCGImagePropertyGPSDictionary,
      property: kCGImagePropertyGPSLongitude,
      field: "경도"
    )
    try setValue(
      (location.longitude < 0 ? "W" : "E") as NSString,
      in: metadata,
      dictionary: kCGImagePropertyGPSDictionary,
      property: kCGImagePropertyGPSLongitudeRef,
      field: "경도 방향"
    )

    if let altitude = location.altitude {
      try setValue(
        rationalString(abs(altitude)),
        in: metadata,
        dictionary: kCGImagePropertyGPSDictionary,
        property: kCGImagePropertyGPSAltitude,
        field: "고도"
      )
      try setValue(
        NSNumber(value: altitude < 0 ? 1 : 0),
        in: metadata,
        dictionary: kCGImagePropertyGPSDictionary,
        property: kCGImagePropertyGPSAltitudeRef,
        field: "고도 기준"
      )
    } else {
      try removeValue(
        from: metadata,
        dictionary: kCGImagePropertyGPSDictionary,
        property: kCGImagePropertyGPSAltitude,
        field: "고도"
      )
      try removeValue(
        from: metadata,
        dictionary: kCGImagePropertyGPSDictionary,
        property: kCGImagePropertyGPSAltitudeRef,
        field: "고도 기준"
      )
    }

    if let direction = location.direction {
      try setValue(
        rationalString(direction),
        in: metadata,
        dictionary: kCGImagePropertyGPSDictionary,
        property: kCGImagePropertyGPSImgDirection,
        field: "촬영 방향"
      )
      try setValue(
        "T" as NSString,
        in: metadata,
        dictionary: kCGImagePropertyGPSDictionary,
        property: kCGImagePropertyGPSImgDirectionRef,
        field: "촬영 방향 기준"
      )
    } else {
      try removeValue(
        from: metadata,
        dictionary: kCGImagePropertyGPSDictionary,
        property: kCGImagePropertyGPSImgDirection,
        field: "촬영 방향"
      )
      try removeValue(
        from: metadata,
        dictionary: kCGImagePropertyGPSDictionary,
        property: kCGImagePropertyGPSImgDirectionRef,
        field: "촬영 방향 기준"
      )
    }
  }

  private func updateValue<Value: Equatable>(
    _ original: Value?,
    _ updated: Value?,
    in metadata: CGMutableImageMetadata,
    dictionary: CFString,
    property: CFString,
    field: String,
    transform: (Value) -> Any
  ) throws {
    guard original != updated else { return }
    try setOrRemove(
      updated,
      in: metadata,
      dictionary: dictionary,
      property: property,
      field: field,
      transform: transform
    )
  }

  private func setOrRemove<Value>(
    _ value: Value?,
    in metadata: CGMutableImageMetadata,
    dictionary: CFString,
    property: CFString,
    field: String,
    transform: (Value) -> Any
  ) throws {
    if let value {
      try setValue(
        transform(value),
        in: metadata,
        dictionary: dictionary,
        property: property,
        field: field
      )
    } else {
      try removeValue(
        from: metadata,
        dictionary: dictionary,
        property: property,
        field: field
      )
    }
  }

  private func setValue(
    _ value: Any,
    in metadata: CGMutableImageMetadata,
    dictionary: CFString,
    property: CFString,
    field: String
  ) throws {
    guard
      CGImageMetadataSetValueMatchingImageProperty(
        metadata,
        dictionary,
        property,
        value as CFTypeRef
      )
    else {
      throw ImageMetadataWriterError.metadataFieldUnsupported(field)
    }
  }

  private func removeValue(
    from metadata: CGMutableImageMetadata,
    dictionary: CFString,
    property: CFString,
    field: String
  ) throws {
    guard
      let tag = CGImageMetadataCopyTagMatchingImageProperty(metadata, dictionary, property),
      let prefix = CGImageMetadataTagCopyPrefix(tag),
      let name = CGImageMetadataTagCopyName(tag)
    else {
      return
    }
    let path = "\(prefix):\(name)" as CFString
    guard CGImageMetadataRemoveTagWithPath(metadata, nil, path) else {
      throw ImageMetadataWriterError.metadataFieldUnsupported(field)
    }
  }

  /// EXIF의 Rational 형식이 소수를 정수로 자르지 않도록 약분된 분수 문자열로 기록합니다.
  private func rationalString(_ value: Double) -> NSString {
    let denominator: Int64 = 1_000_000_000
    let numerator = Int64((value * Double(denominator)).rounded())
    let divisor = greatestCommonDivisor(abs(numerator), denominator)
    return "\(numerator / divisor)/\(denominator / divisor)" as NSString
  }

  private func greatestCommonDivisor(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    var left = lhs
    var right = rhs
    while right != 0 {
      (left, right) = (right, left % right)
    }
    return max(1, left)
  }
}
