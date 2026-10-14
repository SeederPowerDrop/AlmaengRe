import AppKit
import SwiftUI
import Testing

@testable import ImageViewer

/// Run with the localized app-wrapped test runner, once per supported language.
/// The test never changes the user's language preference or opens real media.
@Suite("다국어 프레임 배치의 실제 렌더", .serialized)
@MainActor
struct ViewerFrameLayoutRenderTests {
  @Test("좁은 창의 배치 메뉴와 편집 안내가 넘치지 않고 RTL에서도 사진 위치를 유지한다",
    arguments: [420, 660, 960], [false, true])
  func translatedFrameControlsAndPhysicalPositions(width: Int, isDark: Bool) async throws {
    _ = NSApplication.shared
    let language = L10n.languageIdentifier
    if let expected = ProcessInfo.processInfo.environment["EXPECTED_APP_LANGUAGE"] {
      try #require(language == expected, "The actual app language must match the render matrix")
    }
    for key in ["title", "editing.help", "done", "move.help"] {
      #expect(FrameLayoutL10n.text(key) != key, "Actual translated controls must be rendered")
    }
    let suite = "ViewerFrameLayoutRenderTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let layout = ViewerFrameLayoutStore(defaults: defaults)
    layout.isEditing = true
    layout.swap(0, with: 3, count: 4)
    let workspaceSize = CGSize(width: width, height: 520)
    let initial = layout.configuration(for: 4)
    let initialGeometry = initial.geometry(in: workspaceSize)
    let columnDivider = try #require(initialGeometry.dividers.first { $0.axis == .vertical })
    let widened = initial.resizing(columnDivider,
      translation: CGSize(width: 58, height: 0), in: workspaceSize)
    let rowDivider = try #require(widened.geometry(in: workspaceSize).dividers.first { $0.axis == .horizontal })
    layout.commit(widened.resizing(rowDivider,
      translation: CGSize(width: 0, height: 36), in: workspaceSize), count: 4)
    let geometry = layout.geometry(for: 4, in: workspaceSize)

    let gutter: CGFloat = 40
    let toolbarHeight: CGFloat = 44
    let rtl = language == "ar"
    let editingBar = ViewerFrameEditingBar(layout: layout, count: 4)
      .frame(width: CGFloat(width))
      .environment(\.locale, Locale(identifier: language))
      .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
      .environment(\.colorScheme, isDark ? .dark : .light)
    let barHost = NSHostingView(rootView: editingBar)
    let editingHeight = barHost.fittingSize.height
    #expect(editingHeight >= 30 && editingHeight <= 100,
      "The translated editing help must wrap naturally and keep the Done button visible")

