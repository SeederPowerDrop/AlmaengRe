import AppKit
import SwiftUI
import Testing
@testable import ImageViewer

@Suite("몽땅보기 음성 아이콘·파형·미리 재생 조작부", .serialized)
@MainActor
struct OverviewMediaThumbnailLayoutTests {
  @Test("최소 썸네일부터 큰 썸네일까지 실제 번역·RTL·두 테마의 조작부가 영역 안에 들어간다",
    arguments: [45, 96, 180, 280], [false, true])
  func localizedMediaThumbnails(width: Int, isDark: Bool) async throws {
    _ = NSApplication.shared
    let language = L10n.languageIdentifier
    if let expected = ProcessInfo.processInfo.environment["EXPECTED_APP_LANGUAGE"] {
      try #require(language == expected)
    }
    let preview = OverviewMediaPreviewState()
    let audio = ImageAsset(url: URL(fileURLWithPath: "/layout/audio.m4a"), byteCount: 100, modificationDate: nil)
    let video = ImageAsset(url: URL(fileURLWithPath: "/layout/video.mp4"), byteCount: 100, modificationDate: nil)
    let side = CGFloat(width)
    let root = VStack(spacing: 16) {
      OverviewMediaThumbnail(asset: audio, preview: preview, pointSize: side) {
        OverviewAudioArtwork(fileExtension: "m4a")
      }.frame(width: side, height: side)
      OverviewMediaThumbnail(asset: video, preview: preview, pointSize: side) {
        Color.black.overlay { Image(systemName: "film").foregroundStyle(.white) }
      }.frame(width: side, height: side)
      OverviewAudioArtwork(fileExtension: "flac", isPlaying: true)
        .frame(width: side, height: side)
    }
    .frame(width: side, height: side * 3 + 32)
    .padding(20).background(Color(red: 1, green: 0, blue: 1))
    .environment(\.locale, Locale(identifier: language))
    .environment(\.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight)
    .environment(\.colorScheme, isDark ? .dark : .light)
    let host = NSHostingView(rootView: root)
    let size = CGSize(width: side + 40, height: side * 3 + 72)
    host.frame = NSRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000, width: size.width, height: size.height),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { preview.stop(); window.orderOut(nil); window.contentView = nil; window.close() }
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let reference = try #require(bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
    let scale = CGFloat(bitmap.pixelsWide) / size.width
    var overflow = 0
    for y in stride(from: 5, to: bitmap.pixelsHigh - 5, by: 3) {
      for x in [5.0, 12.0, size.width - 12, size.width - 5] {
        let color = try #require(bitmap.colorAt(x: Int(x * scale), y: y)?.usingColorSpace(.sRGB))
        if abs(color.redComponent - reference.redComponent) > 0.03
          || abs(color.greenComponent - reference.greenComponent) > 0.03
          || abs(color.blueComponent - reference.blueComponent) > 0.03 { overflow += 1 }
      }
    }
    #expect(overflow == 0)
    #expect(preview.playback == nil, "Idle layout must never open media or allocate players")
    if let output = ProcessInfo.processInfo.environment["IMAGEVIEWER_LOCALIZED_CONTROLS_OUTPUT"] {
      let directory = URL(fileURLWithPath: output, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try #require(bitmap.representation(using: .png, properties: [:])).write(to:
        directory.appendingPathComponent("overview-media-\(language)-\(width)-\(isDark ? "dark" : "light").png"))
    }
  }

  @Test("파형 표시의 높이는 재생 시간에 따라 바뀌고 정지 아이콘은 정적으로 유지된다")
  func animatedIndicatorAndStaticArtwork() throws {
    _ = NSApplication.shared
    let initial = try pixels(AudioPlaybackIndicator(phase: 0))
    let advanced = try pixels(AudioPlaybackIndicator(phase: 0.25))
    #expect(initial != advanced)
    let first = try pixels(OverviewAudioArtwork(fileExtension: "mp3"))
    let second = try pixels(OverviewAudioArtwork(fileExtension: "mp3"))
    #expect(first == second)
  }

  private func pixels<V: View>(_ view: V) throws -> Data {
    let host = NSHostingView(rootView: view.frame(width: 180, height: 180))
    host.frame = NSRect(x: 0, y: 0, width: 180, height: 180)
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }
}
