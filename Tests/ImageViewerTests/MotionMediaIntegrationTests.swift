import AppKit
import Combine
import Foundation
import Testing

@testable import ImageViewer

@Suite("영상 표시와 움직이는 이미지 작업 흐름")
@MainActor
struct MotionMediaIntegrationTests {
  @Test("복원 중 영상 표시를 켰다 꺼도 처음과 같은 숨김 목록을 커밋한다")
  func visibilityRoundTripDuringRestoreUsesOneSnapshot() async throws {
    let fixture = try Fixture(showsVideos: false)
    let original = fixture.makeStore()
    let restored = fixture.makeStore()
    defer { cleanup(original); cleanup(restored); fixture.remove() }
    try await openLibrary(original, fixture: fixture)
    original.libraryQuery.sort = .northToSouth
    try await ready(original)
    original.saveSessionNow()
    var began = false
    var ended = false
    let observation = restored.$isIndexingLocations.sink { indexing in
      if indexing && !began {
        began = true
        restored.showsVideos = true
      } else if !indexing && began && !ended {
        ended = true
        restored.showsVideos = false
      }
    }
    defer { observation.cancel() }
    await restored.restoreLastSession()
    try await ready(restored)
    #expect(began && ended && !restored.showsVideos)
    #expect(restored.assets.map(\.filename) == [fixture.photoName, fixture.animationName])
    #expect(restored.allAssets.count == 3)
    #expect(restored.libraryQuery.sort == .northToSouth)
  }

  @Test("영상 숨김을 직접 선택한 뒤 표시 옵션을 바꿔도 이미지·GIF와 유효한 선택을 유지한다")
  func videoVisibilityPreservesImagesAndSafeSelection() async throws {
    let fixture = try Fixture(showsVideos: false)
    let store = fixture.makeStore()
    defer { cleanup(store); fixture.remove() }
    #expect(!store.showsVideos)
    try await openLibrary(store, fixture: fixture)
    #expect(store.assets.map(\.filename) == [fixture.photoName, fixture.animationName])
    let originals = Dictionary(uniqueKeysWithValues: store.allAssets.map { ($0.filename, $0.sessionID) })
    try #require(originals.count == 3)
    let animation = try #require(store.assets.first { $0.filename == fixture.animationName })
    store.select(asset: animation)

    store.showsVideos = true
    try await ready(store)
    #expect(store.assets.map(\.filename) == [fixture.photoName, fixture.animationName, fixture.videoName])
    #expect(store.currentAsset?.sessionID == animation.sessionID)
    #expect(store.selectedAssets.map(\.sessionID) == [animation.sessionID])
    let video = try #require(store.assets.first { $0.isVideo })
    store.select(asset: video)
    #expect(store.selectedAssets.map(\.sessionID) == [video.sessionID])

    store.showsVideos = false
    try await ready(store)
    #expect(store.assets.map(\.filename) == [fixture.photoName, fixture.animationName])
    let current = try #require(store.currentAsset)
    #expect(!current.isVideo && store.assets.indices.contains(store.currentIndex))
    #expect(store.selectedURLs.isSubset(of: Set(store.assets.map(\.url))))
    #expect(!store.selectedURLs.contains(video.url))
    #expect(Dictionary(uniqueKeysWithValues: store.allAssets.map { ($0.filename, $0.sessionID) }) == originals)

    store.showsVideos = true
    try await ready(store)
    #expect(store.assets.first { $0.isVideo }?.sessionID == video.sessionID)
    #expect(store.assets.contains { $0.sessionID == animation.sessionID })
    #expect(store.alert == nil)
  }

