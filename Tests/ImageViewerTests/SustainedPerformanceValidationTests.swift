import Foundation
import Testing

@testable import ImageViewer

@Suite("장시간 실제 앱 관측의 명시적 격리와 원본 증거")
struct SustainedPerformanceValidationTests {
  @Test("일반 실행·짧은 실행·잘못된 시간은30분관측으로 승인되지 않는다")
  func requiresBothExplicitPrivateFlagsAndRealDuration() {
    let valid = ["IMAGEVIEWER_SUSTAINED_QA": "1", "IMAGEVIEWER_MANUAL_QA": "1",
      "IMAGEVIEWER_MANUAL_QA_SOURCE": "/private/source", "IMAGEVIEWER_MANUAL_QA_OUTPUT": "/private/output"]
    #expect(SustainedPerformancePlan.isAuthorized(environment: valid, durationSeconds: 1_800))
    #expect(SustainedPerformancePlan.isAuthorized(environment: valid, durationSeconds: 7_200))
    #expect(!SustainedPerformancePlan.isAuthorized(environment: [:], durationSeconds: 1_800))
    for invalid in [0.0, 1_799, 7_201, Double.nan, Double.infinity] {
      #expect(!SustainedPerformancePlan.isAuthorized(environment: valid, durationSeconds: invalid))
    }
    var ordinary = valid; ordinary.removeValue(forKey: "IMAGEVIEWER_MANUAL_QA")
    #expect(!SustainedPerformancePlan.isAuthorized(environment: ordinary, durationSeconds: 1_800))
  }

  @Test("관측계획은사진4·6장과전체·영상목록·지도·검색을모두보존하고예산을늘리지않는다")
  func planDoesNotOmitWholeMixedOrQualityModes() {
    let actions = Set(SustainedPerformancePlan.actions)
    #expect(actions.contains(.fourPhotos) && actions.contains(.sixPhotos))
    #expect(actions.contains(.mixedOverview) && actions.contains(.videoOverview))
    #expect(actions.contains(.fourVideos) && actions.contains(.sixVideos))
    #expect(actions.contains(.mapSelection) && actions.contains(.metadataFilter) && actions.contains(.filenameFilter))
    #expect(SustainedPerformancePlan.checkpointDue(elapsed: 299, completedIndex: 0) == nil)
    #expect(SustainedPerformancePlan.checkpointDue(elapsed: 301, completedIndex: 0) == 1)
    #expect(SustainedPerformancePlan.checkpointDue(elapsed: 301, completedIndex: 1) == nil)
    #expect(SustainedPerformancePlan.checkpointDue(elapsed: 902, completedIndex: 1) == 3)
  }

