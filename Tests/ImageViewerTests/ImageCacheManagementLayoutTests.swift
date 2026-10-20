import AppKit
import SwiftUI
import Testing

@testable import ImageViewer

/// The same controls used in General settings, rendered with real translations.
/// No original photos, user settings or production disk cache are accessed.
@Suite("캐시 관리 설정의 다국어 배치", .serialized)
@MainActor
struct ImageCacheManagementLayoutTests {
  @Test("확인한 용량과 확인 불가 상태가 좁은 폭·밝은·어두운 모드와 RTL에서 넘치지 않는다",
    arguments: [280, 620], [false, true])
  func controlsFit(width: Int, isDark: Bool) async throws {
    for isDiskUsageComplete in [true, false] {
      try await renderControls(width: width, isDark: isDark,
        isDiskUsageComplete: isDiskUsageComplete)
    }
  }

  private func renderControls(width: Int, isDark: Bool,
    isDiskUsageComplete: Bool) async throws {
    _ = NSApplication.shared
    let language = L10n.languageIdentifier
    if let expected = ProcessInfo.processInfo.environment["EXPECTED_APP_LANGUAGE"] {
      try #require(language == expected)
    }
    let usage = ImageCacheUsage(
      rendered: ImageCacheSnapshot(entryCount: 2, byteCount: 12_345_678, byteLimit: 32_000_000),
      thumbnails: ImageCacheSnapshot(entryCount: 4, byteCount: 345_678, byteLimit: 16_000_000),
      disk: ThumbnailDiskCacheSnapshot(entryCount: 12, byteCount: 1_234_567,
        byteLimit: 512_000_000, previewBytes: 234_567, exactBytes: 1_000_000,
        hits: 0, misses: 0, isComplete: isDiskUsageComplete))
    let expectedDiskValue = isDiskUsageComplete ? usage.formattedDiskSize : L10n.text("cache.usageUnknown")
    #expect(ImageCacheManagementControls.diskUsageText(for: usage)
      == L10n.format("cache.diskUsage", expectedDiskValue))
    if !isDiskUsageComplete {
      #expect(!L10n.text("cache.diskUsageUnavailableHelp").isEmpty)
      #expect(L10n.text("cache.usageUnknown") != "cache.usageUnknown")
    }
    let gutter: CGFloat = 40
    let size = CGSize(width: CGFloat(width) + gutter * 2, height: 1_000)
    let root = VStack(alignment: .leading, spacing: 14) {
      Text(verbatim: L10n.text("cache.title")).font(.headline)
      ImageCacheManagementControls(usage: usage, isRefreshing: false,
        isClearing: false, clearFailed: true, refresh: {}, clear: {})
      Divider()
      ImageCacheManagementControls(usage: nil, isRefreshing: true,
        isClearing: true, clearFailed: false, refresh: {}, clear: {})
    }
    .font(ViewerUIMetrics.font(.body))
    .frame(width: CGFloat(width), height: size.height, alignment: .topLeading)
    .background(ViewerTheme.chrome)
    .padding(.horizontal, gutter)
    .background(Color(red: 1, green: 0, blue: 1))
    .environment(\.locale, Locale(identifier: language))
    .environment(\.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight)
    .environment(\.colorScheme, isDark ? .dark : .light)

    let host = NSHostingView(rootView: root)
    host.frame = NSRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000,
      width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
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
    let marginColor = try #require(bitmap.colorAt(x: 1, y: bitmap.pixelsHigh - 2)?.usingColorSpace(.sRGB))
    var overflowingPixels = 0
    for y in stride(from: 10, to: bitmap.pixelsHigh - 10, by: 3) {
      for pointX in [gutter - 10, size.width - gutter + 10] {
        let color = try #require(bitmap.colorAt(x: Int(pointX * scale), y: y)?.usingColorSpace(.sRGB))
        if abs(color.redComponent - marginColor.redComponent) > 0.03
          || abs(color.greenComponent - marginColor.greenComponent) > 0.03
          || abs(color.blueComponent - marginColor.blueComponent) > 0.03 {
          overflowingPixels += 1
        }
      }
    }
    #expect(overflowingPixels == 0, "Cache labels and buttons must stay inside \(width) pt (\(language))")
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(data.count > 5_000)
    if let output = ProcessInfo.processInfo.environment["IMAGEVIEWER_LOCALIZED_CONTROLS_OUTPUT"] {
      let directory = URL(fileURLWithPath: output, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: directory.appendingPathComponent(
        "cache-\(language)-\(width)-\(isDark ? "dark" : "light")-\(isDiskUsageComplete ? "known" : "unknown").png"))
    }
    print("CACHE_LAYOUT language=\(language) width=\(width) dark=\(isDark) complete=\(isDiskUsageComplete) overflow=\(overflowingPixels)")
  }
}
