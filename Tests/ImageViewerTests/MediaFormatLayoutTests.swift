import AppKit
import SwiftUI
import Testing

@testable import ImageViewer

@Suite("사진·영상·음성 형식 선택기 다국어 배치", .serialized)
@MainActor
struct MediaFormatLayoutTests {
  @Test("실제 확장자 선택기에서 네 종류와 전체 확장자 문구를 잘림 없이 표시한다",
    arguments: [LibraryMediaKind.all, .audio], [false, true])
  func nativePickerFits(kind: LibraryMediaKind, isDark: Bool) async throws {
    _ = NSApplication.shared
    let language = L10n.languageIdentifier
    if let expected = ProcessInfo.processInfo.environment["EXPECTED_APP_LANGUAGE"] {
      try #require(language == expected)
    }
    var query = LibraryQuery()
    query.mediaKind = kind
    let gutter: CGFloat = 30
    let width = ViewerUIMetrics.scale(440)
    let root = LibraryFormatMenu(query: .constant(query),
      availableExtensions: ["png", "jpg", "mp4", "m4a", "wav", "mp3", "caf"])
      .picker
      .font(ViewerUIMetrics.font(.body))
      .background(ViewerTheme.chrome)
      .padding(.horizontal, gutter)
      .padding(.vertical, 10)
      .background(Color(red: 1, green: 0, blue: 1))
      .environment(\.locale, Locale(identifier: language))
      .environment(\.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight)
      .environment(\.colorScheme, isDark ? .dark : .light)
    let host = NSHostingView(rootView: root)
    let size = CGSize(width: width + gutter * 2, height: 530)
    host.frame = NSRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    let window = NSWindow(contentRect: NSRect(x: -3_000, y: -3_000, width: size.width, height: size.height),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    #expect(host.fittingSize.height <= size.height)
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let scale = CGFloat(bitmap.pixelsWide) / size.width
    let reference = try #require(bitmap.colorAt(x: 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    var overflow = 0
    for y in stride(from: 10, to: bitmap.pixelsHigh - 10, by: 3) {
      for x in [CGFloat(10), size.width - 10] {
        let color = try #require(bitmap.colorAt(x: Int(x * scale), y: y)?.usingColorSpace(.sRGB))
        if abs(color.redComponent - reference.redComponent) > 0.03
          || abs(color.greenComponent - reference.greenComponent) > 0.03
          || abs(color.blueComponent - reference.blueComponent) > 0.03 { overflow += 1 }
      }
    }
    #expect(overflow == 0)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(data.count > 8_000)
    if let output = ProcessInfo.processInfo.environment["IMAGEVIEWER_LOCALIZED_CONTROLS_OUTPUT"] {
      let directory = URL(fileURLWithPath: output, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: directory.appendingPathComponent("formats-\(language)-\(kind.rawValue)-\(isDark ? "dark" : "light").png"))
    }
  }
}
