import AppKit
import SwiftUI
import Testing

@testable import ImageViewer

/// Render the actual settings tree, including native popup controls. A saturated
/// backing surface and inherited white text reproduce the original popover risk
/// without capturing any user's video, filenames, subtitles or desktop.
@Suite("자막 설정의 불투명 배경과 가독성", .serialized)
@MainActor
struct SubtitleSettingsAppearanceTests {
  @Test("영상 헤더의 흰색 글씨를 상속해도 밝은·어두운 설정창이 읽힌다", arguments: [false, true])
  func actualSettingsStayOpaqueAndReadable(isDark: Bool) async throws {
    _ = NSApplication.shared
    let session = VideoStudySession(videoURL: URL(fileURLWithPath: "/synthetic/Language lesson.mp4"),
      discoverer: { _ in [] }, loader: { url in
        SubtitleDocument(sourceURL: url, tracks: [SubtitleTrack(id: "test", name: "Test",
          cues: [SubtitleCue(start: 0, end: 5, text: "Synthetic subtitle")])])
      })
    session.primary.load(url: URL(fileURLWithPath: "/synthetic/Language lesson.en.srt"))
    session.secondary.load(url: URL(fileURLWithPath: "/synthetic/Language lesson.ko.srt"))
    session.primary.fontName = "Arial"
    defer { session.cancelPendingWork() }
    let scheme: ColorScheme = isDark ? .dark : .light
    let root = ZStack {
      Color(nsColor: .magenta)
      VideoSubtitleSettings(session: session)
    }
    .foregroundStyle(.white)
    .environment(\.colorScheme, scheme)
    .frame(width: 660, height: 580)
    let host = NSHostingView(rootView: root)
    host.frame = NSRect(x: 0, y: 0, width: 660, height: 580)
    host.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    let window = NSWindow(contentRect: NSRect(x: -3_000, y: -3_000, width: 660, height: 580),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = host.appearance
    window.backgroundColor = .magenta
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    try await waitUntil {
      host.layoutSubtreeIfNeeded()
      return !session.primary.isLoading && !session.secondary.isLoading
        && fontPickers(in: host).count == 2
        && fontPickers(in: host).allSatisfy { $0.bounds.width > 80 && $0.bounds.height >= 20 }
    }
    // Permit the layer-backed SwiftUI text and native cells to complete their
    // next display pass after geometry and asynchronous synthetic loads settle.
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try export(bitmap, isDark: isDark)

    let scaleX = Double(bitmap.pixelsWide) / 660
    let scaleY = Double(bitmap.pixelsHigh) / 580
    func sample(_ x: Double, _ y: Double) throws -> NSColor {
      let pixelX = min(bitmap.pixelsWide - 1, Int(x * scaleX))
      let pixelY = min(bitmap.pixelsHigh - 1, Int(y * scaleY))
      let color = bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(NSColorSpace.sRGB)
      return try #require(color)
    }

    let corners = try [sample(5, 5), sample(655, 5), sample(5, 575), sample(655, 575)]
    for color in corners {
      #expect(color.alphaComponent > 0.99, "Settings must paint an opaque surface over the video")
      let neutral = max(color.redComponent, color.greenComponent, color.blueComponent)
        - min(color.redComponent, color.greenComponent, color.blueComponent) < 0.035
      #expect(neutral, "The saturated simulated video must not bleed into the panel background")
      let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
      #expect(isDark ? brightness < 0.3 : brightness > 0.9,
        "Panel background must follow its requested appearance")
    }

    // Header text has no native controls or accent colors in its rectangle.
    // Requiring many neutral high-contrast pixels catches inherited white text
    // on the light background while tolerating font rasterization differences.
    let background = try sample(5, 5)
    var readableTextPixels = 0
    for y in Int(18 * scaleY)..<Int(45 * scaleY) {
      for x in Int(20 * scaleX)..<Int(620 * scaleX) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(NSColorSpace.sRGB) else { continue }
        let neutral = max(color.redComponent, color.greenComponent, color.blueComponent)
          - min(color.redComponent, color.greenComponent, color.blueComponent) < 0.08
        if neutral && contrast(color, background) >= 4.5 { readableTextPixels += 1 }
      }
    }
    #expect(readableTextPixels > Int(35 * scaleX * scaleY),
      "Actual header glyphs must remain readable against the opaque background")
    let controls = fontPickers(in: host)
    #expect(controls.allSatisfy { $0.isEnabled })
    #expect(controls.contains { $0.selectedItem?.representedObject as? String == "Arial" })
    print("SUBTITLE_APPEARANCE scheme=\(isDark ? "dark" : "light") opaqueCorners=\(corners.count) readableHeaderPixels=\(readableTextPixels) nativeFontControls=\(controls.count)")
  }

  private func fontPickers(in view: NSView) -> [NSPopUpButton] {
    if let button = view as? NSPopUpButton,
      button.accessibilityIdentifier().hasPrefix("video.subtitle.") {
      return [button]
    }
    return view.subviews.flatMap { fontPickers(in: $0) }
  }

  private func contrast(_ first: NSColor, _ second: NSColor) -> Double {
    func luminance(_ color: NSColor) -> Double {
      func linear(_ component: CGFloat) -> Double {
        let value = Double(component)
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
      }
      return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
        + 0.0722 * linear(color.blueComponent)
    }
    let left = luminance(first), right = luminance(second)
    return (max(left, right) + 0.05) / (min(left, right) + 0.05)
  }

  private func export(_ bitmap: NSBitmapImageRep, isDark: Bool) throws {
    guard let path = ProcessInfo.processInfo.environment["IMAGEVIEWER_SUBTITLE_APPEARANCE_OUTPUT"],
      !path.isEmpty else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: directory.appendingPathComponent(isDark ? "subtitle-settings-dark.png" : "subtitle-settings-light.png"))
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(predicate(), "Actual subtitle settings controls did not settle")
  }
}