  @Test("영상 표시 선택은 재실행과 기존 보기 복원에도 유지되고 다시 끄기도 저장된다")
  func visibilityPreferenceSurvivesRelaunchAndSessionRestore() async throws {
    let fixture = try Fixture(showsVideos: false)
    let original = fixture.makeStore()
    var reopened: AppStore?
    var hidden: AppStore?
    defer {
      cleanup(original)
      if let reopened { cleanup(reopened) }
      if let hidden { cleanup(hidden) }
      fixture.remove()
    }
    #expect(!original.showsVideos)
    try await openLibrary(original, fixture: fixture)
    original.showsVideos = true
    try await ready(original)
    let video = try #require(original.assets.first { $0.isVideo })
    original.select(asset: video)
    original.saveSessionNow()

    // A fresh defaults instance exercises persisted preferences, not a reused model.
    let restoredDefaults: UserDefaults = try #require(UserDefaults(suiteName: fixture.suite))
    let restored = fixture.makeStore(defaults: restoredDefaults)
    reopened = restored
    #expect(restored.showsVideos && restored.assets.isEmpty)
    await restored.restoreLastSession()
    try await ready(restored)
    #expect(restored.assets.count == 3)
    #expect(restored.currentAsset?.sessionID == video.sessionID)
    #expect(restored.selectedAssets.map(\.sessionID) == [video.sessionID])

    restored.showsVideos = false
    try await ready(restored)
    restored.saveSessionNow()
    let hiddenDefaults: UserDefaults = try #require(UserDefaults(suiteName: fixture.suite))
    let imagesOnly = fixture.makeStore(defaults: hiddenDefaults)
    hidden = imagesOnly
    #expect(!imagesOnly.showsVideos)
    await imagesOnly.restoreLastSession()
    try await ready(imagesOnly)
    #expect(imagesOnly.assets.map(\.filename) == [fixture.photoName, fixture.animationName])
    #expect(imagesOnly.allAssets.count == 3)
    #expect(imagesOnly.currentAsset?.isVideo == false)
    #expect(imagesOnly.selectedURLs.isSubset(of: Set(imagesOnly.assets.map(\.url))))
    #expect(imagesOnly.alert == nil)
  }

  @Test("저장된 정렬을 복원하는 중 영상 표시를 바꿔도 재조회가 끝나고 원래 정렬을 유지한다")
  func videoToggleDuringSavedQueryRestoreTerminates() async throws {
    let fixture = try Fixture(showsVideos: false)
    let original = fixture.makeStore()
    let restored = fixture.makeStore()
    defer { cleanup(original); cleanup(restored); fixture.remove() }
    try await openLibrary(original, fixture: fixture)
    let savedQuery = LibraryQuery(sort: .northToSouth)
    original.libraryQuery = savedQuery
    try await ready(original)
    original.saveSessionNow()
    try #require(ViewerSessionPersistence(defaults: fixture.defaults).loadSession()?.query == savedQuery)
    try #require(!restored.showsVideos && restored.libraryQuery == LibraryQuery())

    var toggledDuringRestore = false
    // Location indexing starts inside queryAssets after restoration snapshots
    // its visibility option. This changes only video visibility at that exact
    // point, without racing a delay or incrementing libraryQueryRevision.
    let observation = restored.$isIndexingLocations.sink { indexing in
      guard indexing, !toggledDuringRestore else { return }
      toggledDuringRestore = true
      restored.showsVideos = true
    }
    defer { observation.cancel() }
    var finished = false
    let restoration = Task { @MainActor in
      await restored.restoreLastSession()
      finished = true
    }
    defer { restoration.cancel() }
    let deadline = ContinuousClock.now + .seconds(10)
    while !finished, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let completedInTime = finished
    restoration.cancel()
    await restoration.value
    try #require(completedInTime)
    try await ready(restored)
    #expect(toggledDuringRestore && restored.showsVideos)
    #expect(restored.libraryQuery == savedQuery)
    #expect(restored.allAssets.count == 3 && restored.assets.count == 3)
    #expect(restored.assets.contains { $0.isVideo })
    #expect(restored.alert == nil)
  }

