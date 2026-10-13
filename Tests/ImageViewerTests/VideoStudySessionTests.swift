import Foundation
import Testing

@testable import ImageViewer

@Suite("영상의 두 자막과 학습 설정 수명", .serialized)
@MainActor
struct VideoStudySessionTests {
  @Test("두 자막은 트랙·동기화·표시·서식을 독립적으로 유지한다")
  func independentSubtitleSlots() async throws {
    let video = URL(fileURLWithPath: "/synthetic/lesson.mp4")
    let session = VideoStudySession(videoURL: video, loader: { url in Self.document(url) })
    session.primary.load(url: video.deletingPathExtension().appendingPathExtension("smi"))
    session.secondary.load(url: video.deletingPathExtension().appendingPathExtension("srt"))
    try await waitUntil { !session.primary.isLoading && !session.secondary.isLoading }

    #expect(session.primary.text(at: 1.5) == "English")
    session.primary.trackID = "ko"
    #expect(session.primary.text(at: 1.5) == "한국어")
    #expect(session.secondary.text(at: 1.5) == "English")
    session.primary.offsetSeconds = 2
    #expect(session.primary.text(at: 1.5) == nil)
    #expect(session.primary.text(at: 3.5) == "한국어")
    session.secondary.offsetSeconds = -0.5
    #expect(session.secondary.text(at: 0.75) == "English")
    session.primary.fontName = "Menlo"
    session.primary.fontSize = 42
    session.primary.horizontalPosition = 0.25
    session.primary.verticalPosition = 0.3
    #expect(session.secondary.fontName.isEmpty && session.secondary.fontSize == 24)
    #expect(session.secondary.horizontalPosition == 0.5 && session.secondary.verticalPosition == 0.72)

    session.primary.isEnabled = false
    #expect(session.primary.text(at: 3.5) == nil)
    #expect(session.secondary.text(at: 1.5) == "English")
    session.primary.isEnabled = true
    #expect(session.primary.text(at: 3.5) == "한국어")
    #expect(session.primary.text(at: .nan) == nil)
    #expect(session.primary.text(at: .infinity) == nil)
  }

  @Test("늦게 끝난 이전 자막과 제거한 자막이 다시 나타나지 않는다")
  func replacedAndRemovedLoadsCannotReappear() async throws {
    let gate = SubtitleLoadGate()
    let slot = VideoSubtitleSlot(id: .primary) { try await gate.load($0) }
    let old = URL(fileURLWithPath: "/synthetic/old.srt")
    let new = URL(fileURLWithPath: "/synthetic/new.srt")
    slot.load(url: old)
    try await gate.waitForRequest(old)
    slot.load(url: new)
    try await gate.waitForRequest(new)
    await gate.finish(new, document: Self.document(new))
    try await waitUntil { slot.document?.sourceURL == new }
    await gate.finish(old, document: Self.document(old))
    for _ in 0..<5 { await Task.yield() }
    #expect(slot.document?.sourceURL == new && slot.sourceURL == new)
    #expect(slot.errorMessage == nil && !slot.isLoading)

    slot.load(url: old)
    try await gate.waitForRequest(old)
    slot.remove()
    await gate.finish(old, document: Self.document(old))
    for _ in 0..<5 { await Task.yield() }
    #expect(slot.document == nil && slot.sourceURL == nil && slot.trackID == nil)
    #expect(!slot.isEnabled && !slot.isLoading && slot.errorMessage == nil)
  }

