import Foundation
import Testing

@testable import ImageViewer

@Suite("실제 앱 수동 QA의 사용자 상태 격리", .serialized)
@MainActor
struct ManualViewerQAIsolationTests {
  @Test("명시하지 않으면 컨텍스트가 없고 잘못된 명시는 사용자 설정으로 넘어가지 않는다")
  func explicitOnly() throws {
    #expect(try ManualViewerQAContext.makeFromEnvironment([:]) == nil)
    #expect(throws: (any Error).self) {
      try ManualViewerQAContext.makeFromEnvironment(["IMAGEVIEWER_MANUAL_QA": "1"])
    }
  }

  @Test("사진 폴더와 겹치는 출력은 거부하고 새 출력은 설정·분류·캐시를 격리한다")
  func isolatedContext() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("ManualViewerQA.\(UUID())")
    let source = base.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    var env = ["IMAGEVIEWER_MANUAL_QA": "1", "IMAGEVIEWER_MANUAL_QA_SOURCE": source.path,
      "IMAGEVIEWER_MANUAL_QA_OUTPUT": source.appendingPathComponent("unsafe").path]
    #expect(throws: (any Error).self) { try ManualViewerQAContext.makeFromEnvironment(env) }
    env["IMAGEVIEWER_MANUAL_QA_OUTPUT"] = base.appendingPathComponent("isolated").path
    let created = try ManualViewerQAContext.makeFromEnvironment(env)
    let context = try #require(created)
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
    await context.store.photoMarks.waitUntilReady()
    let sentinel = "ManualViewerQAIsolation.\(UUID())"
    #expect(UserDefaults.standard.object(forKey: sentinel) == nil)
    context.defaults.set(true, forKey: sentinel)
    #expect(UserDefaults.standard.object(forKey: sentinel) == nil)
    let persistedLanguage = UserDefaults.standard.string(forKey: LanguageStore.defaultsKey)
    let previousLanguage = AppLanguagePreference.shared.selection
    defer { AppLanguagePreference.shared.selection = previousLanguage }
    let language = context.makeLanguageStore()
    language.selection = "ar"
    #expect(AppLanguagePreference.shared.selection == "ar")
    #expect(L10n.languageIdentifier == "ar")
    #expect(L10n.text("cache.diskUsage") == L10n.text("cache.diskUsage", localeIdentifier: "ar"))
    #expect(context.defaults.string(forKey: LanguageStore.defaultsKey) == "ar")
    #expect(UserDefaults.standard.string(forKey: LanguageStore.defaultsKey) == persistedLanguage)
    #expect(context.store.photoMarks.storageURL.path.hasPrefix(
      base.appendingPathComponent("isolated/runtime").resolvingSymlinksInPath().path))
    #expect(throws: (any Error).self) { try ManualViewerQAContext.makeFromEnvironment(env) }
  }
}
