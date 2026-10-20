import AppKit
import SwiftUI
import Testing

@testable import ImageViewer

@Suite("몽땅보기 Command·Shift 선택", .serialized)
@MainActor
struct OverviewModifierSelectionTests {
  @Test("Shift의 기준점은 해제 뒤에도 고정되고 Command+Shift는 기존 선택에 범위를 더한다")
  func rangeAnchorAndAdditiveRanges() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.store
    try await fixture.open()
    let urls = store.assets.map(\.url)
    store.select(index: 1)
    store.clearSelection()
    #expect(store.selectOverviewCard(url: urls[3], modifiers: .shift))
    #expect(store.selectedURLs == Set(urls[1...3]))
    #expect(store.selectOverviewCard(url: urls[2], modifiers: .shift))
    #expect(store.selectedURLs == Set(urls[1...2]))
    #expect(store.selectOverviewCard(url: urls[0], modifiers: .shift))
    #expect(store.selectedURLs == Set(urls[0...1]))

    store.selectOverviewCard(url: urls[3], modifiers: .command)
    #expect(store.selectedURLs == [urls[0], urls[1], urls[3]])
    store.selectOverviewCard(url: urls[2], modifiers: [.command, .shift])
    #expect(store.selectedURLs == Set(urls))
    store.selectOverviewCard(url: urls[0], modifiers: .command)
    #expect(store.selectedURLs == Set(urls[1...3]))
    store.selectOverviewCard(url: urls[1], modifiers: [])
    #expect(store.selectedURLs == [urls[1]])
  }

  @Test("정렬·필터 변경 중 또는 사라진 카드의 지연 클릭이 다른 파일을 고르지 않는다")
  func clicksResolveIdentityAndCurrentOrder() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.store
    try await fixture.open()
    let original = store.assets.map(\.url)
    store.libraryQuery.sort = .nameDescending
    #expect(!store.selectOverviewCard(url: original[1], modifiers: .command))
    try await fixture.ready()
    store.selectOverviewCard(url: original[2], modifiers: [])
    store.selectOverviewCard(url: original[0], modifiers: .shift)
    #expect(store.selectedAssets.map(\.url) == [original[2], original[1], original[0]])
    store.libraryQuery.searchText = "photo4"
    try await fixture.ready()
    let previous = store.selectedURLs
    #expect(!store.selectOverviewCard(url: original[1], modifiers: .shift))
    #expect(store.selectedURLs == previous)
    store.selectOverviewCard(url: original[3], modifiers: .shift)
    #expect(store.selectedURLs == [original[3]])
  }

  @Test("실제 SwiftUI 카드와 체크상자가 이벤트의 Command·Shift 조합을 받아 다중 선택한다",
    arguments: [false, true])
  func hostedCardReceivesModifierClicks(checkbox: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await fixture.open()
    let store = fixture.store
    let urls = store.assets.map(\.url)
    store.isPhotoMarking = checkbox
    store.thumbnailSize = 100
    store.showsOverviewNumbers = false
    _ = NSApplication.shared
    // Host the complete grid so its simultaneous marquee gesture and scroll
    // handling take part in the same event arbitration as the installed app.
    let host = NSHostingView(rootView: OverviewView(store: store))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 620, height: 440),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    try await settle(host)

    func point(_ index: Int) -> CGPoint {
      // In this fixed 620pt fixture, the grid contains four 137pt cards with
      // 12pt gaps and 18pt outer padding. XCTest does not vend SwiftUI's AX
      // tree for offscreen windows, so use the rendered control geometry.
      let x = CGFloat(index) * 149 + (checkbox ? 37 : 86.5)
      return CGPoint(x: x, y: checkbox ? 296 : 340)
    }

    // Global keyboard flags stay empty; the gesture must retain the flags of
    // the actual click, including after the user's modifier has been released.
    try await click(window, at: point(2), modifiers: .command)
    #expect(store.selectedURLs == [urls[0], urls[2]])
    try await click(window, at: point(0), modifiers: [.command, .shift])
    #expect(store.selectedURLs == Set(urls[0...2]))
    try await click(window, at: point(3), modifiers: .shift)
    #expect(store.selectedURLs == Set(urls[2...3]))
    try await click(window, at: point(2), modifiers: .command)
    #expect(store.selectedURLs == [urls[3]])
    try await click(window, at: point(1), modifiers: [])
    #expect(store.selectedURLs == (checkbox ? [urls[1], urls[3]] : [urls[1]]))
    #expect(store.presentationMode == .overview)

    if !checkbox {
      try await doubleClick(window, at: point(2), modifiers: .command)
      #expect(store.presentationMode == .overview)
      try await doubleClick(window, at: point(2), modifiers: [])
      #expect(store.presentationMode == .viewer)
      #expect(store.currentAsset?.url == urls[2])
    }
  }

  private func doubleClick(_ window: NSWindow, at point: CGPoint,
    modifiers: NSEvent.ModifierFlags) async throws {
    for count in 1...2 {
      for (offset, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
        let event = try #require(NSEvent.mouseEvent(with: type, location: point,
          modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime + Double(offset) * 0.01,
          windowNumber: window.windowNumber, context: nil, eventNumber: count * 2 + offset,
          clickCount: count, pressure: type == .leftMouseDown ? 1 : 0))
        window.sendEvent(event)
      }
      try await Task.sleep(for: .milliseconds(40))
    }
    try await Task.sleep(for: .milliseconds(650))
    window.contentView?.layoutSubtreeIfNeeded()
  }

  @Test("실제 첫 영역 드래그가 첫 프레임 계산 전 끝나거나 다음 드래그로 반복돼도 선택을 확정한다",
    arguments: [false, true])
  func hostedMarqueeCollectsGeometryOnlyWhenNeeded(fastMouseUp: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await fixture.open()
    let store = fixture.store
    let urls = store.assets.map(\.url)
    store.thumbnailSize = 100
    store.showsOverviewNumbers = false
    _ = NSApplication.shared
    let host = NSHostingView(rootView: OverviewView(store: store))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 620, height: 440),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    try await settle(host)

    for _ in 0..<2 {
      store.clearSelection()
      try await settle(host)
      let points: [(NSEvent.EventType, CGPoint)] = [
        (.leftMouseDown, CGPoint(x: 5, y: 425)),
        (.leftMouseDragged, CGPoint(x: 80, y: 375)),
        (.leftMouseDragged, CGPoint(x: 290, y: 285)),
        (.leftMouseUp, CGPoint(x: 290, y: 285)),
      ]
      for (index, entry) in points.enumerated() {
        let event = try #require(NSEvent.mouseEvent(with: entry.0, location: entry.1,
          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.01,
          windowNumber: window.windowNumber, context: nil, eventNumber: index + 1,
          clickCount: 1, pressure: entry.0 == .leftMouseUp ? 0 : 1))
        window.sendEvent(event)
        if !fastMouseUp { try await settle(host) }
      }
      try await settle(host)
      #expect(store.selectedURLs == Set(urls[0...1]))
      #expect(store.overviewSelectionSession == nil)
      #expect(store.presentationMode == .overview)
    }
  }

  private func click(_ window: NSWindow, at point: CGPoint, modifiers: NSEvent.ModifierFlags) async throws {
    for (offset, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
      let event = try #require(NSEvent.mouseEvent(with: type, location: point,
        modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime + Double(offset) * 0.01,
        windowNumber: window.windowNumber, context: nil, eventNumber: offset + 1,
        clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
      window.sendEvent(event)
    }
    try await Task.sleep(for: .milliseconds(650))
    window.contentView?.layoutSubtreeIfNeeded()
  }

  private func settle(_ host: NSView) async throws {
    for _ in 0..<4 {
      try await Task.sleep(for: .milliseconds(50))
      host.layoutSubtreeIfNeeded()
    }
  }

  @MainActor private struct Fixture {
    let folder: URL
    let suite = "OverviewModifierSelectionTests.\(UUID())"
    let defaults: UserDefaults
    let store: AppStore

    init() throws {
      folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
      defaults = try #require(UserDefaults(suiteName: suite))
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let png = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII="))
      for number in 1...4 { try png.write(to: folder.appendingPathComponent("photo\(number).png")) }
      store = AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: folder.appendingPathComponent("marks.sqlite"))
    }

    func open() async throws {
      store.open(urls: [folder])
      try await ready()
      store.presentationMode = .overview
      try #require(store.assets.count == 4)
    }

    func ready() async throws {
      let deadline = ContinuousClock.now + .seconds(8)
      while store.isLoading || store.isFiltering {
        try #require(ContinuousClock.now < deadline)
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    func cleanup() {
      store.folderComparison.cancelLoads()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }
  }
}
