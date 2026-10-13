@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

@Suite("파일·촬영 정보 정렬")
struct LibraryMetadataSortTests {
  @Test("새 수치 정렬은 실제 숫자를 비교하고 결측값과 동률 이름 순서를 보존한다")
  func numericOrdering() throws {
    let metadata = [LibrarySortMetadata(),
      LibrarySortMetadata(pixelWidth: 20, pixelHeight: 20, capturedAt: Date(timeIntervalSince1970: 20), exposureTime: 0.02, aperture: 2),
      LibrarySortMetadata(pixelWidth: 100, pixelHeight: 100, capturedAt: Date(timeIntervalSince1970: 100), exposureTime: 0.1, aperture: 10),
      LibrarySortMetadata(pixelWidth: 20, pixelHeight: 20, capturedAt: Date(timeIntervalSince1970: 20), exposureTime: 0.02, aperture: 2)]
    let assets = zip(["a.jpg", "photo10.jpg", "z.jpg", "photo2.jpg"], metadata).map { asset($0.0, metadata: $0.1) }
    for sort in [LibrarySort.widthAscending, .heightAscending, .capturedOldest, .shutterFastest, .apertureAscending] {
      #expect(try ordered(assets, sort) == ["photo2.jpg", "photo10.jpg", "z.jpg", "a.jpg"])
    }
    for sort in [LibrarySort.widthDescending, .heightDescending, .capturedNewest, .shutterSlowest, .apertureDescending] {
      #expect(try ordered(assets, sort) == ["z.jpg", "photo2.jpg", "photo10.jpg", "a.jpg"])
    }
  }

  @Test("문자 정렬은 대소문자·숫자·공백 결측값을 처리하고 파일 유형 별칭을 합친다")
  func textAndTypeOrdering() throws {
    let assets = [asset("a.jpg", metadata: LibrarySortMetadata(cameraMake: " ", cameraModel: "", colorSpace: "\n")),
      asset("photo10.jpg", metadata: LibrarySortMetadata(cameraMake: "Canon2", cameraModel: "Model2", colorSpace: "Space2")),
      asset("z.jpg", metadata: LibrarySortMetadata(cameraMake: "canon10", cameraModel: "Model10", colorSpace: "space10")),
      asset("photo2.jpg", metadata: LibrarySortMetadata(cameraMake: " canon2 ", cameraModel: "model2", colorSpace: "space2"))]
    for sort in [LibrarySort.makeAscending, .modelAscending, .colorSpaceAscending] {
      #expect(try ordered(assets, sort) == ["photo2.jpg", "photo10.jpg", "z.jpg", "a.jpg"])
    }
    for sort in [LibrarySort.makeDescending, .modelDescending, .colorSpaceDescending] {
      #expect(try ordered(assets, sort) == ["z.jpg", "photo2.jpg", "photo10.jpg", "a.jpg"])
    }
    let files = ["a", "photo10.JPG", "video.MOV", "z.png", "photo2.jpeg"].map { asset($0) }
    #expect(try ordered(files, .typeAscending) == ["photo2.jpeg", "photo10.JPG", "video.MOV", "z.png", "a"])
    #expect(try ordered(files, .typeDescending) == ["z.png", "video.MOV", "photo2.jpeg", "photo10.JPG", "a"])
  }

  @Test("비교 행은 같은 정렬 기준과 없는 A 행의 B 정보를 사용한다")
  func comparisonOrdering() throws {
    let first = [asset("01.jpg", metadata: LibrarySortMetadata(pixelWidth: 200)),
      asset("03.jpg", metadata: LibrarySortMetadata(pixelWidth: 100)), asset("04.jpg")]
    let second = [asset("01.png", metadata: LibrarySortMetadata(pixelWidth: 999)),
      asset("02.png", metadata: LibrarySortMetadata(pixelWidth: 150))]
    let rows = try RustImageEngine.match(first: first, second: second, sort: .widthDescending)
    #expect(rows.map(\.firstIndex) == [0, nil, 1, 2])
    #expect(rows.map(\.secondIndex) == [0, 1, nil, nil])
  }

