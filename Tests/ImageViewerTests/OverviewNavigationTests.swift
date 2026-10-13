import AppKit
import Testing

@testable import ImageViewer

@Suite("몽땅보기 방향키 탐색")
@MainActor
struct OverviewNavigationTests {
  @Test("분류 켜짐과 관계없이 옆 카드와 행으로 이동하고 짧은 마지막 행을 처리한다", arguments: [false, true])
  func gridNavigationAndBounds(marking: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = AppStore(defaults: fixture.defaults, monitorsSystemResources: false)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.open(urls: [fixture.folder])
    try await wait(store)
    store.setImagesPerPage(7)
    store.presentationMode = .overview
    store.overviewColumnCount = 3
    store.wrapsNavigation = true
    store.isPhotoMarking = marking
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    #expect(store.currentIndex == 1)
    #expect(store.positionDescription == "2 / 10")
    #expect(store.handleViewerKeyDown(try key(126), shortcuts: shortcuts))
    #expect(store.currentIndex == 1) // No row above: do not slide sideways to the first card.
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
    #expect(store.currentIndex == 4)
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
    #expect(store.currentIndex == 7)
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
    #expect(store.currentIndex == 9) // The last row contains one card.
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
    #expect(store.currentIndex == 9) // Vertical movement never jumps back to the top.
    #expect(store.handleViewerKeyDown(try key(126), shortcuts: shortcuts))
    #expect(store.currentIndex == 6)
    #expect(store.handleViewerKeyDown(try key(123), shortcuts: shortcuts))
    #expect(store.currentIndex == 5)
    store.select(index: 9)
    #expect(store.handleViewerKeyDown(try key(124), shortcuts: shortcuts))
    #expect(store.currentIndex == 0)
    store.wrapsNavigation = false
    #expect(store.handleViewerKeyDown(try key(123), shortcuts: shortcuts))
    #expect(store.currentIndex == 0)

    store.presentationMode = .viewer
    store.navigatePage(1)
    #expect(store.pageStartIndex == 3) // Existing last-full-page rule for a seven-photo viewer.
  }

  @Test("크기 변경에 맞춰 열 수를 계산한다")
  func responsiveColumns() {
    #expect(OverviewGridNavigation.columnCount(width: 1_200, thumbnailSize: 150) == 6)
    #expect(OverviewGridNavigation.columnCount(width: 600, thumbnailSize: 150) == 3)
    #expect(OverviewGridNavigation.columnCount(width: 600, thumbnailSize: 250) == 2)
    #expect(OverviewGridNavigation.columnCount(width: 80, thumbnailSize: 250) == 1)
    #expect(OverviewGridNavigation.columnCount(width: .nan, thumbnailSize: 150) == 1)
  }

  @Test("사용자 지정 단축키와 분류 방향키를 보존하고 드래그 중 이동을 막는다")
  func respectsOtherKeyboardModes() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = AppStore(defaults: fixture.defaults, monitorsSystemResources: false)
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    store.open(urls: [fixture.folder])
    try await wait(store)
    store.presentationMode = .overview
    store.overviewColumnCount = 3
    shortcuts.setBinding(KeyBinding(key: "down"), for: .zoomIn)
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
    #expect(store.zoom > 1 && store.currentIndex == 0)
    store.isPhotoMarking = true
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
    #expect(store.currentIndex == 3) // Tagging reserves plain arrows for grid navigation.
    store.isPhotoMarking = false
    shortcuts.reset()
    let drag = try #require(store.beginOverviewSelection(modifiers: []))
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
    #expect(store.currentIndex == 3)
    store.cancelOverviewSelection(drag)
    store.overviewColumnCount = 2
    #expect(store.handleViewerKeyDown(try key(125), shortcuts: shortcuts))
    #expect(store.currentIndex == 5)
  }

  private func key(_ code: UInt16) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: code))
  }

  private func wait(_ store: AppStore) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while store.isLoading, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!store.isLoading && store.assets.count == 10)
  }

  private struct Fixture {
    let folder: URL
    let defaults: UserDefaults
    let suite = "OverviewNavigationTests-\(UUID())"

    init() throws {
      defaults = try #require(UserDefaults(suiteName: suite))
      folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let qoi = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
        0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
      for index in 1...10 { try qoi.write(to: folder.appendingPathComponent("photo\(index).qoi")) }
    }

    func remove() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }
  }
}
