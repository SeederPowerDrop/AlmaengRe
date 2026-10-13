import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

@Suite("애니메이션 프레임과 구간 저장")
struct AnimatedImageExporterTests {
  @Test("GIF·APNG·WebP의 캔버스·각 프레임 시간·반복 횟수를 읽는다", arguments: Fixture.allCases)
  func readsMetadata(fixture: Fixture) async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try write(fixture, in: directory)
    let document = try await AnimatedImageExporter().inspect(url: source)
    #expect(document.frameCount == 3 && document.isAnimated)
    #expect(document.width == 8 && document.height == 6)
    #expect(document.loopCount == fixture.totalPlayCount)
    #expect(abs(document.totalDuration - 0.6) < 0.001)
    #expect(document.frames.map(\.index) == [0, 1, 2])
    for (frame, duration) in zip(document.frames, [0.1, 0.2, 0.3]) {
      #expect(abs(frame.duration - duration) < 0.001)
    }
    #expect(abs(document.frames[2].startTime - 0.3) < 0.001)
  }

  @Test("임의 프레임 PNG 추출은 부분 프레임·이전 화면 지우기·투명도를 반영한다", arguments: Fixture.allCases)
  func extractsCompositedFrames(fixture: Fixture) async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try write(fixture, in: directory)
    let original = try Data(contentsOf: source)
    let exporter = AnimatedImageExporter()
    // Start at the last frame; the APNG fixture uses 2x4 offset frames after its
    // 8x6 first frame, with dispose-to-background and a transparent canvas.
    for (sequence, frameIndex) in [2, 0, 1, 2].enumerated() {
      let destination = directory.appendingPathComponent("frame-\(sequence).png")
      _ = try await exporter.extractFrame(sourceURL: source, destinationURL: destination, frameIndex: frameIndex)
      let image = try decoded(destination, index: 0)
      #expect(image.width == 8 && image.height == 6)
      let pixels = try rgba(image)
      for (index, x) in [0, 3, 6].enumerated() {
        let pixel = (2 * image.width + x) * 4
        #expect(pixels[pixel + 3] == (index == frameIndex ? 255 : 0))
        if index == frameIndex { #expect(pixels[pixel + index] > 245) }
      }
    }
    #expect(try Data(contentsOf: source) == original)
    #expect(try temporaryFiles(directory).isEmpty)
  }

  @Test("구간을 새 GIF·APNG에 저장하고 투명도·시간·반복을 보존한다",
    arguments: AnimatedImageExportFormat.allCases)
  func exportsTrimmedAnimation(format: AnimatedImageExportFormat) async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try write(.apng, in: directory)
    let original = try Data(contentsOf: source)
    let destination = directory.appendingPathComponent("trimmed.\(format.fileExtension)")
    let exporter = AnimatedImageExporter()
    let result = try await exporter.export(sourceURL: source, destinationURL: destination,
      format: format, options: .init(frameRange: 1...2))
    #expect(result.sourceFrameIndices == [1, 2])
    #expect(abs(result.totalDuration - 0.5) < 0.001)
    let document = try await exporter.inspect(url: destination)
    #expect(document.frameCount == 2 && document.width == 8 && document.height == 6)
    #expect(document.loopCount == 2)
    #expect(abs(document.totalDuration - 0.5) < 0.011)
    for index in 0..<2 {
      let image = try decoded(destination, index: index)
      let pixels = try rgba(image)
      #expect(pixels[(2 * 8) * 4 + 3] == 0)
      #expect(pixels[(2 * 8 + 3) * 4 + 3] == (index == 0 ? 255 : 0))
      #expect(pixels[(2 * 8 + 6) * 4 + 3] == (index == 1 ? 255 : 0))
    }
    #expect(try Data(contentsOf: source) == original)
    #expect(try temporaryFiles(directory).isEmpty)
  }

  @Test("APNG의 이전 화면 복원·겹치기·반투명 픽셀을 이중 합성하지 않는다")
  func restoresPreviousCanvasWithoutDoubleBlending() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("restore-previous.png")
    // Synthetic APNG: persistent red frame, green OVER with PREVIOUS disposal,
    // then 50%-alpha blue OVER. The final canvas has red and blue, no green.
    let fixture = "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAGCAYAAAD+Bd/7AAAACGFjVEwAAAADAAAAAM7tusAAAAAaZmNUTAAAAAAAAAAIAAAABgAAAAAAAAAAAAEACgAAHz2iFwAAABtJREFUeJxjYCAE/jMw/AdhXPJMhAygXAFBAACCtAQDLSGvTQAAABpmY1RMAAAAAQAAAAUAAAAEAAAAAAAAAAEAAQAFAgHz+XfwAAAAG2ZkQVQAAAACeJxjZEAG/xn+gygmFEEoIF4QAIsaAgaEPr9aAAAAGmZjVEwAAAADAAAACAAAAAQAAAAAAAAAAQADAAoAAWruQvkAAAAaZmRBVAAAAAR4nGNkwAn+N4BIJtwKIIByBQCfKwGHKWW6QQAAAABJRU5ErkJggg=="
    try #require(Data(base64Encoded: fixture)).write(to: source)
    let destination = directory.appendingPathComponent("last.png")
    _ = try await AnimatedImageExporter().extractFrame(sourceURL: source,
      destinationURL: destination, frameIndex: 2)
    let pixels = try rgba(decoded(destination, index: 0))
    #expect(pixels[(2 * 8) * 4] > 245)
    #expect(pixels[(2 * 8) * 4 + 3] == 255)
    #expect(pixels[(2 * 8 + 3) * 4 + 3] == 0)
    #expect((127...129).contains(Int(pixels[(2 * 8 + 6) * 4 + 3])))
    #expect((127...129).contains(Int(pixels[(2 * 8 + 6) * 4 + 2])))
  }

  @Test("축소와 프레임 건너뛰기는 비율과 선택 구간의 전체 재생시간을 유지한다")
  func resizeAndStride() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try write(.gif, in: directory)
    let destination = directory.appendingPathComponent("small.png")
    let exporter = AnimatedImageExporter()
    let result = try await exporter.export(sourceURL: source, destinationURL: destination,
      format: .apng, options: .init(frameRange: 0...2, resize: .longestEdge(4), frameStride: 2))
    #expect(result.sourceFrameIndices == [0, 2])
    #expect(result.width == 4 && result.height == 3)
    let document = try await exporter.inspect(url: destination)
    #expect(document.width == 4 && document.height == 3 && document.frameCount == 2)
    #expect(abs(document.frames[0].duration - 0.3) < 0.001)
    #expect(abs(document.frames[1].duration - 0.3) < 0.001)
    #expect(abs(document.totalDuration - 0.6) < 0.001)
  }

  @Test("GIF의 유한 반복과 무한 반복을 전체 재생 횟수로 GIF·APNG에 보존한다",
    arguments: [UInt16(0), 1, 2, 5])
  func preservesGIFTotalPlays(repeats: UInt16) async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var data = try #require(Data(base64Encoded: Fixture.gif.base64))
    let marker = try #require(data.range(of: Data("NETSCAPE2.0".utf8)))
    // The extension is 03 01 <repeat-count little endian> 00. The file counts
    // repeats AFTER the first play; ImageIO's public properties count all plays.
    data[marker.upperBound + 2] = UInt8(repeats & 0xff)
    data[marker.upperBound + 3] = UInt8(repeats >> 8)
    let source = directory.appendingPathComponent("repeats.gif")
    try data.write(to: source)
    let expectedTotal = repeats == 0 ? 0 : Int(repeats) + 1
    let exporter = AnimatedImageExporter()
    #expect(try await exporter.inspect(url: source).loopCount == expectedTotal)
    for format in AnimatedImageExportFormat.allCases {
      let destination = directory.appendingPathComponent("copy.\(format.fileExtension)")
      _ = try await exporter.export(sourceURL: source, destinationURL: destination,
        format: format, options: .init(frameRange: 0...2))
      let document = try await exporter.inspect(url: destination)
      #expect(document.loopCount == expectedTotal)
      #expect(document.frameCount == 3)
    }
  }

  @Test("반복 확장이 없는 GIF는 다른 형식으로 저장해도 한 번만 재생한다")
  func nonLoopingGIFRemainsSinglePlay() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var data = try #require(Data(base64Encoded: Fixture.gif.base64))
    let marker = try #require(data.range(of: Data("NETSCAPE2.0".utf8)))
    data.removeSubrange((marker.lowerBound - 3)..<(marker.upperBound + 5))
    let source = directory.appendingPathComponent("single-play.gif")
    try data.write(to: source)
    let exporter = AnimatedImageExporter()
    let original = try await exporter.inspect(url: source)
    #expect((original.loopCount ?? 1) == 1)
    for format in AnimatedImageExportFormat.allCases {
      let destination = directory.appendingPathComponent("copy.\(format.fileExtension)")
      _ = try await exporter.export(sourceURL: source, destinationURL: destination,
        format: format, options: .init(frameRange: 0...2))
      let document = try await exporter.inspect(url: destination)
      #expect((document.loopCount ?? 1) == 1)
    }
  }

  @Test("취소하면 완성되지 않은 출력과 임시 파일이 남지 않는다")
  func cancellationCleansUp() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try write(.gif, in: directory)
    let original = try Data(contentsOf: source)
    let destination = directory.appendingPathComponent("cancelled.gif")
    let task = Task {
      try await AnimatedImageExporter().export(sourceURL: source, destinationURL: destination,
        format: .gif, options: .init(frameRange: 0...2), progress: { processed, _ in
          if processed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        })
    }
    do {
      _ = try await task.value
      Issue.record("취소된 변환이 완성된 결과를 공개했습니다.")
    } catch is CancellationError {}
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try temporaryFiles(directory).isEmpty)
    #expect(try Data(contentsOf: source) == original)
  }

  @Test("원본·링크·기존 출력·처리 중 생긴 파일을 덮어쓰지 않는다")
  func protectsSourcesAndDestinations() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try write(.gif, in: directory)
    let original = try Data(contentsOf: source)
    let linked = directory.appendingPathComponent("linked.gif")
    try FileManager.default.linkItem(at: source, to: linked)
    let symlink = directory.appendingPathComponent("symlink.gif")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
    let existing = directory.appendingPathComponent("existing.gif")
    let existingContents = Data("Keep this file".utf8)
    try existingContents.write(to: existing)
    let exporter = AnimatedImageExporter()
    for destination in [source, linked, symlink, existing] {
      do {
        _ = try await exporter.export(sourceURL: source, destinationURL: destination,
          format: .gif, options: .init(frameRange: 0...2))
        Issue.record("기존 파일의 덮어쓰기를 허용했습니다.")
      } catch is AnimatedImageExportError {}
    }
    let conflict = directory.appendingPathComponent("concurrent.gif")
    do {
      _ = try await exporter.export(sourceURL: source, destinationURL: conflict,
        format: .gif, options: .init(frameRange: 0...2), progress: { processed, _ in
          if processed == 1 { try? existingContents.write(to: conflict) }
        })
      Issue.record("변환 도중 생긴 출력 파일을 덮어썼습니다.")
    } catch AnimatedImageExportError.destinationExists {}
    #expect(try Data(contentsOf: source) == original)
    #expect(try Data(contentsOf: existing) == existingContents)
    #expect(try Data(contentsOf: conflict) == existingContents)
    #expect(try temporaryFiles(directory).isEmpty)
  }

  @Test("범위를 벗어난 프레임 추출은 출력을 남기지 않는다")
  func rejectsInvalidFrame() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try write(.gif, in: directory)
    let destination = directory.appendingPathComponent("invalid.png")
    do {
      _ = try await AnimatedImageExporter().extractFrame(sourceURL: source,
        destinationURL: destination, frameIndex: 3)
      Issue.record("범위를 벗어난 프레임을 허용했습니다.")
    } catch AnimatedImageExportError.invalidFrameRange {}
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try temporaryFiles(directory).isEmpty)
  }

  @Test("외부에서 원본이 변경되면 결과를 공개하지 않는다")
  func detectsChangedSource() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try write(.gif, in: directory)
    let replacement = try Data(contentsOf: source) + Data([0])
    let destination = directory.appendingPathComponent("changed.gif")
    do {
      _ = try await AnimatedImageExporter().export(sourceURL: source, destinationURL: destination,
        format: .gif, options: .init(frameRange: 0...2), progress: { processed, total in
          if processed == total { try? replacement.write(to: source, options: .atomic) }
        })
      Issue.record("외부에서 변경된 원본으로 만든 결과를 공개했습니다.")
    } catch AnimatedImageExportError.sourceChanged {}
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try temporaryFiles(directory).isEmpty)
    #expect(try Data(contentsOf: source) == replacement)
  }

  enum Fixture: String, CaseIterable, Sendable {
    case gif, apng, webp
    var totalPlayCount: Int { self == .gif ? 3 : 2 }
    var base64: String {
      // Generated synthetic 8x6 frames: red, green, then blue 2x4 rectangles
      // over a transparent canvas; frame delays 100/200/300ms. The GIF stores
      // 2 repeats (3 plays), whereas APNG/WebP store 2 total plays.
      switch self {
      case .gif:
        "R0lGODlhCAAGAIEAAAAAAP8AAAAAAAAAACH/C05FVFNDQVBFMi4wAwECAAAh+QQJCgAAACwAAAAACAAGAAAIFQABCBwoMEAAggUPIjSIEADDhhADAgAh+QQJFAAAACwAAAAACAAGAIEAAAAA/wAAAAAAAAAIFQABCBxIEECAAAUNIix4MGHDhAQDAgAh+QQJHgAAACwAAAAACAAGAIEAAAAAAP8AAAAAAAAIFAABCBxIkGCAAAUBHEy4sGDDhAEBADs="
      case .apng:
        "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAGCAYAAAD+Bd/7AAAACGFjVEwAAAADAAAAAiDj2+wAAAAaZmNUTAAAAAAAAAAIAAAABgAAAAAAAAAAAAEACgEABiaTVgAAABtJREFUeJxjYCAE/jMw/AdhXPJMhAygXAFBAACCtAQDLSGvTQAAABpmY1RMAAAAAQAAAAIAAAAEAAAAAwAAAAEAAQAFAQB8D/nvAAAAGmZkQVQAAAACeJxjZPjP8J+BgYGBCURgZwAAQnICBnsXBYoAAAAaZmNUTAAAAAMAAAACAAAABAAAAAYAAAABAAMACgEAkVKSGQAAABpmZEFUAAAABHicY2Rg+P+fgYGBgQlEYGcAAEFzAgaFuRZKAAAAAElFTkSuQmCC"
      case .webp:
        "UklGRr4AAABXRUJQVlA4WAoAAAASAAAABwAABQAAQU5JTQYAAAAAAAAAAgBBTk1GLgAAAAAAAAAAAAEAAAQAAGQAAAJWUDhMFgAAAC8BAAEQDxDzH/MfDIUAAqCgieh/8A9BTk1GKgAAAAAAAAAAAAQAAAQAAMgAAAJWUDhMEQAAAC8EAAEQDzD/EfMfjMGI6H94AEFOTUYqAAAAAQAAAAAABQAABAAALAEAAlZQOEwRAAAALwUAARAPEDH/8x+MgYnof3gA"
      }
    }
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imageviewer-animation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
  }

  private func write(_ fixture: Fixture, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("original.\(fixture.rawValue)")
    try #require(Data(base64Encoded: fixture.base64)).write(to: url)
    return url
  }

  private func decoded(_ url: URL, index: Int) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
  }

  private func rgba(_ image: CGImage) throws -> [UInt8] {
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
    return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
  }

  private func temporaryFiles(_ directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix(".imageviewer-animation-") }
  }
}
