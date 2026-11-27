import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

@Suite("사진과 영상의 개별 확장자 필터")
struct LibraryMediaFilterTests {
  @Test("미디어 통합 판정은 모든 지원 확장자·대문자·폴더·ZIP에서 개별 판정과 일치한다")
  func unifiedMediaKindPreservesContract() {
    let extensions = MediaFormatRegistry.videoExtensions.union(MediaFormatRegistry.audioExtensions)
      .union(["png","dng","jpg","","unknown"])
    for ext in extensions {
      for suffix in [ext,ext.uppercased()] {
        for directory in [false,true] {
          let url = URL(fileURLWithPath: "/fixture/file.\(suffix)",isDirectory: directory)
          let asset = ImageAsset(url: url,byteCount: 100,modificationDate: nil)
          #expect(asset.isPlaybackMedia == (asset.isVideo || asset.isAudio))
          #expect(MediaFormatRegistry.isPlaybackMedia(url) == (MediaFormatRegistry.isVideo(url) || MediaFormatRegistry.isAudio(url)))
          var archived = asset
          archived.archiveOrigin = ArchiveImageOrigin(archiveURL: URL(fileURLWithPath: "/archive.zip"),entryPath: "file.\(suffix)")
          #expect(!archived.isPlaybackMedia)
        }
      }
    }
  }

  @Test("미리 준비한 미디어 조건이 공백·대소문자·별칭·ZIP·확장자 없는 이름에서 기존 조건과 같다")
  func preparedPredicateMatchesExistingContract() {
    var samples = assets + ["sound.M4A","song.wav","RAW.DNG","no_extension","folder.mp4/"].map {
      ImageAsset(url: URL(fileURLWithPath: "/synthetic/\($0)"),byteCount: 100,modificationDate: nil)
    }
    samples.append(ImageAsset(url: URL(fileURLWithPath: "/extracted/cache.png"),byteCount: 100,
      modificationDate: nil,archiveOrigin: ArchiveImageOrigin(archiveURL: URL(fileURLWithPath: "/archive.zip"),entryPath: "photo.DNG")))
    let extensionSets: [Set<String>] = [[],[""],["*"],["*.PNG"," png ",".MP4"],["%M4A%","DNG","*.jpg"]]
    for kind in LibraryMediaKind.allCases {
      for formats: Set<ImageFormatFilter> in [[],[.other],[.jpeg,.raw]] {
        for extensions in extensionSets {
          let query = LibraryQuery(formats: formats,mediaKind: kind,fileExtensions: extensions)
          let prepared = PreparedLibraryMediaPredicate(query: query)
          #expect(samples.filter(prepared.matches) == samples.filter { LibraryMediaFilter.matches($0,query: query) })
        }
      }
    }
  }

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
