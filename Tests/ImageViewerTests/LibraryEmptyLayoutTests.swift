import AppKit
import SwiftUI
import Testing

@testable import ImageViewer

/// Hosts RootView rather than reconstructing its stacks: the regression was
/// caused by how the empty result's intrinsic height propagated to its parent.
@Suite("검색 결과가 없을 때 실제 라이브러리 화면 배치", .serialized)
@MainActor
struct LibraryEmptyLayoutTests {
  @Test("분류 필터를 비웠다가 복원해도 검색 도구가 화면 위에 남는다",
    arguments: [ImageViewer.PresentationMode.viewer, .overview], [false, true])
  func filterTransitionsKeepSearchAtTop(mode: ImageViewer.PresentationMode, marking: Bool) async throws {
    let fixture = try Fixture()
    let store = fixture.store
    defer { fixture.cleanup() }
    await store.photoMarks.waitUntilReady()
    try #require(store.photoMarks.isReady)
    store.open(urls: [fixture.photos])
    try await ready(store)
    try #require(store.assets.count == 2)
    store.presentationMode = mode
    store.showsFolderTree = false
    store.thumbnailPanelPlacement = .hidden
    store.isPhotoMarking = marking

    _ = NSApplication.shared
    let host = NSHostingView(rootView: RootView(store: store,
      shortcuts: ShortcutStore(defaults: fixture.defaults)))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 1_100, height: 800),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    let populatedTop = try await settledSearchTop(in: host)
    #expect(populatedTop < 60, "Populated library search controls should be at the top")

    store.photoMarkFilter = PhotoMarkFilter(slots: [.one])
    try await ready(store)
    try #require(store.assets.isEmpty && store.allAssets.count == 2)
    #expect(store.isPhotoMarking == marking)
    let emptyTop = try await settledSearchTop(in: host)
    #expect(abs(emptyTop - populatedTop) <= 1,
      "Empty result moved the search field from \(populatedTop) to \(emptyTop) points below the top")
    #expect(emptyTop < 60, "An empty result must occupy the workspace below the controls")

    store.resetLibraryQuery()
    try await ready(store)
    try #require(store.assets.count == 2)
    let restoredTop = try await settledSearchTop(in: host)
    #expect(abs(restoredTop - populatedTop) <= 1)

    store.openFolderFromTree(fixture.emptyFolder)
    try await ready(store)
    try #require(store.assets.isEmpty && store.allAssets.isEmpty && store.currentFolderURL != nil)
    let emptyFolderTop = try await settledSearchTop(in: host)
    #expect(abs(emptyFolderTop - populatedTop) <= 1,
      "The empty-folder and empty-filter branches must leave controls in the same place")
  }

  @Test("영상 숨김으로 비어 있는 폴더도 검색 도구를 위에 유지하며 표시 전환으로 복구된다",
    arguments: [ImageViewer.PresentationMode.viewer, .overview], [false, true])
  func hiddenVideoOnlyFolderKeepsSearchAtTop(mode: ImageViewer.PresentationMode, marking: Bool) async throws {
    let fixture = try Fixture()
    let store = fixture.store
    defer { fixture.cleanup() }
    await store.photoMarks.waitUntilReady()
    store.showsVideos = false
    store.open(urls: [fixture.photos])
    try await ready(store)
    try #require(store.assets.count == 2)
    store.presentationMode = mode
    store.showsFolderTree = false
    store.thumbnailPanelPlacement = .hidden
    store.isPhotoMarking = marking

    _ = NSApplication.shared
    let host = NSHostingView(rootView: RootView(store: store,
      shortcuts: ShortcutStore(defaults: fixture.defaults)))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 1_100, height: 800),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    let populatedTop = try await settledSearchTop(in: host)
    #expect(populatedTop < 60)

    store.openFolderFromTree(fixture.videoFolder)
    try await ready(store)
    try #require(store.assets.isEmpty && store.allAssets.count == 2)
    try #require(store.allAssets.allSatisfy(\.isVideo) && !store.showsHome)
    #expect(store.alert == nil && store.presentationMode == mode && store.isPhotoMarking == marking)
    let hiddenTop = try await settledSearchTop(in: host)
    #expect(abs(hiddenTop - populatedTop) <= 1,
      "Hiding every video must fill the workspace below the fixed search controls")

    store.showsVideos = true
    try await ready(store)
    try #require(store.assets.count == 2 && store.assets.allSatisfy(\.isVideo))
    let visibleTop = try await settledSearchTop(in: host)
    #expect(abs(visibleTop - populatedTop) <= 1)

    store.showsVideos = false
    store.resetLibraryQuery()
    try await ready(store)
    #expect(store.assets.isEmpty && store.allAssets.count == 2 && !store.showsVideos)
    let hiddenAgainTop = try await settledSearchTop(in: host)
    #expect(abs(hiddenAgainTop - populatedTop) <= 1)
    #expect(store.allAssets.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
  }

  private func settledSearchTop(in host: NSView) async throws -> CGFloat {
    var previous: CGFloat?
    var stableSamples = 0
    for _ in 0..<100 {
      try await Task.sleep(for: .milliseconds(20))
      host.layoutSubtreeIfNeeded()
      guard let search = searchField(in: host) else { continue }
      let rect = host.convert(search.bounds, from: search)
      let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
      if let previous, abs(previous - top) < 0.01 {
        stableSamples += 1
        if stableSamples >= 4 { return top }
      } else { stableSamples = 0 }
      previous = top
    }
    throw LayoutFailure.searchFieldDidNotSettle
  }

  private func searchField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable,
      field.placeholderString == "파일 이름 검색"
        || field.placeholderString == L10n.text("파일 이름 검색") { return field }
    return view.subviews.lazy.compactMap { searchField(in: $0) }.first
  }

  private func ready(_ store: AppStore) async throws {
    for _ in 0..<500 {
      if !store.isLoading && !store.isFiltering && !store.isIndexingLocations { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw LayoutFailure.loadingTimedOut
  }

  private enum LayoutFailure: Error { case loadingTimedOut, searchFieldDidNotSettle }

  @MainActor private struct Fixture {
    let root: URL
    let photos: URL
    let emptyFolder: URL
    let videoFolder: URL
    let suite: String
    let defaults: UserDefaults
    let store: AppStore

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryEmptyLayout-\(UUID())")
      photos = root.appendingPathComponent("Photos", isDirectory: true)
      emptyFolder = root.appendingPathComponent("Empty", isDirectory: true)
      videoFolder = root.appendingPathComponent("Videos", isDirectory: true)
      suite = "LibraryEmptyLayout.\(UUID())"
      defaults = try #require(UserDefaults(suiteName: suite))
      try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: videoFolder, withIntermediateDirectories: true)
      // Admission and layout only; native playback has separate valid-media tests.
      for filename in ["clip-01.mp4", "clip-02.mov"] {
        try Data("Synthetic video layout fixture".utf8).write(to: videoFolder.appendingPathComponent(filename))
      }
      let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 256, bitsPerPixel: 32))
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      for filename in ["photo-01.png", "photo-02.png"] { try png.write(to: photos.appendingPathComponent(filename)) }
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