  @Test("메모리 세션은 같은 영상에서 공유하고 오래된 항목만 제한 수 안에서 비운다")
  func registryIsSharedAndBounded() {
    let registry = VideoStudySessionRegistry(capacity: 2)
    let firstURL = URL(fileURLWithPath: "/synthetic/first.mp4")
    let first = registry.session(for: firstURL)
    first.playbackRate = 1.75
    first.primary.offsetSeconds = 0.75
    let same = registry.session(for: URL(fileURLWithPath: "/synthetic/./first.mp4"))
    #expect(same === first && same.playbackRate == 1.75 && same.primary.offsetSeconds == 0.75)
    let secondURL = URL(fileURLWithPath: "/synthetic/second.mp4")
    let second = registry.session(for: secondURL)
    #expect(registry.cachedSessionCount == 2)
    _ = registry.session(for: firstURL) // first becomes the most recently used.
    second.primary.load(url: URL(fileURLWithPath: "/synthetic/missing.srt"))
    #expect(second.primary.isLoading)
    _ = registry.session(for: URL(fileURLWithPath: "/synthetic/third.mp4"))
    #expect(registry.cachedSessionCount == 2)
    #expect(second.primary.isLoading) // A live view's work survives cache eviction.
    #expect(registry.session(for: firstURL) === first)
    #expect(registry.session(for: secondURL) === second)
    second.primary.remove()

    weak var unowned: VideoStudySession?
    do {
      let session = registry.session(for: URL(fileURLWithPath: "/synthetic/unowned.mp4"))
      unowned = session
    }
    _ = registry.session(for: firstURL)
    _ = registry.session(for: secondURL)
    #expect(unowned == nil)

    let maximum = VideoStudySessionRegistry(capacity: 100)
    for index in 0..<12 {
      _ = maximum.session(for: URL(fileURLWithPath: "/synthetic/\(index).mp4"))
    }
    #expect(maximum.cachedSessionCount == 8)
  }

