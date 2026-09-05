import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

@Suite("이미지뷰어 핵심 로직")
struct ImageViewerTests {
  @Test("1~10장 그리드가 창 비율에 맞는 열 수를 고른다")
  func gridColumnCalculation() {
    #expect(
      ViewerGridLayout.columnCount(itemCount: 1, containerSize: CGSize(width: 1_200, height: 800))
        == 1)
    #expect(
      ViewerGridLayout.columnCount(itemCount: 2, containerSize: CGSize(width: 1_200, height: 800))
        == 2)
    #expect(
      ViewerGridLayout.columnCount(itemCount: 4, containerSize: CGSize(width: 900, height: 900))
        == 2)
    #expect(
      ViewerGridLayout.columnCount(itemCount: 10, containerSize: CGSize(width: 1_600, height: 900))
        == 5)
  }

  @Test("단일 보기에는 선택 테두리를 표시하지 않는다")
  func singleImageTileChrome() {
    #expect(!ViewerTileChrome.showsBoundary(itemCount: 1))
    #expect(!ViewerTileChrome.highlightsSelection(isCurrent: true, itemCount: 1))
    #expect(ViewerTileChrome.showsBoundary(itemCount: 2))
    #expect(ViewerTileChrome.highlightsSelection(isCurrent: true, itemCount: 2))
    #expect(!ViewerTileChrome.highlightsSelection(isCurrent: false, itemCount: 2))
  }

  @Test("파일명은 숨김과 네 단계 크기를 지원한다")
  func filenameDisplaySizes() {
    #expect(FilenameDisplaySize.allCases.count == 5)
    #expect(!FilenameDisplaySize.hidden.isVisible)
    #expect(FilenameDisplaySize.small.isVisible)
    #expect(FilenameDisplaySize.medium.fontSize > FilenameDisplaySize.small.fontSize)
    #expect(FilenameDisplaySize.large.fontSize > FilenameDisplaySize.medium.fontSize)
    #expect(FilenameDisplaySize.extraLarge.fontSize > FilenameDisplaySize.large.fontSize)
  }

  @Test("폴더가 바뀌면 같은 순번과 파일명도 별도 썸네일로 식별한다")
  func thumbnailIdentityAcrossFolders() {
    let date = Date(timeIntervalSinceReferenceDate: 123_456)
    let first = ImageAsset(
      url: URL(fileURLWithPath: "/Pictures/A/frame.png"),
      byteCount: 1_024,
      modificationDate: date
    )
    let second = ImageAsset(
      url: URL(fileURLWithPath: "/Pictures/B/frame.png"),
      byteCount: 1_024,
      modificationDate: date
    )
    let replaced = ImageAsset(
      url: first.url,
      byteCount: 2_048,
      modificationDate: date.addingTimeInterval(1)
    )

    #expect(first.id != second.id)
    #expect(
      ThumbnailCacheKey(asset: first, pixelSize: 256)
        != ThumbnailCacheKey(asset: second, pixelSize: 256))
    #expect(
      ThumbnailCacheKey(asset: first, pixelSize: 256)
        != ThumbnailCacheKey(asset: replaced, pixelSize: 256))
  }

  @Test("이전 폴더에서 늦게 완료된 요청은 최신 썸네일을 덮어쓰지 않는다")
  func latestThumbnailRequestWins() {
    var gate = LatestRequestGate<String>()
    let oldGeneration = gate.begin("A/first.png")
    let newGeneration = gate.begin("B/first.png")

    #expect(!gate.accepts(oldGeneration, for: "A/first.png"))
    #expect(gate.accepts(newGeneration, for: "B/first.png"))
  }

  @Test("Esc는 집중 보기에서 일반 보기와 전체 보기로 순서대로 돌아간다")
  @MainActor
  func escapeNavigation() {
    let store = AppStore()
    store.presentationMode = .overview
    store.toggleFocusMode()

    #expect(store.isFocusMode)
    #expect(store.presentationMode == .viewer)
    #expect(store.handleEscapeKey())
    #expect(!store.isFocusMode)
    #expect(store.presentationMode == .viewer)

    #expect(store.handleEscapeKey())
    #expect(store.presentationMode == .overview)
    #expect(!store.handleEscapeKey())
  }

  @Test("회전 횟수는 항상 0~3 범위로 정규화된다")
  func adjustmentRotationNormalization() {
    var adjustments = ImageAdjustments()
    adjustments.quarterTurns = -1
    #expect(adjustments.normalizedQuarterTurns == 3)

    adjustments.rotateClockwise()
    #expect(adjustments.normalizedQuarterTurns == 0)

    adjustments.quarterTurns = 9
    #expect(adjustments.normalizedQuarterTurns == 1)
  }

  @Test("QOI 자체 디코더가 RGB와 RUN 명령을 읽는다")
  func qoiDecoder() throws {
    let qoi = makeTwoPixelQOI()

    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("imageviewer-test-\(UUID().uuidString).qoi")
    try qoi.write(to: temporaryURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    let image = try QOIDecoder.decode(url: temporaryURL)
    #expect(image.width == 2)
    #expect(image.height == 1)
  }

  @Test("PCX 자체 디코더가 8-bit 팔레트 이미지를 읽는다")
  func pcxDecoder() throws {
    var header = [UInt8](repeating: 0, count: 128)
    header[0] = 0x0A  // ZSoft PCX
    header[1] = 5
    header[2] = 1  // RLE
    header[3] = 8  // bits per pixel
    header[65] = 1  // color planes
    header[66] = 2  // bytes per line (패딩 포함)

    var pcx = Data(header)
    pcx.append(contentsOf: [1, 0])
    pcx.append(0x0C)
    var palette = [UInt8](repeating: 0, count: 768)
    palette[3] = 255  // palette index 1 = red
    pcx.append(contentsOf: palette)

    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("imageviewer-test-\(UUID().uuidString).pcx")
    try pcx.write(to: temporaryURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    let image = try PCXDecoder.decode(url: temporaryURL)
    #expect(image.width == 1)
    #expect(image.height == 1)
  }

  @Test("비파괴 파이프라인 결과를 PNG로 내보낼 수 있다")
  func exportPipeline() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imageviewer-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceURL = directory.appendingPathComponent("source.qoi")
    let destinationURL = directory.appendingPathComponent("converted.png")
    try makeTwoPixelQOI().write(to: sourceURL, options: .atomic)

    let pipeline = ImagePipeline()
    let exporter = ImageExporter(pipeline: pipeline)
    try await exporter.export(
      sourceURL: sourceURL,
      destinationURL: destinationURL,
      format: .png,
      quality: 1,
      adjustments: .identity
    )

    let result = CGImageSourceCreateWithURL(destinationURL as CFURL, nil)
    #expect(result != nil)
    #expect(result.map(CGImageSourceGetCount) == 1)
  }

  @Test("앱 자체 포맷이 폴더 스캔 대상에 포함된다")
  func customFormatsAreRegistered() {
    #expect(ImageFormatRegistry.knownExtensions.contains("qoi"))
    #expect(ImageFormatRegistry.knownExtensions.contains("pcx"))
  }

  @Test("썸네일 패널은 네 방향과 숨김을 지원한다")
  func thumbnailPanelPlacements() {
    #expect(ThumbnailPanelPlacement.allCases.count == 5)
    #expect(ThumbnailPanelPlacement.top.isHorizontal)
    #expect(ThumbnailPanelPlacement.bottom.isHorizontal)
    #expect(!ThumbnailPanelPlacement.left.isHorizontal)
    #expect(!ThumbnailPanelPlacement.hidden.isHorizontal)
  }

  @Test("설정한 포인터 입력만 확대 이미지 팬으로 허용한다")
  func configurablePanInput() {
    #expect(PanInteractionMode.spacePrimaryDrag.accepts(.spacePrimaryDrag))
    #expect(PanInteractionMode.secondaryDrag.accepts(.secondaryDrag))
    #expect(PanInteractionMode.middleDrag.accepts(.middleDrag))
    #expect(PanInteractionMode.trackpadScroll.accepts(.trackpadScroll))
    #expect(!PanInteractionMode.primaryDrag.accepts(.secondaryDrag))
    #expect(!PanInteractionMode.trackpadScroll.accepts(.spacePrimaryDrag))
  }

  @Test("GPS 좌표가 Apple 및 Google 지도 표준 URL로 변환된다")
  func mapURLs() throws {
    let location = ImageLocation(latitude: 48.858_37, longitude: 2.294_481)

    let appleURL = try #require(location.mapURL(for: .apple))
    let appleComponents = try #require(URLComponents(url: appleURL, resolvingAgainstBaseURL: false))
    #expect(appleComponents.scheme == "http")
    #expect(appleComponents.host == "maps.apple.com")
    #expect(
      appleComponents.queryItems?.first(where: { $0.name == "ll" })?.value == "48.858370,2.294481")

    let googleURL = try #require(location.mapURL(for: .google))
    let googleComponents = try #require(
      URLComponents(url: googleURL, resolvingAgainstBaseURL: false))
    #expect(googleComponents.scheme == "https")
    #expect(googleComponents.host == "www.google.com")
    #expect(googleComponents.queryItems?.first(where: { $0.name == "api" })?.value == "1")
    #expect(
      googleComponents.queryItems?.first(where: { $0.name == "query" })?.value
        == "48.858370,2.294481")
  }

  @Test("Image I/O에서 카메라와 GPS EXIF 메타데이터를 읽는다")
  func detailedMetadata() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imageviewer-metadata-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let qoiURL = directory.appendingPathComponent("pixel.qoi")
    let jpegURL = directory.appendingPathComponent("metadata.jpg")
    try makeTwoPixelQOI().write(to: qoiURL, options: .atomic)
    let image = try QOIDecoder.decode(url: qoiURL)
    let destination = try #require(
      CGImageDestinationCreateWithURL(jpegURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    )
    let properties: [CFString: Any] = [
      kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFMake: "Open Camera",
        kCGImagePropertyTIFFModel: "Test Model",
      ],
      kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifFNumber: 2.8,
        kCGImagePropertyExifISOSpeedRatings: [200],
        kCGImagePropertyExifFocalLength: 35.0,
      ],
      kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 37.5665,
        kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 126.978,
        kCGImagePropertyGPSLongitudeRef: "E",
        kCGImagePropertyGPSAltitude: 38.0,
      ],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))

    let metadata = try await ImagePipeline().metadata(for: jpegURL)
    #expect(metadata.cameraMake == "Open Camera")
    #expect(metadata.cameraModel == "Test Model")
    #expect(metadata.aperture == 2.8)
    #expect(metadata.iso == 200)
    #expect(metadata.focalLength == 35)
    #expect(metadata.location?.latitude == 37.5665)
    #expect(metadata.location?.longitude == 126.978)
    #expect(metadata.location?.altitude == 38)
  }

  @Test("메타데이터 편집값이 파일명과 숫자 범위를 검증한다")
  func metadataEditValidation() throws {
    let sourceURL = URL(fileURLWithPath: "/Pictures/photo.jpg")
    let asset = ImageAsset(url: sourceURL, byteCount: 100, modificationDate: Date())
    var draft = ImageMetadataEditDraft(asset: asset, metadata: nil)
    draft.exposureTime = "1/125"
    draft.dpiWidth = "300"
    draft.dpiHeight = ""
    draft.includesLocation = true
    draft.latitude = "37.5665"
    draft.longitude = "126.978"

    let update = try draft.validated(for: sourceURL)
    #expect(update.metadata.exposureTime == 1.0 / 125.0)
    #expect(update.metadata.dpiWidth == 300)
    #expect(update.metadata.dpiHeight == 300)
    #expect(update.metadata.location?.latitude == 37.5665)

    draft.filename = "photo.png"
    do {
      _ = try draft.validated(for: sourceURL)
      Issue.record("정보 편집에서 확장자 변경을 허용했습니다.")
    } catch let error as ImageMetadataEditValidationError {
      #expect(error == .changedExtension(expected: "jpg"))
    }

    draft.filename = "photo.jpg"
    draft.latitude = "91"
    do {
      _ = try draft.validated(for: sourceURL)
      Issue.record("범위를 벗어난 위도를 허용했습니다.")
    } catch let error as ImageMetadataEditValidationError {
      #expect(error == .outOfRange(field: "위도", range: "-90~90"))
    }
  }

  @Test("PNG 픽셀을 바꾸지 않고 정보·GPS·파일명을 수정한다")
  func losslessMetadataEditing() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imageviewer-metadata-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let qoiURL = directory.appendingPathComponent("source.qoi")
    let sourceURL = directory.appendingPathComponent("source.png")
    try makeTwoPixelQOI().write(to: qoiURL, options: .atomic)
    let image = try QOIDecoder.decode(url: qoiURL)
    let destination = try #require(
      CGImageDestinationCreateWithURL(sourceURL as CFURL, UTType.png.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))

    let sourceValues = try sourceURL.resourceValues(forKeys: [
      .fileSizeKey, .contentModificationDateKey,
    ])
    let asset = ImageAsset(
      url: sourceURL,
      byteCount: sourceValues.fileSize.map(Int64.init),
      modificationDate: sourceValues.contentModificationDate
    )
    let initialMetadata = try await ImagePipeline().metadata(for: sourceURL)
    let originalDraft = ImageMetadataEditDraft(asset: asset, metadata: initialMetadata)
    var editedDraft = originalDraft
    editedDraft.filename = "renamed.png"
    editedDraft.modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
    editedDraft.imageDescription = "테스트 이미지 설명"
    editedDraft.copyright = "© ImageViewer"
    editedDraft.dpiWidth = "144"
    editedDraft.dpiHeight = "144"
    editedDraft.cameraMake = "Open Camera"
    editedDraft.cameraModel = "Test Model"
    editedDraft.lensModel = "Test Lens"
    editedDraft.software = "이미지뷰어"
    editedDraft.artist = "테스트 작성자"
    editedDraft.capturedAt = "2026:01:02 03:04:05"
    editedDraft.exposureTime = "1/125"
    editedDraft.aperture = "2.8"
    editedDraft.iso = "200"
    editedDraft.focalLength = "35"
    editedDraft.includesLocation = true
    editedDraft.latitude = "37.5665"
    editedDraft.longitude = "126.978"
    editedDraft.altitude = "38"
    editedDraft.direction = "120"

    let original = try originalDraft.validated(for: sourceURL)
    let update = try editedDraft.validated(for: sourceURL)
    let beforePixels = try pixelBytes(at: sourceURL)
    let outputURL = try await ImageMetadataWriter().apply(
      update,
      replacing: original,
      to: sourceURL
    )

    #expect(outputURL.lastPathComponent == "renamed.png")
    #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
    #expect(try pixelBytes(at: outputURL) == beforePixels)

    let metadata = try await ImagePipeline().metadata(for: outputURL)
    #expect(metadata.imageDescription == "테스트 이미지 설명")
    #expect(metadata.copyright == "© ImageViewer")
    #expect(metadata.dpiWidth == 144)
    #expect(metadata.dpiHeight == 144)
    #expect(metadata.cameraMake == "Open Camera")
    #expect(metadata.cameraModel == "Test Model")
    #expect(metadata.lensModel == "Test Lens")
    #expect(metadata.software == "이미지뷰어")
    #expect(metadata.artist == "테스트 작성자")
    #expect(metadata.capturedAt == "2026:01:02 03:04:05")
    #expect(abs(try #require(metadata.exposureTime) - (1.0 / 125.0)) < 0.000_000_1)
    #expect(metadata.aperture == 2.8)
    #expect(metadata.iso == 200)
    #expect(metadata.focalLength == 35)
    #expect(metadata.location?.latitude == 37.5665)
    #expect(metadata.location?.longitude == 126.978)
    #expect(metadata.location?.altitude == 38)
    #expect(metadata.location?.direction == 120)

    let modified = try outputURL.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
    #expect(abs(try #require(modified).timeIntervalSince1970 - 1_700_000_000) < 1)

    // 입력란을 비우거나 GPS 저장을 끄면 기존 태그도 실제 파일에서 제거해야 합니다.
    let refreshedValues = try outputURL.resourceValues(forKeys: [
      .fileSizeKey, .contentModificationDateKey,
    ])
    let refreshedAsset = ImageAsset(
      url: outputURL,
      byteCount: refreshedValues.fileSize.map(Int64.init),
      modificationDate: refreshedValues.contentModificationDate
    )
    let removalOriginalDraft = ImageMetadataEditDraft(
      asset: refreshedAsset,
      metadata: metadata
    )
    var removalDraft = removalOriginalDraft
    removalDraft.imageDescription = ""
    removalDraft.artist = ""
    removalDraft.copyright = ""
    removalDraft.includesLocation = false

    let removalOutputURL = try await ImageMetadataWriter().apply(
      try removalDraft.validated(for: outputURL),
      replacing: try removalOriginalDraft.validated(for: outputURL),
      to: outputURL
    )
    #expect(removalOutputURL == outputURL)
    #expect(try pixelBytes(at: removalOutputURL) == beforePixels)

    let metadataAfterRemoval = try await ImagePipeline().metadata(for: removalOutputURL)
    #expect(metadataAfterRemoval.imageDescription == nil)
    #expect(metadataAfterRemoval.artist == nil)
    #expect(metadataAfterRemoval.copyright == nil)
    #expect(metadataAfterRemoval.location == nil)
  }

  @Test("JPEG도 재압축하지 않고 기존 EXIF와 GPS를 수정한다")
  func losslessJPEGMetadataEditing() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imageviewer-jpeg-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let qoiURL = directory.appendingPathComponent("source.qoi")
    let jpegURL = directory.appendingPathComponent("source.jpg")
    try makeTwoPixelQOI().write(to: qoiURL, options: .atomic)
    let image = try QOIDecoder.decode(url: qoiURL)
    let destination = try #require(
      CGImageDestinationCreateWithURL(jpegURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(
      destination,
      image,
      [
        kCGImagePropertyTIFFDictionary: [
          kCGImagePropertyTIFFArtist: "이전 작성자"
        ],
        kCGImagePropertyGPSDictionary: [
          kCGImagePropertyGPSLatitude: 48.858_37,
          kCGImagePropertyGPSLatitudeRef: "N",
          kCGImagePropertyGPSLongitude: 2.294_481,
          kCGImagePropertyGPSLongitudeRef: "E",
        ],
      ] as CFDictionary
    )
    #expect(CGImageDestinationFinalize(destination))

    let values = try jpegURL.resourceValues(forKeys: [
      .fileSizeKey, .contentModificationDateKey,
    ])
    let asset = ImageAsset(
      url: jpegURL,
      byteCount: values.fileSize.map(Int64.init),
      modificationDate: values.contentModificationDate
    )
    let metadata = try await ImagePipeline().metadata(for: jpegURL)
    let originalDraft = ImageMetadataEditDraft(asset: asset, metadata: metadata)
    var editedDraft = originalDraft
    editedDraft.artist = "새 작성자"
    editedDraft.imageDescription = "JPEG 설명"
    editedDraft.includesLocation = false

    let beforePixels = try pixelBytes(at: jpegURL)
    _ = try await ImageMetadataWriter().apply(
      try editedDraft.validated(for: jpegURL),
      replacing: try originalDraft.validated(for: jpegURL),
      to: jpegURL
    )

    #expect(try pixelBytes(at: jpegURL) == beforePixels)
    let updatedMetadata = try await ImagePipeline().metadata(for: jpegURL)
    #expect(updatedMetadata.artist == "새 작성자")
    #expect(updatedMetadata.imageDescription == "JPEG 설명")
    #expect(updatedMetadata.location == nil)
  }

  private func pixelBytes(at url: URL) throws -> Data {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let provider = try #require(image.dataProvider)
    return try #require(provider.data) as Data
  }

  private func makeTwoPixelQOI() -> Data {
    var qoi = Data([0x71, 0x6F, 0x69, 0x66])
    qoi.append(contentsOf: [0, 0, 0, 2])  // width = 2
    qoi.append(contentsOf: [0, 0, 0, 1])  // height = 1
    qoi.append(contentsOf: [4, 0])  // RGBA, sRGB
    qoi.append(contentsOf: [0xFF, 0xFF, 0x00, 0x00, 0xFF])
    qoi.append(0xC0)  // 바로 앞 빨강 픽셀을 한 번 더 출력
    qoi.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1])
    return qoi
  }
}
