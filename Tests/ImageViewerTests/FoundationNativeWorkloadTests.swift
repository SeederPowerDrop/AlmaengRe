import AppKit
import ImageIO
import SwiftUI
import XCTest
import UniformTypeIdentifiers
@testable import ImageViewer

/// A real activated window, private defaults/caches, and no source capture.
/// Accepted-frame timings are not GPU-counter or cold-storage measurements.
@MainActor
struct FoundationNativeWorkloadTests {
  func firstAcceptedFrame(condition: String) async throws {
    let output = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEVIEWER_FOUNDATION_OUTPUT"]))
    let suite = "FoundationNative.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    let photos = root.appendingPathComponent("Photos")
    try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let source: URL
    if condition == "raw1" {
      let path = try XCTUnwrap(ProcessInfo.processInfo.environment["IMAGEVIEWER_RAW_DIRECTORY"])
      let listed = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
        includingPropertiesForKeys: [.fileSizeKey])
      let candidates = listed.filter { url in
          guard url.pathExtension.lowercased() == "dng" else { return false }
          let values = try? url.resourceValues(forKeys: [.fileSizeKey])
          return (values?.fileSize ?? 0) > 0
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
      source = try XCTUnwrap(candidates.first)
    } else {
      let context = try XCTUnwrap(CGContext(data: nil,width: 640,height: 480,bitsPerComponent: 8,
        bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
      context.setFillColor(CGColor(red: 0.2,green: 0.55,blue: 0.7,alpha: 1))
      context.fill(CGRect(x: 0,y: 0,width: 640,height: 480))
      let image = try XCTUnwrap(context.makeImage())
      let count = condition == "photo1" ? 1 : 20
      for index in 0..<count {
        let url = photos.appendingPathComponent("photo\(index).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
      }
      source = photos
    }
    let originalVersion = ImageFileVersion(url: source)
    let store = AppStore(defaults: defaults, monitorsSystemResources: true,
      photoMarkDatabaseURL: root.appendingPathComponent("marks.sqlite"), thumbnailDiskCache: nil)
    await store.photoMarks.waitUntilReady()
    let application = NSApplication.shared
    let previousPolicy = application.activationPolicy()
    let previousApp = NSWorkspace.shared.frontmostApplication
    application.setActivationPolicy(.regular)
    let host = NSHostingView(rootView: ViewerCanvas(store: store,shortcuts: ShortcutStore(defaults: defaults)))
    let window = NSWindow(contentRect: NSRect(x: 120,y: 120,width: 1000,height: 720),
      styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
    window.title = "알맹Re 성능 검증"
    window.isReleasedWhenClosed = false; window.contentView = host
    window.makeKeyAndOrderFront(nil); application.activate(ignoringOtherApps: true)
    defer {
      window.orderOut(nil); window.contentView = nil; window.close()
      application.setActivationPolicy(previousPolicy)
      if previousApp?.processIdentifier != getpid() { previousApp?.activate(options: [.activateIgnoringOtherApps]) }
    }
    try await wait("activation") {
      window.occlusionState.contains(.visible) && application.isActive
        && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
    }
    let start = ProcessInfo.processInfo.systemUptime
    store.open(urls: [source])
    try await wait("first_frame") {
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
      guard !store.isLoading, let asset = store.currentAsset else { return false }
      return store.viewerPresentedAssets[0] == AppStore.PresentedAssetVersion(asset)
    }
    let elapsed = ProcessInfo.processInfo.systemUptime-start
    let stillForeground = application.isActive && window.occlusionState.contains(.visible)
      && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
    XCTAssertTrue(stillForeground)
    XCTAssertEqual(ImageFileVersion(url: source), originalVersion)
    let report: [String: Any] = ["condition":condition,"libraryAssets":store.assets.count,
      "firstAcceptedFrameSeconds":elapsed,"foregroundVerified":stillForeground,
      "sourceMetadataUnchanged":true,"physicalMemoryBytes":ProcessInfo.processInfo.physicalMemory,
      "measurement":"fresh store and image caches; native visible accepted frame; excludes GPU counters and cold OS cache claims"]
    try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys])
      .write(to: output.appendingPathComponent("native-\(condition).json"))
  }

  private func wait(_ phase: String, _ predicate: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 30
    while !predicate() {
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw FoundationNativeFailure.deadline(phase) }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

final class FoundationNativeHostTests: XCTestCase {
  func testForegroundFirstFrames() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["IMAGEVIEWER_FOUNDATION_NATIVE"] == "1")
    try MainActor.assumeIsolated {
      try XCTSkipUnless(NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow",
        "Mac screen is locked; foreground acceptance must be run after unlocking")
      let app = NSApplication.shared
      guard !app.isRunning else { throw FoundationNativeFailure.alreadyRunning }
      let oldDelegate = app.delegate, oldPolicy = app.activationPolicy()
      let oldFrontmost = NSWorkspace.shared.frontmostApplication
      let delegate = FoundationNativeDelegate()
      app.delegate = delegate; app.setActivationPolicy(.regular)
      defer {
        delegate.watchdog?.invalidate()
        app.delegate = oldDelegate; app.setActivationPolicy(oldPolicy)
        if oldFrontmost?.processIdentifier != getpid() { oldFrontmost?.activate(options: [.activateIgnoringOtherApps]) }
      }
      app.run()
      try XCTUnwrap(delegate.outcome).get()
    }
  }
}

private enum FoundationNativeFailure: Error { case deadline(String), alreadyRunning }
@MainActor
private final class FoundationNativeDelegate: NSObject, NSApplicationDelegate {
  var outcome: Result<Void, any Error>?
  var watchdog: Timer?
  private var work: Task<Void,Never>?
  func applicationDidFinishLaunching(_ notification: Notification) {
    let timer = Timer(timeInterval: 180,target: self,selector: #selector(expired),userInfo: nil,repeats: false)
    watchdog = timer; RunLoop.main.add(timer,forMode: .common)
    work = Task {
      do {
        for condition in ["photo1","photo20","raw1"] {
          try await FoundationNativeWorkloadTests().firstAcceptedFrame(condition: condition)
          FileHandle.standardOutput.write(Data("FOUNDATION_NATIVE completed=\(condition)\n".utf8))
        }
        finish(.success(()))
      } catch { finish(.failure(error)) }
    }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateCancel }
  @objc private func expired() { work?.cancel(); finish(.failure(FoundationNativeFailure.deadline("watchdog"))) }
  private func finish(_ result: Result<Void, any Error>) {
    guard outcome == nil else { return }; outcome = result
    watchdog?.invalidate(); NSApp.stop(nil)
    if let event = NSEvent.otherEvent(with: .applicationDefined,location: .zero,modifierFlags: [],timestamp: 0,
      windowNumber: 0,context: nil,subtype: 0,data1: 0,data2: 0) { NSApp.postEvent(event,atStart: false) }
  }
}
