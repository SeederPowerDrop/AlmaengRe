import CryptoKit
import Darwin
import Foundation

@MainActor
final class ManualViewerQAContext {
  private enum SetupFailure: Error { case configuration, paths, output, runtime }
  static let active: ManualViewerQAContext? = {
    do { return try makeFromEnvironment() }
    catch { FileHandle.standardError.write(Data("MANUAL_QA setup_failed\n".utf8)); exit(2) }
  }()
  let defaults: UserDefaults
  let store: AppStore
  let suiteName: String
  private let source: URL
  private let output: URL
  private var started = false

  static func makeFromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ManualViewerQAContext? {
    guard environment["IMAGEVIEWER_MANUAL_QA"] != nil else { return nil }
    guard environment["IMAGEVIEWER_MANUAL_QA"] == "1",
      let input = environment["IMAGEVIEWER_MANUAL_QA_SOURCE"], input.hasPrefix("/"),
      let destination = environment["IMAGEVIEWER_MANUAL_QA_OUTPUT"], destination.hasPrefix("/") else { throw SetupFailure.configuration }
    let source = URL(fileURLWithPath: input, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let output = URL(fileURLWithPath: destination, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    guard (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
      !output.pathComponents.starts(with: source.pathComponents), !source.pathComponents.starts(with: output.pathComponents),
      (try? output.deletingLastPathComponent().resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true
      else { throw SetupFailure.paths }
    let suiteName = "ImageViewer.ManualQA.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName)
      else { throw SetupFailure.configuration }
    guard mkdir(output.path, 0o700) == 0 else { throw SetupFailure.output }
    guard mkdir(output.appendingPathComponent("runtime").path, 0o700) == 0 else { throw SetupFailure.runtime }
    return ManualViewerQAContext(source: source, output: output, defaults: defaults, suiteName: suiteName)
  }

  private init(source: URL, output: URL, defaults: UserDefaults, suiteName: String) {
    self.source = source; self.output = output; self.defaults = defaults; self.suiteName = suiteName
    let runtime = output.appendingPathComponent("runtime", isDirectory: true)
    store = AppStore(defaults: defaults, photoMarkDatabaseURL: runtime.appendingPathComponent("marks.sqlite"),
      thumbnailDiskCache: ThumbnailDiskCache(directory: runtime.appendingPathComponent("thumbnails")))
  }

  /// Dynamic L10n labels share the app's in-process language selection while
  /// persistence stays in this session's private defaults suite.
  func makeLanguageStore() -> LanguageStore {
    AppLanguagePreference.shared.selection = defaults.string(forKey: LanguageStore.defaultsKey)
    return LanguageStore(defaults: defaults, preference: .shared)
  }

  func start() {
    guard !started else { return }; started = true
    Task { [self] in
      guard await wait(15, until: { store.photoMarks.isReady }) else { record("marks_not_ready"); return }
      store.open(urls: [source])
      let ready = await wait(90, until: { !store.isLoading && !store.isFiltering && !store.showsHome })
      record(ready ? "ready" : "open_not_ready")
      if ready, ProcessInfo.processInfo.environment["IMAGEVIEWER_SUSTAINED_QA"] == "1" {
        let completed = await SustainedPerformanceValidation.run(store: store, output: output,
          durationSeconds: 1_800)
        record(completed ? "sustained_completed" : "sustained_failed")
      }
    }
  }
  private func wait(_ seconds: Int, until ready: () -> Bool) async -> Bool {
    for _ in 0..<(seconds * 10) { if ready() { return true }; do { try await Task.sleep(for: .milliseconds(100)) } catch { return false } }
    return ready()
  }
  private func record(_ status: String) {
    let value: [String: Any] = ["status": status, "sourceHash": SHA256.hash(data: Data(source.path.utf8)).map { String(format: "%02x", $0) }.joined(),
      "assetCount": store.allAssets.count, "videoCount": store.allAssets.filter(\.isVideo).count,
      "defaultsSuiteName": suiteName,
      "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
      "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"]
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("manual-qa-context.json"), options: .atomic) }
  }
}
