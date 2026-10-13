import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

@Suite("좌우·상하 반전의 화면 기준 기하와 비파괴 출력")
struct ImageFlipTests {
  @Test("이전 저장값은 반전하지 않으며 새 반전 상태는 저장·캐시·초기화에 반영된다")
  func persistedFlagsAndIdentity() throws {
    let legacy = try JSONDecoder().decode(ImageAdjustments.self, from: Data("""
      {"quarterTurns":1,"brightness":0.2,
       "crop":{"x":0.125,"y":0.25,"width":0.5,"height":0.25}}
      """.utf8))
    #expect(!legacy.isFlippedHorizontally && !legacy.isFlippedVertically)
    #expect(legacy.normalizedQuarterTurns == 1 && legacy.brightness == 0.2)
    #expect(legacy.crop == NormalizedCrop(x: 0.125, y: 0.25, width: 0.5, height: 0.25))
    #expect(try JSONDecoder().decode(ImageAdjustments.self, from: Data("{}".utf8)) == .identity)

    var horizontal = ImageAdjustments()
    horizontal.flipHorizontally()
    var vertical = ImageAdjustments()
    vertical.flipVertically()
    var both = horizontal
    both.flipVertically()
    #expect(Set([ImageAdjustments.identity, horizontal, vertical, both]).count == 4)
    for value in [horizontal, vertical, both] {
      #expect(!value.isIdentity)
      let data = try JSONEncoder().encode(value)
      #expect(try JSONDecoder().decode(ImageAdjustments.self, from: data) == value)
      let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(fields["isFlippedHorizontally"] as? Bool == value.isFlippedHorizontally)
      #expect(fields["isFlippedVertically"] as? Bool == value.isFlippedVertically)
      var reset = value
      reset.reset()
      #expect(reset == .identity && reset.isIdentity)
    }
    horizontal.flipHorizontally()
    vertical.flipVertically()
    #expect(horizontal == .identity && horizontal.isIdentity)
    #expect(vertical == .identity && vertical.isIdentity)
  }

