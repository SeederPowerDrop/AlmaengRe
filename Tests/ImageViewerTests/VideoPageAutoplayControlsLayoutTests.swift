import AppKit
import SwiftUI
import Testing

@testable import ImageViewer

/// Each localized runner renders all playback states together, using the real
/// controls and translated labels without opening or decoding any media files.
@Suite("페이지 자동 재생 조작부 다국어 배치", .serialized)
@MainActor
struct VideoPageAutoplayControlsLayoutTests {
  @Test("좁은 사이드바와 최소 창에서 네 재생 상태의 문구가 화면을 넘지 않는다",
    arguments: [420, 660, 960], [false, true])
  func allPlaybackStatesFit(width: Int, isDark: Bool) async throws {
    _ = NSApplication.shared
    let language = L10n.languageIdentifier
    if let expected = ProcessInfo.processInfo.environment["EXPECTED_APP_LANGUAGE"] {
      try #require(language == expected,
        "The process must actually use the requested app language")
    }
    let photo = asset("photo.jpg")
    let video = asset("video.mp4")
    let audio = asset("audio.wav")
    let mixed = [photo, video, audio]
    let initial = VideoGridPlaybackState()
    let currentPage = VideoGridPlaybackState()
    let allPages = VideoGridPlaybackState()
    let photosOnly = VideoGridPlaybackState()
    for state in [initial, currentPage, allPages, photosOnly] {
      state.updateVisibleAssets(mixed)
      state.toggleSelection(video.id)
      state.toggleSelection(audio.id)
    }
    currentPage.playAll()
    for state in [allPages, photosOnly] {
      state.playAll()
      state.playAll()
    }
    photosOnly.updateVisibleAssets([photo])
    #expect(!initial.canEnablePageAutoplay && !initial.followsPages)
    #expect(currentPage.canEnablePageAutoplay && !currentPage.followsPages)
    #expect(allPages.followsPages)
    #expect(photosOnly.followsPages && photosOnly.playingIDs.isEmpty)

    let gutter: CGFloat = 40
    let height: CGFloat = 820
    let root = VStack(spacing: 16) {
      VideoGridPlaybackControls(state: initial, visibleAssets: mixed)
      Divider()
      VideoGridPlaybackControls(state: currentPage, visibleAssets: mixed)
      Divider()
      VideoGridPlaybackControls(state: allPages, visibleAssets: mixed)
      Divider()
      // Cancellation must still be available when autoplay reaches a page
      // containing only photos; this has the same active-state label.
      VideoGridPlaybackControls(state: photosOnly, visibleAssets: [photo])
      Spacer(minLength: 0)
    }
    .padding(.vertical, 12)
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
    let marginColor = try #require(bitmap.colorAt(x: 1, y: bitmap.pixelsHigh - 2)?
      .usingColorSpace(.sRGB))
    var overflowingPixels = 0
    // Compare with the captured color rather than a fixed RGB value because
    // AppKit may color-manage the magenta gutter into the display color space.
    for y in stride(from: 10, to: bitmap.pixelsHigh - 10, by: 3) {
      for pointX in [CGFloat(12), gutter - 10, size.width - gutter + 10, size.width - 12] {
        let color = try #require(bitmap.colorAt(x: Int(pointX * scale), y: y)?
          .usingColorSpace(.sRGB))
        if abs(color.redComponent - marginColor.redComponent) > 0.03
          || abs(color.greenComponent - marginColor.greenComponent) > 0.03
          || abs(color.blueComponent - marginColor.blueComponent) > 0.03 {
          overflowingPixels += 1
        }
      }
    }
    #expect(overflowingPixels == 0,
      "Autoplay labels must fit the \(width) pt viewport (\(language), dark=\(isDark))")
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(data.count > 8_000, "The snapshot must contain all four actual control rows")
    if let output = ProcessInfo.processInfo.environment["IMAGEVIEWER_LOCALIZED_CONTROLS_OUTPUT"] {
      let directory = URL(fileURLWithPath: output, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: directory.appendingPathComponent(
        "page-autoplay-\(language)-\(width)-\(isDark ? "dark" : "light").png"))
    }
    print("PAGE_AUTOPLAY_CONTROLS language=\(language) width=\(width) dark=\(isDark) overflow=\(overflowingPixels)")
  }

  private func asset(_ filename: String) -> ImageAsset {
    ImageAsset(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("autoplay-layout-fixtures", isDirectory: true)
      .appendingPathComponent(filename), byteCount: 1_024, modificationDate: nil)
  }
}
