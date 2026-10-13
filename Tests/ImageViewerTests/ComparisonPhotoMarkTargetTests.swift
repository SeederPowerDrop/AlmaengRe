import AppKit
import Testing

@testable import ImageViewer

@Suite("이미지 비교의 독립 분류 대상")
@MainActor
struct ComparisonPhotoMarkTargetTests {
  @Test("A만·B만 분류는 활성 칸과 이동 대상에 영향받지 않는다",
    arguments: [ComparisonPhotoMarkTarget.first, .second])
  func explicitTargetIsIndependent(_ target: ComparisonPhotoMarkTarget) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await open(fixture)
    let store = fixture.store, comparison = store.folderComparison
    #expect(comparison.photoMarkTarget == .first)
    let first = try #require(comparison.first.currentAsset)
    let second = try #require(comparison.second.currentAsset)
    try #require(first.filename == second.filename && first.photoMarkID != second.photoMarkID)
    comparison.photoMarkTarget = target
    comparison.activeSide = target == .first ? .second : .first
    comparison.navigationTarget = target == .first ? .second : .first
    let state = BrowsingState(comparison)
    store.togglePhotoMarking()
    try #require(store.canMarkPhoto)

    store.togglePhotoMark(.q)
    let expected = target == .first ? first : second
    let other = target == .first ? second : first
    #expect(store.photoMarkAssets.map(\.photoMarkID) == [expected.photoMarkID])
    #expect(store.photoMarks.marks(for: expected) == [.q])
    #expect(store.photoMarks.marks(for: other).isEmpty)
    #expect(store.photoMarkSelectionState(for: .q) == .all)
    #expect(BrowsingState(comparison) == state)
    #expect(try Data(contentsOf: expected.url) == fixture.png)
    #expect(try Data(contentsOf: other.url) == fixture.png)
  }

  @Test("양쪽의 혼합 표시는 모두 추가하고 다시 누르면 모두 해제한다")
  func mixedSelectionConvergesWithoutRetargeting() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await open(fixture)
    let store = fixture.store, comparison = store.folderComparison
    let first = try #require(comparison.first.currentAsset)
    let second = try #require(comparison.second.currentAsset)
    store.photoMarks.toggle(.one, for: first)
    store.photoMarks.toggle(.w, for: first)
    store.photoMarks.toggle(.w, for: second)
    comparison.photoMarkTarget = .both
    comparison.activeSide = .second
    comparison.navigationTarget = .first
    let state = BrowsingState(comparison)
    store.togglePhotoMarking()

    #expect(store.photoMarkSelectionState(for: .one) == .mixed)
    #expect(store.photoMarkSelectionState(for: .w) == .all)
    #expect(store.photoMarkSelectionState(for: .f) == .none)
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, characters: "1",
      charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18))
    #expect(store.handleViewerKeyDown(key, shortcuts: ShortcutStore(defaults: fixture.defaults)))
    #expect(store.photoMarkSelectionState(for: .one) == .all)
    #expect(store.photoMarks.marks(for: first) == [.one, .w])
    #expect(store.photoMarks.marks(for: second) == [.one, .w])
    store.togglePhotoMark(.one)
    #expect(store.photoMarkSelectionState(for: .one) == .none)
    #expect(store.photoMarks.marks(for: first) == [.w])
    #expect(store.photoMarks.marks(for: second) == [.w])
    #expect(BrowsingState(comparison) == state)
  }

  @Test("같은 사진을 양쪽에 열어도 한 번만 변경하며 양쪽 표시 준비를 확인한다")
  func identicalPhotoIsMarkedOnceAfterBothPanesAreReady() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await open(fixture, sameFolder: true)
    let store = fixture.store, comparison = store.folderComparison
    let first = try #require(comparison.first.currentAsset)
    let second = try #require(comparison.second.currentAsset)
    try #require(first.photoMarkID == second.photoMarkID)
    comparison.photoMarkTarget = .both
    comparison.first.beginTrackingPresentation()
    comparison.second.beginTrackingPresentation()
    comparison.first.recordPresentedAsset(first)
    store.togglePhotoMarking()
    #expect(store.photoMarkAssets.count == 1)
    #expect(!store.canMarkPhoto)
    store.togglePhotoMark(.a)
    #expect(store.photoMarks.marks(for: first).isEmpty)

    comparison.second.recordPresentedAsset(second)
    try #require(store.canMarkPhoto)
    store.togglePhotoMark(.a)
    #expect(store.photoMarks.marks(for: first) == [.a])
    #expect(store.photoMarkSelectionState(for: .a) == .all)
    store.togglePhotoMark(.a)
    #expect(store.photoMarks.marks(for: first).isEmpty)
    #expect(store.photoMarkSelectionState(for: .a) == .none)
  }

  @Test("한쪽이 이전 프리뷰를 유지하면 양쪽 분류를 부분 적용하지 않는다")
  func bothRequiresEveryRequestedImagePresentation() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await open(fixture)
    let store = fixture.store, comparison = store.folderComparison
    let first = try #require(comparison.first.currentAsset)
    let previous = try #require(comparison.second.currentAsset)
    comparison.photoMarkTarget = .both
    comparison.first.beginTrackingPresentation()
    comparison.second.beginTrackingPresentation()
    comparison.first.recordPresentedAsset(first)
    comparison.second.recordPresentedAsset(previous)
    store.togglePhotoMarking()
    try #require(store.canMarkPhoto)
    comparison.navigate(.second, direction: 1)
    let requested = try #require(comparison.second.currentAsset)
    try #require(requested.id != previous.id)
    let wrongSize = ImageAsset(url: requested.url, byteCount: (requested.byteCount ?? 0) + 1,
      modificationDate: requested.modificationDate, photoMarkIdentity: requested.photoMarkIdentity)
    let wrongDate = ImageAsset(url: requested.url, byteCount: requested.byteCount,
      modificationDate: (requested.modificationDate ?? .distantPast).addingTimeInterval(-1),
      photoMarkIdentity: requested.photoMarkIdentity)

    for presented in [nil, previous, wrongSize, wrongDate] as [ImageAsset?] {
      comparison.second.recordPresentedAsset(presented)
      #expect(!store.canMarkPhoto)
      store.togglePhotoMark(.e)
      #expect(store.photoMarks.marks(for: first).isEmpty)
      #expect(store.photoMarks.marks(for: previous).isEmpty)
      #expect(store.photoMarks.marks(for: requested).isEmpty)
    }
    comparison.second.recordPresentedAsset(requested)
    try #require(store.canMarkPhoto)
    store.togglePhotoMark(.e)
    #expect(store.photoMarks.marks(for: first) == [.e])
    #expect(store.photoMarks.marks(for: requested) == [.e])
    #expect(store.photoMarks.marks(for: previous).isEmpty)
    store.togglePhotoMarking()
    #expect(!store.canMarkPhoto)
    store.togglePhotoMark(.e)
    #expect(store.photoMarks.marks(for: first) == [.e])
    #expect(store.photoMarks.marks(for: requested) == [.e])
  }

  @Test("양쪽은 빈칸·검색 중에 멈추지만 A만은 B의 준비 상태와 독립적이다")
  func emptyAndFilteringPaneCannotCausePartialChanges() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await open(fixture)
    let store = fixture.store, comparison = store.folderComparison
    let first = try #require(comparison.first.currentAsset)
    let second = try #require(comparison.second.currentAsset)
    comparison.photoMarkTarget = .both
    store.togglePhotoMarking()
    comparison.second.query.searchText = "no-matching-image"
    try #require(comparison.second.isFiltering)
    #expect(!store.canMarkPhoto)
    store.togglePhotoMark(.r)
    #expect(store.photoMarks.marks(for: first).isEmpty)
    #expect(store.photoMarks.marks(for: second).isEmpty)
    try await ready(comparison)
    try #require(comparison.second.currentAsset == nil)
    #expect(!store.canMarkPhoto)
    store.togglePhotoMark(.r)
    #expect(store.photoMarks.marks(for: first).isEmpty)

    comparison.photoMarkTarget = .first
    comparison.second.query.searchText = ""
    try #require(comparison.second.isFiltering)
    try #require(store.canMarkPhoto)
    store.togglePhotoMark(.r)
    #expect(store.photoMarks.marks(for: first) == [.r])
    try await ready(comparison)
    #expect(store.photoMarks.marks(for: second).isEmpty)
  }

  @Test("같은 파일명 비교의 대응 사진 없는 행은 양쪽 분류를 하지 않는다")
  func missingMatchedCounterpartBlocksBothOnly() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await open(fixture)
    let store = fixture.store, comparison = store.folderComparison
    comparison.first.query.searchText = "02"
    comparison.alignment = .filename
    try await ready(comparison)
    comparison.jump(.second, number: 1)
    try #require(comparison.first.showsMissingCounterpart)
    let second = try #require(comparison.second.currentAsset)
    comparison.photoMarkTarget = .both
    store.togglePhotoMarking()
    #expect(!store.canMarkPhoto)
    store.togglePhotoMark(.s)
    #expect(store.photoMarks.marks(for: second).isEmpty)
    comparison.photoMarkTarget = .second
    try #require(store.canMarkPhoto)
    store.togglePhotoMark(.s)
    #expect(store.photoMarks.marks(for: second) == [.s])
    #expect(comparison.first.showsMissingCounterpart)
    #expect(comparison.alignment == .filename)
  }

  @Test("잠금은 분류 대상을 바꾸지 않고 고정된 사진과 화면 위치를 유지한다")
  func lockedPhotosRemainExplicitClassificationTargets() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await open(fixture)
    let store = fixture.store, comparison = store.folderComparison
    comparison.linksViewport = false
    comparison.updateZoom(2, on: .first)
    comparison.pan(CGSize(width: 0.2, height: -0.1), on: .first)
    comparison.updateZoom(3, on: .second)
    comparison.pan(CGSize(width: -0.3, height: 0.2), on: .second)
    comparison.photoMarkTarget = .both
    comparison.toggleLock(on: .first)
    comparison.toggleLock(on: .second)
    let first = try #require(comparison.first.currentAsset)
    let second = try #require(comparison.second.currentAsset)
    let state = BrowsingState(comparison)
    try #require(comparison.first.isLocked && comparison.second.isLocked)
    #expect(comparison.photoMarkTarget == .both)
    store.togglePhotoMarking()
    try #require(store.canMarkPhoto)
    store.togglePhotoMark(.d)
    #expect(store.photoMarks.marks(for: first) == [.d])
    #expect(store.photoMarks.marks(for: second) == [.d])
    #expect(BrowsingState(comparison) == state)
    #expect(comparison.first.isLocked && comparison.second.isLocked)
  }

  @Test("양쪽 분류도 켜진 동안 목록과 선택을 유지하고 끄면 필터를 갱신한다")
  func bothTargetKeepsFilteredMembershipUntilModeEnds() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await open(fixture)
    let store = fixture.store, comparison = store.folderComparison
    comparison.first.photoMarkFilter = PhotoMarkFilter(unmarkedOnly: true)
    comparison.second.photoMarkFilter = PhotoMarkFilter(unmarkedOnly: true)
    try await ready(comparison)
    let first = try #require(comparison.first.currentAsset)
    let second = try #require(comparison.second.currentAsset)
    let firstIDs = Set(comparison.first.assets.map(\.photoMarkID))
    let secondIDs = Set(comparison.second.assets.map(\.photoMarkID))
    comparison.photoMarkTarget = .both
    store.togglePhotoMarking()
    store.togglePhotoMark(.f)
    // A real query exercises frozen membership after both mutation notifications.
    comparison.query.sort = .nameDescending
    try await ready(comparison)
    #expect(Set(comparison.first.assets.map(\.photoMarkID)) == firstIDs)
    #expect(Set(comparison.second.assets.map(\.photoMarkID)) == secondIDs)
    #expect(comparison.first.currentAsset?.id == first.id)
    #expect(comparison.second.currentAsset?.id == second.id)
    store.togglePhotoMarking()
    try await ready(comparison)
    #expect(Set(comparison.first.assets.map(\.photoMarkID)) == firstIDs.subtracting([first.photoMarkID]))
    #expect(Set(comparison.second.assets.map(\.photoMarkID)) == secondIDs.subtracting([second.photoMarkID]))
    #expect(store.photoMarks.marks(for: first) == [.f])
    #expect(store.photoMarks.marks(for: second) == [.f])
  }

  private func open(_ fixture: Fixture, sameFolder: Bool = false) async throws {
    let store = fixture.store
    await store.photoMarks.waitUntilReady()
    try #require(store.photoMarks.isReady)
    store.open(urls: [fixture.firstFolder])
    let deadline = ContinuousClock.now + .seconds(8)
    while store.isLoading || store.isFiltering {
      guard ContinuousClock.now < deadline else { throw FixtureError.loadingTimedOut }
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!store.showsHome && store.alert == nil && store.assets.count == 3)
    store.presentationMode = .folderComparison
    let comparison = store.folderComparison
    comparison.alignment = .sequence
    comparison.open(urls: [fixture.firstFolder], for: .first)
    comparison.open(urls: [sameFolder ? fixture.firstFolder : fixture.secondFolder], for: .second)
    try await ready(comparison)
    try #require(comparison.first.assets.count == 3 && comparison.second.assets.count == 3)
  }

  private func ready(_ comparison: FolderComparisonStore) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while comparison.first.isLoading || comparison.second.isLoading
      || comparison.first.isFiltering || comparison.second.isFiltering || comparison.isMatching {
      guard ContinuousClock.now < deadline else { throw FixtureError.loadingTimedOut }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private enum FixtureError: Error { case loadingTimedOut }

  private struct BrowsingState: Equatable {
    let firstIndex: Int
    let secondIndex: Int
    let activeSide: FolderComparisonSide
    let navigationTarget: ComparisonNavigationTarget
    let firstZoom: CGFloat
    let secondZoom: CGFloat
    let firstPan: CGSize
    let secondPan: CGSize

    @MainActor init(_ comparison: FolderComparisonStore) {
      firstIndex = comparison.first.index
      secondIndex = comparison.second.index
      activeSide = comparison.activeSide
      navigationTarget = comparison.navigationTarget
      firstZoom = comparison.first.zoom
      secondZoom = comparison.second.zoom
      firstPan = comparison.first.normalizedPan
      secondPan = comparison.second.normalizedPan
    }
  }

  @MainActor private struct Fixture {
    let root: URL
    let firstFolder: URL
    let secondFolder: URL
    let suite: String
    let defaults: UserDefaults
    let png: Data
    let store: AppStore

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("ComparisonPhotoMarkTargets-\(UUID())")
      firstFolder = root.appendingPathComponent("A", isDirectory: true)
      secondFolder = root.appendingPathComponent("B", isDirectory: true)
      suite = "ComparisonPhotoMarkTargets.\(UUID())"
      defaults = try #require(UserDefaults(suiteName: suite))
      png = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII="))
      for folder in [firstFolder, secondFolder] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["01.png", "02.png", "03.png"] { try png.write(to: folder.appendingPathComponent(name)) }
      }
      store = AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: root.appendingPathComponent("marks.sqlite"))
    }

    func cleanup() {
      store.folderComparison.cancelLoads()
      store.saveSessionNow()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
