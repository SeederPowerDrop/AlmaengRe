import AppKit
import Testing

@testable import ImageViewer

@Suite("비교 방향키 대상 선택")
@MainActor
struct ComparisonNavigationTargetTests {
  @Test("A와 B 선택은 지정한 칸만 넘기며 개별 단축키는 그대로 동작한다")
  func independentTargets() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults)
    try await load(comparison, fixture: fixture)
    comparison.navigationTarget = .first
    comparison.navigateSelection(1)
    #expect(comparison.first.index == 1 && comparison.second.index == 0)
    comparison.navigateSelection(1)
    #expect(comparison.first.index == 2 && comparison.second.index == 0)
    #expect(!comparison.canNavigateSelection(1))
    comparison.endBehavior = .loop
    comparison.navigateSelection(1)
    #expect(comparison.first.index == 2 && comparison.second.index == 0)
    comparison.navigationTarget = .second
    comparison.navigateSelection(1)
    #expect(comparison.first.index == 2 && comparison.second.index == 1)
    comparison.navigate(.first, direction: -1)
    #expect(comparison.first.index == 1 && comparison.second.index == 1)
    #expect(comparison.navigationTarget == .second)
    comparison.navigateSelection(-1)
    #expect(comparison.first.index == 1 && comparison.second.index == 0)
    #expect(!comparison.canNavigateSelection(-1))
    #expect(!comparison.canNavigateSelection(0))
    comparison.navigateSelection(0)
    #expect(comparison.first.index == 1 && comparison.second.index == 0)
  }

  @Test("양쪽 선택은 짧은 목록 유지와 반복 설정을 적용한다", arguments: ComparisonEndBehavior.allCases)
  func bothTargetsUseEndBehavior(_ behavior: ComparisonEndBehavior) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults)
    try await load(comparison, fixture: fixture)
    comparison.navigationTarget = .both
    comparison.endBehavior = behavior
    for _ in 0..<3 { comparison.navigateSelection(1) }
    #expect(comparison.first.index == (behavior == .hold ? 2 : 0))
    #expect(comparison.second.index == 3)
    comparison.navigateSelection(-1)
    #expect(comparison.first.index == (behavior == .hold ? 1 : 2))
    #expect(comparison.second.index == 2)
    for _ in 0..<2 { comparison.navigateSelection(1) }
    #expect(comparison.second.index == 4)
    #expect(!comparison.canNavigateSelection(1))
    let shorterIndex = comparison.first.index
    comparison.navigateSelection(1)
    #expect(comparison.first.index == shorterIndex && comparison.second.index == 4)
  }

  @Test("대상 설정은 다음 실행에도 유지하고 알 수 없는 값은 양쪽을 사용한다")
  func targetPersistence() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults)
    #expect(comparison.navigationTarget == .both)
    for target in ComparisonNavigationTarget.allCases {
      comparison.navigationTarget = target
      #expect(FolderComparisonStore(defaults: fixture.defaults).navigationTarget == target)
    }
    fixture.defaults.set("unknown", forKey: "ImageViewer.ComparisonNavigationTarget.v1")
    #expect(FolderComparisonStore(defaults: fixture.defaults).navigationTarget == .both)
  }

  @Test("파일명 비교에서 A 또는 B를 직접 선택하면 독립 탐색으로 전환한다", arguments: [ComparisonNavigationTarget.first, .second])
  func explicitTargetLeavesFilenameAlignment(_ target: ComparisonNavigationTarget) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults, alignment: .filename)
    try await load(comparison, fixture: fixture)
    comparison.navigationTarget = target
    #expect(comparison.alignment == .sequence && !comparison.isMatching)
    comparison.navigateSelection(1)
    #expect(comparison.first.index == (target == .first ? 1 : 0))
    #expect(comparison.second.index == (target == .second ? 1 : 0))
    comparison.alignment = .filename
    #expect(comparison.navigationTarget == .both)
    try await ready(comparison)
    let restored = FolderComparisonStore(defaults: fixture.defaults)
    #expect(restored.alignment == .filename && restored.navigationTarget == .both)
  }

  @Test("잠금은 넘기기 대상을 남은 칸으로 바꾸고 모두 해제하면 양쪽으로 돌아온다")
  func locksSynchronizeTarget() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults)
    try await load(comparison, fixture: fixture)
    comparison.toggleLock(on: .second)
    #expect(comparison.navigationTarget == .first)
    comparison.navigationTarget = .second
    #expect(comparison.navigationTarget == .first)
    comparison.navigateSelection(1)
    #expect(comparison.first.index == 1 && comparison.second.index == 0)
    comparison.toggleLock(on: .first)
    #expect(!comparison.canNavigateSelection(1) && !comparison.canNavigateSelection(-1))
    comparison.navigateSelection(1)
    #expect(comparison.first.index == 1 && comparison.second.index == 0)
    comparison.toggleLock(on: .second)
    #expect(comparison.navigationTarget == .second)
    comparison.navigateSelection(1)
    #expect(comparison.first.index == 1 && comparison.second.index == 1)
    comparison.toggleLock(on: .first)
    #expect(comparison.navigationTarget == .both)
    comparison.navigateSelection(1)
    #expect(comparison.first.index == 2 && comparison.second.index == 2)
  }

  @Test("잠금에 따른 자동 대상 변경은 파일명 비교와 잠긴 사진을 유지한다", arguments: FolderComparisonSide.allCases)
  func filenameLockKeepsAlignment(_ lockedSide: FolderComparisonSide) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults, alignment: .filename)
    try await load(comparison, fixture: fixture)
    comparison.toggleLock(on: lockedSide)
    #expect(comparison.navigationTarget == (lockedSide == .first ? .second : .first))
    #expect(comparison.alignment == .filename)
    let lockedAsset = comparison.pane(lockedSide).currentAsset
    comparison.navigateSelection(1)
    #expect(comparison.pane(lockedSide).currentAsset == lockedAsset)
    #expect(comparison.pane(lockedSide == .first ? .second : .first).index == 1)
    comparison.toggleLock(on: lockedSide)
    #expect(comparison.navigationTarget == .both && comparison.alignment == .filename)
    #expect(comparison.first.index == 1 && comparison.second.index == 1)
  }

  @Test("불러오기와 필터 중에는 선택한 칸을 넘기지 않는다")
  func pendingChangesBlockNavigation() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults)
    comparison.navigationTarget = .first
    comparison.first.load(fixture.a)
    #expect(comparison.first.isLoading && !comparison.canNavigateSelection(1))
    comparison.navigateSelection(1)
    try await ready(comparison)
    #expect(comparison.first.index == 0)
    comparison.first.query = LibraryQuery(sort: .nameDescending)
    #expect(comparison.first.isFiltering && !comparison.canNavigateSelection(1))
    comparison.navigateSelection(1)
    comparison.navigationTarget = .both
    #expect(!comparison.canNavigateSelection(1))
    try await ready(comparison)
    #expect(comparison.first.currentAsset?.filename == "001.png")
  }

  @Test("세션 복원은 잠금 대상을 맞추고 잠금이 없으면 수동 대상을 유지한다")
  func restoreReconcilesLocks() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults)
    try await load(comparison, fixture: fixture)
    comparison.navigationTarget = .second
    let unlockedSession = try portableSession(comparison)
    let unlocked = FolderComparisonStore(defaults: fixture.defaults)
    await unlocked.restoreSession(unlockedSession)
    #expect(unlocked.alert == nil && unlocked.navigationTarget == .second)
    comparison.alignment = .filename
    try await ready(comparison)
    comparison.toggleLock(on: .first)
    comparison.navigateSelection(1)
    let lockedSession = try portableSession(comparison)
    let locked = FolderComparisonStore(defaults: fixture.defaults)
    await locked.restoreSession(lockedSession)
    #expect(locked.alert == nil && locked.navigationTarget == .second)
    #expect(locked.alignment == .filename && locked.first.isLocked)
    #expect(locked.first.index == 0 && locked.second.index == 1)
    locked.navigateSelection(1)
    #expect(locked.first.index == 0 && locked.second.index == 2)
  }

  @Test("앱의 방향키와 이전·다음 명령은 대상 선택을 따르고 개별 명령은 독립적이다")
  func appRoutesPageNavigation() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = AppStore(defaults: fixture.defaults, monitorsSystemResources: false)
    store.presentationMode = .folderComparison
    let comparison = store.folderComparison
    try await load(comparison, fixture: fixture)
    await store.resumeWorkspace()
    try #require(!store.showsHome)
    comparison.navigationTarget = .first
    store.navigatePage(1)
    #expect(comparison.first.index == 1 && comparison.second.index == 0)
    comparison.navigationTarget = .second
    store.perform(.nextPage)
    #expect(comparison.first.index == 1 && comparison.second.index == 1)
    store.perform(.previousFirstFolder)
    #expect(comparison.first.index == 0 && comparison.second.index == 1)
    #expect(comparison.navigationTarget == .second)
    comparison.navigationTarget = .both
    store.perform(.nextPage)
    #expect(comparison.first.index == 1 && comparison.second.index == 2)
    comparison.toggleLock(on: .second)
    store.perform(.previousPage)
    #expect(comparison.first.index == 0 && comparison.second.index == 2)
  }

  @Test("분류 중 방향키는 이동 대상과 잠금을 따르며 분류는 별도로 선택한 사진에 붙인다")
  func markingArrowsRespectTargetAndLocks() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = AppStore(defaults: fixture.defaults, monitorsSystemResources: false)
    await store.photoMarks.waitUntilReady()
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.presentationMode = .folderComparison
    let comparison = store.folderComparison
    try await load(comparison, fixture: fixture)
    await store.resumeWorkspace()
    try #require(!store.showsHome)
    store.togglePhotoMarking()
    #expect(store.isPhotoMarking)

    comparison.navigationTarget = .first
    comparison.activeSide = .second
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    #expect(comparison.first.index == 1 && comparison.second.index == 0)
    comparison.navigationTarget = .second
    comparison.activeSide = .first
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
    #expect(comparison.first.index == 1 && comparison.second.index == 1)
    comparison.navigationTarget = .both
    #expect(store.handleViewerKeyDown(try key(123), shortcuts: shortcuts))
    #expect(comparison.first.index == 0 && comparison.second.index == 0)

    comparison.toggleLock(on: .second)
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    #expect(comparison.first.index == 1 && comparison.second.index == 0)
    comparison.toggleLock(on: .first)
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    #expect(comparison.first.index == 1 && comparison.second.index == 0)
    comparison.toggleLock(on: .first)
    #expect(store.handleViewerKeyDown(try key(126), shortcuts: shortcuts))
    #expect(comparison.first.index == 0 && comparison.second.index == 0)
    comparison.toggleLock(on: .second)

    comparison.navigationTarget = .first
    comparison.activeSide = .second
    comparison.photoMarkTarget = .second
    let firstAsset = try #require(comparison.first.currentAsset)
    let secondAsset = try #require(comparison.second.currentAsset)
    #expect(store.handleViewerKeyDown(try key(18), shortcuts: shortcuts))
    #expect(store.photoMarks.marks(for: firstAsset).isEmpty)
    #expect(store.photoMarks.marks(for: secondAsset) == [.one])

    // An unrelated active pane must not block the selected navigation target.
    comparison.second.query = LibraryQuery(sort: .nameDescending)
    #expect(comparison.second.isFiltering && !store.canMarkPhoto)
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    #expect(comparison.first.index == 1 && comparison.second.index == 0)
    try await ready(comparison)
    comparison.activeSide = .second
    comparison.second.load(fixture.b)
    #expect(comparison.second.isLoading)
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    #expect(comparison.first.index == 2)
    try await ready(comparison)
  }

  private func key(_ code: UInt16) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, characters: "",
      charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
  }

  private func load(_ comparison: FolderComparisonStore, fixture: Fixture) async throws {
    comparison.first.load(fixture.a)
    comparison.second.load(fixture.b)
    try await ready(comparison)
    #expect(comparison.first.assets.count == 3 && comparison.second.assets.count == 5)
  }

  private func ready(_ comparison: FolderComparisonStore) async throws {
    for _ in 0..<300 {
      if !comparison.first.isLoading && !comparison.second.isLoading
        && !comparison.first.isFiltering && !comparison.second.isFiltering && !comparison.isMatching { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.loadingTimedOut
  }

  private func portableSession(_ comparison: FolderComparisonStore) throws -> ComparisonSession {
    var session = try #require(comparison.captureSession())
    session.first.sources = session.first.sources.map { var source = $0; source.bookmark = nil; return source }
    session.second.sources = session.second.sources.map { var source = $0; source.bookmark = nil; return source }
    return session
  }

  private enum FixtureError: Error { case loadingTimedOut }

  private struct Fixture {
    let root: URL
    let a: URL
    let b: URL
    let suite: String
    let defaults: UserDefaults

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("ComparisonTarget-\(UUID())")
      a = root.appendingPathComponent("A")
      b = root.appendingPathComponent("B")
      suite = "ComparisonTarget.\(UUID())"
      defaults = UserDefaults(suiteName: suite)!
      try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
      let image = bitmap.representation(using: .png, properties: [:])!
      for index in 1...5 {
        let name = String(format: "%03d.png", index)
        if index <= 3 { try image.write(to: a.appendingPathComponent(name)) }
        try image.write(to: b.appendingPathComponent(name))
      }
    }

    func cleanup() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
