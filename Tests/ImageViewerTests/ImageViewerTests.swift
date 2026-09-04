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
