import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import Testing

@testable import ImageViewer

@Suite("썸네일 사이드바의 창 가림과 선택 복귀", .serialized)
@MainActor
struct SidebarWindowVisibilityTests {
  @MainActor private struct Fixture {
    let suite: String
    let defaults: UserDefaults
    let directory: URL
    let folder: URL
    let disk: ThumbnailDiskCache
    let store: AppStore

    init(count: Int) throws {
      suite = "SidebarWindowVisibility.\(UUID())"
      defaults = try #require(UserDefaults(suiteName: suite))
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
      folder = directory.appendingPathComponent("photos", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let context = try #require(CGContext(data: nil, width: 512, height: 384,
        bitsPerComponent: 8, bytesPerRow: 512 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 512, height: 384))
      let image = try #require(context.makeImage())
      let data = NSMutableData()
      let output = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
      CGImageDestinationAddImage(output, image, nil)
      #expect(CGImageDestinationFinalize(output))
      for index in 0..<count {
        let name = String(format: "photo-%04d", index) + (index.isMultiple(of: 5) ? "-picked" : "")
        try (data as Data).write(to: folder.appendingPathComponent(name).appendingPathExtension("png"))
      }
      disk = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
      store = AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: directory.appendingPathComponent("marks.sqlite"), thumbnailDiskCache: disk)
    }

    func cleanup() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private func open(_ fixture: Fixture, count: Int) async throws {
    fixture.store.openFolderFromTree(fixture.folder)
    try await wait {
      !fixture.store.isLoading && !fixture.store.isFiltering && fixture.store.assets.count == count
    }
    fixture.store.returnToOverview()
    // Finish the normal selected-file metadata request before checking that the
    // hosted sidebar itself admits no thumbnail jobs while covered.
    try await wait {
      let state = await fixture.store.loadingGovernor.stateSnapshot()
      return fixture.store.currentMetadata != nil && state.runningCount == 0 && state.queuedCount == 0
    }
  }

  private func window<Content: View>(_ content: Content, width: CGFloat = 340)
    -> (NSHostingView<Content>, NSWindow) {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: content)
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: width, height: 360),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    return (host, window)
  }

  private func close(_ window: NSWindow) {
    window.orderOut(nil)
    window.contentView = nil
    window.close()
  }

  private func descendants<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
    (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants(type, in: $0) }
  }

  private func wait(host: NSView? = nil, until condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while ContinuousClock.now < deadline {
      host?.layoutSubtreeIfNeeded()
      host?.displayIfNeeded()
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(await condition())
  }

  private func settle(_ host: NSView, passes: Int = 6) async throws {
    for _ in 0..<passes {
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  @Test("가려진 패널은 첫 원본 작업을 시작하지 않고 일부 노출 뒤 기존 품질과 선택을 재개한다",
    arguments: [ThumbnailPanelPlacement.left, .top])
  func hostedSidebarDefersSourcesAndResumesWhenExposed(placement: ThumbnailPanelPlacement) async throws {
    let fixture = try Fixture(count: 4)
    defer { fixture.cleanup() }
    try await open(fixture, count: 4)
    // Drive visibility deterministically; the separate native-bridge test below
    // checks actual NSWindow attachment and notification delivery.
    let gate = OverviewRefinementGate()
    gate.windowVisibilityChanged(isApplicationActive: false, isWindowVisible: false)
    var events: [ThumbnailBitmapStateEvent] = []
    let (host, nativeWindow) = window(SidebarView(store: fixture.store, placement: placement,
      visibilityGate: gate, observesNativeWindowVisibility: false,
      onBitmapStateApplied: { events.append($0) }), width: placement.isHorizontal ? 620 : 340)
    defer { close(nativeWindow); gate.stop() }
    try await settle(host)
    #expect(gate.isWindowSuppressed)
    #expect(events.isEmpty)
    #expect(await fixture.disk.snapshot().entryCount == 0)
    #expect(await fixture.disk.snapshot().misses == 0)
    #expect(await fixture.store.thumbnailPipeline.cacheSnapshot().entryCount == 0)
    #expect(await fixture.store.loadingGovernor.stateSnapshot().runningCount == 0)
    #expect(descendants(OverviewScrollMotionView.self, in: host).isEmpty)

    gate.windowVisibilityChanged(isApplicationActive: false, isWindowVisible: true)
    try await wait(host: host) { !events.isEmpty }
    #expect(events.allSatisfy { $0.pixelWidth == 256 && $0.pixelHeight == 192 })
    let first = fixture.store.assets[0].url
    let second = fixture.store.assets[1].url
    fixture.store.selectForBatch(index: 1, modifiers: .command)
    #expect(fixture.store.selectedURLs == [first, second])
    #expect(fixture.store.currentAsset?.url == second)
    try await settle(host)
    let misses = await fixture.disk.snapshot().misses
    gate.windowVisibilityChanged(isApplicationActive: false, isWindowVisible: false)
    try await settle(host, passes: 2)
    gate.windowVisibilityChanged(isApplicationActive: false, isWindowVisible: true)
    try await settle(host)
    #expect(await fixture.disk.snapshot().misses == misses)
    #expect(fixture.store.selectedURLs == [first, second])
  }

  @Test("패널 하나의 native observer는 자기 창의 가림 상태만 연결한다")
  func nativeSidebarObserverAttachesOnceToItsWindow() async throws {
    let fixture = try Fixture(count: 1)
    defer { fixture.cleanup() }
    try await open(fixture, count: 1)
    let gate = OverviewRefinementGate()
    let (host, nativeWindow) = window(SidebarView(store: fixture.store, placement: .left,
      visibilityGate: gate))
    defer { close(nativeWindow); gate.stop() }
    try await settle(host, passes: 2)
    let observers = descendants(OverviewScrollMotionView.self, in: host)
    #expect(observers.count == 1)
    let observer = try #require(observers.first)
    #expect(observer.window === nativeWindow)
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: nativeWindow)
    #expect(gate.isWindowSuppressed == (!NSApp.isActive && !nativeWindow.occlusionState.contains(.visible)))
    observer.stopObservingWindowVisibility()
    gate.windowVisibilityChanged(isApplicationActive: false, isWindowVisible: true)
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: nativeWindow)
    #expect(!gate.isWindowSuppressed)
  }

  @Test("첫 파일이 같은 필터 적용·해제도 선택한 사진의 실제 스크롤 위치를 복원한다")
  func sameFirstFilterRestoreRevealsRetainedSelection() async throws {
    let fixture = try Fixture(count: 40)
    defer { fixture.cleanup() }
    try await open(fixture, count: 40)
    let gate = OverviewRefinementGate()
    gate.windowVisibilityChanged(isApplicationActive: false, isWindowVisible: true)
    let (host, nativeWindow) = window(SidebarView(store: fixture.store, placement: .left,
      visibilityGate: gate, observesNativeWindowVisibility: false))
    defer { close(nativeWindow); gate.stop() }
    try await wait(host: host) { !self.descendants(NSScrollView.self, in: host).isEmpty }
    let scroll = try #require(descendants(NSScrollView.self, in: host).first)
    try await settle(host)
    fixture.store.selectForBatch(index: 35, modifiers: [])
    try await wait(host: host) { scroll.contentView.bounds.origin.y > 1_000 }
    try await settle(host)
    let selected = try #require(fixture.store.currentAsset?.url)
    let first = fixture.store.assets.first?.url
    fixture.store.libraryQuery.searchText = "*picked*"
    try await wait(host: host) {
      !fixture.store.isFiltering && fixture.store.assets.count == 8 && fixture.store.currentIndex == 7
    }
    try await settle(host)
    #expect(fixture.store.assets.first?.url == first)
    #expect(fixture.store.currentAsset?.url == selected)
    #expect(fixture.store.selectedURLs == [selected])
    fixture.store.libraryQuery.searchText = ""
    try await wait(host: host) {
      !fixture.store.isFiltering && fixture.store.assets.count == 40 && fixture.store.currentIndex == 35
        && scroll.contentView.bounds.origin.y > 1_000
    }
    #expect(fixture.store.currentAsset?.url == selected)
    #expect(fixture.store.selectedURLs == [selected])
  }
}
