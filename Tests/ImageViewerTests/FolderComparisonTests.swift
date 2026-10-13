import AppKit
import Testing

@testable import ImageViewer

@Suite("독립적인 두 폴더 비교")
@MainActor
struct FolderComparisonTests {
  @Test("개별 이동으로 맞춘 순번은 짧은 목록의 끝까지 유지하고 긴 목록은 계속 이동한다")
  func independentAndUnequalNavigation() async throws {
    let a = try fixture(count: 4), b = try fixture(count: 6)
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    let suite = "FolderComparisonTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let comparison = FolderComparisonStore(defaults: defaults, alignment: .sequence)
    comparison.first.load(a); comparison.second.load(b)
    try await wait { !comparison.first.isLoading && !comparison.second.isLoading }
    #expect(comparison.first.assets.count == 4 && comparison.second.assets.count == 6)
    #expect(comparison.first.currentAsset?.filename == comparison.second.currentAsset?.filename)
    #expect(comparison.first.currentAsset?.url != comparison.second.currentAsset?.url)
    comparison.navigate(.first, direction: 1)
    #expect(comparison.first.index == 1 && comparison.second.index == 0)
    comparison.navigateBoth(1)
    #expect(comparison.first.index == 2 && comparison.second.index == 1)
    comparison.navigateBoth(1)
    #expect(comparison.first.index == 3 && comparison.second.index == 2)
    #expect(comparison.canNavigateBoth(1))
    comparison.navigateBoth(1)
    #expect(comparison.first.index == 3 && comparison.second.index == 3)
    comparison.navigate(.second, direction: 1)
    #expect(comparison.first.index == 3 && comparison.second.index == 4)
    comparison.navigateBoth(-1)
    #expect(comparison.first.index == 2 && comparison.second.index == 3)
    comparison.jump(.second, number: 6)
    #expect(comparison.first.index == 2 && comparison.second.index == 5)
    comparison.jump(.second, number: -5)
    comparison.jump(.second, number: 100)
    comparison.jump(.second, number: .min)
    comparison.jump(.second, number: .max)
    comparison.second.select(number: .min)
    comparison.second.select(number: .max)
    #expect(comparison.second.index == 5)
  }

  @Test("5장과 9장을 함께 넘기면 짧은 쪽 화면을 유지하면서 9장까지 이동한다")
  func shorterFolderHoldsUntilLongerFolderEnds() async throws {
    let a = try fixture(count: 5), b = try fixture(count: 9)
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    let suite = "FolderComparisonHoldTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let comparison = FolderComparisonStore(defaults: defaults, alignment: .sequence)
    comparison.first.load(a); comparison.second.load(b)
    try await wait { !comparison.first.isLoading && !comparison.second.isLoading }
    #expect(comparison.endBehavior == .hold)
    for _ in 0..<4 { comparison.navigateBoth(1) }
    #expect(comparison.first.position == "5 / 5" && comparison.second.position == "5 / 9")
    comparison.updateZoom(2, on: .first)
    comparison.pan(CGSize(width: 30, height: 40), on: .first)
    let heldAsset = comparison.first.currentAsset
    let heldPan = comparison.first.pan
    for expectedIndex in 5...8 {
      #expect(comparison.canNavigateBoth(1))
      comparison.navigateBoth(1)
      #expect(comparison.first.currentAsset == heldAsset && comparison.second.index == expectedIndex)
      #expect(comparison.first.zoom == 2 && comparison.first.pan == heldPan)
    }
    #expect(!comparison.canNavigateBoth(1))
    comparison.navigateBoth(.max)
    #expect(comparison.first.index == 4 && comparison.second.index == 8)
    #expect(!comparison.canNavigateBoth(0))
    comparison.navigateBoth(0)
    #expect(comparison.first.zoom == 2 && comparison.first.pan == heldPan)
    comparison.navigateBoth(.min)
    #expect(comparison.first.index == 3 && comparison.second.index == 7)
    for _ in 0..<7 { comparison.navigateBoth(-1) }
    #expect(comparison.first.index == 0 && comparison.second.index == 0)
    #expect(!comparison.canNavigateBoth(-1))
  }

