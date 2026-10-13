import AppKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

/// Hosts the real comparison hierarchy: a standalone frame-loader test cannot
/// catch SwiftUI throwing its StateObject away when the selected file changes.
@Suite("비교 화면의 실제 SwiftUI 표시 연속성", .serialized)
@MainActor
struct ComparisonRenderingContinuityTests {
  private struct DeadlineExceeded: Error { let phase: String }

  @Test("디코더가 바쁠 때 연속 넘기기도 기존 화면을 유지하고 마지막 사진으로 이어진다")
  func pendingNavigationKeepsTheNativeImageView() async throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let suite = "ComparisonRenderingContinuityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    let comparison = store.folderComparison
    comparison.alignment = .sequence
    comparison.showsThumbnails = false
    comparison.first.load(folder)
    try await wait("folder loaded") { !comparison.first.isLoading && !comparison.first.isFiltering }
    try #require(comparison.first.assets.count == 3)
    await store.loadingGovernor.update(ImageResourceSnapshot(
      physicalMemory: 16 * 1_024 * 1_024 * 1_024,
      activeProcessorCount: 8, appleSilicon: true))

    _ = NSApplication.shared
    let host = NSHostingView(rootView: FolderComparisonView(store: store,
      shortcuts: ShortcutStore(defaults: defaults), comparison: comparison))
    let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 1_100, height: 800),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    try await wait("initial image") {
      host.layoutSubtreeIfNeeded()
      return imageViews(in: host).count == 1
    }
    // Let the initial precise frame settle before occupying the decoder slots.
    try await Task.sleep(for: .milliseconds(250))
    let gate = ComparisonRenderGate()
    let governor = store.loadingGovernor
    let blocks = (0..<2).map { index in
      Task {
        try await governor.value(for: ImageResourceWorkKey(namespace: UUID(), key: index),
          url: folder.appendingPathComponent("01.png"), priority: .interactivePreview) { _ in
          await gate.wait()
          return index
        }
      }
    }
    defer {
      blocks.forEach { $0.cancel() }
      Task { await gate.release() }
    }
    try await wait("decoder slots occupied") { await gate.waitingCount == 2 }
    let backing = try #require(imageViews(in: host).first)
    let originalImage = try #require(displayedImage(in: backing))
    #expect(isDominant(.red, in: originalImage))
    #expect(comparison.first.canMarkPresentedAsset)

    for number in (0..<18).map({ $0.isMultiple(of: 2) ? 2 : 3 }) {
      comparison.jump(.first, number: number)
      try await Task.sleep(for: .milliseconds(15))
      host.layoutSubtreeIfNeeded()
      let visible = imageViews(in: host)
      #expect(visible.count == 1)
      #expect(visible.first === backing)
      #expect(displayedImage(in: visible.first) === originalImage)
      #expect(!comparison.first.canMarkPresentedAsset)
      // Two deliberately occupied slots plus at most one preview and one
      // refinement per pane: key repeat must not grow a queue of old files.
      #expect(await governor.stateSnapshot().queuedCount <= 2)
    }
    #expect(comparison.first.currentAsset?.filename == "03.png")
    await gate.release()
    for block in blocks { _ = try await block.value }
    try await wait("latest blue image") {
      host.layoutSubtreeIfNeeded()
      guard let image = displayedImage(in: imageViews(in: host).first) else { return false }
      return isDominant(.blue, in: image) && comparison.first.canMarkPresentedAsset
    }
    #expect(imageViews(in: host).first === backing)
    #expect(comparison.first.baseImageSize.height > comparison.first.baseImageSize.width)

    // Identical image dimensions must still publish geometry for a new file.
    // Otherwise a stale size can remain after navigation now that the tile lives on.
    comparison.jump(.first, number: 1)
    try await wait("return to red image") {
      host.layoutSubtreeIfNeeded()
      guard let image = displayedImage(in: imageViews(in: host).first) else { return false }
      return isDominant(.red, in: image)
    }
    try await Task.sleep(for: .milliseconds(250))
    let firstSize = comparison.first.baseImageSize
    let sentinel = CGSize(width: 123, height: 456)
    comparison.updateBaseImageSize(sentinel, on: .first,
      assetID: comparison.first.currentAsset?.id)
    comparison.jump(.first, number: 2)
    try await wait("green image with matching size") {
      host.layoutSubtreeIfNeeded()
      guard let image = displayedImage(in: imageViews(in: host).first) else { return false }
      return isDominant(.green, in: image) && comparison.first.baseImageSize == firstSize
    }
    #expect(imageViews(in: host).first === backing)

    // A folder switch must still tear down the old image, not carry it into an
    // unrelated collection. The empty-folder fixture contains no image files.
    let emptyFolder = folder.appendingPathComponent("empty", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: false)
    comparison.first.load(emptyFolder)
    try await wait("empty folder clears image") {
      host.layoutSubtreeIfNeeded()
      return !comparison.first.isLoading && imageViews(in: host).isEmpty
    }
    #expect(comparison.first.currentAsset == nil)
    store.saveSessionNow()
  }

  private enum Channel: Int { case red = 0, green = 1, blue = 2 }

  private func isDominant(_ channel: Channel, in image: CGImage) -> Bool {
    let values = pixelValues(in: image)
    guard values.count == 4 else { return false }
    // Precise Display P3/HDR frames can mix small amounts of other channels
    // when drawn into DeviceRGB (pure blue becomes [4, 51, 255] on this Mac).
    // Only image identity is under test; require a clearly dominant channel.
    return values[channel.rawValue] > 200
      && (0..<3).filter { $0 != channel.rawValue }
        .allSatisfy { Int(values[channel.rawValue]) > Int(values[$0]) + 100 }
  }

  private func pixelValues(in image: CGImage) -> [UInt8] {
    guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data
    else { return [] }
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let values = data.assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: values, count: 4))
  }

  private func displayedImage(in view: ExtendedRangeBackingView?) -> CGImage? {
    guard let contents = view?.layer?.contents,
      CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
    return (contents as! CGImage)
  }

  private func imageViews(in view: NSView) -> [ExtendedRangeBackingView] {
    (view as? ExtendedRangeBackingView).map { [$0] }
      ?? view.subviews.flatMap { imageViews(in: $0) }
  }

  private func wait(_ phase: String, _ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !(await condition()) {
      guard ContinuousClock.now < deadline else { throw DeadlineExceeded(phase: phase) }
      try await Task.sleep(for: .milliseconds(10))
    }
    print("COMPARISON_HOSTING_PHASE \(phase)")
  }

  private func fixture() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComparisonRenderingContinuity-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for index in 1...3 {
      let width = index == 3 ? 32 : 64, height = index == 3 ? 64 : 32
      let context = try #require(CGContext(data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      let color = index == 1 ? CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        : index == 2 ? CGColor(red: 0, green: 1, blue: 0, alpha: 1)
        : CGColor(red: 0, green: 0, blue: 1, alpha: 1)
      context.setFillColor(color)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      let image = try #require(context.makeImage())
      let destination = try #require(CGImageDestinationCreateWithURL(
        folder.appendingPathComponent(String(format: "%02d.png", index)) as CFURL,
        UTType.png.identifier as CFString, 1, nil))
      CGImageDestinationAddImage(destination, image, nil)
      try #require(CGImageDestinationFinalize(destination))
    }
    return folder
  }
}

private actor ComparisonRenderGate {
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var isReleased = false
  var waitingCount: Int { continuations.count }

  func wait() async {
    guard !isReleased else { return }
    await withCheckedContinuation { continuations.append($0) }
  }

  func release() {
    isReleased = true
    let pending = continuations
    continuations.removeAll()
    pending.forEach { $0.resume() }
  }
}