  @Test("비교 화면 복원 중 바꾼 영상 표시는 일반 보기로 복귀할 때 적용된다", arguments: [true, false])
  func videoToggleDuringComparisonRestoreUpdatesViewer(_ targetShowsVideos: Bool) async throws {
    let fixture = try Fixture()
    let original = fixture.makeStore()
    var reopened: AppStore?
    defer {
      cleanup(original)
      if let reopened { cleanup(reopened) }
      fixture.remove()
    }
    original.showsVideos = !targetShowsVideos
    try await openLibrary(original, fixture: fixture)
    let savedQuery = LibraryQuery(sort: .nameDescending)
    original.libraryQuery = savedQuery
    try await ready(original)
    original.toggleFolderComparison()
    original.folderComparison.open(urls: [fixture.folder], for: .first)
    original.folderComparison.open(urls: [fixture.otherFolder], for: .second)
    try await ready(original.folderComparison)
    original.saveSessionNow()
    let saved = try #require(ViewerSessionPersistence(defaults: fixture.defaults).loadSession())
    try #require(saved.comparison != nil && saved.query == savedQuery)

    let restored = fixture.makeStore()
    reopened = restored
    try #require(restored.showsVideos != targetShowsVideos)
    var toggledDuringRestore = false
    var committedViewerCount: Int?
    // The first comparison pane starts only after the regular-viewer list has
    // committed. Changing just this preference leaves libraryQuery unchanged,
    // so restoration must retain a pending video-visibility reconciliation for
    // the user's return to the regular viewer.
    let observation = restored.folderComparison.first.$isLoading.sink { loading in
      guard loading, !toggledDuringRestore else { return }
      toggledDuringRestore = true
      committedViewerCount = restored.assets.count
      restored.showsVideos = targetShowsVideos
    }
    defer { observation.cancel() }
    await restored.restoreLastSession()
    try await ready(restored)
    #expect(toggledDuringRestore)
    #expect(committedViewerCount == (targetShowsVideos ? 2 : 3))
    #expect(restored.showsVideos == targetShowsVideos)
    #expect(restored.libraryQuery == savedQuery)
    #expect(restored.allAssets.count == 3)
    #expect(restored.assets.count == (targetShowsVideos ? 2 : 3))
    #expect(restored.assets.contains { $0.isVideo } == !targetShowsVideos)
    #expect(restored.selectedURLs.isSubset(of: Set(restored.assets.map(\.url))))
    #expect(restored.presentationMode == .folderComparison)
    #expect(restored.folderComparison.first.assets.count == 2)
    #expect(restored.folderComparison.second.assets.count == 1)
    #expect(restored.folderComparison.first.assets.allSatisfy { !$0.isVideo })
    #expect(restored.alert == nil)
    restored.presentationMode = .viewer
    #expect(restored.isFiltering)
    #expect(restored.assets.count == committedViewerCount)
    try await ready(restored)
    #expect(restored.assets.count == (targetShowsVideos ? 3 : 2))
    #expect(restored.assets.contains { $0.isVideo } == targetShowsVideos)
    #expect(restored.selectedURLs.isSubset(of: Set(restored.assets.map(\.url))))
  }

  @Test("영상 파일 직접 열기는 표시 옵션을 켜고 선택한 영상으로 이동한다")
  func openingVideoDirectlyEnablesVisibility() async throws {
    let fixture = try Fixture(showsVideos: false)
    let store = fixture.makeStore()
    defer { cleanup(store); fixture.remove() }
    #expect(!store.showsVideos)
    store.open(urls: [fixture.video])
    #expect(store.showsVideos)
    try await ready(store)
    let selected = try #require(store.currentAsset)
    #expect(selected.isVideo)
    #expect(selected.url.standardizedFileURL == fixture.video.standardizedFileURL)
    #expect(store.selectedAssets.map(\.sessionID) == [selected.sessionID])
    #expect(store.assets.map(\.filename) == [fixture.photoName, fixture.animationName, fixture.videoName])
    #expect(store.alert == nil)
  }