  @Test("8개를 넘겨도 화면이 보유한 영상의 전체 화면은 같은 자막·속도를 사용한다")
  func liveSessionKeepsIdentityBeyondRecentLimit() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-live-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let subtitle = folder.appendingPathComponent("lesson.ko.srt")
    try Data("1\n00:00:01,000 --> 00:00:03,000\n보존되는 자막\n".utf8).write(to: subtitle)
    let video = folder.appendingPathComponent("lesson.mp4")
    let registry = VideoStudySessionRegistry()
    let visibleSession = registry.session(for: video)
    visibleSession.playbackRate = 1.75
    visibleSession.primary.offsetSeconds = 0.5
    visibleSession.primary.fontSize = 36
    visibleSession.primary.load(url: subtitle)
    try await waitUntil { !visibleSession.primary.isLoading }
    try #require(visibleSession.primary.document != nil)
    for index in 0..<9 {
      _ = registry.session(for: folder.appendingPathComponent("other-\(index).mp4"))
    }
    #expect(registry.cachedSessionCount == 8)
    let fullScreenSession = registry.session(for: video)
    #expect(fullScreenSession === visibleSession)
    #expect(fullScreenSession.playbackRate == 1.75)
    #expect(fullScreenSession.primary.fontSize == 36 && fullScreenSession.primary.offsetSeconds == 0.5)
    #expect(fullScreenSession.primary.sourceURL == subtitle)
    #expect(fullScreenSession.primary.text(at: 2) == "보존되는 자막")
    #expect(registry.cachedSessionCount == 8)
  }

  @Test("유효하지 않은 재생 속도·자막 위치·크기가 화면 상태로 전파되지 않는다")
  func boundsAndFiniteValues() {
    let session = VideoStudySession(videoURL: URL(fileURLWithPath: "/synthetic/lesson.mp4"))
    session.playbackRate = 9
    #expect(session.playbackRate == 4)
    session.playbackRate = -1
    #expect(session.playbackRate == 0.25)
    session.playbackRate = .nan
    #expect(session.playbackRate == 1)
    session.primary.offsetSeconds = .infinity
    session.primary.horizontalPosition = 2
    session.primary.verticalPosition = -.infinity
    session.primary.fontSize = 1
    #expect(session.primary.offsetSeconds == 0 && session.primary.horizontalPosition == 1)
    #expect(session.primary.verticalPosition == 0.84 && session.primary.fontSize == 12)
    session.secondary.horizontalPosition = .nan
    session.secondary.verticalPosition = -1
    session.secondary.fontSize = .nan
    #expect(session.secondary.horizontalPosition == 0.5 && session.secondary.verticalPosition == 0)
    #expect(session.secondary.fontSize == 24)
  }

  @Test("같은 전체 이름과 언어 접미사의 자막만 제안하고 비슷한 다른 영상은 제외한다")
  func strictSidecarMatching() {
    let video = URL(fileURLWithPath: "/synthetic/Lesson 01.mp4")
    for name in ["Lesson 01.srt", "lesson 01.ko.srt", "Lesson 01_eng.SRT", "Lesson 01.en-US.vtt",
      "Lesson 01.zh-Hant-TW.smi", "Lesson 01 [한국어].srt", "Lesson 01.ko.forced.srt",
      "Lesson 01.en.sdh.srt", "Lesson 01.kor.sami"] {
      #expect(VideoSubtitleSidecars.matches(URL(fileURLWithPath: name), videoURL: video), "\(name)")
    }
    for name in ["Lesson 010.srt", "Lesson 01extra.srt", "Lesson 01-other.srt",
      "Lesson 01.en.copy.srt", "Lesson 01.en.draft.srt", "Lesson 01..srt", "Lesson 01.srt.zip",
      "Lesson 02.en.srt", "Lesson 01.en.png"] {
      #expect(!VideoSubtitleSidecars.matches(URL(fileURLWithPath: name), videoURL: video), "\(name)")
    }
  }

  @Test("폴더 제안은 일반 파일만 찾고 제안 요청만으로 자막 내용을 읽지 않는다")
  func explicitDiscoveryAndReadOnlyLoad() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-session-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let subtitle = folder.appendingPathComponent("lesson.ko.srt")
    let data = Data("1\n00:00:01,000 --> 00:00:03,000\n안녕하세요\n".utf8)
    try data.write(to: subtitle)
    try data.write(to: folder.appendingPathComponent("lesson10.en.srt"))
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("lesson.en.srt"),
      withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("lesson.ja.srt"),
      withDestinationURL: subtitle)
    let session = VideoStudySession(videoURL: folder.appendingPathComponent("lesson.mp4"))
    #expect(session.sidecarURLs.isEmpty && !session.isDiscovering)
    #expect(session.primary.document == nil && session.secondary.document == nil)
    await session.discoverSidecars()
    #expect(session.sidecarURLs.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
      == [subtitle.standardizedFileURL.resolvingSymlinksInPath()])
    #expect(!session.isDiscovering && session.sidecarErrorMessage == nil)
    #expect(session.primary.document == nil && session.secondary.document == nil)
    session.primary.load(url: subtitle)
    try await waitUntil { !session.primary.isLoading }
    #expect(session.primary.errorMessage == nil)
    #expect(session.primary.text(at: 1.5) == "안녕하세요")
    #expect(session.secondary.document == nil)
    #expect(try Data(contentsOf: subtitle) == data)

    session.primary.load(url: folder.appendingPathComponent("missing.srt"))
    try await waitUntil { !session.primary.isLoading }
    #expect(session.primary.document == nil && session.primary.errorMessage != nil)
    session.primary.load(url: subtitle)
    try await waitUntil { !session.primary.isLoading }
    #expect(session.primary.errorMessage == nil && session.primary.text(at: 1.5) == "안녕하세요")
  }

  @Test("자동 자막은 재생 요청 때만 시작하고 앱 언어와 다른 언어를 한 번씩 연결한다")
  func automaticSelectionUsesAppLanguageAndDeduplicatesFormats() async throws {
    let video = URL(fileURLWithPath: "/synthetic/lesson.mp4")
    let candidates = ["lesson.en.srt", "lesson.ko.vtt", "lesson.kor.srt", "lesson10.en.srt"]
      .map { video.deletingLastPathComponent().appendingPathComponent($0) }
    let counter = SubtitleReadCounter()
    let session = VideoStudySession(videoURL: video, preferredLanguage: "ko-KR",
      discoverer: { _ in candidates }, loader: { url in
        await counter.record(url)
        return Self.singleTrackDocument(url)
      })
    #expect(await counter.urls.isEmpty)
    #expect(!session.isDiscovering && !session.isPreparingAutomaticSubtitles)
    #expect(session.primary.document == nil && session.secondary.document == nil)
    session.prepareAutomaticSubtitles()
    try await waitUntil { !session.isPreparingAutomaticSubtitles }
    #expect(session.primary.sourceURL?.lastPathComponent == "lesson.kor.srt")
    #expect(session.secondary.sourceURL?.lastPathComponent == "lesson.en.srt")
    #expect(session.primary.isEnabled && session.secondary.isEnabled)
    #expect(await counter.urls.count == 2)
    session.prepareAutomaticSubtitles()
    await session.discoverSidecars()
    #expect(await counter.urls.count == 2)

    let englishSession = VideoStudySession(videoURL: video, preferredLanguage: "en",
      discoverer: { _ in candidates }, loader: Self.singleTrackDocument)
    englishSession.prepareAutomaticSubtitles()
    try await waitUntil { !englishSession.isPreparingAutomaticSubtitles }
    #expect(englishSession.primary.sourceURL?.lastPathComponent == "lesson.en.srt")
    #expect(englishSession.secondary.sourceURL?.lastPathComponent == "lesson.kor.srt")
  }

  @Test("동명 자막은 우선 연결하고 한 SMI의 두 언어도 중복 읽기 없이 선택한다")
  func exactStemAndMultilingualSAMI() async throws {
    let video = URL(fileURLWithPath: "/synthetic/lesson.mp4")
    let exact = video.deletingPathExtension().appendingPathExtension("srt")
    let english = video.deletingLastPathComponent().appendingPathComponent("lesson.en.srt")
    let session = VideoStudySession(videoURL: video, preferredLanguage: "ko",
      discoverer: { _ in [english, exact] }, loader: Self.singleTrackDocument)
    session.prepareAutomaticSubtitles()
    try await waitUntil { !session.isPreparingAutomaticSubtitles }
    #expect(session.primary.sourceURL == exact && session.secondary.sourceURL == english)

    let sami = video.deletingPathExtension().appendingPathExtension("smi")
    let counter = SubtitleReadCounter()
    let bilingual = VideoStudySession(videoURL: video, preferredLanguage: "ko",
      discoverer: { _ in [sami] }, loader: { url in
        await counter.record(url)
        return SubtitleDocument(sourceURL: url, tracks: [
          SubtitleTrack(id: "encc", name: "English", cues: [SubtitleCue(start: 1, end: 3, text: "English")]),
          SubtitleTrack(id: "krcc", name: "한국어", cues: [SubtitleCue(start: 1, end: 3, text: "한국어")]),
        ])
      })
    bilingual.prepareAutomaticSubtitles()
    try await waitUntil { !bilingual.isPreparingAutomaticSubtitles }
    #expect(bilingual.primary.text(at: 1.5) == "한국어")
    #expect(bilingual.secondary.text(at: 1.5) == "English")
    #expect(bilingual.primary.sourceURL == sami && bilingual.secondary.sourceURL == sami)
    #expect(await counter.urls == [sami])
  }

  @Test("동시 재생·설정 요청과 반복 팝오버 열기는 같은 발견 작업과 캐시를 쓴다")
  func discoveryCoalescesAndCaches() async throws {
    let video = URL(fileURLWithPath: "/synthetic/lesson.mp4")
    let gate = SubtitleDiscoveryGate()
    let session = VideoStudySession(videoURL: video, discoverer: { try await gate.discover($0) })
    #expect(await gate.requestCount == 0)
    session.prepareAutomaticSubtitles()
    session.prepareAutomaticSubtitles()
    try await gate.waitForRequests(1)
    let popup = Task { await session.discoverSidecars() }
    for _ in 0..<5 { await Task.yield() }
    #expect(await gate.requestCount == 1)
    await gate.finishNext(with: [])
    await popup.value
    try await waitUntil { !session.isPreparingAutomaticSubtitles }
    await session.discoverSidecars()
    session.prepareAutomaticSubtitles()
    #expect(await gate.requestCount == 1)
    let refresh = Task { await session.discoverSidecars(forceRefresh: true) }
    try await gate.waitForRequests(2)
    await gate.finishNext(with: [])
    await refresh.value
    #expect(await gate.requestCount == 2)
  }

  @Test("발견 도중 끄거나 제거한 자막은 자동으로 다시 켜지지 않는다")
  func disablingDuringDiscoveryPreventsAutomaticLoad() async throws {
    let video = URL(fileURLWithPath: "/synthetic/lesson.mp4")
    let gate = SubtitleDiscoveryGate()
    let reads = SubtitleReadCounter()
    let session = VideoStudySession(videoURL: video, discoverer: { try await gate.discover($0) },
      loader: { url in await reads.record(url); return Self.document(url) })
    session.prepareAutomaticSubtitles()
    try await gate.waitForRequests(1)
    session.primary.isEnabled = false
    session.secondary.remove()
    await gate.finishNext(with: [video.deletingPathExtension().appendingPathExtension("smi")])
    try await waitUntil { !session.isPreparingAutomaticSubtitles }
    #expect(await reads.urls.isEmpty)
    #expect(!session.primary.isEnabled && !session.secondary.isEnabled)
    #expect(session.primary.document == nil && session.secondary.document == nil)
    session.prepareAutomaticSubtitles()
    #expect(await gate.requestCount == 1)
  }

  @Test("자동 파싱 도중 고른 수동 자막과 꺼 둔 상태를 늦은 작업이 덮어쓰지 않는다")
  func manualSelectionAndDisabledStateWinOverPendingLoad() async throws {
    let video = URL(fileURLWithPath: "/synthetic/lesson.mp4")
    let automatic = video.deletingLastPathComponent().appendingPathComponent("lesson.ko.srt")
    let manual = video.deletingLastPathComponent().appendingPathComponent("my-choice.srt")
    let gate = SubtitleLoadGate()
    let session = VideoStudySession(videoURL: video, preferredLanguage: "ko",
      discoverer: { _ in [automatic] }, loader: { try await gate.load($0) })
    session.prepareAutomaticSubtitles()
    try await gate.waitForRequest(automatic)
    session.primary.load(url: manual)
    try await gate.waitForRequest(manual)
    session.primary.isEnabled = false
    session.secondary.remove()
    await gate.finish(manual, document: Self.singleTrackDocument(manual))
    try await waitUntil { !session.primary.isLoading }
    await gate.finish(automatic, document: Self.singleTrackDocument(automatic))
    try await waitUntil { !session.isPreparingAutomaticSubtitles }
    #expect(session.primary.sourceURL == manual && session.primary.document?.sourceURL == manual)
    #expect(!session.primary.isEnabled && !session.secondary.isEnabled)
    #expect(session.secondary.document == nil)
  }

  @Test("취소한 발견과 자동 읽기의 늦은 완료는 재시도한 세션을 오염시키지 않는다")
  func cancellationAndRetryRejectLateWork() async throws {
    let video = URL(fileURLWithPath: "/synthetic/lesson.mp4")
    let subtitle = video.deletingLastPathComponent().appendingPathComponent("lesson.ko.srt")
    let discovery = SubtitleDiscoveryGate()
    let loads = SubtitleLoadGate()
    let session = VideoStudySession(videoURL: video, preferredLanguage: "ko",
      discoverer: { try await discovery.discover($0) }, loader: { try await loads.load($0) })
    session.prepareAutomaticSubtitles()
    try await discovery.waitForRequests(1)
    session.cancelPendingWork()
    session.prepareAutomaticSubtitles()
    try await discovery.waitForRequests(2)
    await discovery.finishNext(with: []) // Canceled generation finishes after its replacement started.
    for _ in 0..<5 { await Task.yield() }
    #expect(session.isPreparingAutomaticSubtitles && session.isDiscovering)
    await discovery.finishNext(with: [subtitle])
    try await loads.waitForRequest(subtitle)
    session.cancelPendingWork()
    session.prepareAutomaticSubtitles()
    try await loads.waitForRequest(subtitle, count: 2)
    await loads.finish(subtitle, document: Self.singleTrackDocument(subtitle, text: "stale"))
    for _ in 0..<5 { await Task.yield() }
    #expect(session.primary.document == nil && session.isPreparingAutomaticSubtitles)
    await loads.finish(subtitle, document: Self.singleTrackDocument(subtitle, text: "current"))
    try await waitUntil { !session.isPreparingAutomaticSubtitles }
    #expect(session.primary.text(at: 1.5) == "current")
    #expect(await discovery.requestCount == 2) // Completed discovery is reused after parse cancellation.
  }

  @Test("잘못된 선호 자막 형식은 같은 언어의 다른 형식으로 복구한다")
  func invalidSidecarFallsBackToAnotherFormat() async throws {
    let video = URL(fileURLWithPath: "/synthetic/lesson.mp4")
    let broken = video.deletingLastPathComponent().appendingPathComponent("lesson.ko.srt")
    let fallback = video.deletingLastPathComponent().appendingPathComponent("lesson.ko.vtt")
    let session = VideoStudySession(videoURL: video, preferredLanguage: "ko",
      discoverer: { _ in [broken, fallback] }, loader: { url in
        if url == broken { throw CocoaError(.fileReadCorruptFile) }
        return Self.singleTrackDocument(url)
      })
    session.prepareAutomaticSubtitles()
    try await waitUntil { !session.isPreparingAutomaticSubtitles }
    #expect(session.primary.sourceURL == fallback && session.primary.isEnabled)
    #expect(session.secondary.document == nil)
    #expect(session.sidecarErrorMessage == nil)
  }

  private nonisolated static func singleTrackDocument(_ url: URL) -> SubtitleDocument {
    singleTrackDocument(url, text: url.lastPathComponent)
  }

  private nonisolated static func singleTrackDocument(_ url: URL, text: String) -> SubtitleDocument {
    SubtitleDocument(sourceURL: url, tracks: [
      SubtitleTrack(id: "default", name: "", cues: [SubtitleCue(start: 1, end: 3, text: text)]),
    ])
  }

  private nonisolated static func document(_ url: URL) -> SubtitleDocument {
    SubtitleDocument(sourceURL: url, tracks: [
      SubtitleTrack(id: "en", name: "English", cues: [SubtitleCue(start: 1, end: 3, text: "English")]),
      SubtitleTrack(id: "ko", name: "한국어", cues: [SubtitleCue(start: 1, end: 3, text: "한국어")]),
    ])
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(predicate(), "Subtitle session did not finish the expected transition")
  }
}