    let root = VStack(spacing: 0) {
      HStack(spacing: 12) {
        ViewerFrameLayoutMenu(layout: layout, count: 4, compact: false)
        Spacer(minLength: 12)
        ViewerFrameLayoutMenu(layout: layout, count: 4)
      }
      .padding(.horizontal, 14)
      .frame(height: toolbarHeight)
      .background(ViewerTheme.chrome)
      editingBar
      ViewerFrameWorkspace(layout: layout, count: 4) { slot, _ in
        ZStack {
          Self.colors[slot]
          Text(verbatim: "\(slot + 1)")
            .font(.system(size: 40, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
        }
      }
      .frame(width: workspaceSize.width, height: workspaceSize.height)
      .background(ViewerTheme.canvas)
      .environment(\.colorScheme, .dark)
    }
    .frame(width: CGFloat(width))
    .padding(gutter)
    .background(Color(.sRGB, red: 1, green: 0, blue: 1, opacity: 1))
    .environment(\.locale, Locale(identifier: language))
    .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
    .environment(\.colorScheme, isDark ? .dark : .light)

    let host = NSHostingView(rootView: root)
    host.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    let size = host.fittingSize
    #expect(abs(size.width - CGFloat(width) - 2 * gutter) < 1)
    #expect(abs(size.height - toolbarHeight - editingHeight - workspaceSize.height - 2 * gutter) < 1)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000,
      width: size.width, height: size.height), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = host.appearance
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    try await Task.sleep(for: .milliseconds(180))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    let capturedBitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: capturedBitmap)
    // AppKit captures in the display's ICC space. colorAt() exposes those raw
    // components as Generic RGB, so converting that NSColor a second time
    // would misinterpret the profile. Convert the whole bitmap first, then
    // compare its already-sRGB component values directly.
    let bitmap = try #require(capturedBitmap.converting(to: .sRGB,
      renderingIntent: .relativeColorimetric))
    let scale = CGFloat(bitmap.pixelsWide) / size.width
    let margin = try pixel(bitmap, at: CGPoint(x: 2, y: 2), scale: scale)
    var overflow = 0
    for y in stride(from: CGFloat(12), to: size.height - 12, by: 6) {
      for x in [CGFloat(12), gutter - 10, size.width - gutter + 10, size.width - 12] {
        if colorDistance(try pixel(bitmap, at: CGPoint(x: x, y: y), scale: scale), margin) > 0.04 {
          overflow += 1
        }
      }
    }
    for x in stride(from: CGFloat(12), to: size.width - 12, by: 6) {
      for y in [CGFloat(12), size.height - 12] {
        if colorDistance(try pixel(bitmap, at: CGPoint(x: x, y: y), scale: scale), margin) > 0.04 {
          overflow += 1
        }
      }
    }
    #expect(overflow == 0,
      "Frame controls must stay inside the \(width) pt viewport, \(language), dark=\(isDark)")

    // Check rendered content, not only the geometry model. The four unique
    // colors must appear in the swapped physical slots even for Arabic RTL.
    // Sample near every content corner to detect clipped, mirrored, or
    // overlapping frames; avoid the move handle and central synthetic number.
    let workspaceOrigin = CGPoint(x: gutter, y: gutter + toolbarHeight + editingHeight)
    for frame in geometry.frames {
      let expected = Self.components[frame.slot]
      for x in [frame.rect.minX + 12, frame.rect.maxX - 12] {
        for y in [frame.rect.minY + 28 + 12, frame.rect.maxY - 12] {
          let point = CGPoint(x: workspaceOrigin.x + x, y: workspaceOrigin.y + y)
          let color = try pixel(bitmap, at: point, scale: scale)
          #expect(abs(color.redComponent - expected.0) < 0.05
            && abs(color.greenComponent - expected.1) < 0.05
            && abs(color.blueComponent - expected.2) < 0.05,
            "Source slot \(frame.slot) must occupy its physical frame at \(point), language=\(language)")
        }
      }
    }
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(data.count > 4_000, "The snapshot must contain real controls and four synthetic frames")
    if let output = ProcessInfo.processInfo.environment["IMAGEVIEWER_LOCALIZED_CONTROLS_OUTPUT"] {
      let directory = URL(fileURLWithPath: output, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: directory.appendingPathComponent(
        "frames-\(language)-\(width)-\(isDark ? "dark" : "light").png"))
    }
    print("FRAME_LAYOUT language=\(language) width=\(width) dark=\(isDark) overflow=\(overflow) editingHeight=\(editingHeight)")
  }

  private static let components: [(CGFloat, CGFloat, CGFloat)] = [
    (0.82, 0.14, 0.18), (0.12, 0.57, 0.26), (0.12, 0.34, 0.80), (0.90, 0.44, 0.08),
  ]

  private static var colors: [Color] {
    components.map { Color(.sRGB, red: Double($0.0), green: Double($0.1), blue: Double($0.2), opacity: 1) }
  }

  private func pixel(_ bitmap: NSBitmapImageRep, at point: CGPoint, scale: CGFloat) throws -> NSColor {
    try #require(bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale)))
  }

  private func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
    max(abs(lhs.redComponent - rhs.redComponent),
      abs(lhs.greenComponent - rhs.greenComponent), abs(lhs.blueComponent - rhs.blueComponent))
  }
}