  @Test("반전한 크롭 좌표는 선택 크기를 유지하고 같은 축을 두 번 반전하면 복원된다")
  func cropCoordinatesAndRoundTrip() {
    let crop = NormalizedCrop(x: 0.125, y: 0.25, width: 0.25, height: 0.25)
    #expect(crop.flippedHorizontally()
      == NormalizedCrop(x: 0.625, y: 0.25, width: 0.25, height: 0.25))
    #expect(crop.flippedVertically()
      == NormalizedCrop(x: 0.125, y: 0.5, width: 0.25, height: 0.25))
    #expect(crop.flippedHorizontally().flippedHorizontally() == crop)
    #expect(crop.flippedVertically().flippedVertically() == crop)
    #expect(NormalizedCrop.full.flippedHorizontally() == .full)
    #expect(NormalizedCrop.full.flippedVertically() == .full)

    var edited = ImageAdjustments()
    edited.crop = crop
    edited.flipHorizontally()
    edited.flipVertically()
    #expect(edited.crop == crop.flippedHorizontally().flippedVertically())
    edited.flipVertically()
    edited.flipHorizontally()
    #expect(edited.crop == crop)
    #expect(!edited.isFlippedHorizontally && !edited.isFlippedVertically)
  }

  @Test("같은 파이프라인의 캐시에서도 좌우·상하·양축과 두 번 복원의 실제 픽셀이 구별된다")
  func asymmetricGridFlipsAndCacheKeys() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("grid.png")
    try writeGrid(to: url, cellSize: 128)
    let pipeline = ImagePipeline()
    var horizontal = ImageAdjustments()
    horizontal.flipHorizontally()
    var vertical = ImageAdjustments()
    vertical.flipVertically()
    var both = horizontal
    both.flipVertically()
    var horizontalTwice = horizontal
    horizontalTwice.flipHorizontally()
    var verticalTwice = vertical
    verticalTwice.flipVertically()

    let cases: [(ImageAdjustments, [Cell])] = [
      (.identity, [.red, .green, .blue, .cyan, .magenta, .yellow]),
      (horizontal, [.blue, .green, .red, .yellow, .magenta, .cyan]),
      (vertical, [.cyan, .magenta, .yellow, .red, .green, .blue]),
      (both, [.yellow, .magenta, .cyan, .blue, .green, .red]),
      (horizontalTwice, [.red, .green, .blue, .cyan, .magenta, .yellow]),
      (verticalTwice, [.red, .green, .blue, .cyan, .magenta, .yellow]),
    ]
    // Reuse the URL, dimensions and pipeline so missing flags in the render key
    // would incorrectly return the first cached bitmap for later cases.
    for (adjustments, expected) in cases {
      let frame = try await pipeline.renderFrame(url: url, maxPixelSize: 512,
        adjustments: adjustments, prefersHDR: false)
      #expect(frame.image.width == 384 && frame.image.height == 256)
      #expect(frame.sourcePixelSize == CGSize(width: 384, height: 256))
      #expect(try grid(in: frame.image, columns: 3, rows: 2) == expected)
    }
  }

  @Test("반전과 회전의 순서를 화면 기준으로 적용하고 회전 때 반전 축을 교환한다")
  func rotationAfterFlipUsesDisplayedAxes() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("grid.png")
    try writeGrid(to: url, cellSize: 128)
    var horizontalThenClockwise = ImageAdjustments()
    horizontalThenClockwise.flipHorizontally()
    horizontalThenClockwise.rotateClockwise()
    #expect(!horizontalThenClockwise.isFlippedHorizontally)
    #expect(horizontalThenClockwise.isFlippedVertically)
    #expect(horizontalThenClockwise.normalizedQuarterTurns == 1)

    var clockwiseThenHorizontal = ImageAdjustments()
    clockwiseThenHorizontal.rotateClockwise()
    clockwiseThenHorizontal.flipHorizontally()
    var horizontalThenCounterclockwise = ImageAdjustments()
    horizontalThenCounterclockwise.flipHorizontally()
    horizontalThenCounterclockwise.rotateCounterclockwise()
    #expect(!horizontalThenCounterclockwise.isFlippedHorizontally)
    #expect(horizontalThenCounterclockwise.isFlippedVertically)
    #expect(horizontalThenCounterclockwise.normalizedQuarterTurns == 3)
    var verticalThenClockwise = ImageAdjustments()
    verticalThenClockwise.flipVertically()
    verticalThenClockwise.rotateClockwise()
    #expect(verticalThenClockwise.isFlippedHorizontally)
    #expect(!verticalThenClockwise.isFlippedVertically)

    let cases: [(ImageAdjustments, [Cell])] = [
      (horizontalThenClockwise, [.yellow, .blue, .magenta, .green, .cyan, .red]),
      (clockwiseThenHorizontal, [.red, .cyan, .green, .magenta, .blue, .yellow]),
      (horizontalThenCounterclockwise, [.red, .cyan, .green, .magenta, .blue, .yellow]),
      (verticalThenClockwise, [.red, .cyan, .green, .magenta, .blue, .yellow]),
    ]
    let pipeline = ImagePipeline()
    for (adjustments, expected) in cases {
      let frame = try await pipeline.renderFrame(url: url, maxPixelSize: nil,
        adjustments: adjustments, prefersHDR: false)
      #expect(frame.image.width == 256 && frame.image.height == 384)
      #expect(frame.sourcePixelSize == CGSize(width: 256, height: 384))
      #expect(try grid(in: frame.image, columns: 2, rows: 3) == expected)
    }
    horizontalThenClockwise.rotateCounterclockwise()
    #expect(horizontalThenClockwise.normalizedQuarterTurns == 0)
    #expect(horizontalThenClockwise.isFlippedHorizontally)
    #expect(!horizontalThenClockwise.isFlippedVertically)
  }

  @Test("이미 자른 사진을 반전·회전해도 선택했던 원본 내용은 그대로 유지된다")
  func flippingPreservesTheSelectedCropContents() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("grid.png")
    try writeGrid(to: url, cellSize: 128)
    var cropped = ImageAdjustments()
    cropped.crop = NormalizedCrop(x: 0, y: 0, width: 2.0 / 3.0, height: 1)
    var horizontal = cropped
    horizontal.flipHorizontally()
    var vertical = cropped
    vertical.flipVertically()
    var rotated = horizontal
    rotated.rotateClockwise()
    let cases: [(ImageAdjustments, [Cell])] = [
      (cropped, [.red, .green, .cyan, .magenta]),
      (horizontal, [.green, .red, .magenta, .cyan]),
      (vertical, [.cyan, .magenta, .red, .green]),
      (rotated, [.magenta, .green, .cyan, .red]),
    ]
    let pipeline = ImagePipeline()
    for (adjustments, expected) in cases {
      let frame = try await pipeline.renderFrame(url: url, maxPixelSize: nil,
        adjustments: adjustments, prefersHDR: false)
      #expect(frame.image.width == 256 && frame.image.height == 256)
      #expect(frame.sourcePixelSize == CGSize(width: 256, height: 256))
      #expect(try grid(in: frame.image, columns: 2, rows: 2) == expected)
    }
  }

  @Test("자르기 초안을 만든 뒤 반전·회전·사진 선택이 바뀌어도 원래 피사체에만 적용한다")
  @MainActor
  func capturedCropSurvivesOrientationAndSelectedFileChanges() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("01.png")
    try writeGrid(to: source, cellSize: 128)
    try writeGrid(to: directory.appendingPathComponent("02.png"), cellSize: 128)
    let suite = "ImageFlipTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    defer { store.saveSessionNow() }
    await store.photoMarks.waitUntilReady()
    store.open(urls: [directory])
    let deadline = ContinuousClock.now + .seconds(10)
    while store.isLoading || store.isFiltering {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(store.assets.count == 2)
    store.select(index: 0)
    let capturedAsset = try #require(store.currentAsset)
    store.flipHorizontally()
    store.rotateClockwise()
    let reference = store.currentAdjustments
    // In this sheet orientation, the bottom row is [cyan, red], which is
    // the original image's first column after horizontal flip then rotation.
    let draft = NormalizedCrop(x: 0, y: 2.0 / 3.0, width: 1, height: 1.0 / 3.0)

    store.rotateCounterclockwise()
    store.flipVertically()
    store.flipHorizontally()
    #expect(!store.currentAdjustments.isFlippedHorizontally)
    #expect(store.currentAdjustments.isFlippedVertically)
    #expect(store.currentAdjustments.normalizedQuarterTurns == 0)
    store.select(index: 1)
    let otherAsset = try #require(store.currentAsset)
    store.applyCrop(draft, to: capturedAsset, relativeTo: reference)
    #expect(store.currentAsset == otherAsset)
    #expect(store.currentAdjustments.isIdentity)

    let edited = store.adjustments(for: capturedAsset)
    let crop = try #require(edited.crop)
    #expect(abs(crop.x) < 1e-8 && abs(crop.y) < 1e-8)
    #expect(abs(crop.width - 1.0 / 3.0) < 1e-8 && abs(crop.height - 1) < 1e-8)
    let frame = try await store.pipeline.renderFrame(url: capturedAsset.url,
      maxPixelSize: nil, adjustments: edited, prefersHDR: false)
    #expect(frame.image.width == 128 && frame.image.height == 256)
    #expect(try grid(in: frame.image, columns: 1, rows: 2) == [.cyan, .red])
  }

  @Test("축소 미리보기와 PNG 내보내기는 반전·회전·크롭 결과가 같고 원본을 보존한다")
  func reducedPreviewAndPNGExportAgree() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.png")
    let destination = directory.appendingPathComponent("flipped.png")
    try writeGrid(to: source, cellSize: 512)
    let originalBytes = try Data(contentsOf: source)
    var adjustments = ImageAdjustments()
    adjustments.crop = NormalizedCrop(x: 0, y: 0, width: 2.0 / 3.0, height: 1)
    adjustments.flipHorizontally()
    adjustments.rotateClockwise()
    adjustments.flipVertically()
    let expected: [Cell] = [.cyan, .red, .magenta, .green]
    let pipeline = ImagePipeline()
    let preview = try await pipeline.renderFrame(url: source, maxPixelSize: 256,
      adjustments: adjustments, prefersHDR: false)
    try await ImageExporter(pipeline: pipeline).export(sourceURL: source,
      destinationURL: destination, format: .png, quality: 1, adjustments: adjustments)
    let outputSource = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
    let output = try #require(CGImageSourceCreateImageAtIndex(outputSource, 0, nil))
    #expect(preview.image.width == 256 && preview.image.height == 256)
    #expect(preview.sourcePixelSize == CGSize(width: 1_024, height: 1_024))
    #expect(output.width == 1_024 && output.height == 1_024)
    #expect(try grid(in: preview.image, columns: 2, rows: 2) == expected)
    #expect(try grid(in: output, columns: 2, rows: 2) == expected)
    #expect(try Data(contentsOf: source) == originalBytes)
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil)
      as? [CFString: Any])
    #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 1_024)
    #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 1_024)
    #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
  }

  private enum Cell: CaseIterable {
    case red, green, blue, cyan, magenta, yellow

    var rgb: [UInt8] {
      switch self {
      case .red: [225, 25, 25]
      case .green: [25, 225, 25]
      case .blue: [25, 25, 225]
      case .cyan: [25, 225, 225]
      case .magenta: [225, 25, 225]
      case .yellow: [225, 225, 25]
      }
    }
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imageviewer-flips-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
  }

  private func writeGrid(to url: URL, cellSize: Int) throws {
    let width = cellSize * 3, height = cellSize * 2
    let layout: [Cell] = [.red, .green, .blue, .cyan, .magenta, .yellow]
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let color = layout[(y / cellSize) * 3 + x / cellSize].rgb
        let offset = (y * width + x) * 4
        for channel in 0..<3 { pixels[offset + channel] = color[channel] }
      }
    }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
      bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
      UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
  }

  /// Sample cell centers in the CGImage's top-left pixel coordinates; sampling
  /// away from edges tolerates reduction filters without hiding axis mistakes.
  private func grid(in image: CGImage, columns: Int, rows: Int) throws -> [Cell] {
    var cells: [Cell] = []
    for row in 0..<rows {
      for column in 0..<columns {
        let x = (2 * column + 1) * image.width / (2 * columns)
        let y = (2 * row + 1) * image.height / (2 * rows)
        let pixel = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        let context = try #require(CGContext(data: nil, width: 1, height: 1,
          bitsPerComponent: 8, bytesPerRow: 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        func distance(_ cell: Cell) -> Int {
          zip(cell.rgb, 0..<3).reduce(0) { $0 + abs(Int($1.0) - Int(bytes[$1.1])) }
        }
        let nearest = try #require(Cell.allCases.min { distance($0) < distance($1) })
        #expect(distance(nearest) < 40)
        #expect(bytes[3] >= 254)
        cells.append(nearest)
      }
    }
    return cells
  }
}