  @Test("영상이 선택되면 이미지 일괄 변환과 배경화면 설정을 막는다")
  func videoSelectionRejectsImageOnlyOperations() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store); fixture.remove() }
    try await openLibrary(store, fixture: fixture)
    #expect(store.canExportBatchImages() && store.canSetWallpaper)
    store.showsVideos = true
    try await ready(store)
    let video = try #require(store.assets.first { $0.isVideo })
    store.select(asset: video)
    #expect(store.canStartBatchOperation)
    #expect(!store.canExportBatchImages() && !store.canSetWallpaper)
    #expect(!store.canExportBatchImages(urls: [video.url]))
    store.presentBatchExport()
    #expect(store.batchSheet == nil)
    store.rotateClockwise()
    #expect(store.currentAdjustments.isIdentity)
    store.selectAllAssets()
    #expect(!store.canExportBatchImages())

    let photo = try #require(store.assets.first { $0.filename == fixture.photoName })
    store.select(asset: photo)
    #expect(store.canExportBatchImages() && store.canSetWallpaper)
    #expect(store.canExportBatchImages(urls: [photo.url]))
  }

  @Test("영상 도구는 원래 대상을 보관하고 일반 단축키와 다른 파일 열기를 막는다")
  func motionEditorKeepsItsAssetAndBlocksBackgroundActions() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store); fixture.remove() }
    store.open(urls: [fixture.video])
    try await ready(store)
    let original = try #require(store.currentAsset)
    let originalCollection = store.assets.map(\.sessionID)
    let originalSelection = store.selectedURLs
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    try #require(store.canOpenMotionMedia)
    store.presentMotionMedia()
    #expect(store.motionMediaAsset?.id == original.id)
    #expect(store.motionMediaAsset?.url == original.url)
    #expect(!store.canOpenFolderFromTree && !store.canStartBatchOperation)
    #expect(!store.canMarkPhoto && !store.canTogglePhotoMarking)
    #expect(!store.handleViewerKeyDown(try key(123), shortcuts: shortcuts))
    #expect(!store.handleViewerKeyDown(try key(0, characters: "a", modifiers: .command), shortcuts: shortcuts))
    #expect(!store.handleViewerKeyDown(try key(18, characters: "1"), shortcuts: shortcuts))
    store.perform(.previousPage)
    store.perform(.zoomIn)
    store.open(urls: [fixture.otherPhoto])
    store.openFolderFromTree(fixture.otherFolder)
    await Task.yield()
    #expect(!store.isLoading)
    #expect(store.assets.map(\.sessionID) == originalCollection)
    #expect(store.currentAsset?.sessionID == original.sessionID)
    #expect(store.selectedURLs == originalSelection)
    #expect(store.zoom == 1)
    #expect(store.motionMediaAsset?.sessionID == original.sessionID)

    store.motionMediaAsset = nil
    #expect(store.canOpenFolderFromTree)
    store.open(urls: [fixture.otherPhoto])
    try await ready(store)
    #expect(store.currentAsset?.filename == fixture.otherPhoto.lastPathComponent)
    #expect(store.assets.count == 1)
    #expect(store.alert == nil)
  }

  @Test("영상 표시를 껐다 켜도 사진·GIF·영상의 분류와 분류 필터를 유지한다")
  func classificationMembershipSurvivesVisibilityChanges() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store); fixture.remove() }
    try await openLibrary(store, fixture: fixture)
    store.showsVideos = true
    try await ready(store)
    let photo = try #require(store.assets.first { $0.filename == fixture.photoName })
    let animation = try #require(store.assets.first { $0.filename == fixture.animationName })
    let video = try #require(store.assets.first { $0.isVideo })
    store.photoMarks.setLabels([.one: "업로드", .w: "보관"])
    store.togglePhotoMarking()
    try #require(store.isPhotoMarking)
    for (asset, slot) in [(photo, PhotoMarkSlot.one), (animation, .w), (video, .one)] {
      store.select(asset: asset)
      try #require(store.canMarkPhoto)
      store.togglePhotoMark(slot)
    }
    store.togglePhotoMarking()
    store.photoMarkFilter = PhotoMarkFilter(slots: [.one])
    try await ready(store)
    #expect(store.assets.map(\.filename) == [fixture.photoName, fixture.videoName])

    store.showsVideos = false
    try await ready(store)
    #expect(store.assets.map(\.filename) == [fixture.photoName])
    #expect(store.photoMarkFilter.slots == [.one])
    #expect(store.photoMarks.marks(for: video) == [.one])
    #expect(store.photoMarks.marks(for: animation) == [.w])
    store.showsVideos = true
    try await ready(store)
    #expect(store.assets.map(\.filename) == [fixture.photoName, fixture.videoName])
    let visibleVideo = try #require(store.assets.first { $0.isVideo })
    #expect(visibleVideo.photoMarkID == video.photoMarkID)
    #expect(store.photoMarks.marks(for: visibleVideo) == [.one])
    #expect(store.photoMarks.label(for: .one) == "업로드")

    store.photoMarkFilter = PhotoMarkFilter()
    try await ready(store)
    #expect(store.assets.count == 3)
    #expect(store.photoMarks.marks(for: photo) == [.one])
    #expect(store.photoMarks.marks(for: animation) == [.w])
    #expect(store.alert == nil)
  }

  private func openLibrary(_ store: AppStore, fixture: Fixture) async throws {
    await store.photoMarks.waitUntilReady()
    try #require(store.photoMarks.isReady)
    store.open(urls: [fixture.folder])
    try await ready(store)
    try #require(store.alert == nil)
  }

  private func ready(_ store: AppStore) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while store.isLoading || store.isFiltering {
      guard ContinuousClock.now < deadline else { throw FixtureError.loadingTimedOut }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func ready(_ comparison: FolderComparisonStore) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while comparison.first.isLoading || comparison.second.isLoading
      || comparison.first.isFiltering || comparison.second.isFiltering || comparison.isMatching {
      guard ContinuousClock.now < deadline else { throw FixtureError.loadingTimedOut }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func key(_ code: UInt16, characters: String = "",
    modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: 0, context: nil, characters: characters,
      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
  }

  private func cleanup(_ store: AppStore) {
    store.folderComparison.cancelLoads()
    store.saveSessionNow()
  }

  private enum FixtureError: Error { case loadingTimedOut }

  private struct Fixture {
    let root: URL
    let folder: URL
    let otherFolder: URL
    let video: URL
    let otherPhoto: URL
    let suite: String
    let defaults: UserDefaults
    let database: URL
    let photoName = "01-photo.png"
    let animationName = "02-animation.gif"
    let videoName = "03-movie.mp4"

    init(showsVideos: Bool? = nil) throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("motion-media-integration-\(UUID())", isDirectory: true)
      folder = root.appendingPathComponent("mixed", isDirectory: true)
      otherFolder = root.appendingPathComponent("other", isDirectory: true)
      video = folder.appendingPathComponent(videoName)
      otherPhoto = otherFolder.appendingPathComponent("separate.png")
      database = root.appendingPathComponent("marks.sqlite")
      suite = "MotionMediaIntegration.\(UUID())"
      defaults = try #require(UserDefaults(suiteName: suite))
      // Hidden-video scenarios deliberately preserve an existing user choice;
      // tests without this argument exercise the app's default-on behavior.
      if let showsVideos { defaults.set(showsVideos, forKey: "ImageViewer.ShowsVideos.v1") }
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
      let png = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII="))
      try png.write(to: folder.appendingPathComponent(photoName))
      try png.write(to: otherPhoto)
      // Three synthetic colored GIF frames. The video intentionally tests only
      // list admission; actual decoding has separate AVFoundation fixture tests.
      let gif = try #require(Data(base64Encoded:
        "R0lGODlhCAAGAIEAAAAAAP8AAAAAAAAAACH/C05FVFNDQVBFMi4wAwECAAAh+QQJCgAAACwAAAAACAAGAAAIFQABCBwoMEAAggUPIjSIEADDhhADAgAh+QQJFAAAACwAAAAACAAGAIEAAAAA/wAAAAAAAAAIFQABCBxIEECAAAUNIix4MGHDhAQDAgAh+QQJHgAAACwAAAAACAAGAIEAAAAAAP8AAAAAAAAIFAABCBxIkGCAAAUBHEy4sGDDhAEBADs="))
      try gif.write(to: folder.appendingPathComponent(animationName))
      try Data("video list fixture".utf8).write(to: video)
    }

    @MainActor func makeStore(defaults override: UserDefaults? = nil) -> AppStore {
      AppStore(defaults: override ?? defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: database)
    }

    func remove() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
