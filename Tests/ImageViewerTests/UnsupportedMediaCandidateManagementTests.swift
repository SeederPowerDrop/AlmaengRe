import Foundation
import Testing

@testable import ImageViewer

@Suite("재생 지원과 분리된 미디어 후보 파일 관리")
struct UnsupportedMediaCandidateManagementTests {
  private static let videos = ["clip.WEBM", "clip.WMV", "clip.FLV", "clip.OGV"]
  private static let audio = ["recording.OGG", "recording.OGA", "recording.OPUS", "recording.WMA", "recording.MKA"]

  @Test("네이티브 재생이 보장되지 않는 후보도 폴더·직접 열기·종류 필터에서 유지된다")
  func candidatesAreManageableWithoutAPlaybackPromise() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let library = ImageLibrary()
    let hidden = try await library.open(urls: [fixture.source], includesVideos: false)
    #expect(hidden.assets.map(\.filename) == ["photo.png"])
    let mixed = try await library.open(urls: [fixture.source], includesVideos: true)
    #expect(Set(mixed.assets.map(\.filename)) == Set(Self.videos + Self.audio + ["photo.png"]))
    #expect(Set(mixed.assets.filter(\.isVideo).map(\.filename)) == Set(Self.videos))
    #expect(Set(mixed.assets.filter(\.isAudio).map(\.filename)) == Set(Self.audio))

    for name in Self.videos + Self.audio {
      let url = fixture.source.appendingPathComponent(name)
      let opened = try await library.open(urls: [url], includesVideos: true)
      #expect(opened.focusedURL == url)
      #expect(opened.assets.count == mixed.assets.count)
      await #expect(throws: (any Error).self) {
        try await library.open(urls: [url], includesVideos: false)
      }
    }
    var query = LibraryQuery()
    query.mediaKind = .videos
    #expect(Set(try RustImageEngine.query(mixed.assets, options: query).map(\.filename)) == Set(Self.videos))
    query.mediaKind = .audio
    #expect(Set(try RustImageEngine.query(mixed.assets, options: query).map(\.filename)) == Set(Self.audio))
    query.fileExtensions = ["*.OPUS"]
    #expect(try RustImageEngine.query(mixed.assets, options: query).map(\.filename) == ["recording.OPUS"])
    #expect(!MediaFormatRegistry.canAttemptToOpen(fixture.source.appendingPathComponent("notes.txt"), includesVideos: true))
  }

  @Test("미리보기 거부 후에도 사진과 후보 영상·음성을 원본 바이트 그대로 복사·이름 변경한다")
  @MainActor func rejectedPreviewDoesNotPreventCopyAndRename() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let assets = try await ImageLibrary().scan(folder: fixture.source, includesVideos: true)
    for name in ["clip.WEBM", "recording.OPUS"] {
      let asset = try #require(assets.first { $0.filename == name })
      let playback = VideoPlaybackState()
      await playback.monitor(asset)
      #expect(playback.errorMessage?.isEmpty == false)
      #expect(playback.document == nil && playback.player.currentItem == nil)
    }
    let plan = try BatchFileOperationPlanner.plan(assets: assets, operation: .copy,
      destinationFolder: fixture.destination)
    let copied = await BatchFileOperator().execute(plan)
    try #require(copied.completed.count == assets.count && copied.failures.isEmpty && !copied.wasCancelled)
    let copiedURLs = try copied.completed.map { try #require($0.destinationURL) }
    var options = BatchRenameOptions()
    options.prefix = "managed_"
    let rename = BatchRenamePlanner.plan(urls: copiedURLs, options: options)
    try #require(rename.canApply)
    let mapping = try await BatchRenamer().apply(rename)
    #expect(mapping.count == assets.count)
    for entry in rename.entries {
      #expect(try Data(contentsOf: entry.destinationURL) == fixture.bytes[entry.sourceURL.lastPathComponent])
      #expect(!FileManager.default.fileExists(atPath: entry.sourceURL.path))
    }
    for (name, bytes) in fixture.bytes {
      #expect(try Data(contentsOf: fixture.source.appendingPathComponent(name)) == bytes)
    }
    let renamed = try await ImageLibrary().scan(folder: fixture.destination, includesVideos: true)
    #expect(renamed.filter(\.isVideo).count == Self.videos.count)
    #expect(renamed.filter(\.isAudio).count == Self.audio.count)
    #expect(renamed.count == assets.count)
  }

  private struct Fixture {
    let root: URL
    let source: URL
    let destination: URL
    let bytes: [String: Data]

    init() throws {
      root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("UnsupportedMediaCandidates-\(UUID())", isDirectory: true)
      source = root.appendingPathComponent("SyntheticSeeds", isDirectory: true)
      destination = root.appendingPathComponent("WorkingCopies", isDirectory: true)
      for folder in [source, destination] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      }
      bytes = Dictionary(uniqueKeysWithValues: (videos + audio + ["photo.png", "notes.txt"]).map {
        ($0, Data("Deliberately undecodable synthetic fixture: \($0)".utf8))
      })
      for (name, contents) in bytes { try contents.write(to: source.appendingPathComponent(name)) }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
  }
}