  @Test("실제 AppStore의 88개 가상 영상에서 25·26회차 내부 선택과 왕복을 재현한다",
    arguments: [25, 26])
  @MainActor
  func realStorePreservesPageWhenSixTileSelectionIsInsideFourTilePage(cycle: Int) async throws {
    // Same isolated defaults/temp-library pattern as GridRowNavigationTests.
    // Synthetic MP4 list entries exercise navigation, not playback readiness.
    // No UI is hosted; slow mode disables speculative thumbnail decoding.
    let suite = "SustainedNavigation.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(ImageLoadingMode.slow.rawValue, forKey: "ImageViewer.ImageLoadingMode.v1")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }
    for index in 0..<88 {
      try Data("Synthetic video navigation fixture".utf8).write(to:
        folder.appendingPathComponent(String(format: "item%02d.mp4", index)))
    }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: folder.appendingPathComponent("marks.sqlite"), thumbnailDiskCache: nil)
    defer {
      store.presentationMode = .overview
      store.folderComparison.cancelLoads()
      store.photoMarks.flush()
      store.saveSessionNow()
    }
    await store.photoMarks.waitUntilReady()
    store.open(urls: [folder])
    let deadline = ContinuousClock.now + .seconds(8)
    while store.isLoading || store.isFiltering {
      try #require(ContinuousClock.now < deadline, "Synthetic video list did not finish loading")
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(store.alert == nil && store.assets.count == 88)
    try #require(store.assets.allSatisfy { $0.isVideo && ($0.byteCount ?? 0) > 0 })
    let libraryVersions = store.assets.map { AppStore.PresentedAssetVersion($0) }
    store.presentationMode = .viewer
    store.wrapsNavigation = false
    store.setImagesPerPage(4)
    let fourTileSelection = (cycle * 37) % (store.assets.count - 4 * 3)
    store.select(index: fourTileSelection)
    try #require(store.pageStartIndex == fourTileSelection)
    for direction in [1, 1, -1, -1] { store.navigatePage(direction) }
    try #require(store.pageStartIndex == fourTileSelection)

    store.setImagesPerPage(6)
    let sixTileSelection = (cycle * 37) % (store.assets.count - 6 * 3)
    store.select(index: sixTileSelection)
    try #require(sixTileSelection == fourTileSelection + 2)
    #expect(store.currentIndex == sixTileSelection)
    #expect(store.selectedURLs == Set([store.assets[sixTileSelection].url]))
    #expect(store.pageStartIndex == fourTileSelection)
    let initialPageStart = store.pageStartIndex
    let initialVersions = store.visibleAssets.map { AppStore.PresentedAssetVersion($0) }
    var pageStarts = [initialPageStart]
    for direction in [1, 1, -1, -1] {
      store.navigatePage(direction)
      pageStarts.append(store.pageStartIndex)
    }
    #expect(pageStarts == [fourTileSelection, fourTileSelection + 6,
      fourTileSelection + 12, fourTileSelection + 6, fourTileSelection])
    #expect(store.currentIndex == initialPageStart)
    #expect(store.selectedURLs == Set([store.assets[initialPageStart].url]))
    #expect(store.pageStartIndex != sixTileSelection,
      "The previous diagnostic incorrectly required the selected inner tile to become the page start")
    #expect(SustainedPerformancePlan.isPageRoundtripRestored(
      initialPageStart: initialPageStart, initialVersions: initialVersions,
      finalPageStart: store.pageStartIndex,
      finalVersions: store.visibleAssets.map { AppStore.PresentedAssetVersion($0) }, expectedVisibleCount: 6))
    #expect(store.assets.map { AppStore.PresentedAssetVersion($0) } == libraryVersions)
    #expect(store.videoGridPlayback.playingIDs.isEmpty && store.videoGridPlayback.audioID == nil)
  }

  @Test("선택된 내부 타일과 실제 페이지 시작은 다른 값이어도 같은 페이지 왕복이다")
  func pageRoundtripUsesCapturedPageInsteadOfSelectedTile() {
    // The two actual 90-run failing cycles selected 15/52 inside pages 13/50.
    for sample in [(page: 13, selection: 15), (page: 50, selection: 52)] {
      let versions = Array(sample.page..<(sample.page + 6))
      #expect(sample.selection != sample.page)
      #expect(SustainedPerformancePlan.isPageRoundtripRestored(
        initialPageStart: sample.page, initialVersions: versions,
        finalPageStart: sample.page, finalVersions: versions, expectedVisibleCount: 6))
      #expect(!SustainedPerformancePlan.isPageRoundtripRestored(
        initialPageStart: sample.page, initialVersions: versions,
        finalPageStart: sample.selection, finalVersions: versions, expectedVisibleCount: 6))
      #expect(!SustainedPerformancePlan.isPageRoundtripRestored(
        initialPageStart: sample.page, initialVersions: versions,
        finalPageStart: sample.page, finalVersions: Array(versions.reversed()), expectedVisibleCount: 6))
      #expect(!SustainedPerformancePlan.isPageRoundtripRestored(
        initialPageStart: sample.page, initialVersions: versions,
        finalPageStart: sample.page, finalVersions: Array(versions.prefix(5)), expectedVisibleCount: 6))
    }
  }

  @Test("UInt64 메모리 중앙값은 비트 패턴이 아닌 실제 바이트의 수치로 변환된다")
  func byteMediansUseNumericUInt64Conversion() {
    #expect(SustainedPerformancePlan.medianByteCount([]) == 0)
    #expect(SustainedPerformancePlan.medianByteCount([991_308_480]) == 991_308_480)
    #expect(SustainedPerformancePlan.medianByteCount([986_098_368, 991_308_480, 993_241_792]) == 991_308_480)
    #expect(SustainedPerformancePlan.medianByteCount([1_000_000_000, 1_100_000_000]) == 1_050_000_000)
    #expect(SustainedPerformancePlan.medianByteCount([UInt64.max]) == Double(UInt64.max))
  }

  @Test("관측 시간 완료만으로 시나리오 누락이나 최종 저장 실패를 통과시키지 않는다")
  func completedObservationCannotMaskValidationGaps() {
    #expect(SustainedPerformancePlan.validationSucceeded(observationCompleted: true,
      allScenarioChecksPassed: true, finalWriteSucceeded: true))
    #expect(!SustainedPerformancePlan.validationSucceeded(observationCompleted: true,
      allScenarioChecksPassed: false, finalWriteSucceeded: true))
    #expect(!SustainedPerformancePlan.validationSucceeded(observationCompleted: false,
      allScenarioChecksPassed: true, finalWriteSucceeded: true))
    #expect(!SustainedPerformancePlan.validationSucceeded(observationCompleted: true,
      allScenarioChecksPassed: true, finalWriteSucceeded: false))
  }

  @Test("원본증거는이름대신해시만기록하고변경된파일버전을검출한다")
  func sourceEvidenceIsReadOnlyPrivateAndDetectsReplacement() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SustainedEvidence.\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("personal-name-must-not-appear.dng")
    try Data([1, 2, 3]).write(to: file)
    let before = try SustainedSourceInventory.capture(directory: directory)
    #expect(try SustainedSourceInventory.capture(directory: directory) == before)
    let encoded = try JSONEncoder().encode(before)
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(!text.contains(file.lastPathComponent) && !text.contains(directory.path))
    #expect(before.entries.count == 1 && before.entries[0].pathSHA256.count == 64)
    try Data([4, 5, 6, 7]).write(to: file)
    let after = try SustainedSourceInventory.capture(directory: directory)
    #expect(after != before && after.digest != before.digest)
  }

  @Test("일반설정증거는키순서에무관하고개인경로값을내보내지않는다")
  func preferenceDigestIsStableAndSensitiveWithoutDisclosure() {
    let a: [String: Any] = ["photo": "/private/personal-file.dng", "count": 4, "nested": ["flag": true]]
    let b: [String: Any] = ["nested": ["flag": true], "count": 4, "photo": "/private/personal-file.dng"]
    let digest = SustainedMetadataDigest.preferences(a)
    #expect(digest == SustainedMetadataDigest.preferences(b))
    #expect(digest.count == 64 && !digest.contains("personal"))
    #expect(digest != SustainedMetadataDigest.preferences(["photo": "/private/replaced-file.dng", "count": 4]))
  }

  @Test("포스터 outcome ledger는 최신 source버전만 조회하고 최대512개로 제한한다")
  func posterOutcomeLedgerIsBoundedAndRejectsOldVersions() {
    var ledger = SustainedPosterOutcomeLedger(capacity: 10_000)
    for index in 0..<600 {
      let asset = diagnosticAsset(name: "video-\(index).mp4")
      ledger.record(VideoPosterDiagnosticEvent(request: VideoTilePosterRequest(asset: asset, maxPixelSize: 512),
        outcome: .accepted))
    }
    #expect(ledger.count == 512 && ledger.evictions == 88)
    #expect(ledger.event(for: diagnosticAsset(name: "video-0.mp4")) == nil)
    let current = diagnosticAsset(name: "video-599.mp4")
    #expect(ledger.event(for: current)?.outcome == .accepted)
    #expect(ledger.event(for: diagnosticAsset(name: "video-599.mp4", bytes: 11)) == nil)
    var enriched = current; enriched.hasReadLocation = true
    enriched.sortMetadata = LibrarySortMetadata(cameraMake: "Apple")
    ledger.record(VideoPosterDiagnosticEvent(request: VideoTilePosterRequest(asset: enriched, maxPixelSize: 1_024),
      outcome: .accepted))
    #expect(ledger.count == 512 && ledger.evictions == 88)
    #expect(ledger.event(for: current)?.request.asset.hasReadLocation == true)
  }

  @Test("실제 typed terminal은 미표시와 구별하고 unreadableData는 unsupported로 승격하지 않는다")
  @MainActor
  func currentSlotsRequireMatchingSourceAndPreserveTypedFailure() throws {
    let video = diagnosticAsset(name: "private-video.mp4")
    var ledger = SustainedPosterOutcomeLedger()
    ledger.record(VideoPosterDiagnosticEvent(request: VideoTilePosterRequest(asset: video, maxPixelSize: 512),
      outcome: .terminalFailure(.init(error: ImagePipelineError.unsupported(video.url)))))
    let snapshot = SustainedCurrentSlotOutcomes(assets: [video],
      presented: [0: AppStore.PresentedAssetVersion(video)], posterLedger: ledger)
    #expect(snapshot.acceptedIndices.isEmpty && snapshot.unverifiedIndices.isEmpty)
    #expect(snapshot.terminalSlots.count == 1 && snapshot.unsupportedSlots.isEmpty)
    let failure = try #require(snapshot.terminalSlots.first)
    #expect(failure["failureKind"] as? String == "unreadableData")
    #expect(failure["sourceVersionMatchesCurrent"] as? Bool == true)
    #expect(failure["sourcePathSHA256"] as? String == SustainedMetadataDigest.hash(Data(video.url.path.utf8)))
    #expect(failure["sourceByteCount"] as? Int64 == 10)
    #expect(failure["sourceModificationTime"] as? Double == 100)
    let encoded = try JSONSerialization.data(withJSONObject: snapshot.terminalSlots)
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(!text.contains(video.filename) && !text.contains(video.url.path))

    let replaced = diagnosticAsset(name: "private-video.mp4", bytes: 11)
    let stale = SustainedCurrentSlotOutcomes(assets: [replaced],
      presented: [0: AppStore.PresentedAssetVersion(video)], posterLedger: ledger)
    #expect(stale.acceptedIndices.isEmpty && stale.terminalSlots.isEmpty && stale.unverifiedIndices == [0])
  }

  @Test("accepted observer만으로 표시를 추측하지 않고 명시적unsupported만 별도 분류한다")
  @MainActor
  func slotPartitionRequiresPublicationAndExplicitUnsupported() {
    let video = diagnosticAsset(name: "video.mp4")
    var ledger = SustainedPosterOutcomeLedger()
    ledger.record(VideoPosterDiagnosticEvent(request: VideoTilePosterRequest(asset: video, maxPixelSize: 512), outcome: .accepted))
    let missing = SustainedCurrentSlotOutcomes(assets: [video], presented: [:], posterLedger: ledger)
    #expect(missing.unverifiedIndices == [0] && missing.acceptedIndices.isEmpty)
    let published = SustainedCurrentSlotOutcomes(assets: [video],
      presented: [0: AppStore.PresentedAssetVersion(video)], posterLedger: ledger)
    #expect(published.acceptedIndices == [0] && published.unverifiedIndices.isEmpty && published.terminalSlots.isEmpty)
    // Use a typed decoder variant with a deterministic .unsupported classifier.
    let typed = VideoPosterDiagnosticEvent.Failure(error: BitmapDecoderError.unsupportedVariant("synthetic"))
    #expect(typed.kind == .unsupported)
    ledger.record(VideoPosterDiagnosticEvent(request: VideoTilePosterRequest(asset: video, maxPixelSize: 256),
      outcome: .terminalFailure(typed)))
    let terminal = SustainedCurrentSlotOutcomes(assets: [video], presented: [:], posterLedger: ledger)
    #expect(terminal.acceptedIndices.isEmpty && terminal.unverifiedIndices.isEmpty)
    #expect(terminal.terminalSlots.count == 1 && terminal.unsupportedSlots.count == 1)
  }

  @Test("2초 자료는 이후 settle 성공으로 덮어쓰지 않고 최종 publication을 따로 남긴다")
  @MainActor
  func earlyAndFinalSlotSnapshotsRemainIndependent() {
    let photos = [diagnosticAsset(name: "a.dng"), diagnosticAsset(name: "b.dng")]
    let ledger = SustainedPosterOutcomeLedger()
    var published = [0: AppStore.PresentedAssetVersion(photos[0])]
    let early = SustainedCurrentSlotOutcomes(assets: photos, presented: published, posterLedger: ledger)
    published[1] = AppStore.PresentedAssetVersion(photos[1])
    let final = SustainedCurrentSlotOutcomes(assets: photos, presented: published, posterLedger: ledger)
    #expect(early.acceptedIndices == [0] && early.unverifiedIndices == [1])
    #expect(final.acceptedIndices == [0, 1] && final.unverifiedIndices.isEmpty)
    #expect(early.terminalSlots.isEmpty && final.terminalSlots.isEmpty)
  }

  @Test("source digest는 원본 이름을 내보내지 않고 Unix 날짜·크기·원본교체를 구분한다")
  func diagnosticSourceTuplesArePrivateAndVersionSensitive() throws {
    let asset = diagnosticAsset(name: "private-source.mp4")
    let version = SustainedDiagnosticSourceVersion(asset)
    #expect(version.sourceModificationTime == 100)
    #expect(version.sourceByteCount == 10 && version.sourcePathSHA256.count == 64)
    #expect(version.digest?.count == 64)
    #expect(version.digest != SustainedDiagnosticSourceVersion(diagnosticAsset(name: "private-source.mp4", bytes: 11)).digest)
    let json = try JSONSerialization.data(withJSONObject: version.json(slotIndex: 3))
    let text = String(decoding: json, as: UTF8.self)
    #expect(!text.contains(asset.filename) && !text.contains(asset.url.path))
  }

  private func diagnosticAsset(name: String, bytes: Int64 = 10) -> ImageAsset {
    ImageAsset(url: URL(fileURLWithPath: "/synthetic-sustained/\(name)"), byteCount: bytes,
      modificationDate: Date(timeIntervalSince1970: 100))
  }
}
