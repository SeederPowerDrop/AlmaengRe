import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

@Suite("워터마크 픽셀·메타데이터·자원")
struct WatermarkRendererTests {
  @Test("기본 비활성화와 빈 설정은 픽셀을 다시 만들지 않는다")
  func disabledIsIdentity() async throws {
    let image = try WatermarkTestImages.image(width: 32, height: 24)
    let renderer = WatermarkRenderer()
    let nonexistent = URL(fileURLWithPath: "/does-not-exist.png")
    let disabled = try await renderer.render(image: image, sourceURL: nonexistent, options: .disabled)
    #expect(disabled === image)
    let result = try await renderer.renderResult(image: image, sourceURL: nonexistent, options: .disabled)
    #expect(result.image === image && result.layout == nil && result.watermarkImage == nil)
    var empty = WatermarkOptions()
    empty.isEnabled = true
    #expect(try await renderer.render(image: image, sourceURL: nonexistent, options: empty) === image)
  }

  @Test("촬영 시점을 추가하거나 긴 문구를 줄바꿈해도 기존 글자 크기는 유지한다")
  func metadataAndWrappingDoNotShrinkText() async throws {
    let directory = try WatermarkTestImages.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("photo.tiff")
    let image = try WatermarkTestImages.image(width: 800, height: 600)
    try WatermarkTestImages.write(image, to: source, metadata: WatermarkTestImages.exif(make: "Demo"))
    let renderer = WatermarkRenderer()
    var options = WatermarkOptions()
    options.isEnabled = true
    options.text = "SIGNATURE"
    options.opacity = 1
    options.readability = .none
    let plain = try await renderer.renderResult(image: image, sourceURL: source, options: options)
    options.metadataFields = [.captureDate]
    let dated = try await renderer.renderResult(image: image, sourceURL: source, options: options)
    let plainMark = try #require(plain.watermarkImage)
    let datedMark = try #require(dated.watermarkImage)
    let plainBands = WatermarkTestImages.alphaBands(plainMark)
    let datedBands = WatermarkTestImages.alphaBands(datedMark)
    #expect(plainBands.count == 1 && datedBands.count == 2)
    let plainGlyphs = try #require(plainBands.first)
    // The date plus its field label is longer than SIGNATURE. Identify the
    // signature by width instead of assuming Core Image bitmap rows are bottom-up.
    let datedGlyphs = try #require(datedBands.min { $0.width < $1.width })
    #expect(abs(plainGlyphs.width - datedGlyphs.width) <= 2)
    #expect(abs(plainGlyphs.height - datedGlyphs.height) <= 1)
    #expect(datedMark.height > plainMark.height)
    #expect(datedMark.width > plainMark.width)

    options.metadataFields = []
    options.text = String(repeating: "SIGNATURE ", count: 18)
    let wrapped = try await renderer.renderResult(image: image, sourceURL: source, options: options)
    let bands = WatermarkTestImages.alphaBands(try #require(wrapped.watermarkImage))
    #expect(bands.count >= 3)
    #expect(bands.allSatisfy { abs($0.height - plainGlyphs.height) <= 1 })
    #expect(try #require(wrapped.layout).effectiveRect.width <= 800 - 2 * 600 * options.marginFraction)
  }

  @Test("많은 줄은 자동 축소 없이 넘침을 알리고 명시적으로 허용할 때만 캔버스를 늘린다")
  func overflowRequiresExplicitExpansion() async throws {
    let image = try WatermarkTestImages.image(width: 400, height: 80)
    let source = URL(fileURLWithPath: "/unused.png")
    let renderer = WatermarkRenderer()
    var options = WatermarkOptions()
    options.isEnabled = true
    options.text = Array(repeating: "TEXT", count: 20).joined(separator: "\n")
    options.sizeFraction = 0.5
    options.position = .topLeading
    options.marginFraction = 0
    options.readability = .none
    do {
      _ = try await renderer.renderResult(image: image, sourceURL: source, options: options)
      Issue.record("여러 줄이 글자 크기를 바꾸지 않고 들어갈 수 없는 캔버스에 저장되었습니다.")
    } catch WatermarkError.contentOverflow(let scale) {
      #expect(scale > 0 && scale < 0.5)
    } catch { Issue.record("다른 오류: \(error)") }
    options.expandsCanvas = true
    let result = try await renderer.renderResult(image: image, sourceURL: source, options: options)
    #expect(result.image.width == 400 && result.image.height > 400)
    #expect(WatermarkTestImages.alphaBands(try #require(result.watermarkImage)).count == 20)
  }

  @Test("지나치게 큰 확장 캔버스는 출력 비트맵을 만들기 전에 거절한다")
  func unsafeExtensionIsRejected() async throws {
    let image = try WatermarkTestImages.image(width: 5_000, height: 1)
    var options = WatermarkOptions()
    options.isEnabled = true
    options.text = String(repeating: "W", count: 2_000)
    options.sizeFraction = 0.9
    options.expandsCanvas = true
    do {
      _ = try await WatermarkRenderer().renderResult(image: image,
        sourceURL: URL(fileURLWithPath: "/unused.png"), options: options)
      Issue.record("안전 한도를 넘는 캔버스가 생성되었습니다.")
    } catch WatermarkError.unsafeCanvas {} catch { Issue.record("다른 오류: \(error)") }
  }

  @Test("큰 물리적 워터마크도 미리보기용 투명 비트맵은 한 변 4096을 넘지 않는다")
  func overlayRasterIsBoundedIndependentlyOfLayout() async throws {
    let image = try WatermarkTestImages.image(width: 5_000, height: 1)
    var options = WatermarkOptions()
    options.isEnabled = true
    options.text = "WWWWWWWW"
    options.sizeFraction = 0.9
    options.readability = .none
    options.expandsCanvas = true
    let result = try await WatermarkRenderer().renderResult(image: image,
      sourceURL: URL(fileURLWithPath: "/unused.png"), options: options)
    let layout = try #require(result.layout)
    let raster = try #require(result.watermarkImage)
    #expect(layout.effectiveRect.width > 4_096)
    #expect(raster.width <= 4_096 && raster.height <= 4_096)
    #expect(result.image.width == 5_000)
  }

  @Test("캔버스 확장은 원본 크기와 픽셀을 유지하고 바깥의 빈 공간은 투명하게 둔다")
  func expandedCanvasPreservesSourcePixels() async throws {
    let directory = try WatermarkTestImages.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let logo = directory.appendingPathComponent("logo.png")
    try WatermarkTestImages.write(WatermarkTestImages.image(width: 80, height: 40, color: (1, 0, 0, 1)), to: logo)
    // Different pixels make an accidental vertical flip or scale observable.
    let bitmap = try #require(CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    bitmap.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    bitmap.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
    bitmap.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
    bitmap.fill(CGRect(x: 0, y: 60, width: 100, height: 60))
    let image = try #require(bitmap.makeImage())
    var options = WatermarkOptions()
    options.isEnabled = true
    options.logoURL = logo
    options.sizeFraction = 0.25
    options.opacity = 1
    options.readability = .none
    options.customPosition = WatermarkPoint(x: -0.25, y: -0.25)
    options.expandsCanvas = true
    let result = try await WatermarkRenderer().renderResult(image: image, sourceURL: logo, options: options)
    let layout = try #require(result.layout)
    #expect(layout.canvasBounds.minX < 0 && layout.canvasBounds.minY < 0)
    #expect(layout.originalRectInCanvas.size == CGSize(width: 200, height: 120))
    let dx = Int(-layout.canvasBounds.minX)
    let dy = Int(layout.canvasBounds.maxY) - image.height
    for (x, y) in [(20, 20), (20, 90), (150, 90), (199, 119)] {
      #expect(WatermarkTestImages.pixel(result.image, x: x + dx, y: y + dy)
        == WatermarkTestImages.pixel(image, x: x, y: y))
    }
    #expect(WatermarkTestImages.pixel(result.image, x: result.image.width - 1,
      y: result.image.height - 1)[3] == 0)
    let cx = Int(layout.effectiveRect.midX - layout.canvasBounds.minX)
    let cy = Int(layout.canvasBounds.maxY - layout.effectiveRect.midY)
    #expect(WatermarkTestImages.pixel(result.image, x: cx, y: cy) == [255, 0, 0, 255])
  }

  @Test("투명 로고를 9개 위치에 비율대로 배치하고 다른 픽셀은 보존한다",
    arguments: WatermarkPosition.allCases)
  func logoPosition(position: WatermarkPosition) async throws {
    let directory = try WatermarkTestImages.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let logoURL = directory.appendingPathComponent("logo.png")
    let logo = try WatermarkTestImages.image(width: 80, height: 40, color: (1, 0, 0, 0.5))
    try WatermarkTestImages.write(logo, to: logoURL)
    let originalLogo = try Data(contentsOf: logoURL)
    let image = try WatermarkTestImages.image(width: 300, height: 200)
    var options = WatermarkOptions()
    options.isEnabled = true
    options.logoURL = logoURL
    options.position = position
    options.sizeFraction = 0.2
    options.marginFraction = 0.1
    options.opacity = 0.5
    options.readability = .none
    let output = try await WatermarkRenderer().render(image: image, sourceURL: logoURL, options: options)
    #expect(output.width == 300 && output.height == 200)
    let x: Int
    let y: Int
    switch position {
    case .topLeading, .leading, .bottomLeading: x = 50
    case .top, .center, .bottom: x = 150
    case .topTrailing, .trailing, .bottomTrailing: x = 250
    }
    switch position {
    case .topLeading, .top, .topTrailing: y = 164
    case .leading, .center, .trailing: y = 100
    case .bottomLeading, .bottom, .bottomTrailing: y = 35
    }
    let marked = WatermarkTestImages.pixel(output, x: x, y: y)
    // Source-over occurs in a linear working space: 25% linear red is ~137 in sRGB.
    #expect(marked[0] > 90 && marked[0] < 180)
    #expect(marked[1] < 3 && marked[2] < 3 && marked[3] == 255)
    #expect(WatermarkTestImages.pixel(output, x: 1, y: 1) == [0, 0, 0, 255])
    #expect(WatermarkTestImages.pixel(image, x: x, y: y) == [0, 0, 0, 255])
    #expect(try Data(contentsOf: logoURL) == originalLogo)
    // 2:1 logo remains rectangular instead of filling a square watermark block.
    #expect(WatermarkTestImages.pixel(output, x: x + 20, y: y)[0] > 90)
    #expect(WatermarkTestImages.pixel(output, x: x, y: y + 20)[0] < 3)
  }

  @Test("문구·서명 폰트·EXIF·로고를 한 사본에 함께 합성한다")
  func combinesTextMetadataAndLogo() async throws {
    let directory = try WatermarkTestImages.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("photo.tiff")
    let image = try WatermarkTestImages.image(width: 640, height: 480)
    try WatermarkTestImages.write(image, to: source, metadata: WatermarkTestImages.exif(make: "Synthetic Camera"))
    let logo = directory.appendingPathComponent("logo.png")
    try WatermarkTestImages.write(WatermarkTestImages.image(width: 100, height: 30, color: (1, 0, 0, 1)), to: logo)
    var options = WatermarkOptions()
    options.isEnabled = true
    options.text = "Signature / 서명 / 署名"
    options.fontPostScriptName = "Helvetica-Oblique"
    options.logoURL = logo
    options.metadataFields = [.cameraMake, .shutterSpeed]
    options.sizeFraction = 0.45
    options.position = .center
    options.readability = .background
    let output = try await WatermarkRenderer().render(image: image, sourceURL: source, options: options)
    let pixels = WatermarkTestImages.rgba(output)
    var red = 0
    var white = 0
    for offset in stride(from: 0, to: pixels.count, by: 4) {
      if pixels[offset] > 80 && pixels[offset + 1] < 3 { red += 1 }
      if pixels[offset] > 100 && pixels[offset + 1] > 100 && pixels[offset + 2] > 100 { white += 1 }
    }
    #expect(red > 100 && white > 100)
    #expect(WatermarkTestImages.pixel(output, x: 2, y: 2) == [0, 0, 0, 255])
  }

  @Test("각 원본의 EXIF 값만 읽고 없는 항목과 개인정보 GPS는 포함하지 않는다")
  func metadataIsPerSource() async throws {
    let directory = try WatermarkTestImages.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let renderer = WatermarkRenderer()
    let image = try WatermarkTestImages.image(width: 20, height: 10)
    for make in ["Alpha", "Beta"] {
      let url = directory.appendingPathComponent("\(make).tiff")
      try WatermarkTestImages.write(image, to: url, metadata: WatermarkTestImages.exif(make: make))
      let values = try await renderer.metadataValues(sourceURL: url)
      #expect(values[.cameraMake] == make)
      #expect(values[.filename] == "\(make).tiff")
      #expect(values[.cameraModel] == "Demo One")
      #expect(values[.captureDate] == "2026:10:05 10:20:30")
      #expect(values[.shutterSpeed] == "1/250 s")
      #expect(values[.aperture] == "f/2.8")
      #expect(values[.iso] == "400")
      #expect(values[.focalLength] == "50 mm")
      #expect(values[.lens] == nil)
    }
    let bare = directory.appendingPathComponent("bare.png")
    try WatermarkTestImages.write(image, to: bare)
    #expect(try await renderer.metadataValues(sourceURL: bare) == [.filename: "bare.png"])
    var options = WatermarkOptions()
    options.isEnabled = true
    options.metadataFields = [.cameraMake, .lens]
    #expect(try await renderer.render(image: image, sourceURL: bare, options: options) === image)
  }

  @Test("설정 변경에는 EXIF를 재사용하고 원본 변경에는 갱신하며 캐시 수를 제한한다")
  func metadataCacheIsBoundedAndInvalidated() async throws {
    let directory = try WatermarkTestImages.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let renderer = WatermarkRenderer()
    let image = try WatermarkTestImages.image(width: 64, height: 48)
    let first = directory.appendingPathComponent("first.tiff")
    try WatermarkTestImages.write(image, to: first, metadata: WatermarkTestImages.exif(make: "Before"))
    var options = WatermarkOptions()
    options.isEnabled = true
    options.metadataFields = [.cameraMake]
    for position in WatermarkPosition.allCases {
      options.position = position
      _ = try await renderer.render(image: image, sourceURL: first, options: options)
    }
    #expect(await renderer.metadataLoadCount == 1)
    try WatermarkTestImages.write(image, to: first,
      metadata: WatermarkTestImages.exif(make: "Changed Camera With A Different Size"))
    #expect(try await renderer.metadataValues(sourceURL: first)[.cameraMake] == "Changed Camera With A Different Size")
    #expect(await renderer.metadataLoadCount == 2)
    for index in 0..<(WatermarkRenderer.metadataCacheLimit + 5) {
      let url = directory.appendingPathComponent("\(index).png")
      try WatermarkTestImages.write(image, to: url)
      _ = try await renderer.metadataValues(sourceURL: url)
    }
    #expect(await renderer.metadataCacheEntryCount == WatermarkRenderer.metadataCacheLimit)
  }

  @Test("큰 로고는 필요한 크기로 읽으며 방향·투명도를 보존한다")
  func boundedLogoDecode() throws {
    let directory = try WatermarkTestImages.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("large.tiff")
    try WatermarkTestImages.write(
      WatermarkTestImages.image(width: 1600, height: 800, color: (0, 1, 0, 0.5)), to: url,
      metadata: [kCGImagePropertyOrientation: 6])
    let logo = try WatermarkRenderer.downsampleLogo(url: url, maximumPixelSize: 100)
    #expect(logo.width == 50 && logo.height == 100)
    let pixel = WatermarkTestImages.pixel(logo, x: 25, y: 50)
    #expect((126...129).contains(Int(pixel[3])))
  }

  @Test("워터마크 밖의 Display P3 색과 부동소수 HDR 밝기를 유지한다")
  func preservesColorSpaceAndHDR() async throws {
    let size = 64
    var pixels = [Float](repeating: 0, count: size * size * 4)
    for i in stride(from: 0, to: pixels.count, by: 4) {
      pixels[i] = 1.5; pixels[i + 1] = 0.2; pixels[i + 2] = 0.05; pixels[i + 3] = 1
    }
    let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
    let data = pixels.withUnsafeBytes { Data($0) }
    let provider = try #require(CGDataProvider(data: data as CFData))
    let image = try #require(CGImage(width: size, height: size, bitsPerComponent: 32,
      bitsPerPixel: 128, bytesPerRow: size * 16, space: space,
      bitmapInfo: [.floatComponents, .byteOrder32Little,
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    var options = WatermarkOptions()
    options.isEnabled = true
    options.text = "HDR"
    options.readability = .none
    let output = try await WatermarkRenderer().render(image: image,
      sourceURL: URL(fileURLWithPath: "/unused.tiff"), options: options)
    #expect(output.bitsPerComponent > 8)
    #expect(output.colorSpace?.name == space.name)
    var sample = [Float](repeating: 0, count: 4)
    sample.withUnsafeMutableBytes { bytes in
      CIContext().render(CIImage(cgImage: output), toBitmap: bytes.baseAddress!, rowBytes: 16,
        bounds: CGRect(x: 2, y: 60, width: 1, height: 1), format: .RGBAf, colorSpace: space)
    }
    #expect(abs(sample[0] - 1.5) < 0.01)
    #expect(abs(sample[1] - 0.2) < 0.01)
    #expect(abs(sample[2] - 0.05) < 0.01)
  }

  @Test("취소된 요청은 메타데이터나 로고를 읽지 않는다")
  func cancellationStopsWork() async throws {
    let image = try WatermarkTestImages.image(width: 32, height: 24)
    let renderer = WatermarkRenderer()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      var options = WatermarkOptions()
      options.isEnabled = true
      options.metadataFields = [.cameraMake]
      return try await renderer.render(image: image,
        sourceURL: URL(fileURLWithPath: "/missing.tiff"), options: options)
    }
    do {
      _ = try await task.value
      Issue.record("취소된 요청이 완료되었습니다.")
    } catch is CancellationError {} catch { Issue.record("취소 오류가 아닙니다: \(error)") }
    #expect(await renderer.metadataLoadCount == 0)
  }
}

