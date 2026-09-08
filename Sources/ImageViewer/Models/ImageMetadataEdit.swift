import Foundation

/// 실제 파일 안에 기록할 수 있는 표준 TIFF/EXIF/GPS 값입니다.
struct EditableImageMetadata: Equatable, Sendable {
  var imageDescription: String?
  var copyright: String?
  var dpiWidth: Double?
  var dpiHeight: Double?
  var cameraMake: String?
  var cameraModel: String?
  var lensModel: String?
  var software: String?
  var artist: String?
  var capturedAt: String?
  var exposureTime: Double?
  var aperture: Double?
  var iso: Int?
  var focalLength: Double?
  var location: ImageLocation?
}

/// 검증을 마친 파일 시스템 변경과 내장 메타데이터를 한 번에 전달합니다.
struct ImageMetadataUpdate: Equatable, Sendable {
  var filename: String
  var modificationDate: Date
  var metadata: EditableImageMetadata
}

enum ImageMetadataEditValidationError: LocalizedError, Equatable {
  case invalidFilename
  case hiddenFilename
  case changedExtension(expected: String)
  case invalidNumber(field: String)
  case outOfRange(field: String, range: String)
  case incompleteLocation

  var errorDescription: String? {
    switch self {
    case .invalidFilename:
      L10n.text("파일 이름에는 ‘/’, ‘:’ 또는 줄바꿈을 사용할 수 없습니다.")
    case .hiddenFilename:
      L10n.text("점(.)으로 시작하는 숨김 파일 이름은 사용할 수 없습니다.")
    case .changedExtension(let expected):
      L10n.format(
        "정보 편집에서는 파일 형식을 바꿀 수 없습니다. 확장자를 .%@로 유지해 주세요.",
        expected
      )
    case .invalidNumber(let field):
      L10n.format("‘%@’에 올바른 숫자를 입력해 주세요.", L10n.text(field))
    case .outOfRange(let field, let range):
      L10n.format("‘%@’ 값은 %@ 범위여야 합니다.", L10n.text(field), range)
    case .incompleteLocation:
      L10n.text("위치 정보를 사용하려면 위도와 경도를 모두 입력해 주세요.")
    }
  }
}

/// TextField에서 빈 값과 입력 중인 숫자를 자연스럽게 다룰 수 있는 편집용 초안입니다.
struct ImageMetadataEditDraft: Equatable, Sendable {
  var filename: String
  var modificationDate: Date
  var imageDescription: String
  var copyright: String
  var dpiWidth: String
  var dpiHeight: String
  var cameraMake: String
  var cameraModel: String
  var lensModel: String
  var software: String
  var artist: String
  var capturedAt: String
  var exposureTime: String
  var aperture: String
  var iso: String
  var focalLength: String
  var includesLocation: Bool
  var latitude: String
  var longitude: String
  var altitude: String
  var direction: String

  init(asset: ImageAsset?, metadata: ImageMetadata?) {
    filename = asset?.filename ?? ""
    modificationDate = asset?.modificationDate ?? Date()
    imageDescription = metadata?.imageDescription ?? ""
    copyright = metadata?.copyright ?? ""
    dpiWidth = Self.numberText(metadata?.dpiWidth)
    dpiHeight = Self.numberText(metadata?.dpiHeight ?? metadata?.dpiWidth)
    cameraMake = metadata?.cameraMake ?? ""
    cameraModel = metadata?.cameraModel ?? ""
    lensModel = metadata?.lensModel ?? ""
    software = metadata?.software ?? ""
    artist = metadata?.artist ?? ""
    capturedAt = metadata?.capturedAt ?? ""
    exposureTime = Self.numberText(metadata?.exposureTime)
    aperture = Self.numberText(metadata?.aperture)
    iso = metadata?.iso.map(String.init) ?? ""
    focalLength = Self.numberText(metadata?.focalLength)
    includesLocation = metadata?.location != nil
    latitude = Self.numberText(metadata?.location?.latitude)
    longitude = Self.numberText(metadata?.location?.longitude)
    altitude = Self.numberText(metadata?.location?.altitude)
    direction = Self.numberText(metadata?.location?.direction)
  }

