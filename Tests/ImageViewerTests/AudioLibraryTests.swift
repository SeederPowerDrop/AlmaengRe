import Foundation
import Testing

@testable import ImageViewer

@Suite("사진·영상·음성 라이브러리 분리")
struct AudioLibraryTests {
  @Test("영상 표시 저장 옵션이 음성 후보도 함께 포함하고 이미지 전용 스캔에서는 제외한다")
  func scanAndOpenRespectPlaybackToggle() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let names = ["photo.jpg", "clip.mp4", "recording.WAV", "music.m4a", "notes.txt"]
    for name in names { try Data([1]).write(to: folder.appendingPathComponent(name)) }
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("folder.mp3"),
      withIntermediateDirectories: false)
    let library = ImageLibrary()
    let images = try await library.scan(folder: folder, includesVideos: false)
    #expect(images.map(\.filename) == ["photo.jpg"])
    let all = try await library.scan(folder: folder, includesVideos: true)
    #expect(Set(all.map(\.filename)) == Set(names.dropLast()))
    #expect(all.filter { $0.isAudio }.count == 2)
    #expect(all.filter { $0.isVideo }.count == 1)
    let audioURL = folder.appendingPathComponent("recording.WAV")
    let opened = try await library.assets(from: [audioURL], includesVideos: true)
    #expect(opened.count == 1 && opened[0].isAudio && opened[0].isPlaybackMedia)
    await #expect(throws: (any Error).self) {
      try await library.assets(from: [audioURL], includesVideos: false)
    }
  }

  @Test("음성·영상·이미지 필터와 확장자 필터를 독립적으로 조합한다")
  func mediaFiltersAndExtensions() throws {
    let assets = ["photo.jpg", "clip.mp4", "recording.wav", "music.m4a"].map(asset)
    var query = LibraryQuery()
    query.mediaKind = .audio
    #expect(Set(try RustImageEngine.query(assets, options: query).map(\.filename))
      == ["recording.wav", "music.m4a"])
    query.fileExtensions = ["*.WAV"]
    #expect(try RustImageEngine.query(assets, options: query).map(\.filename) == ["recording.wav"])
    query.mediaKind = .videos
    #expect(try RustImageEngine.query(assets, options: query).isEmpty)
    query.fileExtensions = []
    #expect(try RustImageEngine.query(assets, options: query).map(\.filename) == ["clip.mp4"])
    query.mediaKind = .images
    #expect(try RustImageEngine.query(assets, options: query).map(\.filename) == ["photo.jpg"])
    query.mediaKind = .all
    query.formats = [.other]
    #expect(try RustImageEngine.query(assets, options: query).isEmpty)
    for ext in MediaFormatRegistry.audioExtensions {
      let url = URL(fileURLWithPath: "/synthetic/recording.\(ext.uppercased())")
      #expect(MediaFormatRegistry.isAudio(url) && !MediaFormatRegistry.isVideo(url))
      #expect(!MediaFormatRegistry.canAttemptToOpen(url, includesVideos: false))
      #expect(MediaFormatRegistry.canAttemptToOpen(url, includesVideos: true))
      #expect(!MediaFormatRegistry.isAudio(URL(fileURLWithPath: url.path, isDirectory: true)))
    }
  }

  @Test("음성은 사진 GPS 디코더를 건너뛰고 정렬 시 네이티브 미디어 메타데이터 경로를 쓴다")
  func audioNeverUsesImageHeaderReader() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("recording.wav")
    try Data([1]).write(to: url)
    let audio = ImageAsset(url: url, byteCount: 1, modificationDate: nil)
    let reads = MetadataReads()
    let cache = LibrarySortMetadataCache { _, isPlaybackMedia in
      await reads.append(isPlaybackMedia)
      return LibrarySortMetadata(additionalSearchText: "Voice recording")
    }
    let library = ImageLibrary()
    let located = try await library.enrichLocations([audio], cache: cache)
    #expect(located[0].hasReadLocation && located[0].location == nil)
    #expect(await reads.values.isEmpty)
    let sorted = try await library.enrichSortMetadata(located, for: .capturedNewest, cache: cache)
    #expect(sorted[0].sortMetadata?.additionalSearchText == "Voice recording")
    #expect(await reads.values == [true])
  }

  @Test("대량 음성 미리보기는 파일을 디코딩하지 않고 작은 공용 그림을 재사용한다")
  func placeholderIsSharedAndBounded() async throws {
    // These sources do not exist. Producing the visual must never read them or
    // ask ImageIO/Quick Look/AVFoundation to decode an audio stream.
    let first = asset("one.mp3"), second = asset("two.wav")
    let thumbnails = ThumbnailPipeline()
    let firstImage = try await thumbnails.thumbnail(for: first, maxPixelSize: 512)
    let secondImage = try await thumbnails.browsingThumbnail(for: second, maxPixelSize: 512)
    #expect(firstImage === secondImage)
    #expect(max(firstImage.width, firstImage.height) == 256)
    let small = try await thumbnails.thumbnail(for: first, maxPixelSize: 48)
    #expect(max(small.width, small.height) <= 48)
    #expect(await thumbnails.cacheSnapshot().entryCount == 0)
    let pipeline = ImagePipeline()
    let frame = try await pipeline.renderFrame(url: first.url, maxPixelSize: 512,
      adjustments: .identity, prefersHDR: true)
    #expect(frame.image === firstImage && frame.sourcePixelSize == nil)
    #expect(await pipeline.cacheSnapshot().entryCount == 0)
    let metadata = AudioMediaPreview.metadata(for: first.url)
    #expect(metadata.pixelWidth == 0 && metadata.pixelHeight == 0 && metadata.location == nil)
  }

  @Test("음성 아이콘을 원본 사진 내보내기나 사진 보정 결과로 저장하지 않는다")
  func imageOnlyOperationsRejectAudio() async throws {
    let pipeline = ImagePipeline()
    let url = asset("recording.wav").url
    await #expect(throws: (any Error).self) {
      try await pipeline.renderFrame(url: url, maxPixelSize: nil, adjustments: .identity, prefersHDR: false)
    }
    var adjustments = ImageAdjustments.identity
    adjustments.exposure = 1
    await #expect(throws: (any Error).self) {
      try await pipeline.renderFrame(url: url, maxPixelSize: 512, adjustments: adjustments, prefersHDR: false)
    }
  }

  @Test("음성은 기존 최근 사진 목록에 사진으로 기록되지 않는다")
  @MainActor
  func recentPhotosRemainPhotoOnly() throws {
    let suite = "AudioLibraryTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let recent = RecentPhotoStore(defaults: defaults)
    recent.record(asset("photo.jpg"))
    recent.record(asset("recording.wav"))
    recent.record(asset("clip.mp4"))
    #expect(recent.items.map(\.filename) == ["photo.jpg"])
  }

  private func asset(_ filename: String) -> ImageAsset {
    ImageAsset(url: URL(fileURLWithPath: "/synthetic-audio-tests/\(filename)"),
      byteCount: 1, modificationDate: nil)
  }

  private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("audio-library-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
  }

  private actor MetadataReads {
    var values: [Bool] = []
    func append(_ value: Bool) { values.append(value) }
  }
}
