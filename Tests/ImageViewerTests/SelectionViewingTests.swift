import AppKit
import SwiftUI
import Testing
@testable import ImageViewer

@Suite("선택한 파일만 단일·다중보기", .serialized)
@MainActor
struct SelectionViewingTests {
  @Test("비연속 선택을 원래 순서로 탐색하고 원래 선택·초점·배치를 복원한다", arguments: [false, true])
  func navigationAndReturn(together: Bool) async throws {
    let f = try Fixture(count: 16)
    defer { f.remove() }
    let store = f.store()
    try await open(store, f)
    let original = store.assets
    store.setImagesPerPage(4)
    store.selectForBatch(index: 1, modifiers: [])
    store.selectForBatch(index: 5, modifiers: .command)
    store.selectForBatch(index: 14, modifiers: .command)
    let selected = store.selectedURLs
    store.viewSelectedFiles(together: together)
    #expect(store.presentationMode == .viewer)
    #expect(store.assets == [original[1], original[5], original[14]])
    #expect(store.allAssets == original)
    #expect(store.imagesPerPage == (together ? 3 : 1))
    let focused = try #require(store.currentAsset)
    #expect(store.visibleAssets.contains(focused))
    store.setImagesPerPage(2)
    for direction in [1, 1, -1, -1, 1] {
      store.navigatePage(direction)
      #expect(store.visibleAssets.allSatisfy { selected.contains($0.url) })
      let currentURL = try #require(store.currentAsset?.url)
      #expect(selected.contains(currentURL))
    }
    store.returnToOverview()
    #expect(store.selectionViewingContext == nil)
    #expect(store.assets == original)
    #expect(store.selectedURLs == selected)
    #expect(store.currentAsset == original[14])
    #expect(store.imagesPerPage == 4)
  }

  @Test("10개 초과 선택과 선택 해제·작업 중 진입을 처리한다")
  func guardsAndLargeSelection() async throws {
    let f = try Fixture(count: 16)
    defer { f.remove() }
    let store = f.store()
    try await open(store, f)
    store.clearSelection()
    #expect(!store.canViewSelectedFiles)
    store.viewSelectedFiles()
    #expect(store.presentationMode == .overview)
    store.selectAllAssets()
    store.batchSheet = .rename
    #expect(!store.canViewSelectedFiles)
    store.viewSelectedFiles()
    #expect(store.selectionViewingContext == nil)
    store.batchSheet = nil
    store.viewSelectedFiles(together: true)
    #expect(store.assets.count == 16 && store.imagesPerPage == 10)
    #expect(store.visibleAssets.count == 10 && store.currentIndex == 0)
  }