  @Test("반복 설정은 짧은 목록만 양방향으로 반복하고 긴 목록의 끝에서는 멈춘다")
  func shorterFolderLoopsInBothDirections() async throws {
    let a = try fixture(count: 5), b = try fixture(count: 9)
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    let suite = "FolderComparisonLoopTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let comparison = FolderComparisonStore(defaults: defaults, alignment: .sequence)
    comparison.endBehavior = .loop
    comparison.first.load(a); comparison.second.load(b)
    try await wait { !comparison.first.isLoading && !comparison.second.isLoading }
    for _ in 0..<5 { comparison.navigateBoth(.max) }
    #expect(comparison.first.index == 0 && comparison.second.index == 5)
    comparison.navigateBoth(.min)
    #expect(comparison.first.index == 4 && comparison.second.index == 4)
    for _ in 0..<4 { comparison.navigateBoth(1) }
    #expect(comparison.first.index == 3 && comparison.second.index == 8)
    #expect(!comparison.canNavigateBoth(1))
    comparison.navigateBoth(1)
    #expect(comparison.first.index == 3 && comparison.second.index == 8)
    for _ in 0..<8 { comparison.navigateBoth(-1) }
    #expect(comparison.first.index == 0 && comparison.second.index == 0)
    #expect(!comparison.canNavigateBoth(-1))

    // 목록이 더 긴 칸이 A인 경우에도 동일하게 작동합니다.
    comparison.first.load(b); comparison.second.load(a)
    try await wait { !comparison.first.isLoading && !comparison.second.isLoading }
    for _ in 0..<8 { comparison.navigateBoth(1) }
    #expect(comparison.first.index == 8 && comparison.second.index == 3)
    #expect(!comparison.canNavigateBoth(1))
  }

  @Test("동수 목록은 함께 끝에서 멈추고 한 장뿐인 반복 목록은 화면을 유지한다")
  func equalCountsAndSingleImageLoop() async throws {
    let a = try fixture(count: 3), b = try fixture(count: 1)
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    let suite = "FolderComparisonEqualCountTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let comparison = FolderComparisonStore(defaults: defaults, alignment: .sequence)
    comparison.endBehavior = .loop
    comparison.first.load(a); comparison.second.load(a)
    try await wait { !comparison.first.isLoading && !comparison.second.isLoading }
    comparison.navigateBoth(1); comparison.navigateBoth(1)
    #expect(comparison.first.index == 2 && comparison.second.index == 2)
    #expect(!comparison.canNavigateBoth(1))
    comparison.navigate(.second, direction: -1)
    #expect(comparison.canNavigateBoth(1))
    comparison.navigateBoth(1)
    #expect(comparison.first.index == 2 && comparison.second.index == 2)
    comparison.navigate(.first, direction: -1)
    comparison.navigateBoth(-1)
    #expect(comparison.first.index == 0 && comparison.second.index == 1)
    #expect(comparison.canNavigateBoth(-1))
    comparison.navigateBoth(-1)
    #expect(comparison.first.index == 0 && comparison.second.index == 0)
    #expect(!comparison.canNavigateBoth(-1))

    comparison.first.load(b)
    try await wait { !comparison.first.isLoading }
    comparison.updateZoom(2, on: .first)
    comparison.pan(CGSize(width: 10, height: 20), on: .first)
    comparison.navigateBoth(1); comparison.navigateBoth(1)
    #expect(comparison.first.index == 0 && comparison.second.index == 2)
    #expect(comparison.first.zoom == 2 && comparison.first.pan == CGSize(width: 10, height: 20))
  }

  @Test("빈 칸·불러오는 칸·잠긴 긴 목록은 열린 다른 목록의 이동을 막지 않는다")
  func unavailablePanesDoNotBlockNavigation() async throws {
    let a = try fixture(count: 3), b = try fixture(count: 5), empty = try fixture(count: 0)
    defer {
      try? FileManager.default.removeItem(at: a)
      try? FileManager.default.removeItem(at: b)
      try? FileManager.default.removeItem(at: empty)
    }
    let suite = "FolderComparisonAvailablePaneTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let comparison = FolderComparisonStore(defaults: defaults, alignment: .sequence)
    #expect(!comparison.canNavigateBoth(1))
    comparison.first.load(a)
    try await wait { !comparison.first.isLoading }
    comparison.navigateBoth(1)
    #expect(comparison.first.index == 1 && comparison.second.currentAsset == nil)
    comparison.second.load(b)
    #expect(comparison.second.isLoading)
    comparison.navigateBoth(1)
    #expect(comparison.first.index == 2 && comparison.second.isLoading)
    try await wait { !comparison.second.isLoading }
    comparison.second.load(empty)
    try await wait { !comparison.second.isLoading }
    comparison.navigateBoth(-1)
    #expect(comparison.first.index == 1 && comparison.second.assets.isEmpty)

    comparison.second.load(b)
    try await wait { !comparison.second.isLoading }
    comparison.jump(.second, number: 4)
    comparison.updateZoom(2, on: .second)
    comparison.pan(CGSize(width: 10, height: 20), on: .second)
    comparison.toggleLock(on: .second)
    comparison.endBehavior = .loop
    comparison.navigateBoth(1)
    #expect(comparison.first.index == 2 && comparison.second.index == 3)
    #expect(!comparison.canNavigateBoth(1))
    comparison.navigateBoth(-1); comparison.navigateBoth(-1)
    #expect(comparison.first.index == 0 && comparison.second.index == 3)
    #expect(comparison.second.zoom == 2 && comparison.second.pan == CGSize(width: 10, height: 20))
    comparison.toggleLock(on: .first)
    #expect(!comparison.canNavigateBoth(1) && !comparison.canNavigateBoth(-1))
  }

