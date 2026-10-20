import Foundation
import Testing

@testable import ImageViewer

@Suite("사진과 macOS 영상 목록")
struct VideoLibraryTests {
  @Test("이미지 전용 스캔과 영상 포함 스캔을 명시적으로 구분한다")
  func folderOptIn() async throws {
    #expect(MediaFormatRegistry.isVideo(URL(fileURLWithPath: "/fixture/movie.MKV")))
    let fixture = try Fixture()
    defer { fixture.remove() }
    for ext in MediaFormatRegistry.videoExtensions {
      try Data([1, 2, 3]).write(to: fixture.folder.appendingPathComponent("clip.\(ext)"))
    }
    try Data([0]).write(to: fixture.folder.appendingPathComponent("notes.txt"))
    let library = ImageLibrary()
    let images = try await library.open(urls: [fixture.folder])
    #expect(images.assets.map(\.filename) == ["photo.png"])
    let mixed = try await library.open(urls: [fixture.folder], includesVideos: true)
    #expect(mixed.assets.count == MediaFormatRegistry.videoExtensions.count + 1)
    #expect(mixed.assets.filter(\.isVideo).count == MediaFormatRegistry.videoExtensions.count)
    #expect(try RustImageEngine.scan(folder: fixture.folder).count == 1)
    #expect(try RustImageEngine.scan(folder: fixture.folder, includesVideos: true).count == mixed.assets.count)
    #expect(try await library.scan(folder: fixture.folder).map(\.filename) == ["photo.png"])
  }