  @Test("기존 저장값을 읽고 모든 정렬·그룹·10개 언어의 번역 키가 일치한다")
  func persistenceAndLocalizations() throws {
    let old = Data(#"{"searchText":"photo","sort":"sizeLargest","formats":[]}"#.utf8)
    #expect(try JSONDecoder().decode(LibraryQuery.self, from: old).sort == .sizeLargest)
    for sort in LibrarySort.allCases {
      let query = LibraryQuery(sort: sort)
      #expect(try JSONDecoder().decode(LibraryQuery.self, from: JSONEncoder().encode(query)) == query)
    }
    let grouped = LibrarySort.groupedCases.flatMap { $0.sorts }
    #expect(grouped.count == LibrarySort.allCases.count)
    #expect(Set(grouped) == Set(LibrarySort.allCases))
    let languages = L10n.supportedLocalizations
    let keys = Set(LibrarySort.allCases.filter { $0.requiresMetadata || [.typeAscending, .typeDescending].contains($0) }.map(\.rawValue))
      .union(["category.file", "category.dimensions", "category.camera", "category.location"])
    for language in languages {
      #expect(SortL10n.keys(localeIdentifier: language) == keys)
      for key in keys { #expect(SortL10n.text(key, localeIdentifier: language) != key) }
    }
  }

  @Test("EXIF 회전·소수 초·UTC 오프셋을 반영하고 유효하지 않은 정보는 결측값으로 둔다")
  func metadataParsing() throws {
    let properties: [CFString: Any] = [
      kCGImagePropertyPixelWidth: 600, kCGImagePropertyPixelHeight: 400, kCGImagePropertyOrientation: 6,
      kCGImagePropertyProfileName: "Display P3",
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: " Example ", kCGImagePropertyTIFFModel: "Model 2"],
      kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:01:02 03:04:05",
        kCGImagePropertyExifOffsetTimeOriginal: "+09:00", kCGImagePropertyExifSubsecTimeOriginal: "125",
        kCGImagePropertyExifExposureTime: 0.004, kCGImagePropertyExifFNumber: 2.8] as [CFString: Any],
    ]
    let result = LibrarySortMetadataReader.imageMetadata(properties)
    #expect(result.pixelWidth == 400 && result.pixelHeight == 600)
    #expect(result.cameraMake == "Example" && result.cameraModel == "Model 2")
    #expect(result.exposureTime == 0.004 && result.aperture == 2.8 && result.colorSpace == "Display P3")
    let expected = try #require(ISO8601DateFormatter().date(from: "2024-01-01T18:04:05Z"))
    #expect(result.capturedAt?.timeIntervalSince1970 == expected.timeIntervalSince1970 + 0.125)
    #expect(LibrarySortMetadataReader.capturedDate("2024:02:30 01:00:00", offset: nil) == nil)
    #expect(LibrarySortMetadataReader.capturedDate("2024:02:20 01:00:00", offset: "+30:99") == nil)
    let unknown = LibrarySortMetadataReader.imageMetadata([
      kCGImagePropertyColorModel: "RGB", kCGImagePropertyPixelWidth: 0,
      kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: -1, kCGImagePropertyExifFNumber: Double.infinity],
    ])
    #expect(unknown.pixelWidth == nil && unknown.colorSpace == nil && unknown.exposureTime == nil && unknown.aperture == nil)
  }

  @Test("일반·유형 정렬은 메타데이터를 읽지 않고 읽은 결측값도 파일 버전에 따라 캐시한다")
  func lazyNegativeCacheAndReplacement() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("test.jpg")
    try Data([1, 2, 3]).write(to: url)
    let counter = SortReadCounter()
    let cache = LibrarySortMetadataCache { _, _ in
      await counter.increment()
      return LibrarySortMetadata()
    }
    let library = ImageLibrary()
    let source = [ImageAsset(url: url, byteCount: 3, modificationDate: nil)]
    for sort in [LibrarySort.nameAscending, .sizeLargest, .typeAscending] {
      let result = try await library.enrichSortMetadata(source, for: sort, cache: cache)
      #expect(result[0].sortMetadata == nil)
    }
    #expect(await counter.value == 0)
    let first = try await library.enrichSortMetadata(source, for: .widthAscending, cache: cache)
    _ = try await library.enrichSortMetadata(source, for: .heightDescending, cache: cache)
    #expect(await counter.value == 1)
    let oldDate = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    try Data([4, 5, 6]).write(to: url, options: .atomic)
    if let oldDate { try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path) }
    let refreshed = try await library.enrichSortMetadata(first, for: .widthAscending, cache: cache)
    #expect(await counter.value == 2)
    #expect(refreshed[0].sortMetadataVersion != first[0].sortMetadataVersion)
  }

  @Test("작은 캐시는 오래된 항목을 버리고 취소된 읽기를 저장하지 않는다")
  func boundedCacheAndCancellation() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let counter = SortReadCounter()
    let cache = LibrarySortMetadataCache(maximumEntries: 2) { _, _ in
      await counter.increment()
      return LibrarySortMetadata()
    }
    let versions = (0..<3).map { LibrarySortFileVersion(url: folder.appendingPathComponent("\($0).jpg")) }
    for version in versions { _ = try await cache.metadata(for: version, isVideo: false) }
    _ = try await cache.metadata(for: versions[0], isVideo: false)
    #expect(await counter.value == 4)
    let cancellationCounter = SortReadCounter()
    let cancellable = LibrarySortMetadataCache { _, _ in
      await cancellationCounter.increment()
      try await Task.sleep(for: .seconds(30))
      return LibrarySortMetadata()
    }
    let work = Task { try await cancellable.metadata(for: versions[0], isVideo: false) }
    let deadline = ContinuousClock.now + .seconds(3)
    while await cancellationCounter.value == 0, ContinuousClock.now < deadline { await Task.yield() }
    work.cancel()
    await #expect(throws: CancellationError.self) { try await work.value }
  }

  @Test("실제 파일 정보 읽기는 원본 크기와 카메라 정보를 반환하고 손상된 영상도 정렬을 막지 않는다")
  func nativeMetadataReading() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let imageURL = folder.appendingPathComponent("sample.jpg")
    let context = try #require(CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8,
      bytesPerRow: 384, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let image = try #require(context.makeImage())
    let output = try #require(CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(output, image, [
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Synthetic", kCGImagePropertyTIFFModel: "Camera 2"],
      kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: 0.01, kCGImagePropertyExifFNumber: 4.0],
    ] as CFDictionary)
    try #require(CGImageDestinationFinalize(output))
    let value = try await LibrarySortMetadataReader.read(imageURL, isVideo: false)
    #expect(value.pixelWidth == 96 && value.pixelHeight == 64)
    #expect(value.cameraMake == "Synthetic" && value.cameraModel == "Camera 2")
    #expect(value.exposureTime == 0.01 && value.aperture == 4)
    let brokenURL = folder.appendingPathComponent("broken.mov")
    try Data([1, 2, 3]).write(to: brokenURL)
    #expect(try await LibrarySortMetadataReader.read(brokenURL, isVideo: true) == LibrarySortMetadata())
  }

  @Test("영상 트랙 크기는 회전을 반영하며 사진 전용 EXIF는 만들지 않는다")
  func nativeVideoMetadata() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("portrait.mov")
    try await writeMovie(to: url, transform: CGAffineTransform(rotationAngle: .pi / 2))
    let value = try await LibrarySortMetadataReader.read(url, isVideo: true)
    #expect(value.pixelWidth == 64 && value.pixelHeight == 96)
    #expect(value.exposureTime == nil && value.aperture == nil)
    #expect(value.capturedAt == ISO8601DateFormatter().date(from: "2024-01-02T03:04:05Z"))
  }

  private func asset(_ name: String, metadata: LibrarySortMetadata? = nil) -> ImageAsset {
    ImageAsset(url: URL(fileURLWithPath: "/sort-test/" + name), byteCount: nil, modificationDate: nil,
      sortMetadata: metadata)
  }

  private func ordered(_ assets: [ImageAsset], _ sort: LibrarySort) throws -> [String] {
    try RustImageEngine.query(assets, options: LibraryQuery(sort: sort)).map(\.filename)
  }

  private func makeFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-sort-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }
  /// A tiny, synthetic local video avoids user media and external codec tools.
  private func writeMovie(to url: URL, transform: CGAffineTransform) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let created = AVMutableMetadataItem()
    created.identifier = .quickTimeMetadataCreationDate
    created.dataType = kCMMetadataBaseDataType_UTF8 as String
    created.value = "2024-01-02T03:04:05Z" as NSString
    writer.metadata = [created]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: 96,
      AVVideoHeightKey: 64,
    ])
    input.transform = transform
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 96,
        kCVPixelBufferHeightKey as String: 64,
      ])
    try #require(writer.canAdd(input))
    writer.add(input)
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    try #require(CVPixelBufferCreate(kCFAllocatorDefault, 96, 64,
      kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
    for y in 0..<64 {
      for x in 0..<96 {
        let offset = y * rowBytes + x * 4
        base[offset] = 30
        base[offset + 1] = 80
        base[offset + 2] = 200
        base[offset + 3] = 255
      }
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    let deadline = ContinuousClock.now + .seconds(10)
    for frame in 0..<2 {
      while !input.isReadyForMoreMediaData, writer.status == .writing, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      try #require(input.isReadyForMoreMediaData)
      try #require(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
    }
    writer.endSession(atSourceTime: CMTime(value: 2, timescale: 10))
    input.markAsFinished()
    await writer.finishWriting()
    try #require(writer.status == .completed, "\(String(describing: writer.error))")
  }
}

private actor SortReadCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}
