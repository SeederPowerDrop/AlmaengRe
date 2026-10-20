import AppKit
import SwiftUI
import Testing

@testable import ImageViewer

@Suite("포함·제외 분류 필터의 다국어 배치", .serialized)
@MainActor
struct PhotoMarkFilterLayoutTests {
  @Test("포함·제외 탭과 좁은 비교 칸을 라이트·다크·RTL로 표시한다",
    arguments: [false, true], [false, true])
  func filterEditorFits(editsExclusions: Bool, isDark: Bool) async throws {
    _ = NSApplication.shared
    let language = L10n.languageIdentifier
    if let expected = ProcessInfo.processInfo.environment["EXPECTED_APP_LANGUAGE"] {
      try #require(language == expected)
    }
    let marks = PhotoMarkStore(inMemory: true)
    await marks.waitUntilReady()
    let filter = PhotoMarkFilter(slots: [.s, .a], excludedSlots: [.e])
    let editor = PhotoMarkFilterEditor(filter: .constant(filter), marks: marks,
      title: PhotoMarkL10n.text("filter.title"), editLabels: {}, editsExclusions: editsExclusions)
    try await capture(editor, width: ViewerUIMetrics.scale(430), maximumHeight: 620,
      name: "editor-\(editsExclusions ? "exclude" : "include")", language: language, isDark: isDark)

    let suite = "PhotoMarkFilterLayoutTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let comparison = FolderComparisonStore(defaults: defaults, alignment: .sequence, photoMarks: marks)
    defer {
      comparison.cancelLoads()
      defaults.removePersistentDomain(forName: suite)
    }
    comparison.first.photoMarkFilter = filter
    let controls = ComparisonPhotoMarkControls(comparison: comparison, pane: comparison.first,
      marks: marks, side: .first)
    try await capture(controls.padding(10), width: 260, maximumHeight: 140,
      name: "comparison-\(editsExclusions ? "exclude" : "include")", language: language, isDark: isDark)
  }

  private func capture<Content: View>(_ content: Content, width: CGFloat, maximumHeight: CGFloat,
    name: String, language: String, isDark: Bool) async throws {
    let gutter: CGFloat = 30
    let root = content
      .frame(width: width)
      .background(ViewerTheme.chrome)
      .padding(gutter)
      .background(Color(red: 1, green: 0, blue: 1))
      .environment(\.locale, Locale(identifier: language))
      .environment(\.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight)
      .environment(\.colorScheme, isDark ? .dark : .light)
    let host = NSHostingView(rootView: root)
    host.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    let size = host.fittingSize
    #expect(abs(size.width - width - 2 * gutter) < 1)
    #expect(size.height <= maximumHeight + 2 * gutter,
      "The production filter must fit without scrolling: \(language), \(name)")
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000,
      width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = host.appearance
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    let captured = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: captured)
    let bitmap = try #require(captured.converting(to: .sRGB, renderingIntent: .relativeColorimetric))
    let scale = CGFloat(bitmap.pixelsWide) / size.width
    let reference = try #require(bitmap.colorAt(x: 2, y: 2))
    var overflow = 0
    for y in stride(from: CGFloat(10), to: size.height - 10, by: 3) {
      for x in [CGFloat(10), gutter - 8, size.width - gutter + 8, size.width - 10] {
        let pixel = try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale)))
        if max(abs(pixel.redComponent - reference.redComponent),
          abs(pixel.greenComponent - reference.greenComponent),
          abs(pixel.blueComponent - reference.blueComponent)) > 0.04 { overflow += 1 }
      }
    }
    #expect(overflow == 0, "Translated controls must stay within their frame: \(language), \(name)")
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(data.count > 3_000)
    if let output = ProcessInfo.processInfo.environment["IMAGEVIEWER_LOCALIZED_CONTROLS_OUTPUT"] {
      let directory = URL(fileURLWithPath: output, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: directory.appendingPathComponent(
        "photo-mark-filter-\(language)-\(name)-\(isDark ? "dark" : "light").png"))
    }
    print("PHOTO_MARK_FILTER language=\(language) name=\(name) dark=\(isDark) height=\(size.height - 2 * gutter) overflow=\(overflow)")
  }
}