  @Test("범위 내 검색·정렬·분류 필터를 바꿔도 선택하지 않은 파일이 섞이지 않는다")
  func queryWithinSelection() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let store = f.store()
    try await open(store, f)
    let original = store.assets
    store.selectForBatch(index: 0, modifiers: [])
    store.selectForBatch(index: 2, modifiers: .command)
    store.photoMarks.set(.q, enabled: true, for: [original[0], original[1]])
    try await ready(store)
    store.viewSelectedFiles()
    store.libraryQuery.sort = .nameDescending
    try await ready(store)
    #expect(store.assets.map(\.url) == [original[2].url, original[0].url])
    store.photoMarkFilter = PhotoMarkFilter(slots: [.q])
    try await ready(store)
    #expect(store.assets.map(\.url) == [original[0].url])
    store.photoMarkFilter = PhotoMarkFilter()
    store.libraryQuery.searchText = "photo2"
    try await ready(store)
    #expect(store.assets.isEmpty)
    #expect(store.selectionViewingContext != nil)
    store.resetLibraryQuery()
    try await ready(store)
    #expect(store.assets.map(\.url) == [original[0].url, original[2].url])
    store.libraryQuery.searchText = "photo2"
    try await ready(store)
    store.returnToOverview()
    #expect(store.assets.map(\.url) == [original[1].url])
    #expect(store.libraryQuery.searchText == "photo2")
    #expect(store.allAssets.count == 4)
  }

  @Test("세션 재개와 이전 버전 세션을 호환하고 다른 폴더를 열면 임시 범위를 해제한다")
  func sessionAndNewSource() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let store = f.store()
    try await open(store, f)
    let original = store.assets
    store.selectForBatch(index: 1, modifiers: [])
    store.selectForBatch(index: 3, modifiers: .command)
    let selected = store.selectedURLs
    store.viewSelectedFiles()
    store.navigatePage(-1)
    store.saveSessionNow()
    let restored = f.store()
    await restored.restoreLastSession()
    try await ready(restored)
    #expect(restored.selectionViewingContext != nil)
    #expect(Set(restored.assets.map(\.sessionID)) == Set(original.filter { selected.contains($0.url) }.map(\.sessionID)))
    restored.returnToOverview()
    #expect(restored.assets.map(\.sessionID) == original.map(\.sessionID))
    #expect(Set(restored.selectedAssets.map(\.sessionID)) == Set(original.filter { selected.contains($0.url) }.map(\.sessionID)))
    restored.viewSelectedFiles()
    let other = f.root.appendingPathComponent("Other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try f.png.write(to: other.appendingPathComponent("other.png"))
    restored.open(urls: [other])
    try await ready(restored)
    restored.returnToOverview()
    #expect(restored.selectionViewingContext == nil)
    #expect(restored.assets.map(\.filename) == ["other.png"])

    let saved = try #require(ViewerSessionPersistence(defaults: f.defaults).loadSession())
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
    legacy.removeValue(forKey: "selectionViewing")
    let decoded = try JSONDecoder().decode(ViewerSession.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.selectionViewing == nil)
  }

  @Test("범위 내 이름 변경·휴지통 처리가 복귀 목록에도 반영된다")
  func fileMutations() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let store = f.store()
    try await open(store, f)
    let original = store.assets
    store.selectForBatch(index: 0, modifiers: [])
    store.selectForBatch(index: 2, modifiers: .command)
    store.viewSelectedFiles(together: true)
    var options = BatchRenameOptions()
    options.prefix = "picked-"
    let plan = BatchRenamePlanner.plan(urls: store.selectedAssets.map(\.url), options: options)
    try #require(plan.canApply)
    try await store.renameSelectedFiles(using: plan)
    try await ready(store)
    #expect(store.assets.count == 2)
    #expect(store.assets.allSatisfy { $0.filename.hasPrefix("picked-") })
    store.select(index: 0)
    let deleted = try #require(store.currentAsset)
    store.presentFileOperation(.trash)
    let request = try #require(store.fileOperationRequest)
    let trashPlan = try BatchFileOperationPlanner.plan(assets: request.assets, operation: .trash)
    let result = await store.performFileOperation(trashPlan)
    #expect(result.failures.isEmpty && result.completed.count == 1)
    store.batchSheet = nil
    store.returnToOverview()
    #expect(store.assets.count == 3)
    #expect(!store.assets.contains { $0.url == deleted.url })
    #expect(store.assets.contains { $0.url == original[1].url })
    #expect(store.assets.contains { $0.url == original[3].url })
    #expect(store.selectedAssets.count == 1 && store.selectedAssets[0].filename.hasPrefix("picked-"))
  }

  @Test("필터로 숨긴 선택 항목도 재실행 후 필터를 해제하면 원래 범위로 돌아온다")
  func restoredFilteredScopeRetainsHiddenMembers() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let store = f.store()
    try await open(store, f)
    store.selectForBatch(index: 0, modifiers: [])
    store.selectForBatch(index: 2, modifiers: .command)
    let chosen = Set(store.selectedAssets.map(\.sessionID))
    store.viewSelectedFiles()
    store.libraryQuery.searchText = "photo3"
    try await ready(store)
    store.saveSessionNow()
    let restored = f.store()
    await restored.restoreLastSession()
    try await ready(restored)
    #expect(restored.assets.count == 1)
    restored.resetLibraryQuery()
    try await ready(restored)
    #expect(Set(restored.assets.map(\.sessionID)) == chosen)
    #expect(restored.allAssets.count == 4)
  }

  @Test("선택 전체·일부·해제 상태와 빌드 118 세션을 중복 저장 없이 복원한다",
    arguments: ["same", "partial", "cleared", "legacy"])
  func compactSelectionSession(state: String) async throws {
    let f = try Fixture()
    defer { f.remove() }
    let store = f.store()
    try await open(store, f)
    store.selectAllAssets()
    let originalIDs = Set(store.assets.map(\.sessionID))
    store.viewSelectedFiles(together: true)
    if state == "partial" { store.select(index: 1) }
    if state == "cleared" { store.clearSelection() }
    let expected = Set(store.selectedAssets.map(\.sessionID))
    store.saveSessionNow()
    let session = try #require(ViewerSessionPersistence(defaults: f.defaults).loadSession())
    #expect(session.selectionUsesViewingScope == (state == "same" || state == "legacy" ? true : nil))
    if state == "same" { #expect(session.selectedIDs.isEmpty) }
    if state == "legacy" {
      var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
      fields.removeValue(forKey: "selectionUsesViewingScope")
      fields["selectedIDs"] = Array(originalIDs)
      var scope = try #require(fields["selectionViewing"] as? [String: Any])
      scope["overviewSelectedIDs"] = Array(originalIDs)
      fields["selectionViewing"] = scope
      f.defaults.set(try JSONSerialization.data(withJSONObject: fields), forKey: ViewerSessionPersistence.sessionKey)
    }
    let restored = f.store()
    await restored.restoreLastSession()
    try await ready(restored)
    #expect(Set(restored.selectedAssets.map(\.sessionID)) == expected)
    restored.returnToOverview()
    #expect(Set(restored.selectedAssets.map(\.sessionID)) == originalIDs)
  }

  @Test("복귀 스크롤을 클립 뷰에 한 번만 적용하고 현재 문서 크기로 제한한다")
  func scrollRestoration() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let store = f.store()
    try await open(store, f)
    store.rememberOverviewScrollOrigin(CGPoint(x: 0, y: 1234))
    store.viewSelectedFiles()
    store.returnToOverview()
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 3000))
    #expect(store.restoreOverviewScrollPosition(in: scroll))
    #expect(abs(scroll.contentView.bounds.origin.y - 1234) < 1)
    #expect(!store.restoreOverviewScrollPosition(in: scroll))
    store.rememberOverviewScrollOrigin(CGPoint(x: 0, y: 9000))
    store.viewSelectedFiles()
    store.returnToOverview()
    #expect(store.restoreOverviewScrollPosition(in: scroll))
    #expect(scroll.contentView.bounds.maxY <= 3000)
  }

  private func open(_ store: AppStore, _ fixture: Fixture) async throws {
    store.open(urls: [fixture.photos])
    try await ready(store)
    store.returnToOverview()
  }

  private struct TestWorkspace: View {
    @ObservedObject var store: AppStore
    let shortcuts: ShortcutStore
    let preloader: OverviewThumbnailPreloader
    var body: some View {
      if store.presentationMode == .overview {
        OverviewView(store: store, thumbnailPreloader: preloader)
      } else {
        ViewerCanvas(store: store, shortcuts: shortcuts)
      }
    }
  }

  @Test("몽땅보기 복귀 위치는 같은 배치에서 보존되고 창·썸네일 크기가 바뀌면 현재 파일이 보인다", arguments: [false, true])
  func nativeOverviewRoundTrip(resize: Bool) async throws {
    _ = NSApplication.shared
    let f = try Fixture(count: 360)
    defer { f.remove() }
    let store = f.store()
    try await open(store, f)
    store.thumbnailSize = 120
    let preloader = OverviewThumbnailPreloader()
    let host = NSHostingView(rootView: TestWorkspace(store: store,
      shortcuts: ShortcutStore(defaults: f.defaults), preloader: preloader)
      .environment(\.locale, Locale(identifier: L10n.languageIdentifier))
      .environment(\.layoutDirection, L10n.languageIdentifier == "ar" ? .rightToLeft : .leftToRight))
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 960, height: 680),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    try await settle(host)
    store.selectForBatch(index: 180, modifiers: [])
    store.selectForBatch(index: 182, modifiers: .command)
    try await settle(host)
    let scroll = try #require(findScroll(in: host))
    let origin = CGPoint(x: 0, y: scroll.contentView.bounds.origin.y + 37)
    scroll.contentView.scroll(to: origin)
    scroll.reflectScrolledClipView(scroll.contentView)
    try await settle(host)
    let expected = scroll.contentView.bounds.origin
    #expect(expected.y > 500)
    store.viewSelectedFiles(together: true)
    #expect(abs((store.selectionViewingContext?.saved.scrollY ?? -1) - expected.y) < 1)
    try await settle(host)
    #expect(findScroll(in: host) == nil)
    if resize {
      store.thumbnailSize = 180
      window.setContentSize(NSSize(width: 660, height: 680))
    }
    store.returnToOverview()
    try await settle(host)
    let returned = try #require(findScroll(in: host))
    if resize {
      #expect(preloader.visibleIndices.contains(182), "Changed layout must reveal the restored focus")
    } else {
      #expect(abs(returned.contentView.bounds.origin.y - expected.y) < 2,
        "Native scroll return: expected \(expected.y), got \(returned.contentView.bounds.origin.y)")
    }
    #expect(store.selectedAssets.count == 2 && store.currentIndex == 182)
    if let output = ProcessInfo.processInfo.environment["IMAGEVIEWER_SELECTION_NATIVE_OUTPUT"] {
      let directory = URL(fileURLWithPath: output)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("overview-return.png"))
    }
  }

  private func findScroll(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    for child in view.subviews { if let scroll = findScroll(in: child) { return scroll } }
    return nil
  }
  private func settle(_ host: NSView) async throws {
    for _ in 0..<12 {
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
      try await Task.sleep(for: .milliseconds(50))
    }
  }
  private func ready(_ store: AppStore) async throws {
    await store.photoMarks.waitUntilReady()
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while store.isLoading || store.isFiltering || store.isRenaming {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
  }
  private struct Fixture {
    let root: URL, photos: URL, trash: URL
    let suite: String, defaults: UserDefaults
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=")!
    init(count: Int = 4) throws {
      suite = "SelectionViewingTests.\(UUID())"
      defaults = try #require(UserDefaults(suiteName: suite))
      root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
      photos = root.appendingPathComponent("Photos"); trash = root.appendingPathComponent("SyntheticTrash")
      for folder in [photos, trash] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
      for i in 1...count { try png.write(to: photos.appendingPathComponent("photo\(i).png")) }
    }
    @MainActor func store() -> AppStore {
      let destination = trash
      return AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: root.appendingPathComponent("marks.sqlite"),
        batchFileOperator: BatchFileOperator(trashFile: { source in
          let target = destination.appendingPathComponent(source.lastPathComponent)
          try BatchFileOperator.moveExclusively(source, target)
          return target
        }))
    }
    func remove() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
