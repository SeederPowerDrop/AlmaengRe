import AppKit
import Foundation
import XCTest

/// Run only this synchronous XCTest entry for the opt-in native workload.
/// NSApplication.run owns AppKit's real event loop while its delegate's async
/// task drives the benchmark. Swift Testing's async-main drain never hosts it.
final class RealRAWOverviewNativeHostTests: XCTestCase {
  func testPreparedNativeRoundTrip() throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(environment["IMAGEVIEWER_RAW_OVERVIEW_FULL"] == "1"
      && environment["IMAGEVIEWER_FULL_APPKIT_HOST"] == "1",
      "Opt in with IMAGEVIEWER_RAW_OVERVIEW_FULL=1 IMAGEVIEWER_FULL_APPKIT_HOST=1")
    guard Thread.isMainThread else {
      XCTFail("The synchronous native AppKit host must run on the main thread")
      return
    }
    try MainActor.assumeIsolated {
      let application = NSApplication.shared
      guard !application.isRunning else { throw FullOverviewNativeHostFailure.applicationAlreadyRunning }
      let previousDelegate = application.delegate
      let previousPolicy = application.activationPolicy()
      let delegate = FullOverviewNativeHostDelegate()
      application.delegate = delegate
      _ = application.setActivationPolicy(.regular)
      defer {
        delegate.cancelWatchdog()
        application.delegate = previousDelegate
        _ = application.setActivationPolicy(previousPolicy)
      }
      hostLog("RAW_OVERVIEW_NATIVE_HOST starting synchronous_NSApplication_run=true")
      application.run()
      guard let outcome = delegate.outcome else { throw FullOverviewNativeHostFailure.runReturnedWithoutOutcome }
      try outcome.get()
      try Self.validateFinalReport(environment: environment)
      hostLog("RAW_OVERVIEW_NATIVE_HOST validated_final_report=true completed=true")
    }
  }

  private static func validateFinalReport(environment: [String: String]) throws {
    let path = try XCTUnwrap(environment["IMAGEVIEWER_FULL_OVERVIEW_OUTPUT"],
      "An explicit output directory is required to validate completion")
    let reportURL = URL(fileURLWithPath: path, isDirectory: true)
      .appendingPathComponent("full-folder-report.json")
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL))
    let report = try XCTUnwrap(object as? [String: Any])
    XCTAssertEqual(report["status"] as? String, "completed")
    XCTAssertEqual(report["foregroundValidationComplete"] as? Bool, true)
    XCTAssertEqual(report["sourceMetadataUnchanged"] as? Bool, true)
    let sources = try XCTUnwrap(report["sources"] as? [String: Any])
    XCTAssertEqual((sources["total"] as? NSNumber)?.intValue, 729)
    XCTAssertEqual((sources["nonempty"] as? NSNumber)?.intValue, 717)
    let preparation = try XCTUnwrap(report["afterPreparation"] as? [String: Any])
    XCTAssertEqual((preparation["previewCoveredAssets"] as? NSNumber)?.intValue, 717)
    let scrolls = try XCTUnwrap(report["scrolls"] as? [[String: Any]])
    XCTAssertEqual(scrolls.count, 2)
    for scroll in scrolls {
      XCTAssertEqual((scroll["uniqueVisibleCount"] as? NSNumber)?.intValue, 729)
      XCTAssertEqual((scroll["cacheFirstPixelMisses"] as? NSNumber)?.intValue, 0)
      let actualUI = try XCTUnwrap(scroll["actualUICachedPreview"] as? [String: Any])
      XCTAssertEqual((actualUI["uncancelledMisses"] as? NSNumber)?.intValue, 0)
      XCTAssertGreaterThan((actualUI["eligibleRecordedRequests"] as? NSNumber)?.intValue ?? 0, 0)
      XCTAssertGreaterThan((actualUI["uncancelledHits"] as? NSNumber)?.intValue ?? 0, 0)
      XCTAssertEqual(actualUI["ledgerMayHaveReachedLimit"] as? Bool, false)
    }
  }
}

@MainActor
private final class FullOverviewNativeHostDelegate: NSObject, NSApplicationDelegate {
  private(set) var outcome: Result<Void, any Error>?
  private var task: Task<Void, Never>?
  private var watchdog: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let timer = Timer(timeInterval: 21 * 60, target: self,
      selector: #selector(watchdogExpired(_:)), userInfo: nil, repeats: false)
    watchdog = timer
    RunLoop.main.add(timer, forMode: .common)
    task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await RealRAWOverviewFullFolderTests().fullFolderPreparationAndNativeRevisit()
        finish(.success(()))
      } catch { finish(.failure(error)) }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    .terminateCancel
  }

  func cancelWatchdog() {
    watchdog?.invalidate()
    watchdog = nil
  }

  @objc private func watchdogExpired(_ timer: Timer) {
    task?.cancel()
    finish(.failure(FullOverviewNativeHostFailure.watchdogExpired))
  }

  private func finish(_ result: Result<Void, any Error>) {
    guard outcome == nil else { return }
    outcome = result
    cancelWatchdog()
    NSApp.stop(nil)
    if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
      NSApp.postEvent(wake, atStart: false)
    }
  }
}

private enum FullOverviewNativeHostFailure: Error {
  case applicationAlreadyRunning
  case runReturnedWithoutOutcome
  case watchdogExpired
}

private func hostLog(_ text: String) {
  FileHandle.standardOutput.write(Data((text + "\n").utf8))
}
