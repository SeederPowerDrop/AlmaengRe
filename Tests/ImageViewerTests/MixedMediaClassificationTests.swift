import AppKit
@preconcurrency import AVFoundation
import AVKit
import Combine
import CoreVideo
import ImageIO
import SwiftUI
import Testing
@testable import ImageViewer

@Suite("조건 선택부터 혼합 미디어 분류·지도·비교까지", .serialized)
@MainActor
struct MixedMediaClassificationTests {
  private struct SelectionWorkspace: View {
    @ObservedObject var store: AppStore
    let shortcuts: ShortcutStore
    var body: some View {
      if store.presentationMode == .viewer {
        ViewerCanvas(store: store, shortcuts: shortcuts)
      } else { Color.clear }
    }
  }
  private final class PlayerReference {
    weak var value: AVPlayer?
    init(_ player: AVPlayer) { value = player }
  }

  @Test("선택한 MP4·M4A·사진을 단일·다중보기로 반복 재생하고 이전 디코더를 해제한다")
  func selectedMediaNativePlaybackAndResources() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let store = fixture.store()
    store.open(urls: [fixture.media])
    try await ready(store)
    store.returnToOverview()
    let original = store.assets
    let versions = original.map { ImageFileVersion(url: $0.url) }
    let chosen = original.filter { $0.filename.hasPrefix("kit_") }
    for (offset, asset) in chosen.enumerated() {
      store.selectForBatch(index: try #require(original.firstIndex(of: asset)),
        modifiers: offset == 0 ? [] : .command)
    }
    let selected = store.selectedURLs
    _ = NSApplication.shared
    let host = NSHostingView(rootView: AnyView(SelectionWorkspace(store: store,
      shortcuts: ShortcutStore(defaults: fixture.defaults))))
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 960, height: 680),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host; window.orderBack(nil)
    defer {
      host.rootView = AnyView(Color.clear)
      window.orderOut(nil); window.contentView = nil; window.close()
    }
    let resource = SelectionViewingResourceTests()
    var references: [PlayerReference] = []
    var releasedItems = 0, maximumPlayers = 0
    var warmedFootprint: UInt64 = 0
    let cpuStart = OverviewWarmCPUCost.processCPUSeconds() ?? 0
    let started = ProcessInfo.processInfo.systemUptime
    let rounds = min(120,max(12,Int(ProcessInfo.processInfo.environment["IMAGEVIEWER_MEDIA_STRESS_ROUNDS"] ?? "12") ?? 12))
    for round in 0..<rounds {
      let together = round % 2 == 1
      store.viewSelectedFiles(together: together)
      if !together {
        let index = try #require(store.assets.firstIndex { round % 4 == 0 ? $0.isVideo : $0.isAudio })
        store.select(index: index)
      }
      try await wait("selected media visible tiles") {
        host.layoutSubtreeIfNeeded()
        return store.tracksViewerPresentation && store.visibleAssets.enumerated().allSatisfy {
          store.viewerPresentedAssets[$0.offset] == AppStore.PresentedAssetVersion($0.element)
        }
      }
      NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
      if together { store.videoGridPlayback.playAll() }
      let expected = Set(store.visibleAssets.filter(\.isPlaybackMedia).map(\.url))
      try await wait("selected media decoding real MP4/M4A") {
        host.layoutSubtreeIfNeeded()
        let native = players(in: host)
        return Set(native.compactMap { ($0.currentItem?.asset as? AVURLAsset)?.url }) == expected
          && native.allSatisfy { $0.rate > 0 && $0.currentTime().seconds > 0.04 }
      }
      if round == 0 {
        #expect(players(in: host).allSatisfy { $0.isMuted })
        let id = try #require(store.currentAsset?.id)
        store.videoGridPlayback.cycleSound(id)
        store.videoGridPlayback.cycleSound(id)
      }
      try await wait("selected media session sound ownership") {
        store.mediaSoundSession.isEnabled && players(in: host).filter { !$0.isMuted }.count == 1
      }
      let previous = players(in: host)
      maximumPlayers = max(maximumPlayers, previous.count)
      references.append(contentsOf: previous.map(PlayerReference.init))
      store.returnToOverview()
      try await wait("selected media previous decoder release") {
        host.layoutSubtreeIfNeeded()
        return previous.allSatisfy { $0.currentItem == nil && $0.rate == 0 }
          && players(in: host).isEmpty && !store.tracksViewerPresentation
      }
      releasedItems += previous.count
      #expect(store.videoGridPlayback.playingIDs.isEmpty)
      #expect(store.selectionViewingContext == nil && store.selectedURLs == selected)
      #expect(store.mediaSoundSession.isEnabled)
      if round == 2 { warmedFootprint = resource.footprint() }
    }
    let playbackCPU = (OverviewWarmCPUCost.processCPUSeconds() ?? cpuStart) - cpuStart
    let playbackWall = ProcessInfo.processInfo.systemUptime - started
    host.rootView = AnyView(Color.clear)
    try await Task.sleep(for: .seconds(1))
    let cpuBefore = OverviewWarmCPUCost.processCPUSeconds() ?? 0
    try await Task.sleep(for: .seconds(2))
    let idleCPU = (OverviewWarmCPUCost.processCPUSeconds() ?? cpuBefore) - cpuBefore
    let finalFootprint = resource.footprint()
    let remainingPlayers = references.filter { $0.value != nil }.count
    #expect(remainingPlayers <= 2, "Repeated native views must not accumulate players")
    #expect(finalFootprint < warmedFootprint + 48 * 1024 * 1024)
    #expect(original.map { ImageFileVersion(url: $0.url) } == versions)
    #expect(store.alert == nil && store.overviewMediaPreview.playback == nil)
    if ProcessInfo.processInfo.environment["IMAGEVIEWER_SELECTION_RESOURCE_OUTPUT"] != nil {
      try resource.reportResult(["cycles": rounds, "maximumConcurrentPlayers": maximumPlayers,
        "releasedPlayerItems": releasedItems, "remainingWeakPlayersAfterIdle": remainingPlayers,
        "warmedFootprint": warmedFootprint, "finalFootprint": finalFootprint,
        "playbackProcessCPUSeconds": playbackCPU, "playbackWallSeconds": playbackWall,
        "idleProcessCPUSecondsOver2Seconds": idleCPU, "sourceMetadataUnchanged": true,
        "formats": ["jpg", "mp4", "m4a"],
        "measurement": "offscreen native AVPlayer decoding and view lifetimes; not foreground GPU rendering"],
        name: "native-selected-media-resources")
    }
  }

  @Test("선택 범위는 실제 사진·영상·음성을 함께 보존하고 지도 전환 시 원래 목록을 돌려준다")
  func selectedMixedMediaViewing() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let store = fixture.store()
    store.open(urls: [fixture.media])
    try await ready(store)
    store.returnToOverview()
    let original = store.assets
    let chosen = original.filter { $0.filename.hasPrefix("kit_") }
    for (offset, asset) in chosen.enumerated() {
      store.selectForBatch(index: try #require(original.firstIndex(of: asset)),
        modifiers: offset == 0 ? [] : .command)
    }
    store.viewSelectedFiles(together: true)
    #expect(store.assets == chosen)
    #expect(store.visibleAssets.contains { $0.isVideo })
    #expect(store.visibleAssets.contains { $0.isAudio })
    #expect(store.visibleAssets.contains { !$0.isPlaybackMedia })
    for index in chosen.indices {
      store.setImagesPerPage(1)
      store.select(index: index)
      #expect(store.currentAsset == chosen[index])
    }
    store.presentationMode = .map
    #expect(store.selectionViewingContext == nil)
    #expect(store.assets == original)
    #expect(store.selectedAssets == chosen)
  }

  @Test("뷰어·몽땅보기·지도에서 포함·제외 분류 필터와 조건 검색을 재실행 후 함께 복원한다",
    arguments: ["viewer", "overview", "map"])
  func ordinaryClassificationFilterSurvivesSessionRestore(mode: String) async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let store = fixture.store()
    defer { store.folderComparison.cancelLoads() }
    store.open(urls: [fixture.media])
    try await ready(store)
    let photo = try #require(store.assets.first { !$0.isPlaybackMedia })
    let video = try #require(store.assets.first { $0.isVideo })
    store.photoMarks.set(.s, enabled: true, for: [photo, video])
    store.photoMarks.set(.one, enabled: true, for: [photo])
    store.libraryQuery = LibraryQuery(searchText: "kit_*", fileExtensions: ["jpg", "mp4", "m4a"])
    store.photoMarkFilter = PhotoMarkFilter(slots: [.s], excludedSlots: [.one])
    store.presentationMode = try #require(PresentationMode(rawValue: mode))
    try await ready(store)
    try #require(store.assets.map(\.filename) == ["kit_video.mp4"])
    store.saveSessionNow()
    let restored = fixture.store()
    defer { restored.folderComparison.cancelLoads() }
    await restored.restoreLastSession()
    try await ready(restored)
    #expect(restored.photoMarkFilter == store.photoMarkFilter)
    #expect(restored.libraryQuery == store.libraryQuery)
    #expect(restored.presentationMode == store.presentationMode)
    #expect(restored.assets.map(\.filename) == ["kit_video.mp4"])

    // Removing the new optional key reproduces a session written by build 113.
    let persistence = ViewerSessionPersistence(defaults: fixture.defaults)
    let saved = try #require(persistence.loadSession())
    let encoded = try JSONEncoder().encode(saved)
    var oldFields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    oldFields.removeValue(forKey: "photoMarkFilter")
    fixture.defaults.set(try JSONSerialization.data(withJSONObject: oldFields),
      forKey: ViewerSessionPersistence.sessionKey)
    let legacy = fixture.store()
    defer { legacy.folderComparison.cancelLoads() }
    await legacy.restoreLastSession()
    try await ready(legacy)
    #expect(legacy.photoMarkFilter == PhotoMarkFilter())
    #expect(legacy.libraryQuery == store.libraryQuery)
    #expect(legacy.assets.count == 3)
  }

  @Test("비교 복원 중 바꾼 일반 분류 필터는 비교를 나올 때 최신 조건으로 적용한다")
  func latestClassificationFilterWinsDuringComparisonRestore() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let original = fixture.store()
    defer { original.folderComparison.cancelLoads() }
    original.open(urls: [fixture.media])
    try await ready(original)
    original.photoMarks.set(.s, enabled: true, for: original.assets.filter { !$0.isAudio })
    original.libraryQuery = LibraryQuery(searchText: "kit_*")
    original.photoMarkFilter = PhotoMarkFilter(slots: [.s])
    try await ready(original)
    original.compareCurrentCollectionByMarks()
    try await ready(original)
    original.saveSessionNow()

    let restored = fixture.store()
    defer { restored.folderComparison.cancelLoads() }
    let latestFilter = PhotoMarkFilter(unmarkedOnly: true)
    var changedDuringRestore = false
    // Loading A/B suspends after the ordinary collection has been committed.
    let observation = restored.folderComparison.first.$isLoading.sink { loading in
      guard loading, !changedDuringRestore else { return }
      changedDuringRestore = true
      restored.photoMarkFilter = latestFilter
    }
    defer { observation.cancel() }
    await restored.restoreLastSession()
    try await ready(restored)
    #expect(changedDuringRestore)
    #expect(restored.photoMarkFilter == latestFilter)
    #expect(restored.presentationMode == .folderComparison)
    #expect(Set(restored.assets.map(\.filename)) == ["kit_photo.jpg", "kit_video.mp4"])
    restored.presentationMode = .overview
    try await ready(restored)
    #expect(restored.assets.map(\.filename) == ["kit_audio.m4a"])
  }

  @Test("영상·음성의 확대 단축키와 연결 설정은 반대편 사진의 확대·이동을 바꾸지 않는다")
  func mediaViewportCommandsLeavePhotoReferenceUntouched() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let store = fixture.store()
    defer { store.folderComparison.cancelLoads() }
    store.open(urls: [fixture.media])
    try await ready(store)
    store.compareCurrentCollectionByMarks()
    try await ready(store)
    let comparison = store.folderComparison
    comparison.linksViewport = false
    let photoIndex = try #require(comparison.second.assets.firstIndex { !$0.isPlaybackMedia })
    comparison.jump(.second, number: photoIndex + 1)
    comparison.updateZoom(2, on: .second)
    comparison.pan(CGSize(width: 30, height: 20), on: .second)
    let reference = comparison.second.viewport.snapshot
    for kind in [LibraryMediaKind.audio, .videos] {
      let mediaIndex = try #require(comparison.first.assets.firstIndex {
        kind == .audio ? $0.isAudio : $0.isVideo
      })
      comparison.jump(.first, number: mediaIndex + 1)
      let mediaViewport = comparison.first.viewport.snapshot
      comparison.activeSide = .first
      comparison.linksViewport = true
      comparison.updateZoom(2)
      comparison.setScale(.actualPixels)
      comparison.centerImage()
      comparison.updateLiveMagnification(2, on: .first)
      comparison.endLiveMagnification(2, on: .first)
      #expect(comparison.first.viewport.snapshot == mediaViewport)
      #expect(comparison.second.viewport.snapshot == reference)
      #expect(!comparison.showsLiveInput(on: .second))
      comparison.linksViewport = false
    }
    let photoOnFirst = try #require(comparison.first.assets.firstIndex { !$0.isPlaybackMedia })
    comparison.jump(.first, number: photoOnFirst + 1)
    comparison.linksViewport = true
    comparison.updateZoom(1.5, on: .first)
    #expect(comparison.second.zoom == comparison.first.zoom)
  }

  @Test("파일명·확장자·EXIF 조건 결과를 분류하고 같은 폴더에서 네 보기로 필터링한다")
  func querySelectionClassificationAndEveryView() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let store = fixture.store()
    defer { store.folderComparison.cancelLoads(); store.saveSessionNow() }
    store.open(urls: [fixture.media])
    try await ready(store)
    try #require(store.allAssets.count == 4)
    let originals = try Dictionary(uniqueKeysWithValues: store.allAssets.map { ($0.url, try Data(contentsOf: $0.url)) })
    store.presentationMode = .overview

    // EXIF filters are applied to real JPEG headers, then to the actual selection.
    store.libraryQuery = LibraryQuery(searchText: "kit_*", fileExtensions: ["jpg"],
      searchFilters: LibrarySearchFilters(metadataText: "Canon"))
    try await ready(store)
    try #require(store.assets.count == 1 && store.assets[0].filename == "kit_photo.jpg")
    store.selectAllAssets()
    store.presentSelectionClassification()
    try #require(store.canMarkPhoto)
    store.togglePhotoMark(.one)
    store.togglePhotoMarking()

    // Select the mixed filename/extension result without accidentally marking
    // unrelated files in this folder or equally named files in another folder.
    store.libraryQuery = LibraryQuery(searchText: "kit_*", fileExtensions: ["jpg", "mp4", "m4a"])
    try await ready(store)
    try #require(store.assets.count == 3)
    store.selectAllAssets()
    store.presentSelectionClassification()
    store.togglePhotoMark(.s)
    store.togglePhotoMarking()
    let outside = try #require(try await ImageLibrary().scan(folder: fixture.other).first)
    store.photoMarks.set(.s, enabled: true, for: [outside])
    store.libraryQuery = LibraryQuery()
    store.photoMarkFilter = PhotoMarkFilter(slots: [.s])
    try await ready(store)
    let expected = Set(["kit_photo.jpg", "kit_video.mp4", "kit_audio.m4a"])
    #expect(Set(store.assets.map(\.filename)) == expected)
    for mode in [PresentationMode.viewer, .overview, .map] {
      store.presentationMode = mode
      try await ready(store)
      #expect(Set(store.assets.map(\.filename)) == expected)
    }
    #expect(Set(store.mapAssets.filter { $0.location != nil }.map(\.filename)) == expected)
    store.libraryQuery.geographicSelection = .radius(
      center: GeoCoordinate(latitude: 37.5665, longitude: 126.978), meters: 500)
    try await ready(store)
    #expect(Set(store.assets.map(\.filename)) == expected)
    store.showMapSelection(in: .overview)
    #expect(store.presentationMode == .overview && Set(store.assets.map(\.filename)) == expected)

    try #require(store.canCompareCurrentCollectionByMarks)
    store.compareCurrentCollectionByMarks()
    try await ready(store)
    #expect(store.presentationMode == .folderComparison)
    #expect(Set(store.folderComparison.first.assets.map(\.filename)) == expected)
    #expect(Set(store.folderComparison.second.assets.map(\.filename)) == expected)
    store.folderComparison.first.photoMarkFilter = PhotoMarkFilter(slots: [.one])
    store.folderComparison.second.photoMarkFilter = PhotoMarkFilter(slots: [.s], excludedSlots: [.one])
    try await ready(store)
    #expect(store.folderComparison.first.assets.map(\.filename) == ["kit_photo.jpg"])
    #expect(Set(store.folderComparison.second.assets.map(\.filename)) == ["kit_video.mp4", "kit_audio.m4a"])
    #expect(store.folderComparison.first.sourceURLs == [fixture.media])
    for (url, bytes) in originals { #expect(try Data(contentsOf: url) == bytes) }
    try #require(await store.photoMarks.flushAsync())
  }

  @Test("비교 칸은 실제 영상·음성을 무음 재생하고 필터 변경 시 이전 플레이어를 해제한다")
  func nativeComparisonPlaybackAndTeardown() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let store = fixture.store()
    defer { store.folderComparison.cancelLoads(); store.saveSessionNow() }
    store.open(urls: [fixture.media])
    try await ready(store)
    let video = try #require(store.assets.first { $0.isVideo })
    let audio = try #require(store.assets.first { $0.isAudio })
    store.photoMarks.set(.one, enabled: true, for: [video])
    store.photoMarks.set(.two, enabled: true, for: [audio])
    store.compareCurrentCollectionByMarks()
    store.folderComparison.first.photoMarkFilter = PhotoMarkFilter(slots: [.one])
    store.folderComparison.second.photoMarkFilter = PhotoMarkFilter(slots: [.two])
    try await ready(store)
    _ = NSApplication.shared
    let host = NSHostingView(rootView: AnyView(FolderComparisonView(store: store,
      shortcuts: ShortcutStore(defaults: fixture.defaults), comparison: store.folderComparison)))
    let window = NSWindow(contentRect: NSRect(x: -3_000, y: -3_000, width: 960, height: 600),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { host.rootView = AnyView(Color.clear); window.orderOut(nil); window.contentView = nil; window.close() }
    try await wait("both comparison presentations") {
      host.layoutSubtreeIfNeeded()
      return store.folderComparison.first.presentationTracking.isTracking
        && store.folderComparison.second.presentationTracking.isTracking
        && store.folderComparison.first.canMarkPresentedAsset && store.folderComparison.second.canMarkPresentedAsset
    }
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    try await wait("native video and audio playback") {
      host.layoutSubtreeIfNeeded()
      let players = players(in: host)
      return players.count == 2 && players.allSatisfy { $0.rate > 0 && $0.isMuted }
    }
    let oldPlayers = players(in: host)
    store.folderComparison.activeSide = .first
    store.mediaSoundSession.setEnabled(true)
    try await wait("session sound only on active video comparison pane") {
      host.layoutSubtreeIfNeeded()
      return oldPlayers.filter { !$0.isMuted }.count == 1
        && oldPlayers.contains { ($0.currentItem?.asset as? AVURLAsset)?.url == video.url && !$0.isMuted }
    }
    store.folderComparison.activeSide = .second
    try await wait("session sound follows active audio comparison pane") {
      host.layoutSubtreeIfNeeded()
      return store.mediaSoundSession.isEnabled && oldPlayers.filter { !$0.isMuted }.count == 1
        && oldPlayers.contains { ($0.currentItem?.asset as? AVURLAsset)?.url == audio.url && !$0.isMuted }
    }
    store.mediaSoundSession.setEnabled(false)
    try await wait("comparison returns to mute") { oldPlayers.allSatisfy(\.isMuted) }
    store.folderComparison.photoMarkTarget = .both
    store.togglePhotoMarking()
    try #require(store.canMarkPhoto)
    store.togglePhotoMark(.s)
    #expect(store.photoMarks.marks(for: video).contains(.s))
    #expect(store.photoMarks.marks(for: audio).contains(.s))
    store.togglePhotoMarking()
    store.folderComparison.first.photoMarkFilter = PhotoMarkFilter(slots: [.q])
    store.folderComparison.second.photoMarkFilter = PhotoMarkFilter(slots: [.q])
    try await ready(store)
    try await wait("hidden players released after filtering") {
      host.layoutSubtreeIfNeeded()
      return oldPlayers.allSatisfy { $0.currentItem == nil && $0.rate == 0 }
    }
    #expect(players(in: host).isEmpty)
  }

  @Test("음성만 있는 폴더도 비교에 열리고 재실행한 분류 필터가 유지된다")
  func audioOnlyComparisonAndPersistentMarks() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let first = fixture.store()
    first.open(urls: [fixture.audio])
    try await ready(first)
    let audio = try #require(first.assets.first { $0.isAudio })
    first.photoMarks.set(.r, enabled: true, for: [audio])
    try #require(await first.photoMarks.flushAsync())
    let reopened = fixture.store()
    defer { first.folderComparison.cancelLoads(); reopened.folderComparison.cancelLoads() }
    reopened.open(urls: [fixture.audioOnly])
    try await ready(reopened)
    // Copy to this separate folder explicitly and assign its own classification.
    let copied = try #require(reopened.currentAsset)
    reopened.photoMarks.set(.r, enabled: true, for: [copied])
    reopened.photoMarkFilter = PhotoMarkFilter(slots: [.r])
    try await ready(reopened)
    try #require(reopened.assets.count == 1 && reopened.canCompareCurrentCollectionByMarks)
    reopened.compareCurrentCollectionByMarks()
    try await ready(reopened)
    #expect(reopened.folderComparison.first.currentAsset?.isAudio == true)
    #expect(reopened.folderComparison.second.currentAsset?.isAudio == true)
    // Opening a folder separately uses the same mixed-media scanner.
    reopened.folderComparison.open(urls: [fixture.media], for: .second)
    try await ready(reopened)
    #expect(reopened.folderComparison.second.assets.count == 4)
    #expect(reopened.photoMarks.marks(for: audio).contains(.r))
  }

  @Test("지도 조건을 다시 적용해도 영상·음성의 GPS와 위치 없음 결과를 재사용한다")
  func locationCacheRoutesMediaAndRetainsNegativeLookups() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let source = try await ImageLibrary().scan(folder: fixture.media, includesVideos: true)
    let reads = LocationReads()
    let cache = LibrarySortMetadataCache { url, nativeMedia in
      await reads.record(url: url, nativeMedia: nativeMedia)
      return LibrarySortMetadata(embeddedLocation: nativeMedia
        ? ImageLocation(latitude: 37.5665, longitude: 126.978) : nil)
    }
    let first = try await ImageLibrary().enrichLocations(source, cache: cache)
    let second = try await ImageLibrary().enrichLocations(first, cache: cache)
    let fresh = try await ImageLibrary().enrichLocations(source, cache: cache)
    #expect(await reads.count == source.count)
    #expect(await reads.nativeCount == 2)
    #expect(second == first && fresh == first)
    #expect(first.filter(\.isPlaybackMedia).allSatisfy { $0.location != nil && $0.hasReadLocation })
    #expect(first.filter { !$0.isPlaybackMedia }.allSatisfy { $0.location == nil && $0.hasReadLocation })
  }

  @Test("최소 창과 사이드바 폭에서 혼합 비교 조작부를 실제 언어·RTL·두 배치로 렌더한다",
    arguments: [660, 960], [(false, false), (false, true), (true, false), (true, true)])
  func localizedMixedComparisonLayout(width: Int, configuration: (Bool, Bool)) async throws {
    let (vertical, isDark) = configuration
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let store = fixture.store()
    defer { store.folderComparison.cancelLoads() }
    let language = L10n.languageIdentifier
    if let expected = ProcessInfo.processInfo.environment["EXPECTED_APP_LANGUAGE"] {
      try #require(language == expected)
    }
    store.open(urls: [fixture.media])
    try await ready(store)
    store.compareCurrentCollectionByMarks()
    store.folderComparison.arrangement = vertical ? .vertical : .horizontal
    store.folderComparison.showsThumbnails = false
    store.folderComparison.first.photoMarkFilter = PhotoMarkFilter()
    store.folderComparison.query.mediaKind = .audio
    try await ready(store)
    store.mediaSoundSession.setEnabled(true)
    let size = NSSize(width: width + 80, height: 680)
    let root = FolderComparisonView(store: store, shortcuts: ShortcutStore(defaults: fixture.defaults),
      comparison: store.folderComparison)
      .frame(width: CGFloat(width), height: 600)
      .padding(40).background(Color(red: 1, green: 0, blue: 1))
      .environment(\.locale, Locale(identifier: language))
      .environment(\.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight)
      .environment(\.colorScheme, isDark ? .dark : .light)
    _ = NSApplication.shared
    let host = NSHostingView(rootView: AnyView(root))
    host.frame = NSRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000, width: size.width, height: size.height),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { host.rootView = AnyView(Color.clear); window.orderOut(nil); window.contentView = nil; window.close() }
    try await wait("layout presentations") {
      host.layoutSubtreeIfNeeded()
      return store.folderComparison.first.presentationTracking.isTracking
        && store.folderComparison.second.presentationTracking.isTracking
        && store.folderComparison.first.canMarkPresentedAsset && store.folderComparison.second.canMarkPresentedAsset
    }
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    try await wait("layout native audio controls") {
      host.layoutSubtreeIfNeeded()
      return players(in: host).count == 2 && players(in: host).allSatisfy { $0.rate > 0 }
    }
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let scale = CGFloat(bitmap.pixelsWide) / size.width
    let reference = try #require(bitmap.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
    var overflow = 0
    for y in stride(from: 10, to: bitmap.pixelsHigh - 10, by: 4) {
      for x in [12.0, 30.0, size.width - 30, size.width - 12] {
        let color = try #require(bitmap.colorAt(x: Int(x * scale), y: y)?.usingColorSpace(.sRGB))
        if abs(color.redComponent - reference.redComponent) > 0.03
          || abs(color.greenComponent - reference.greenComponent) > 0.03
          || abs(color.blueComponent - reference.blueComponent) > 0.03 { overflow += 1 }
      }
    }
    #expect(overflow == 0, "Comparison controls must stay inside the available width")
    if let output = ProcessInfo.processInfo.environment["IMAGEVIEWER_LOCALIZED_CONTROLS_OUTPUT"] {
      let directory = URL(fileURLWithPath: output, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try #require(bitmap.representation(using: .png, properties: [:])).write(to:
        directory.appendingPathComponent("mixed-comparison-\(language)-\(width)-\(vertical ? "vertical" : "horizontal")-\(isDark ? "dark" : "light").png"))
    }
  }

  private func ready(_ store: AppStore) async throws {
    try await wait("query ready") {
      !store.isLoading && !store.isFiltering && store.photoMarks.isReady
        && !store.folderComparison.first.isLoading && !store.folderComparison.second.isLoading
        && !store.folderComparison.first.isFiltering && !store.folderComparison.second.isFiltering
    }
  }

  private func wait(_ phase: String, _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(predicate(), "Mixed-media validation did not reach: \(phase)")
  }

  private func players(in view: NSView) -> [AVPlayer] {
    if let native = view as? AVPlayerView { return native.player.map { [$0] } ?? [] }
    return view.subviews.flatMap { players(in: $0) }
  }

  private struct Fixture {
    let root: URL
    let defaults: UserDefaults
    let suite: String
    var media: URL { root.appendingPathComponent("Media") }
    var other: URL { root.appendingPathComponent("Other") }
    var audioOnly: URL { root.appendingPathComponent("AudioOnly") }
    var audio: URL { media.appendingPathComponent("kit_audio.m4a") }

    static func make() async throws -> Self {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-classify-\(UUID())")
      let suite = "MixedClassification.\(UUID())"
      let fixture = Self(root: root, defaults: try #require(UserDefaults(suiteName: suite)), suite: suite)
      for folder in [fixture.media, fixture.other, fixture.audioOnly] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      }
      do {
        try fixture.writePhoto("kit_photo.jpg", gps: true)
        try fixture.writePhoto("unrelated.jpg", gps: false)
        try FileManager.default.copyItem(at: fixture.media.appendingPathComponent("kit_photo.jpg"),
          to: fixture.other.appendingPathComponent("outside.jpg"))
        try await fixture.writeMovie()
        try await fixture.writeAudio()
        try FileManager.default.copyItem(at: fixture.audio, to: fixture.audioOnly.appendingPathComponent("only.m4a"))
        if let output = ProcessInfo.processInfo.environment["IMAGEVIEWER_MIXED_FIXTURE_OUTPUT"] {
          let destination = URL(fileURLWithPath: output, isDirectory: true)
          if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: fixture.media, to: destination)
          }
        }
        return fixture
      } catch { fixture.remove(); throw error }
    }

    @MainActor func store() -> AppStore {
      AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: root.appendingPathComponent("marks.sqlite"), thumbnailDiskCache: nil)
    }
    func remove() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }

    private func writePhoto(_ name: String, gps: Bool) throws {
      let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 96,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 640, bitsPerPixel: 32))
      bitmap.bitmapData?.initialize(repeating: 180, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
      let image = try #require(bitmap.cgImage)
      let destination = try #require(CGImageDestinationCreateWithURL(media.appendingPathComponent(name) as CFURL,
        "public.jpeg" as CFString, 1, nil))
      var properties: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:24 12:00:00"]]
      if gps { properties[kCGImagePropertyGPSDictionary] = [
        kCGImagePropertyGPSLatitude: 37.5665, kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 126.978, kCGImagePropertyGPSLongitudeRef: "E"] }
      CGImageDestinationAddImage(destination, image, properties as CFDictionary)
      try #require(CGImageDestinationFinalize(destination))
    }

    private var metadata: [AVMetadataItem] {
      let location = AVMutableMetadataItem()
      location.identifier = .quickTimeMetadataLocationISO6709
      location.value = "+37.5665+126.9780/" as NSString
      location.dataType = kCMMetadataBaseDataType_UTF8 as String
      let title = AVMutableMetadataItem()
      title.identifier = .commonIdentifierTitle
      title.value = "Canon synthetic catalog" as NSString
      return [location, title]
    }

    private func writeMovie() async throws {
      let writer = try AVAssetWriter(outputURL: media.appendingPathComponent("kit_video.mp4"), fileType: .mp4)
      writer.metadata = metadata
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 96,
        AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false]])
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
          kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96])
      writer.add(input)
      try #require(writer.startWriting())
      writer.startSession(atSourceTime: .zero)
      var pixels: CVPixelBuffer?
      try #require(CVPixelBufferCreate(kCFAllocatorDefault, 160, 96, kCVPixelFormatType_32BGRA,
        nil, &pixels) == kCVReturnSuccess)
      let buffer = try #require(pixels)
      CVPixelBufferLockBaseAddress(buffer, [])
      CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt32.self)
        .initialize(repeating: 0xFF_30_70_90, count: CVPixelBufferGetBytesPerRow(buffer) * 96 / 4)
      CVPixelBufferUnlockBaseAddress(buffer, [])
      for frame in 0..<120 {
        let deadline = ContinuousClock.now + .seconds(5)
        while !input.isReadyForMoreMediaData, ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(5))
        }
        try #require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 4)))
      }
      input.markAsFinished()
      writer.endSession(atSourceTime: CMTime(seconds: 30, preferredTimescale: 600))
      await writer.finishWriting()
      try #require(writer.status == .completed)
    }

    private func writeAudio() async throws {
      let url = root.appendingPathComponent("silent.caf")
      let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 30))
      buffer.frameLength = buffer.frameCapacity
      buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(buffer.frameLength))
      do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
      let exporter = try #require(AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetAppleM4A))
      exporter.metadata = metadata
      exporter.outputURL = audio
      exporter.outputFileType = .m4a
      await exporter.export()
      try #require(exporter.status == .completed)
    }
  }
}

private actor LocationReads {
  var count = 0
  var nativeCount = 0
  func record(url: URL, nativeMedia: Bool) {
    count += 1
    if nativeMedia { nativeCount += 1 }
  }
}
