import AppKit
import Testing

@testable import ImageViewer

@Suite("최근 본 사진 기록", .serialized)
@MainActor
struct RecentPhotoStoreTests {
  @Test("폴더마다 실제로 본 최근 다섯 장만 최신순으로 저장한다")
  func historyIsBoundedAndPersistent() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = RecentPhotoStore(defaults: fixture.defaults)
    let assets = try (1...8).map { try fixture.asset("photo-\($0).png") }
    for (index, asset) in assets.enumerated() {
      store.record(asset, at: Date(timeIntervalSince1970: Double(index)))
    }
    let expected = Array(assets.suffix(5).reversed().map(\.sessionID))
    #expect(store.items.map(\.id) == expected)
    #expect(store.folders.count == 1)
    #expect(store.items.count == RecentPhotoStore.maximumPhotosPerFolder)
    #expect(store.folders.first?.photos.map(\.id) == expected)
    let reopened = RecentPhotoStore(defaults: fixture.defaults)
    #expect(reopened.items == store.items)
    #expect(reopened.items.first?.filename == "photo-8.png")
    #expect(reopened.folders == store.folders)
  }

  @Test("최근 연 여덟 폴더만 보존하고 폴더당 다섯 장을 넘기지 않는다")
  func folderAndPhotoBoundsAreIndependent() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = RecentPhotoStore(defaults: fixture.defaults)
    for folder in 1...9 {
      for photo in 1...7 {
        store.record(try fixture.asset("folder-\(folder)/photo-\(photo).png"),
          at: Date(timeIntervalSince1970: Double(folder * 10 + photo)))
      }
    }
    #expect(store.folders.map(\.name) == (2...9).reversed().map { "folder-\($0)" })
    #expect(store.folders.count == RecentPhotoStore.maximumFolderCount)
    #expect(store.items.count == RecentPhotoStore.maximumCount)
    #expect(store.folders.allSatisfy { $0.photos.map(\.filename) == (3...7).reversed().map { "photo-\($0).png" } })
    #expect(RecentPhotoStore(defaults: fixture.defaults).folders == store.folders)
    let storedHistory = fixture.defaults.data(forKey: RecentPhotoStore.defaultsKey)
    #expect(store.homeFolders.map(\.name) == ["folder-9", "folder-8", "folder-7"])
    #expect(store.homeFolders.allSatisfy {
      $0.photos.map(\.filename) == ["photo-7.png", "photo-6.png", "photo-5.png", "photo-4.png"]
    })
    #expect(RecentPhotoStore(defaults: fixture.defaults).homeFolders == store.homeFolders)
    #expect(fixture.defaults.data(forKey: RecentPhotoStore.defaultsKey) == storedHistory,
      "Limiting Home must not discard older saved folders or photos")
    store.recordFolder(url: fixture.root.appendingPathComponent("folder-3"),
      at: Date(timeIntervalSince1970: 1_000))
    #expect(store.homeFolders.map(\.name) == ["folder-3", "folder-9", "folder-8"])
    #expect(store.homeFolders.first?.photos.first?.filename == "photo-7.png")
  }

  @Test("폴더를 다시 열면 사진 기록을 바꾸지 않고 최신 폴더로 옮기며 빈 폴더도 남는다")
  func explicitFolderVisitsKeepPhotoHistoryAndEmptyFolders() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = RecentPhotoStore(defaults: fixture.defaults)
    let a = try fixture.asset("first/a.png"), b = try fixture.asset("second/b.png")
    store.record(a, at: Date(timeIntervalSince1970: 1))
    store.record(b, at: Date(timeIntervalSince1970: 2))
    let before = store.items
    let firstFolder = a.url.deletingLastPathComponent()
    store.recordFolder(url: firstFolder, at: Date(timeIntervalSince1970: 3))
    #expect(store.folders.map(\.name) == ["first", "second"])
    #expect(store.items == before)
    #expect(store.folders.first?.lastOpened == Date(timeIntervalSince1970: 3))
    let empty = fixture.root.appendingPathComponent("empty", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    store.recordFolder(url: empty, at: Date(timeIntervalSince1970: 4))
    #expect(store.folders.map(\.name) == ["empty", "first", "second"])
    #expect(store.folders.first?.photos.isEmpty == true)
    #expect(RecentPhotoStore(defaults: fixture.defaults).folders == store.folders)
  }

  @Test("이전 일곱 장 이력을 원본 접근 없이 폴더별로 이관하고 미리보기를 유지한다")
  func legacyHistoryMigratesAndRetainsThumbnailsWithoutSources() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let jpeg = try thumbnail(width: 64)
    var legacy: [RecentPhoto] = []
    for index in 1...7 {
      let folder = index == 7 ? "second" : "first"
      legacy.insert(RecentPhoto(asset: try fixture.asset("\(folder)/photo-\(index).png"),
        lastViewed: Date(timeIntervalSince1970: Double(index)), thumbnailData: jpeg), at: 0)
    }
    fixture.defaults.set(try JSONEncoder().encode(legacy), forKey: RecentPhotoStore.legacyDefaultsKey)
    try FileManager.default.removeItem(at: fixture.root)
    let store = RecentPhotoStore(defaults: fixture.defaults)
    #expect(store.folders.map(\.name) == ["second", "first"])
    #expect(store.folders.map { $0.photos.count } == [1, 5])
    #expect(store.items.map(\.filename) == (2...7).reversed().map { "photo-\($0).png" })
    #expect(store.items.allSatisfy { $0.thumbnailData == jpeg })
    #expect(store.folders.allSatisfy { $0.location.bookmark == nil })
    #expect(store.items.first?.location == legacy.first?.location)
    #expect(fixture.defaults.data(forKey: RecentPhotoStore.defaultsKey) != nil)
    #expect(fixture.defaults.object(forKey: RecentPhotoStore.legacyDefaultsKey) == nil)
    #expect(RecentPhotoStore(defaults: fixture.defaults).folders == store.folders)
  }

  @Test("이전 폴더의 사진을 표시해도 최근 연 폴더는 바뀌지 않고 명시적 열기만 순서를 바꾼다")
  func viewingOlderFolderDoesNotChangeMostRecentlyOpenedFolder() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = RecentPhotoStore(defaults: fixture.defaults)
    let a = try fixture.asset("first/a.png"), b = try fixture.asset("second/b.png")
    let first = a.url.deletingLastPathComponent(), second = b.url.deletingLastPathComponent()
    store.recordFolder(url: first, at: Date(timeIntervalSince1970: 1))
    store.recordFolder(url: second, at: Date(timeIntervalSince1970: 2))
    store.record(a, at: Date(timeIntervalSince1970: 3))
    #expect(store.folders.map(\.name) == ["second", "first"])
    #expect(store.folders.first?.photos.isEmpty == true)
    store.record(b, at: Date(timeIntervalSince1970: 4))
    store.record(a, at: Date(timeIntervalSince1970: 5))
    #expect(store.folders.map(\.name) == ["second", "first"])
    #expect(store.folders.map(\.lastOpened) == [Date(timeIntervalSince1970: 2), Date(timeIntervalSince1970: 1)])
    #expect(store.items.map(\.id) == [a.sessionID, b.sessionID])
    #expect(RecentPhotoStore(defaults: fixture.defaults).folders == store.folders)
    store.recordFolder(url: first, at: Date(timeIntervalSince1970: 6))
    #expect(store.folders.map(\.name) == ["first", "second"])
    #expect(store.folders.first?.lastOpened == Date(timeIntervalSince1970: 6))
    #expect(store.folders.first?.photos.first?.lastViewed == Date(timeIntervalSince1970: 5))
    #expect(RecentPhotoStore(defaults: fixture.defaults).folders == store.folders)
  }

  @Test("같은 사진을 다시 보면 중복 없이 맨 앞으로 옮기고 시간을 갱신한다")
  func revisitingDeduplicatesAndMovesToFront() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = RecentPhotoStore(defaults: fixture.defaults)
    let a = try fixture.asset("a.png"), b = try fixture.asset("b.png")
    store.record(a, at: Date(timeIntervalSince1970: 1))
    store.record(b, at: Date(timeIntervalSince1970: 2))
    let latest = Date(timeIntervalSince1970: 3)
    store.record(a, at: latest)
    #expect(store.items.map(\.id) == [a.sessionID, b.sessionID])
    #expect(store.items.first?.lastViewed == latest)
    #expect(RecentPhotoStore(defaults: fixture.defaults).items == store.items)
    let c = try fixture.asset("c.png")
    store.record(c, at: Date(timeIntervalSince1970: 2.5))
    #expect(store.homeFolders.first?.photos.map(\.id) == [a.sessionID, c.sessionID, b.sessionID],
      "A delayed work completion must retain activity-time ordering")
    #expect(RecentPhotoStore(defaults: fixture.defaults).homeFolders == store.homeFolders)
  }

  @Test("개별 제거와 전체 비우기는 기록만 지우고 원본 파일은 보존한다")
  func removingAndClearingNeverDeletesOriginalFiles() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = RecentPhotoStore(defaults: fixture.defaults)
    let a = try fixture.asset("a.png"), b = try fixture.asset("b.png")
    let originalA = try Data(contentsOf: a.url), originalB = try Data(contentsOf: b.url)
    store.record(a)
    store.record(b)
    store.remove(id: a.sessionID)
    #expect(RecentPhotoStore(defaults: fixture.defaults).items.map(\.id) == [b.sessionID])
    store.clear()
    #expect(RecentPhotoStore(defaults: fixture.defaults).items.isEmpty)
    #expect(fixture.defaults.object(forKey: RecentPhotoStore.defaultsKey) == nil)
    #expect(try Data(contentsOf: a.url) == originalA)
    #expect(try Data(contentsOf: b.url) == originalB)
  }

  @Test("동영상은 사진 기록에 포함하지 않는다")
  func videosAreIgnored() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = RecentPhotoStore(defaults: fixture.defaults)
    store.record(try fixture.asset("clip.MOV"))
    store.record(try fixture.asset("clip.mp4"))
    #expect(store.items.isEmpty)
    #expect(fixture.defaults.object(forKey: RecentPhotoStore.defaultsKey) == nil)
  }

  @Test("ZIP 사진은 임시 추출 경로 대신 ZIP 원본과 구성원 경로를 저장한다")
  func archiveMembersKeepLogicalIdentity() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = RecentPhotoStore(defaults: fixture.defaults)
    let archive = try fixture.asset("album.zip").url
    let origin = ArchiveImageOrigin(archiveURL: archive, entryPath: "day-1/photo.png")
    let first = ImageAsset(url: fixture.root.appendingPathComponent("first-extraction/photo.png"),
      byteCount: 50, modificationDate: nil, archiveOrigin: origin)
    let second = ImageAsset(url: fixture.root.appendingPathComponent("second-extraction/photo.png"),
      byteCount: 50, modificationDate: nil, archiveOrigin: origin)
    store.record(first)
    store.record(second)
    let photo = try #require(RecentPhotoStore(defaults: fixture.defaults).items.first)
    #expect(store.items.count == 1)
    #expect(photo.id == first.sessionID)
    #expect(photo.location.url == archive)
    #expect(photo.archiveEntryPath == "day-1/photo.png")
    #expect(photo.filename == "photo.png")
    #expect(photo.matches(second, sourceURL: archive))
    let movedArchive = fixture.root.appendingPathComponent("moved.zip")
    #expect(photo.sessionID(for: movedArchive) == movedArchive.absoluteString + "#day-1/photo.png")
    let another = ImageAsset(url: fixture.root.appendingPathComponent("third-extraction/other.png"),
      byteCount: 42, modificationDate: nil,
      archiveOrigin: ArchiveImageOrigin(archiveURL: archive, entryPath: "day-2/other.png"))
    store.record(another)
    #expect(store.folders.count == 1)
    #expect(store.folders.first?.isArchive == true)
    #expect(store.folders.first?.location.url == archive)
    #expect(store.folders.first?.photos.map(\.id) == [another.sessionID, first.sessionID])
    let encoded = try #require(fixture.defaults.data(forKey: RecentPhotoStore.defaultsKey))
    let json = String(decoding: encoded, as: UTF8.self)
    #expect(!json.contains("first-extraction") && !json.contains("second-extraction") && !json.contains("third-extraction"))

    fixture.defaults.removeObject(forKey: RecentPhotoStore.defaultsKey)
    fixture.defaults.set(try JSONEncoder().encode([photo]), forKey: RecentPhotoStore.legacyDefaultsKey)
    let migrated = RecentPhotoStore(defaults: fixture.defaults)
    #expect(migrated.folders.count == 1)
    #expect(migrated.folders.first?.isArchive == true)
    #expect(migrated.folders.first?.location == photo.location)
    #expect(migrated.items == [photo])
  }

  @Test("폴더 제거는 해당 사진과 늦은 미리보기만 제거하며 다른 폴더와 원본을 보존한다")
  func removingFolderPreventsLateThumbnailAndKeepsOtherHistory() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = RecentPhotoStore(defaults: fixture.defaults)
    let a = try fixture.asset("first/a.png"), b = try fixture.asset("second/b.png")
    store.record(a)
    store.record(b)
    store.removeFolder(id: a.url.deletingLastPathComponent().standardizedFileURL.absoluteString)
    store.setThumbnail(try thumbnail(width: 64), for: a.sessionID)
    #expect(store.items.map(\.id) == [b.sessionID])
    #expect(store.folders.map(\.name) == ["second"])
    #expect(RecentPhotoStore(defaults: fixture.defaults).folders == store.folders)
    #expect(FileManager.default.fileExists(atPath: a.url.path))
    store.remove(id: b.sessionID)
    #expect(store.folders.count == 1)
    #expect(store.folders.first?.photos.isEmpty == true)
    #expect(RecentPhotoStore(defaults: fixture.defaults).folders == store.folders)
  }

  @Test("작은 JPEG 미리보기는 순서와 열람 시각을 바꾸지 않고 다시 실행해도 남는다")
  func thumbnailPersistencePreservesOrderingAndDate() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = RecentPhotoStore(defaults: fixture.defaults)
    let a = try fixture.asset("a.png"), b = try fixture.asset("b.png")
    store.record(a, at: Date(timeIntervalSince1970: 1))
    store.record(b, at: Date(timeIntervalSince1970: 2))
    let order = store.items.map(\.id), dates = store.items.map(\.lastViewed)
    let data = try thumbnail(width: 64)
    store.setThumbnail(data, for: a.sessionID)
    #expect(store.items.map(\.id) == order)
    #expect(store.items.map(\.lastViewed) == dates)
    #expect(RecentPhotoStore(defaults: fixture.defaults).items.last?.thumbnailData == data)
    store.record(a, at: Date(timeIntervalSince1970: 3))
    #expect(store.items.first?.thumbnailData == data)
    let updated = ImageAsset(url: a.url, byteCount: a.byteCount,
      modificationDate: Date(timeIntervalSince1970: 4))
    store.record(updated, at: Date(timeIntervalSince1970: 4))
    #expect(store.items.first?.thumbnailData == nil)
    store.setThumbnail(data, for: a.sessionID, matchingLastViewed: Date(timeIntervalSince1970: 3))
    #expect(store.items.first?.thumbnailData == nil)
  }

  @Test("지운 기록에 늦게 도착한 미리보기가 기록을 되살리지 않는다")
  func lateThumbnailCannotResurrectRemovedHistory() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = RecentPhotoStore(defaults: fixture.defaults)
    let asset = try fixture.asset("a.png"), data = try thumbnail(width: 64)
    store.record(asset)
    store.remove(id: asset.sessionID)
    store.setThumbnail(data, for: asset.sessionID)
    #expect(store.items.isEmpty)
    store.record(asset)
    store.clear()
    store.setThumbnail(data, for: asset.sessionID)
    #expect(RecentPhotoStore(defaults: fixture.defaults).items.isEmpty)
    #expect(fixture.defaults.object(forKey: RecentPhotoStore.defaultsKey) == nil)
  }

  @Test("미리보기는 384픽셀·128KiB 이하 JPEG로 제한한다")
  func thumbnailLimitsRejectOversizedOrWrongFormatData() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = RecentPhotoStore(defaults: fixture.defaults)
    let asset = try fixture.asset("a.png")
    store.record(asset)
    for invalid in [Data(repeating: 0, count: RecentPhotoStore.maximumThumbnailBytes + 1),
      try thumbnail(width: 385), try thumbnail(width: 64, format: .png), Data("not an image".utf8)] {
      store.setThumbnail(invalid, for: asset.sessionID)
      #expect(store.items.first?.thumbnailData == nil)
    }
    let valid = try thumbnail(width: 384)
    store.setThumbnail(valid, for: asset.sessionID)
    #expect(store.items.first?.thumbnailData == valid)
  }

  @Test("없어진 사진과 손상된 기록이 있어도 시작 시 원본을 다시 읽지 않는다")
  func missingSourceAndMalformedPersistenceAreSafe() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = RecentPhotoStore(defaults: fixture.defaults)
    let asset = try fixture.asset("missing.png")
    store.record(asset)
    try FileManager.default.removeItem(at: asset.url)
    #expect(RecentPhotoStore(defaults: fixture.defaults).items.map(\.id) == [asset.sessionID])
    fixture.defaults.set(Data("broken history".utf8), forKey: RecentPhotoStore.defaultsKey)
    #expect(RecentPhotoStore(defaults: fixture.defaults).items.isEmpty)
  }

  private func thumbnail(width: Int, format: NSBitmapImageRep.FileType = .jpeg) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 24,
      bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: width * 3, bitsPerPixel: 24))
    bitmap.bitmapData?.initialize(repeating: 128, count: width * 24 * 3)
    return try #require(bitmap.representation(using: format, properties: [.compressionFactor: 0.7]))
  }

  @MainActor private struct Fixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("RecentPhotos-\(UUID())")
      suite = "RecentPhotoStoreTests.\(UUID())"
      defaults = try #require(UserDefaults(suiteName: suite))
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func asset(_ name: String) throws -> ImageAsset {
      let url = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let content = Data("Synthetic original: \(name)".utf8)
      try content.write(to: url)
      return ImageAsset(url: url, byteCount: Int64(content.count), modificationDate: nil)
    }

    func cleanup() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
