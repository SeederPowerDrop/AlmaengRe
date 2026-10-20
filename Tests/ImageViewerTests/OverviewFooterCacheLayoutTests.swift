import AppKit
import SwiftUI
import Testing

@testable import ImageViewer

/// Exercise the production footer through its real controls. This deliberately
/// does not reproduce or inspect the layout cache's measurement algorithm.
/// Run with scripts/test-localized-layouts.py so actual localized bundles agree
/// with the SwiftUI locale; no global language preference is changed here.
@Suite("몽땅보기 하단 배치 캐시의 실제 조작부 갱신", .serialized)
@MainActor
struct OverviewFooterCacheLayoutTests {
  @Test("번역·테마·방향과 폭·상태가 바뀌어도 슬라이더를 유지하고 하단 줄을 다시 배치한다",
    arguments: [false, true])
  func actualFooterReflowsAfterEnvironmentAndStateChanges(isDark: Bool) async throws {
    _ = NSApplication.shared
    let language = L10n.languageIdentifier
    if let expected = ProcessInfo.processInfo.environment["EXPECTED_APP_LANGUAGE"] {
      try #require(language == expected, "Use the requested app localization in the actual controls")
    }
    let suite = "OverviewFooterCacheLayout.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: folder.appendingPathComponent("marks.sqlite"), thumbnailDiskCache: nil)
    store.presentationMode = .overview
    store.thumbnailSize = 99.9
    let environment = FooterEnvironment(isRightToLeft: language == "ar", isDark: isDark)
    let host = NSHostingView(rootView: Harness(store: store, environment: environment, language: language))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 1_400, height: 700),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    host.appearance = window.appearance
    window.contentView = host
    window.orderBack(nil)
    defer {
      window.orderOut(nil); window.contentView = nil; window.close()
      store.folderComparison.cancelLoads()
    }

    let original = try await settledSlider(in: host)
    let wide = frame(original, in: host)
    let wideBottomDistance = bottomDistance(wide, in: host)
    try snapshot(host, language: language, isDark: isDark, stage: "wide")
    var narrowBottomDistance: CGFloat?
    // Widths include the minimum app window, an open-sidebar pane, and the
    // 167pt pane left by a folder tree, filmstrip and inspector together.
    for width: CGFloat in [960, 660, 520, 167, 1_400] {
      window.setContentSize(CGSize(width: width, height: 700))
      let slider = try await settledSlider(in: host)
      #expect(slider === original, "Reflow must preserve native slider tracking identity")
      let before = frame(slider, in: host)
      for (size, marking, numbers): (CGFloat, Bool, Bool) in [
        (100, true, false), (665.6, false, true), (44.8, false, false), (99.9, false, true),
      ] {
        store.isPhotoMarking = marking
        store.showsOverviewNumbers = numbers
        let range = OverviewThumbnailSizing.range
        let fraction = Double((size - range.lowerBound) / (range.upperBound - range.lowerBound))
        slider.doubleValue = slider.minValue + fraction * (slider.maxValue - slider.minValue)
        try #require(slider.sendAction(slider.action, to: slider.target))
        let updated = try await settledSlider(in: host)
        #expect(updated === original)
        #expect(abs(store.thumbnailSize - size) < 0.01)
        let after = frame(updated, in: host)
        #expect(abs(before.width - after.width) < 0.5,
          "Value digits and classification state must not reshape the native slider")
        #expect(abs(before.midY - after.midY) < 0.5,
          "The current width's measured row must remain valid after a state change")
        for control in controls(in: host) where !control.isHiddenOrHasHiddenAncestor {
          let actual = frame(control, in: host)
          #expect(actual.minX >= -0.5 && actual.maxX <= host.bounds.maxX + 0.5,
            "A real control overflowed the \(width)pt pane in \(language): \(actual)")
          #expect(actual.minY >= -0.5 && actual.maxY <= host.bounds.maxY + 0.5)
        }
      }
      if width == 167 {
        narrowBottomDistance = bottomDistance(frame(slider, in: host), in: host)
        try snapshot(host, language: language, isDark: isDark, stage: "minimum-pane")
      }
    }
    let restored = try await settledSlider(in: host)
    #expect(abs(bottomDistance(frame(restored, in: host), in: host) - wideBottomDistance) < 1,
      "Returning to the wide pane must restore the original single-row position")
    #expect(try #require(narrowBottomDistance) > wideBottomDistance + 8,
      "The narrow pane must actually move its actions below the slider row")

    // Change environment on this same live tree, without a replacement root ID.
    // Arabic's initial direction is RTL; every language also exercises the reverse.
    environment.isRightToLeft.toggle()
    let mirrored = try await settledSlider(in: host)
    #expect(mirrored === original)
    environment.isRightToLeft.toggle()
    let returned = try await settledSlider(in: host)
    #expect(returned === original)
    let returnedFrame = frame(returned, in: host)
    #expect(abs(returnedFrame.minX - wide.minX) < 1 && abs(returnedFrame.midY - wide.midY) < 1,
      "Changing layout direction and back must invalidate measurements without moving the restored controls")
    try snapshot(host, language: language, isDark: isDark, stage: "restored")
    print("OVERVIEW_FOOTER_LAYOUT language=\(language) dark=\(isDark) nativeSliderPreserved=true narrowPaneReflow=true")
  }

  private func settledSlider(in host: NSView) async throws -> NSSlider {
    for _ in 0..<4 {
      try await Task.sleep(for: .milliseconds(25))
      host.layoutSubtreeIfNeeded()
    }
    let values = controls(in: host).compactMap { $0 as? NSSlider }
    try #require(values.count == 1, "Use one real production overview size slider")
    return try #require(values.first)
  }

  private func controls(in view: NSView) -> [NSControl] {
    (view as? NSControl).map { [$0] } ?? view.subviews.flatMap { controls(in: $0) }
  }

  private func frame(_ control: NSControl, in host: NSView) -> CGRect {
    host.convert(control.bounds, from: control)
  }

  private func bottomDistance(_ frame: CGRect, in host: NSView) -> CGFloat {
    host.isFlipped ? host.bounds.maxY - frame.midY : frame.midY - host.bounds.minY
  }

  private func snapshot(_ host: NSView, language: String, isDark: Bool, stage: String) throws {
    guard let output = ProcessInfo.processInfo.environment["IMAGEVIEWER_LOCALIZED_CONTROLS_OUTPUT"] else { return }
    host.displayIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let folder = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try data.write(to: folder.appendingPathComponent(
      "overview-footer-\(language)-\(isDark ? "dark" : "light")-\(stage).png"))
  }

  private final class FooterEnvironment: ObservableObject {
    @Published var isRightToLeft: Bool
    let isDark: Bool
    init(isRightToLeft: Bool, isDark: Bool) {
      self.isRightToLeft = isRightToLeft; self.isDark = isDark
    }
  }

  private struct Harness: View {
    let store: AppStore
    @ObservedObject var environment: FooterEnvironment
    let language: String
    var body: some View {
      OverviewView(store: store)
        .environment(\.locale, Locale(identifier: language))
        .environment(\.layoutDirection, environment.isRightToLeft ? .rightToLeft : .leftToRight)
        .environment(\.colorScheme, environment.isDark ? .dark : .light)
    }
  }
}