  @Test("영상 직접 선택은 명시적으로 켰을 때만 열고 이웃 목록과 선택 위치를 유지한다")
  func explicitVideoOpen() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let video = fixture.folder.appendingPathComponent("movie.MOV")
    try Data([1, 2, 3]).write(to: video)
    let library = ImageLibrary()
    await #expect(throws: (any Error).self) { try await library.open(urls: [video]) }
    let mixed = try await library.open(urls: [video], includesVideos: true)
    #expect(mixed.focusedURL == video)
    #expect(Set(mixed.assets.map(\.filename)) == ["movie.MOV", "photo.png"])
    let selected = try await library.assets(from: [video, fixture.photo], includesVideos: true)
    #expect(selected.count == 2 && selected.filter(\.isVideo).count == 1)
    #expect(try await library.assets(from: [video, fixture.photo]).map(\.filename) == ["photo.png"])
    #expect(!MediaFormatRegistry.isVideo(fixture.folder.appendingPathComponent("movie.mp4", isDirectory: true)))
  }

  @Test("영상만 있는 폴더도 숨김 상태로 열 수 있고 ZIP 영상은 옵션과 무관하게 제외한다")
  func emptyAndArchiveScope() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try FileManager.default.removeItem(at: fixture.photo)
    try Data([0]).write(to: fixture.folder.appendingPathComponent("clip.mp4"))
    let library = ImageLibrary()
    #expect(try await library.open(urls: [fixture.folder], allowsEmptyFolder: true).assets.isEmpty)
    #expect(try await library.open(urls: [fixture.folder], includesVideos: true).assets.count == 1)
    let archive = fixture.folder.appendingPathComponent("mixed.zip")
    let zip = "UEsDBBQAAAAAAKSxRV2P/VI7RAAAAEQAAAAJAAAAcGhvdG8ucG5niVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYIJQSwMEFAAAAAAApLFFXZsKzi0rAAAAKwAAAAgAAABjbGlwLm1wNHZpZGVvIGZpeHR1cmUgZXhjbHVkZWQgZnJvbSBpbWFnZSBaSVAgc2NvcGVQSwECFAMUAAAAAACksUVdj/1SO0QAAABEAAAACQAAAAAAAAAAAAAAgAEAAAAAcGhvdG8ucG5nUEsBAhQDFAAAAAAApLFFXZsKzi0rAAAAKwAAAAgAAAAAAAAAAAAAAIABawAAAGNsaXAubXA0UEsFBgAAAAACAAIAbQAAALwAAAAAAA=="
    try #require(Data(base64Encoded: zip)).write(to: archive)
    let extracted = try await library.open(urls: [archive], includesVideos: true)
    #expect(extracted.assets.map(\.filename) == ["photo.png"])
    #expect(extracted.assets.allSatisfy { $0.isReadOnly && !$0.isVideo })
  }

  @Test("영상에는 사진 GPS 디코더를 쓰지 않고 원래 식별정보를 유지한다")
  func videoLocationsAreSkipped() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let video = fixture.folder.appendingPathComponent("clip.mp4")
    try Data([0]).write(to: video)
    let library = ImageLibrary()
    let assets = try await library.assets(from: [video], includesVideos: true)
    let prepared = try await library.enrichLocations(assets)
    #expect(prepared.count == 1 && prepared[0].isVideo)
    #expect(prepared[0].hasReadLocation && prepared[0].location == nil)
    #expect(prepared[0].photoMarkID == assets[0].photoMarkID)
    #expect(prepared[0].sessionID == assets[0].sessionID)
    #expect(prepared[0].replacingURL(video.deletingLastPathComponent().appendingPathComponent("renamed.mov")).isVideo)
    #expect(MediaFormatRegistry.videoExtensions.isDisjoint(with: ImageFormatRegistry.knownExtensions))
  }

  @Test("설정이 없는 새 실행은 혼합 폴더와 영상 전용 폴더의 영상을 바로 보여준다", arguments: [false, true])
  @MainActor func newPreferencesShowMixedAndVideoOnlyFolders(videoOnly: Bool) async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { store.saveSessionNow(); fixture.remove() }
    if videoOnly { try FileManager.default.removeItem(at: fixture.photo) }
    let video = fixture.folder.appendingPathComponent("movie.mp4")
    try Data("Synthetic video list fixture".utf8).write(to: video)
    try #require(fixture.defaults.object(forKey: "ImageViewer.ShowsVideos.v1") == nil)
    #expect(store.showsVideos)

    store.open(urls: [fixture.folder])
    try await ready(store)

    #expect(!store.showsHome && store.alert == nil)
    #expect(store.assets.count == (videoOnly ? 1 : 2))
    #expect(store.allAssets.count == store.assets.count)
    #expect(store.assets.filter(\.isVideo).map(\.filename) == ["movie.mp4"])
    #expect(store.currentFolderURL?.standardizedFileURL == fixture.folder.standardizedFileURL)
    if videoOnly { #expect(store.currentAsset?.isVideo == true) }
    else { #expect(store.assets.contains { $0.filename == "photo.png" && !$0.isVideo }) }
  }

  @Test("저장된 영상 숨김은 재실행에도 유지하고 영상 직접 열기는 표시를 다시 켠다", arguments: [false, true])
  @MainActor func explicitHiddenPreferenceSurvivesRestartUntilDirectVideoOpen(videoOnly: Bool) async throws {
    let fixture = try Fixture()
    fixture.defaults.set(false, forKey: "ImageViewer.ShowsVideos.v1")
    let store = fixture.makeStore()
    let reopened = fixture.makeStore()
    defer { store.saveSessionNow(); reopened.saveSessionNow(); fixture.remove() }
    if videoOnly { try FileManager.default.removeItem(at: fixture.photo) }
    let video = fixture.folder.appendingPathComponent("movie.MOV")
    try Data("Synthetic video list fixture".utf8).write(to: video)
    #expect(!store.showsVideos && !reopened.showsVideos)
    reopened.open(urls: [fixture.folder])
    try await ready(reopened)
    #expect(reopened.assets.count == (videoOnly ? 0 : 1))
    #expect(reopened.allAssets.count == (videoOnly ? 1 : 2))
    #expect(reopened.assets.allSatisfy { !$0.isVideo })
    #expect(!fixture.defaults.bool(forKey: "ImageViewer.ShowsVideos.v1"))

    reopened.open(urls: [video])
    try await ready(reopened)
    #expect(reopened.showsVideos && reopened.currentAsset?.isVideo == true)
    #expect(reopened.currentAsset?.url.standardizedFileURL == video.standardizedFileURL)
    #expect(reopened.assets.count == (videoOnly ? 1 : 2))
    #expect(fixture.defaults.bool(forKey: "ImageViewer.ShowsVideos.v1"))
    #expect(reopened.alert == nil)
  }

  @MainActor private func ready(_ store: AppStore) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while store.isLoading || store.isFiltering || store.isIndexingLocations {
      try #require(ContinuousClock.now < deadline, "The media collection did not settle")
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private struct Fixture {
    let folder: URL
    let photo: URL
    let suite: String
    let defaults: UserDefaults

    init() throws {
      folder = FileManager.default.temporaryDirectory.appendingPathComponent("video-library-\(UUID())", isDirectory: true)
      photo = folder.appendingPathComponent("photo.png")
      suite = "VideoLibraryTests.\(UUID())"
      defaults = UserDefaults(suiteName: suite)!
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
      try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=")!.write(to: photo)
    }

    @MainActor func makeStore() -> AppStore {
      AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: folder.appendingPathComponent("marks-\(UUID()).sqlite"))
    }

    func remove() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }
  }
}