  func validated(for sourceURL: URL) throws -> ImageMetadataUpdate {
    let cleanFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
    let forbidden = CharacterSet(charactersIn: "/:").union(.newlines).union(.controlCharacters)
    guard !cleanFilename.isEmpty,
      cleanFilename.rangeOfCharacter(from: forbidden) == nil,
      cleanFilename != ".",
      cleanFilename != ".."
    else {
      throw ImageMetadataEditValidationError.invalidFilename
    }
    guard !cleanFilename.hasPrefix(".") else {
      throw ImageMetadataEditValidationError.hiddenFilename
    }

    let expectedExtension = sourceURL.pathExtension.lowercased()
    guard cleanFilename.pathExtension.lowercased() == expectedExtension else {
      throw ImageMetadataEditValidationError.changedExtension(expected: expectedExtension)
    }

    var parsedDPIWidth = try optionalDouble(dpiWidth, field: "가로 DPI", range: 1...100_000)
    var parsedDPIHeight = try optionalDouble(dpiHeight, field: "세로 DPI", range: 1...100_000)
    if parsedDPIWidth == nil { parsedDPIWidth = parsedDPIHeight }
    if parsedDPIHeight == nil { parsedDPIHeight = parsedDPIWidth }

    let parsedExposure = try optionalDouble(
      exposureTime,
      field: "노출 시간",
      range: Double.leastNonzeroMagnitude...86_400,
      acceptsFraction: true
    )
    let parsedAperture = try optionalDouble(aperture, field: "조리개", range: 0.1...128)
    let parsedISO = try optionalInteger(iso, field: "ISO", range: 1...10_000_000)
    let parsedFocalLength = try optionalDouble(
      focalLength, field: "초점 거리", range: 0...100_000)

    let location: ImageLocation?
    if includesLocation {
      guard
        let parsedLatitude = try optionalDouble(latitude, field: "위도", range: -90...90),
        let parsedLongitude = try optionalDouble(longitude, field: "경도", range: -180...180)
      else {
        throw ImageMetadataEditValidationError.incompleteLocation
      }
      location = ImageLocation(
        latitude: parsedLatitude,
        longitude: parsedLongitude,
        altitude: try optionalDouble(altitude, field: "고도", range: -12_000...100_000),
        direction: try optionalDouble(direction, field: "촬영 방향", range: 0...360)
      )
    } else {
      location = nil
    }

    return ImageMetadataUpdate(
      filename: cleanFilename,
      modificationDate: modificationDate,
      metadata: EditableImageMetadata(
        imageDescription: optionalText(imageDescription),
        copyright: optionalText(copyright),
        dpiWidth: parsedDPIWidth,
        dpiHeight: parsedDPIHeight,
        cameraMake: optionalText(cameraMake),
        cameraModel: optionalText(cameraModel),
        lensModel: optionalText(lensModel),
        software: optionalText(software),
        artist: optionalText(artist),
        capturedAt: normalizedCapturedAt(capturedAt),
        exposureTime: parsedExposure,
        aperture: parsedAperture,
        iso: parsedISO,
        focalLength: parsedFocalLength,
        location: location
      )
    )
  }

  private func optionalText(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func optionalDouble(
    _ text: String,
    field: String,
    range: ClosedRange<Double>,
    acceptsFraction: Bool = false
  ) throws -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let value: Double?
    if acceptsFraction, trimmed.contains("/") {
      let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
      if components.count == 2,
        let numerator = Double(components[0]),
        let denominator = Double(components[1]),
        denominator != 0
      {
        value = numerator / denominator
      } else {
        value = nil
      }
    } else {
      value = Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    guard let value, value.isFinite else {
      throw ImageMetadataEditValidationError.invalidNumber(field: field)
    }
    guard range.contains(value) else {
      throw ImageMetadataEditValidationError.outOfRange(
        field: field,
        range: "\(Self.numberText(range.lowerBound))~\(Self.numberText(range.upperBound))"
      )
    }
    return value
  }

  private func optionalInteger(
    _ text: String,
    field: String,
    range: ClosedRange<Int>
  ) throws -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let value = Int(trimmed) else {
      throw ImageMetadataEditValidationError.invalidNumber(field: field)
    }
    guard range.contains(value) else {
      throw ImageMetadataEditValidationError.outOfRange(
        field: field,
        range: "\(range.lowerBound)~\(range.upperBound)"
      )
    }
    return value
  }

  private func normalizedCapturedAt(_ value: String) -> String? {
    guard let value = optionalText(value) else { return nil }
    let pieces = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    if pieces.count == 2 {
      let date = pieces[0].split(separator: ":", omittingEmptySubsequences: false)
      if date.count == 3 {
        return "\(date[0])-\(date[1])-\(date[2])T\(pieces[1])"
      }
      if pieces[0].contains("-") {
        return "\(pieces[0])T\(pieces[1])"
      }
    }
    return value
  }

  private static func numberText(_ value: Double?) -> String {
    guard let value else { return "" }
    return String(format: "%.10g", locale: Locale(identifier: "en_US_POSIX"), value)
  }
}

extension String {
  fileprivate var pathExtension: String {
    (self as NSString).pathExtension
  }
}
