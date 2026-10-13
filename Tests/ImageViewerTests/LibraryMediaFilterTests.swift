import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

@Suite("사진과 영상의 개별 확장자 필터")
struct LibraryMediaFilterTests {
  private let assets = ["photo.jpg", "photo.png", "clip.mp4", "clip.mov", "extra.qoi"].map {
    ImageAsset(url: URL(fileURLWithPath: "/synthetic/\($0)"), byteCount: 100, modificationDate: nil)
  }

  @Test("미디어 종류와 확장자를 실제 정렬 엔진에 함께 적용한다")
  func kindsAndExtensions() throws {
    var query = LibraryQuery()
    query.mediaKind = .images
    #expect(try RustImageEngine.query(assets, options: query).count == 3)
    query.mediaKind = .videos
    #expect(try RustImageEngine.query(assets, options: query).count == 2)
    query.mediaKind = .all
    query.fileExtensions = ["*.PNG", ".mp4"]
    #expect(Set(try RustImageEngine.query(assets, options: query).map(\.filename)) == ["photo.png", "clip.mp4"])
    query.mediaKind = .images
    #expect(try RustImageEngine.query(assets, options: query).map(\.filename) == ["photo.png"])
    query.fileExtensions = []
    query.formats = [.other]
    #expect(try RustImageEngine.query(assets, options: query).map(\.filename) == ["extra.qoi"])
  }

  @Test("새 JPEG 별칭은 폴더 검색과 디코딩과 JPEG 필터를 통과한다")
  func jpegAliasesDecode() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jpeg-alias-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let context = try #require(CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
    let image = try #require(context.makeImage())
    let pipeline = ImagePipeline()
    for ext in ["jif", "jfi"] {
      let url = folder.appendingPathComponent("alias.\(ext)")
      let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
      CGImageDestinationAddImage(destination, image, nil)
      #expect(CGImageDestinationFinalize(destination))
      let frame = try await pipeline.renderFrame(url: url, maxPixelSize: 16, adjustments: .identity, prefersHDR: false)
      #expect(frame.image.width == 16 && frame.image.height == 12)
    }
    let scanned = try RustImageEngine.scan(folder: folder)
    #expect(scanned.count == 2)
    var query = LibraryQuery(); query.formats = [.jpeg]
    #expect(try RustImageEngine.query(scanned, options: query).count == 2)
  }
}