enum WatermarkTestImages {
  static func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("watermark-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }

  static func image(width: Int, height: Int,
    color: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 1)) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: color.3)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
  }

  static func write(_ image: CGImage, to url: URL, metadata: [CFString: Any] = [:]) throws {
    let type: String
    switch url.pathExtension.lowercased() {
    case "tiff": type = "public.tiff"
    case "jpg", "jpeg": type = "public.jpeg"
    default: type = "public.png"
    }
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
  }

  /// A synthetic study scene, independent of files used during manual UI checks.
  static func studyImage(width: Int, height: Int, index: Int) throws -> CGImage {
    let bitmap = try #require(CGContext(data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    bitmap.setFillColor(CGColor(red: 0.1 + CGFloat(index) * 0.025, green: 0.2, blue: 0.35, alpha: 1))
    bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
    bitmap.setFillColor(CGColor(red: 0.82, green: 0.52, blue: 0.18, alpha: 1))
    bitmap.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
    bitmap.setFillColor(CGColor(red: 0.1, green: 0.55, blue: 0.4, alpha: 1))
    bitmap.fillEllipse(in: CGRect(x: width / 3, y: height / 3, width: width / 5, height: height / 5))
    return try #require(bitmap.makeImage())
  }

  static func exif(make: String) -> [CFString: Any] {
    [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: make, kCGImagePropertyTIFFModel: "Demo One"],
      kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:05 10:20:30",
        kCGImagePropertyExifExposureTime: 0.004, kCGImagePropertyExifFNumber: 2.8,
        kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifFocalLength: 50],
      kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.34, kCGImagePropertyGPSLatitudeRef: "N"]]
  }

  static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
    var values = [UInt8](repeating: 0, count: 4)
    values.withUnsafeMutableBytes { bytes in
      CIContext().render(CIImage(cgImage: image), toBitmap: bytes.baseAddress!, rowBytes: 4,
        bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
    return values
  }

  static func rgba(_ image: CGImage) -> [UInt8] {
    var values = [UInt8](repeating: 0, count: image.width * image.height * 4)
    values.withUnsafeMutableBytes { bytes in
      CIContext().render(CIImage(cgImage: image), toBitmap: bytes.baseAddress!, rowBytes: image.width * 4,
        bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
    return values
  }

  /// Occupied alpha rows in bitmap memory order. Uppercase text leaves separate bands
  /// between lines, allowing glyph dimensions to be checked independently of layout.
  static func alphaBands(_ image: CGImage) -> [CGRect] {
    let values = rgba(image)
    var result: [CGRect] = []
    var active: CGRect?
    for y in 0..<image.height {
      var left = image.width
      var right = -1
      for x in 0..<image.width where values[(y * image.width + x) * 4 + 3] > 96 {
        left = min(left, x)
        right = max(right, x)
      }
      if right >= left {
        let row = CGRect(x: left, y: y, width: right - left + 1, height: 1)
        if let previous = active { active = previous.union(row) } else { active = row }
      } else if let previous = active {
        result.append(previous)
        active = nil
      }
    }
    if let active { result.append(active) }
    return result
  }
}
