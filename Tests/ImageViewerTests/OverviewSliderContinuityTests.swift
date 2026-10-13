import AppKit
import SwiftUI
import Testing

@testable import ImageViewer

@Suite("몽땅보기 크기 슬라이더의 실제 화면 연속성", .serialized)
@MainActor
struct OverviewSliderContinuityTests {
  @Test("숫자 자릿수와 도구 모음 줄 수가 바뀌어도 슬라이더와 선택한 크기를 유지한다")
  func resizingKeepsTheNativeSliderAndValue() async throws {
    let suite = "OverviewSliderContinuityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: folder.appendingPathComponent("marks.sqlite"))
    store.presentationMode = .overview
    store.thumbnailSize = 99.9
    _ = NSApplication.shared
    let host = NSHostingView(rootView: OverviewView(store: store))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 1_400, height: 700),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }

    let slider = try await settledSlider(in: host)
    let range = OverviewThumbnailSizing.range
    // Exercise the actual AppKit-to-SwiftUI binding across both value-width and
    // footer-layout changes, rather than assigning only the model property.
    // A 960pt window can leave only 167pt after the folder tree, right filmstrip,
    // and inspector are all shown. The controls must fit that actual pane width.
    for width: CGFloat in [1_400, 720, 520, 167, 1_400] {
      window.setContentSize(NSSize(width: width, height: 700))
      let current = try await settledSlider(in: host)
      #expect(current === slider, "Reflow must preserve the native control's tracking state")
      let trackWidth = current.bounds.width
      for size: CGFloat in [99.9, 100, 240.5, 665.6, 44.8] {
        let fraction = Double((size - range.lowerBound) / (range.upperBound - range.lowerBound))
        current.doubleValue = current.minValue + fraction * (current.maxValue - current.minValue)
        try #require(current.sendAction(current.action, to: current.target))
        let updated = try await settledSlider(in: host)
        #expect(updated === slider)
        #expect(abs(updated.bounds.width - trackWidth) < 0.1,
          "At the same pane width, changing the value must not reshape the slider track")
        #expect(abs(store.thumbnailSize - size) < 0.01)
        #expect(abs(defaults.double(forKey: "ImageViewer.OverviewThumbnailSize.v1") - Double(size)) < 0.01)
        for control in controls(in: host) where !control.isHiddenOrHasHiddenAncestor {
          let frame = host.convert(control.bounds, from: control)
          #expect(frame.minX >= -0.5 && frame.maxX <= width + 0.5,
            "A control crossed the overview pane bounds at \(width)pt: \(frame)")
        }
      }
    }
  }

  private func settledSlider(in host: NSView) async throws -> NSSlider {
    for _ in 0..<4 {
      try await Task.sleep(for: .milliseconds(25))
      host.layoutSubtreeIfNeeded()
    }
    let controls = sliders(in: host)
    try #require(controls.count == 1, "The overview should keep one live size slider")
    return try #require(controls.first)
  }

  private func sliders(in view: NSView) -> [NSSlider] {
    if let slider = view as? NSSlider { return [slider] }
    return view.subviews.flatMap { sliders(in: $0) }
  }

  private func controls(in view: NSView) -> [NSControl] {
    if let control = view as? NSControl { return [control] }
    return view.subviews.flatMap { controls(in: $0) }
  }
}
