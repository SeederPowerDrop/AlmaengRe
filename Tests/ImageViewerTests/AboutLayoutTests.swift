import AppKit
import SwiftUI
import Testing

@testable import ImageViewer

@Suite("10개 언어의 정보창 배치", .serialized)
@MainActor
struct AboutLayoutTests {
  @Test("긴 번역과 RTL 소개·후원·닫기 버튼이 스크롤 없이 한 창에 들어간다",
    arguments: L10n.supportedLocalizations, [false, true])
  func introductionFitsVisibleWindow(language: String, isDark: Bool) async throws {
    _ = NSApplication.shared
    // Keep the width below the production window's usual 1,000 points, so a
    // narrower screen also exercises the longest translated paragraphs.
    let root = AboutView(localeIdentifier: language, width: 960)
      .font(ViewerUIMetrics.font(.body))
      .environment(\.colorScheme, isDark ? .dark : .light)
    let host = NSHostingView(rootView: root)
    host.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    let fitting = host.fittingSize
    #expect(abs(fitting.width - 960) < 1)
    #expect(fitting.height > 400 && fitting.height <= 740,
      "\(language) needs \(fitting.height) points; the full introduction must fit a typical 800-point screen")
    host.frame = NSRect(origin: .zero, size: fitting)
    let window = NSWindow(contentRect: NSRect(x: -3_000, y: -3_000,
      width: fitting.width, height: fitting.height), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = host.appearance
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }

    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    #expect(!containsScrollView(host), "The introduction and donation cards must not scroll")
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(data.count > 20_000)
    if let path = ProcessInfo.processInfo.environment["IMAGEVIEWER_ABOUT_LAYOUT_OUTPUT"], !path.isEmpty {
      let directory = URL(fileURLWithPath: path, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: directory.appendingPathComponent("about-\(language)-\(isDark ? "dark" : "light").png"))
    }
    print("ABOUT_LAYOUT language=\(language) scheme=\(isDark ? "dark" : "light") size=\(fitting)")
  }

  private func containsScrollView(_ view: NSView) -> Bool {
    view is NSScrollView || view.subviews.contains(where: containsScrollView)
  }
}
