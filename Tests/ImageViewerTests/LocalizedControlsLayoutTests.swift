import AppKit
import SwiftUI
import Testing

@testable import ImageViewer

/// Runs once per language in a fresh process, so Bundle-based translations and
/// SwiftUI's locale agree without changing the user's language preferences.
@Suite("다국어 뷰어 조작부 배치", .serialized)
@MainActor
struct LocalizedControlsLayoutTests {
  @Test("최소 창과 사이드바가 열린 폭에서 조작부가 프레임 밖으로 넘치지 않는다",
    arguments: [660, 960], [false, true])
  func controlsStayInsideViewport(width: Int, isDark: Bool) async throws {
    _ = NSApplication.shared
    let language = L10n.languageIdentifier
    if let expected = ProcessInfo.processInfo.environment["EXPECTED_APP_LANGUAGE"] {
      try #require(language == expected, "The process must actually use the requested app language")
    }
    let suite = "LocalizedControlsLayoutTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(suite, isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: temporary)
    }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: temporary.appendingPathComponent("marks.sqlite"))
    let shortcuts = ShortcutStore(defaults: defaults)
    let singleStore = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: temporary.appendingPathComponent("single-marks.sqlite"))
    singleStore.presentationMode = .viewer
    singleStore.imagesPerPage = 1
    singleStore.photoMapPreview.focus(on: temporary.appendingPathComponent("synthetic-map-photo.jpg"))
    defer {
      store.folderComparison.cancelLoads()
      singleStore.folderComparison.cancelLoads()
    }
    store.presentationMode = .viewer
    store.imagesPerPage = width == 660 ? 3 : 10
    let video = ImageAsset(url: temporary.appendingPathComponent("synthetic-video.mp4"),
      byteCount: 1_024, modificationDate: nil)
    let playback = VideoGridPlaybackState()
    playback.updateVisibleAssets([video])
    playback.toggleSelection(video.id)

    let gutter: CGFloat = 40
    let height: CGFloat = 1_650
    let root = VStack(spacing: 20) {
      HStack(spacing: 12) {
        ViewerPageNavigationHint(store: store, shortcuts: shortcuts)
          .frame(width: 110, alignment: .trailing)
        Spacer(minLength: 0)
        ViewerPageNavigationHint(store: store, shortcuts: shortcuts)
      }.padding(.horizontal, 16)
      LibraryControlsView(store: store).padding(.horizontal, 16)
      VideoGridPlaybackControls(state: playback, visibleAssets: [video])
      BottomControlBar(store: store, shortcuts: shortcuts)
      BottomControlBar(store: singleStore, shortcuts: shortcuts)
      // A map photo preview is narrower than the main viewport. Its full menu
      // title must remain discoverable at the real card width in every language.
      HStack {
        PhotoMapPreviewControls(preview: singleStore.photoMapPreview)
          .frame(width: 252)
          .padding(12)
          .background(ViewerTheme.panel)
        Spacer(minLength: 0)
      }
      PhotoMarkPanel(store: store, marks: store.photoMarks, shortcuts: shortcuts)
      FolderComparisonView(store: store, shortcuts: shortcuts, comparison: store.folderComparison)
        .frame(height: 700)
      Spacer(minLength: 0)
    }
    .frame(width: CGFloat(width), height: height, alignment: .top)
    .background(ViewerTheme.chrome)
    .padding(.horizontal, gutter)
    .background(Color(red: 1, green: 0, blue: 1))
    .font(ViewerUIMetrics.font(.body))
    .environment(\.locale, Locale(identifier: language))
    .environment(\.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight)
    .environment(\.colorScheme, isDark ? .dark : .light)

    let size = CGSize(width: CGFloat(width) + gutter * 2, height: height)
    let host = NSHostingView(rootView: root)
    host.frame = NSRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000,
      width: size.width, height: size.height), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = host.appearance
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let scale = CGFloat(bitmap.pixelsWide) / size.width
    // AppKit may capture Display P3/device RGB and color-manage the specified
    // magenta. Compare with the rendered background, not assumed sRGB numbers.
    let marginColor = try #require(bitmap.colorAt(x: 1, y: bitmap.pixelsHigh - 2)?
      .usingColorSpace(.sRGB))
    var overflowingPixels = 0
    // Check both gutters beyond the normal 2–3 pt button shadow. A fixed-width
    // child that overflows its parent paints into this otherwise magenta area.
    for y in stride(from: 10, to: bitmap.pixelsHigh - 10, by: 3) {
      for pointX in [CGFloat(12), gutter - 10, size.width - gutter + 10, size.width - 12] {
        let color = try #require(bitmap.colorAt(x: Int(pointX * scale), y: y)?.usingColorSpace(.sRGB))
        if abs(color.redComponent - marginColor.redComponent) > 0.03
          || abs(color.greenComponent - marginColor.greenComponent) > 0.03
          || abs(color.blueComponent - marginColor.blueComponent) > 0.03 {
          overflowingPixels += 1
        }
      }
    }
    #expect(overflowingPixels == 0,
      "Translated controls must not overflow the \(width) pt viewport (\(language), dark=\(isDark))")
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(data.count > 12_000, "The snapshot must include real controls, not an empty host")
    if let output = ProcessInfo.processInfo.environment["IMAGEVIEWER_LOCALIZED_CONTROLS_OUTPUT"] {
      let directory = URL(fileURLWithPath: output, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: directory.appendingPathComponent(
        "controls-\(language)-\(width)-\(isDark ? "dark" : "light").png"))
    }
    print("LOCALIZED_CONTROLS language=\(language) width=\(width) dark=\(isDark) overflow=\(overflowingPixels)")
  }
}