private actor SubtitleLoadGate {
  private var requests: [URL: [CheckedContinuation<SubtitleDocument, Error>]] = [:]

  func load(_ url: URL) async throws -> SubtitleDocument {
    try await withCheckedThrowingContinuation { requests[url, default: []].append($0) }
  }

  func waitForRequest(_ url: URL, count: Int = 1) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while (requests[url]?.count ?? 0) < count, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require((requests[url]?.count ?? 0) >= count, "Subtitle load did not start")
  }

  func finish(_ url: URL, document: SubtitleDocument) {
    guard requests[url]?.isEmpty == false else { return }
    requests[url]?.removeFirst().resume(returning: document)
  }
}

private actor SubtitleReadCounter {
  private(set) var urls: [URL] = []
  func record(_ url: URL) { urls.append(url) }
}

private actor SubtitleDiscoveryGate {
  private(set) var requestCount = 0
  private var requests: [CheckedContinuation<[URL], Error>] = []

  func discover(_ url: URL) async throws -> [URL] {
    requestCount += 1
    return try await withCheckedThrowingContinuation { requests.append($0) }
  }

  func waitForRequests(_ count: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while requestCount < count, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(requestCount >= count, "Subtitle discovery did not start")
  }

  func finishNext(with urls: [URL]) {
    guard !requests.isEmpty else { return }
    requests.removeFirst().resume(returning: urls)
  }
}