  @Test("폴더 교체·빠른 재열기·실패에서 이전 폴더 결과가 새 칸에 남지 않는다")
  func folderReplacement() async throws {
    let a = try fixture(count: 4), b = try fixture(count: 2), empty = try fixture(count: 0)
    defer {
      try? FileManager.default.removeItem(at: a)
      try? FileManager.default.removeItem(at: b)
      try? FileManager.default.removeItem(at: empty)
    }
    let pane = FolderComparisonPane()
    pane.load(a)
    try await wait { !pane.isLoading }
    pane.select(number: 4)
    pane.load(b)
    #expect(pane.assets.isEmpty && pane.index == 0)
    try await wait { !pane.isLoading }
    #expect(pane.assets.count == 2 && pane.folderURL == b)
    // Foundation은 /var와 /private/var처럼 같은 폴더의 별칭을 정규화할 수 있습니다.
    #expect(pane.assets.allSatisfy {
      $0.url.deletingLastPathComponent().resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    })
    pane.load(a); pane.load(b)
    try await wait { !pane.isLoading }
    #expect(pane.assets.count == 2 && pane.folderURL == b)
    pane.load(empty)
    try await wait { !pane.isLoading }
    #expect(pane.assets.isEmpty && pane.errorMessage == nil)
    pane.load(empty.appendingPathComponent("missing-folder"))
    try await wait { !pane.isLoading }
    #expect(pane.assets.isEmpty && pane.errorMessage != nil)
    pane.load(a); pane.cancelLoad()
    try await Task.sleep(for: .milliseconds(100))
    #expect(!pane.isLoading && pane.assets.isEmpty)
  }

  @Test("확대·팬 연결과 개별 조작, 좌우·상하 배치를 저장한다")
  func viewportAndPreferences() throws {
    let suite = "FolderComparisonViewportTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let comparison = FolderComparisonStore(defaults: defaults, alignment: .sequence)
    #expect(comparison.linksViewport && comparison.arrangement == .horizontal)
    #expect(comparison.endBehavior == .hold && comparison.showsThumbnails)
    comparison.updateZoom(2, on: .first)
    comparison.pan(CGSize(width: 30, height: 40), on: .first)
    #expect(comparison.first.zoom == 2 && comparison.second.zoom == 2)
    #expect(comparison.first.pan == comparison.second.pan)
    comparison.linksViewport = false
    comparison.updateZoom(2, on: .second)
    #expect(comparison.first.zoom == 2 && comparison.second.zoom == 4)
    comparison.gestureSide = .second
    comparison.liveMagnification = 1.5
    #expect(!comparison.showsLiveInput(on: .first) && comparison.showsLiveInput(on: .second))
    comparison.linksViewport = true
    #expect(comparison.first.zoom == 4 && comparison.showsLiveInput(on: .first))
    comparison.resetLiveInput()
    comparison.setScale(.actualPixels)
    #expect(comparison.first.scaleMode == .actualPixels && comparison.second.zoom == 1)
    comparison.arrangement = .vertical
    comparison.linksViewport = false
    comparison.endBehavior = .loop
    comparison.showsThumbnails = false
    let restored = FolderComparisonStore(defaults: defaults, alignment: .sequence)
    #expect(restored.arrangement == .vertical && !restored.linksViewport)
    #expect(restored.endBehavior == .loop && !restored.showsThumbnails)
    #expect(restored.first.assets.isEmpty && restored.second.assets.isEmpty)
    defaults.set("unknown", forKey: "ImageViewer.ComparisonEndBehavior.v1")
    #expect(FolderComparisonStore(defaults: defaults, alignment: .sequence).endBehavior == .hold)
  }

  @Test("한쪽 잠금은 이미지·확대·위치를 유지하고 다른 쪽만 조작한다")
  func paneLockKeepsReferenceImage() async throws {
    let a = try fixture(count: 3), b = try fixture(count: 4)
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    let suite = "FolderComparisonLockTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let comparison = FolderComparisonStore(defaults: defaults, alignment: .sequence)
    comparison.first.load(a); comparison.second.load(b)
    try await wait { !comparison.first.isLoading && !comparison.second.isLoading }
    comparison.navigate(.first, direction: 1)
    comparison.updateZoom(2, on: .first)
    comparison.pan(CGSize(width: 30, height: 40), on: .first)
    let referenceAsset = comparison.first.currentAsset
    let referencePan = comparison.first.pan
    comparison.toggleLock(on: .first)
    #expect(comparison.first.isLocked && comparison.activeSide == .second)
    #expect(!comparison.first.canStep(1))
    comparison.navigate(.first, direction: 1)
    comparison.jump(.first, number: 3)
    comparison.first.load(b)
    comparison.updateZoom(2, on: .first)
    comparison.pan(CGSize(width: 90, height: 90), on: .first)
    comparison.updateLiveMagnification(3, on: .first)
    comparison.updateLiveTranslation(CGSize(width: 50, height: 50), on: .first)
    #expect(comparison.gestureSide == nil)
    #expect(comparison.first.currentAsset == referenceAsset && comparison.first.folderURL == a)
    #expect(comparison.first.zoom == 2 && comparison.first.pan == referencePan)

    #expect(comparison.canNavigateBoth(1))
    comparison.navigateBoth(1)
    #expect(comparison.second.index == 1 && comparison.first.currentAsset == referenceAsset)
    comparison.updateZoom(3, on: .second)
    comparison.pan(CGSize(width: 100, height: 100), on: .second)
    comparison.updateLiveMagnification(1.5, on: .second)
    #expect(comparison.showsLiveInput(on: .second) && !comparison.showsLiveInput(on: .first))
    #expect(comparison.effectiveZoom(on: .first) == 2 && comparison.effectivePan(on: .first) == referencePan)
    comparison.resetLiveInput()
    comparison.setScale(.actualPixels)
    #expect(comparison.first.scaleMode == .fit && comparison.first.pan == referencePan)
    comparison.linksViewport = false; comparison.linksViewport = true
    #expect(comparison.first.zoom == 2 && comparison.first.pan == referencePan)

    comparison.toggleLock(on: .second)
    #expect(!comparison.canNavigateBoth(1))
    comparison.setScale(.fit)
    #expect(comparison.second.scaleMode == .actualPixels)
    comparison.toggleLock(on: .first)
    #expect(comparison.activeSide == .first)
    #expect(comparison.first.currentAsset == referenceAsset && comparison.first.pan == referencePan)
    comparison.navigate(.first, direction: 1)
    #expect(comparison.first.index == 2 && comparison.second.index == 1)
  }

  @Test("이미지 크기·종횡비·창 크기가 달라도 같은 상대 좌표를 확대한다")
  func linkedImageCoordinates() throws {
    let suite = "FolderComparisonCoordinatesTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let comparison = FolderComparisonStore(defaults: defaults, alignment: .sequence)
    comparison.updateBaseImageSize(CGSize(width: 400, height: 200), on: .first)
    comparison.updateBaseImageSize(CGSize(width: 200, height: 400), on: .second)
    comparison.updateZoom(2, on: .first)
    comparison.pan(CGSize(width: 80, height: 40), on: .first)
    #expect(comparison.first.pan == CGSize(width: 80, height: 40))
    #expect(comparison.second.pan == CGSize(width: 40, height: 80))
    #expect(comparison.first.normalizedPan == comparison.second.normalizedPan)
    comparison.updateLiveMagnification(1.5, on: .first)
    #expect(comparison.effectivePan(on: .first) == CGSize(width: 120, height: 60))
    #expect(comparison.effectivePan(on: .second) == CGSize(width: 60, height: 120))
    comparison.updateZoom(1.5, on: .first)
    comparison.resetLiveInput()
    #expect(comparison.first.pan == CGSize(width: 120, height: 60))
    #expect(comparison.second.pan == CGSize(width: 60, height: 120))

    comparison.updateBaseImageSize(CGSize(width: 100, height: 600), on: .second)
    #expect(comparison.second.pan == CGSize(width: 30, height: 180))
    comparison.updateLiveTranslation(CGSize(width: 120, height: 60), on: .first)
    #expect(comparison.effectivePan(on: .first) == CGSize(width: 240, height: 120))
    #expect(comparison.effectivePan(on: .second) == CGSize(width: 60, height: 360))
    comparison.pan(CGSize(width: 120, height: 60), on: .first)
    comparison.resetLiveInput()
    #expect(comparison.second.pan == CGSize(width: 60, height: 360))

    comparison.setScale(.actualPixels)
    comparison.updateBaseImageSize(CGSize(width: 2000, height: 1000), on: .first)
    comparison.updateBaseImageSize(CGSize(width: 1000, height: 2000), on: .second)
    comparison.pan(CGSize(width: 200, height: 100), on: .first)
    #expect(comparison.second.pan == CGSize(width: 100, height: 200))
    comparison.linksViewport = false
    comparison.pan(CGSize(width: 20, height: 30), on: .second)
    #expect(comparison.first.pan == CGSize(width: 200, height: 100))
    #expect(abs(comparison.second.pan.width - 120) < 0.000_001)
    #expect(abs(comparison.second.pan.height - 230) < 0.000_001)

    // 잠금 해제 자체는 기준 화면을 바꾸지 않고, 다음 연결 제스처 시작 시
    // 소스의 배율·좌표로 맞춰 손을 뗄 때 목적지 화면이 튀지 않게 합니다.
    comparison.linksViewport = true
    comparison.toggleLock(on: .first)
    let lockedPan = comparison.first.pan
    comparison.updateZoom(2, on: .second)
    comparison.pan(CGSize(width: 100, height: 200), on: .second)
    comparison.toggleLock(on: .first)
    #expect(comparison.first.zoom == 1 && comparison.first.pan == lockedPan)
    comparison.updateLiveMagnification(1.5, on: .second)
    #expect(comparison.first.zoom == comparison.second.zoom)
    #expect(comparison.first.normalizedPan == comparison.second.normalizedPan)
    #expect(comparison.effectiveZoom(on: .first) == 3)
    let liveFirstPan = comparison.effectivePan(on: .first)
    let liveSecondPan = comparison.effectivePan(on: .second)
    comparison.updateZoom(1.5, on: .second)
    comparison.resetLiveInput()
    #expect(comparison.first.pan == liveFirstPan && comparison.second.pan == liveSecondPan)
  }

  @Test("비교 트랙패드 이동은 일반 뷰어 설정과 무관하며 잠긴 칸을 바꾸지 않는다")
  func comparisonTrackpadInput() throws {
    let suite = "FolderComparisonTrackpadTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let comparison = FolderComparisonStore(defaults: defaults, alignment: .sequence)
    comparison.updateZoom(2)
    let delta = CGSize(width: 30, height: 40)
    #expect(comparison.handlePointerPan(.trackpadScroll, delta: delta, on: .first,
      preferredMode: .primaryDrag))
    #expect(comparison.first.pan == delta && comparison.second.pan == delta)
    comparison.toggleLock(on: .first)
    #expect(comparison.handlePointerPan(.trackpadScroll, delta: delta, on: .first,
      preferredMode: .secondaryDrag))
    #expect(comparison.handlePointerPan(.secondaryDrag, delta: delta, on: .first,
      preferredMode: .secondaryDrag))
    #expect(comparison.first.pan == delta && comparison.second.pan == delta)
    #expect(comparison.handlePointerPan(.trackpadScroll, delta: delta, on: .second,
      preferredMode: .spacePrimaryDrag))
    #expect(comparison.first.pan == delta && comparison.second.pan == CGSize(width: 60, height: 80))
    #expect(!comparison.handlePointerPan(.middleDrag, delta: delta, on: .second,
      preferredMode: .primaryDrag))
    comparison.updateLiveMagnification(100, on: .second)
    #expect(comparison.effectiveZoom(on: .second) == 16)
    comparison.updateZoom(100, on: .second)
    comparison.resetLiveInput()
    #expect(comparison.second.zoom == 16)
    #expect(comparison.first.zoom == 2)
  }

  @Test("비교 진입·복귀는 일반 폴더와 위치를 보존하고 비교 단축키만 대상 칸을 바꾼다")
  func appRouting() async throws {
    let a = try fixture(count: 4), b = try fixture(count: 6)
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    let suite = "FolderComparisonRoutingTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    // This routing regression exercises the retained independent sequence mode.
    store.folderComparison.alignment = .sequence
    store.open(urls: [a])
    try await wait { !store.isLoading }
    store.select(index: 2)
    let original = store.currentAsset
    store.presentationMode = .overview
    store.toggleFolderComparison()
    store.folderComparison.first.load(a); store.folderComparison.second.load(b)
    try await wait { !store.folderComparison.first.isLoading && !store.folderComparison.second.isLoading }
    #expect(store.presentationMode == .folderComparison && !store.canStartSlideshow && !store.canSetWallpaper)
    store.perform(.nextFirstFolder)
    #expect(store.folderComparison.first.index == 1 && store.folderComparison.second.index == 0)
    store.perform(.nextPage)
    #expect(store.folderComparison.first.index == 2 && store.folderComparison.second.index == 1)
    store.perform(.nextSecondFolder)
    #expect(store.folderComparison.first.index == 2 && store.folderComparison.second.index == 2)
    #expect(store.currentAsset == original && store.currentIndex == 2)
    #expect(store.handleEscapeKey())
    #expect(store.presentationMode == .overview && store.currentAsset == original)
    store.perform(.nextFirstFolder)
    #expect(store.folderComparison.first.index == 2)
  }

  @Test("10개 언어와 충돌 없는 개별 탐색 단축키를 제공한다")
  func localizationAndShortcuts() {
    let keys = [
      "이미지 비교",
      "이미지 비교 전환",
      "이미지 비교 시작",
      "A · 왼쪽/위",
      "B · 오른쪽/아래",
      "A · 왼쪽",
      "A · 위",
      "B · 오른쪽",
      "B · 아래",
      "이 폴더에 같은 이름의 사진이 없습니다.",
      "폴더는 그대로 열려 있습니다. 파일명과 관계없이 보려면 목록 순서로 전환하세요.",
      "목록 순서로 비교",
      "양쪽 폴더를 목록 순서대로 비교합니다. 각 칸의 사진을 따로 고를 수 있습니다.",
      "좌우 배치",
      "상하 배치",
      "%@ 폴더 열기",
      "비교할 폴더 선택",
      "비교할 폴더 선택…",
      "비교할 폴더를 정확히 두 개 선택해 주세요.",
      "A 폴더만 이전 이미지",
      "A 폴더만 다음 이미지",
      "B 폴더만 이전 이미지",
      "B 폴더만 다음 이미지",
      "양쪽 이전 이미지",
      "양쪽 다음 이미지",
      "양쪽 이동: %@ / %@",
      "이미지가 많은 쪽의 끝까지 이동합니다. 적은 쪽은 마지막 이미지를 유지하거나 반복합니다.",
      "마지막 이미지 유지",
      "처음부터 반복",
      "썸네일 표시",
      "비교 화면 배치",
      "확대·이동 함께",
      "이미지 비교 종료 (Esc)",
      "폴더를 선택하세요",
      "이미지 번호",
      "이동",
      "잠금",
      "잠김",
      "잠금 해제",
      "이 칸의 이미지와 확대·이동 위치를 고정합니다.",
      "이전 비교 이미지",
      "다음 비교 이미지",
      "이미지 이동: %@ / %@",
      "같은 위치를 함께 확대·이동합니다. 잠긴 칸은 유지합니다.",
      "두 손가락으로 이동 · 핀치로 확대 · 한쪽을 잠그면 다른 쪽만 조작",
      "양쪽이 열려 있으면 함께 이동하고, 한쪽을 잠그면 다른 쪽만 이동합니다.",
      "A와 B에 이미지나 폴더를 열어 비교하세요.",
    ]
    for locale in L10n.supportedLocalizations {
      let available = L10n.keys(localeIdentifier: locale)
      let missing = keys.filter { !available.contains($0) }
      #expect(missing.isEmpty, "Missing comparison translations in \(locale)")
    }
    #expect(ShortcutAction.previousPage.defaultBinding == KeyBinding(key: "left"))
    #expect(ShortcutAction.nextFirstFolder.defaultBinding == KeyBinding(key: "right", modifiers: [.option]))
    #expect(ShortcutAction.nextSecondFolder.defaultBinding == KeyBinding(key: "right", modifiers: [.option, .shift]))
    #expect(Set(ShortcutAction.allCases.map(\.defaultBinding)).count == ShortcutAction.allCases.count)
  }

  private func wait(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
  }

  private func fixture(count: Int) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("compare-test-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let data = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
      0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    for i in 0..<count { try data.write(to: folder.appendingPathComponent("photo\(i + 1).qoi")) }
    return folder
  }
}
