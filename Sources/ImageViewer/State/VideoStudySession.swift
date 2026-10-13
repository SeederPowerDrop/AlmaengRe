import Combine
import Foundation

enum VideoSubtitleSlotID: String, CaseIterable, Sendable {
  case primary, secondary
}

/// One independently configured subtitle surface. Positive offsets delay the
/// text: a cue at 10 seconds appears at video time 12 with an offset of +2.
@MainActor
final class VideoSubtitleSlot: ObservableObject, Identifiable {
  typealias Loader = @Sendable (URL) async throws -> SubtitleDocument

  let id: VideoSubtitleSlotID
  @Published private(set) var document: SubtitleDocument?
  @Published private(set) var sourceURL: URL?
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?
  @Published var trackID: String?
  @Published var isEnabled = true {
    didSet {
      if oldValue != isEnabled { hasUserSelection = true }
    }
  }
  @Published var offsetSeconds = 0.0 {
    didSet { if !offsetSeconds.isFinite { offsetSeconds = 0 } }
  }
  /// An empty name selects the system font; named fonts are resolved by the UI.
  @Published var fontName = ""
  @Published var fontSize = 24.0 {
    didSet {
      let value = Self.bounded(fontSize, in: 12...96, fallback: 24)
      if fontSize != value { fontSize = value }
    }
  }
  @Published var horizontalPosition = 0.5 {
    didSet {
      let value = Self.bounded(horizontalPosition, in: 0...1, fallback: 0.5)
      if horizontalPosition != value { horizontalPosition = value }
    }
  }
  @Published var verticalPosition: Double {
    didSet {
      let value = Self.bounded(verticalPosition, in: 0...1, fallback: defaultVerticalPosition)
      if verticalPosition != value { verticalPosition = value }
    }
  }

  private let loader: Loader
  private let defaultVerticalPosition: Double
  private var loadingTask: Task<Void, Never>?
  private var generation = UUID()
  private var hasUserSelection = false

  init(id: VideoSubtitleSlotID, loader: @escaping Loader = VideoStudySession.readSubtitle) {
    self.id = id
    let position = id == .primary ? 0.84 : 0.72
    verticalPosition = position
    defaultVerticalPosition = position
    self.loader = loader
  }

  var selectedTrack: SubtitleTrack? {
    guard let document else { return nil }
    return document.tracks.first { $0.id == trackID } ?? document.tracks.first
  }

  func text(at playbackSeconds: Double) -> String? {
    guard isEnabled, playbackSeconds.isFinite else { return nil }
    let subtitleSeconds = playbackSeconds - offsetSeconds
    guard subtitleSeconds.isFinite else { return nil }
    return selectedTrack?.text(at: subtitleSeconds)
  }

  func load(url: URL) {
    hasUserSelection = true
    cancelPendingLoad()
    let token = UUID()
    generation = token
    sourceURL = url
    document = nil
    trackID = nil
    errorMessage = nil
    isEnabled = true
    isLoading = true
    let loader = loader
    loadingTask = Task { [weak self] in
      do {
        let document = try await loader(url)
        try Task.checkCancellation()
        guard let self, self.generation == token else { return }
        self.document = document
        self.trackID = document.tracks.first?.id
        self.isLoading = false
        self.loadingTask = nil
      } catch {
        guard let self, self.generation == token else { return }
        if !(error is CancellationError), !Task.isCancelled {
          self.errorMessage = error.localizedDescription
        }
        self.isLoading = false
        self.loadingTask = nil
      }
    }
  }

  func remove() {
    hasUserSelection = true
    cancelPendingLoad()
    document = nil
    sourceURL = nil
    trackID = nil
    errorMessage = nil
    isEnabled = false
  }

  /// A manual choice (including turning an empty slot off) takes precedence
  /// over directory discovery or parsing that may still be running.
  fileprivate var allowsAutomaticSelection: Bool {
    !hasUserSelection && isEnabled && sourceURL == nil && document == nil && !isLoading
  }

  @discardableResult
  fileprivate func installAutomatically(_ document: SubtitleDocument, trackID: String) -> Bool {
    guard allowsAutomaticSelection else { return false }
    self.sourceURL = document.sourceURL
    self.document = document
    self.trackID = trackID
    errorMessage = nil
    return true
  }

  /// Eviction/cancellation releases pending work without discarding a document
  /// that is still displayed by a view holding this session.
  func cancelPendingLoad() {
    generation = UUID()
    loadingTask?.cancel()
    loadingTask = nil
    if isLoading { isLoading = false }
  }

  private static func bounded(_ value: Double, in range: ClosedRange<Double>, fallback: Double) -> Double {
    value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
  }

  deinit { loadingTask?.cancel() }
}

/// Shared across the normal viewer, hover preview, and dedicated fullscreen
/// window for one video. No folder scan or subtitle read starts in init.
@MainActor
final class VideoStudySession: ObservableObject {
  typealias Discoverer = @Sendable (URL) async throws -> [URL]

  let videoURL: URL
  let primary: VideoSubtitleSlot
  let secondary: VideoSubtitleSlot
  @Published var playbackRate = 1.0 {
    didSet {
      let value = playbackRate.isFinite ? min(4, max(0.25, playbackRate)) : 1
      if playbackRate != value { playbackRate = value }
    }
  }
  @Published private(set) var sidecarURLs: [URL] = []
  @Published private(set) var isDiscovering = false
  @Published private(set) var sidecarErrorMessage: String?
  @Published private(set) var isPreparingAutomaticSubtitles = false

  private let loader: VideoSubtitleSlot.Loader
  private let discoverer: Discoverer
  private let preferredLanguage: String
  private var discoveryTask: Task<[URL], Error>?
  private var discoveryGeneration = UUID()
  private var hasDiscoveredSidecars = false
  private var automaticTask: Task<Void, Never>?
  private var automaticGeneration = UUID()
  private var hasPreparedAutomaticSubtitles = false

  init(videoURL: URL, preferredLanguage: String? = nil,
    discoverer: @escaping Discoverer = VideoStudySession.findSidecars,
    loader: @escaping VideoSubtitleSlot.Loader = VideoStudySession.readSubtitle) {
    self.videoURL = videoURL.standardizedFileURL
    self.preferredLanguage = VideoSubtitleSidecars.canonicalLanguage(preferredLanguage ?? L10n.languageIdentifier)
    self.loader = loader
    self.discoverer = discoverer
    primary = VideoSubtitleSlot(id: .primary, loader: loader)
    secondary = VideoSubtitleSlot(id: .secondary, loader: loader)
  }

  static func session(for videoURL: URL) -> VideoStudySession {
    VideoStudySessionRegistry.shared.session(for: videoURL)
  }

  /// Start only when a video is actually opened for playback. Constructing a
  /// session for a grid tile remains free of file-system work.
  func prepareAutomaticSubtitles() {
    guard !hasPreparedAutomaticSubtitles, automaticTask == nil else { return }
    let token = UUID()
    automaticGeneration = token
    isPreparingAutomaticSubtitles = true
    automaticTask = Task { [weak self] in
      await self?.prepareAutomaticSubtitles(generation: token)
    }
  }

  /// Settings and playback share one scan, including when both request it at
  /// once. Closing a popover does not cancel another consumer's discovery.
  func discoverSidecars(forceRefresh: Bool = false) async {
    if forceRefresh {
      discoveryTask?.cancel()
      discoveryTask = nil
      hasDiscoveredSidecars = false
      discoveryGeneration = UUID()
    }
    if hasDiscoveredSidecars { return }
    if discoveryTask == nil {
      discoveryGeneration = UUID()
      isDiscovering = true
      sidecarErrorMessage = nil
      let videoURL = videoURL
      let discoverer = discoverer
      discoveryTask = Task { try await discoverer(videoURL) }
    }
    guard let task = discoveryTask else { return }
    let token = discoveryGeneration
    do {
      let urls = try await task.value
      guard discoveryGeneration == token else { return }
      sidecarURLs = urls
    } catch {
      guard discoveryGeneration == token else { return }
      if !(error is CancellationError), !Task.isCancelled {
        sidecarErrorMessage = error.localizedDescription
      }
    }
    guard discoveryGeneration == token else { return }
    hasDiscoveredSidecars = true
    isDiscovering = false
    discoveryTask = nil
  }

  private func prepareAutomaticSubtitles(generation token: UUID) async {
    await discoverSidecars()
    guard automaticGeneration == token, !Task.isCancelled else { return }
    let candidates = VideoSubtitleSidecars.ranked(sidecarURLs, videoURL: videoURL,
      preferredLanguage: preferredLanguage)
    var attemptedLanguages: Set<String> = []
    var loadingError: String?
    for url in candidates {
      guard automaticGeneration == token, !Task.isCancelled else { return }
      guard [primary, secondary].contains(where: \.allowsAutomaticSelection) else { break }
      let fileLanguage = VideoSubtitleSidecars.language(of: url, videoURL: videoURL)
      // SRT/VTT variants of a successfully loaded language are alternatives,
      // not a reason to show the same language on both subtitle surfaces.
      if let fileLanguage, attemptedLanguages.contains(fileLanguage) { continue }
      do {
        let document = try await loader(url)
        guard automaticGeneration == token, !Task.isCancelled else { return }
        let tracks = document.tracks.sorted { lhs, rhs in
          let left = VideoSubtitleSidecars.language(of: lhs) ?? fileLanguage
          let right = VideoSubtitleSidecars.language(of: rhs) ?? fileLanguage
          return (left == preferredLanguage ? 0 : 1) < (right == preferredLanguage ? 0 : 1)
        }
        for track in tracks {
          let language = VideoSubtitleSidecars.language(of: track) ?? fileLanguage ?? preferredLanguage
          let occupied = Set([primary, secondary].compactMap { slot -> String? in
            guard let sourceURL = slot.sourceURL else { return nil }
            return slot.selectedTrack.flatMap { VideoSubtitleSidecars.language(of: $0) }
              ?? VideoSubtitleSidecars.language(of: sourceURL, videoURL: videoURL) ?? preferredLanguage
          })
          guard !occupied.contains(language),
            let slot = [primary, secondary].first(where: \.allowsAutomaticSelection) else { continue }
          if slot.installAutomatically(document, trackID: track.id) {
            attemptedLanguages.insert(language)
          }
        }
      } catch {
        guard automaticGeneration == token, !Task.isCancelled else { return }
        // A bad sidecar does not prevent trying another format or language.
        if !(error is CancellationError) { loadingError = error.localizedDescription }
      }
    }
    guard automaticGeneration == token else { return }
    if primary.document == nil, secondary.document == nil, let loadingError {
      sidecarErrorMessage = loadingError
    }
    hasPreparedAutomaticSubtitles = true
    isPreparingAutomaticSubtitles = false
    automaticTask = nil
  }

  func cancelPendingWork() {
    automaticGeneration = UUID()
    automaticTask?.cancel()
    automaticTask = nil
    isPreparingAutomaticSubtitles = false
    primary.cancelPendingLoad()
    secondary.cancelPendingLoad()
    discoveryGeneration = UUID()
    discoveryTask?.cancel()
    discoveryTask = nil
    if isDiscovering { isDiscovering = false }
  }

  nonisolated static func findSidecars(_ videoURL: URL) async throws -> [URL] {
    let task = Task.detached(priority: .utility) { try VideoSubtitleSidecars.discover(for: videoURL) }
    return try await withTaskCancellationHandler {
      let result = try await task.value
      try Task.checkCancellation()
      return result
    } onCancel: { task.cancel() }
  }

  nonisolated static func readSubtitle(_ url: URL) async throws -> SubtitleDocument {
    let task = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      let hasAccess = url.startAccessingSecurityScopedResource()
      defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
      return try SubtitleReader.read(url)
    }
    return try await withTaskCancellationHandler {
      let result = try await task.value
      try Task.checkCancellation()
      return result
    } onCancel: {
      task.cancel()
    }
  }

  deinit {
    discoveryTask?.cancel()
    automaticTask?.cancel()
  }
}

/// Retain eight recent videos. A weak index also reuses sessions still owned by
/// visible views, so opening fullscreen never forks a live video's settings.
/// The index does not extend document/task lifetimes or persist them to disk.
@MainActor
final class VideoStudySessionRegistry {
  static let shared = VideoStudySessionRegistry()
  private let capacity: Int
  private var sessions: [URL: VideoStudySession] = [:]
  private var liveSessions: [URL: WeakSession] = [:]
  private var recency: [URL] = []

  private final class WeakSession {
    weak var value: VideoStudySession?
    init(_ value: VideoStudySession) { self.value = value }
  }

  init(capacity: Int = 8) { self.capacity = min(8, max(1, capacity)) }

  var cachedSessionCount: Int { sessions.count }

  func session(for videoURL: URL) -> VideoStudySession {
    liveSessions = liveSessions.filter { $0.value.value != nil }
    let key = videoURL.standardizedFileURL
    recency.removeAll { $0 == key }
    recency.append(key)
    if let existing = sessions[key] { return existing }
    let session = liveSessions[key]?.value ?? VideoStudySession(videoURL: key)
    sessions[key] = session
    liveSessions[key] = WeakSession(session)
    while recency.count > capacity {
      let expired = recency.removeFirst()
      // Removing the cache's ownership must not cancel a load belonging to a
      // still-visible tile. Slot/session deinit cancels truly unowned work.
      sessions.removeValue(forKey: expired)
    }
    return session
  }
}

enum VideoSubtitleSidecars {
  private static let extensions: Set<String> = ["srt", "vtt", "smi", "sami"]
  private static let languages = Set(Locale.isoLanguageCodes).union([
    "eng", "kor", "jpn", "zho", "chi", "fra", "fre", "spa", "vie", "deu", "ger",
    "ita", "por", "rus", "ara", "hin", "ind", "tha", "nld", "dut", "chs", "cht",
    "english", "korean", "japanese", "chinese", "french", "spanish", "vietnamese",
    "한국어", "영어", "일본어", "중국어",
  ])
  private static let modifiers: Set<String> = ["forced", "sdh", "cc", "hi"]
  private static let regions = Set(Locale.isoRegionCodes.map { $0.lowercased() })
  private static let scripts: Set<String> = [
    "latn", "cyrl", "arab", "hans", "hant", "jpan", "kore", "deva", "thai", "grek",
    "hebr", "beng", "guru", "taml", "telu",
  ]
  private static let languageAliases = [
    "eng": "en", "english": "en", "영어": "en", "encc": "en",
    "kor": "ko", "korean": "ko", "한국어": "ko", "krcc": "ko", "kocc": "ko",
    "jpn": "ja", "japanese": "ja", "일본어": "ja", "jpcc": "ja", "jacc": "ja",
    "zho": "zh", "chi": "zh", "chinese": "zh", "중국어": "zh", "chs": "zh", "cht": "zh",
    "fra": "fr", "fre": "fr", "french": "fr", "frcc": "fr",
    "spa": "es", "spanish": "es", "escc": "es",
    "vie": "vi", "vietnamese": "vi", "vicc": "vi",
    "deu": "de", "ger": "de", "german": "de", "decc": "de",
    "rus": "ru", "russian": "ru", "rucc": "ru",
    "ara": "ar", "arabic": "ar", "arcc": "ar",
    "ita": "it", "por": "pt", "hin": "hi", "ind": "id", "tha": "th",
    "nld": "nl", "dut": "nl",
  ]

  static func canonicalLanguage(_ identifier: String) -> String {
    let base = normalized(identifier).components(separatedBy: CharacterSet(charactersIn: "-_ ")).first ?? ""
    return languageAliases[base] ?? base
  }

  static func language(of subtitleURL: URL, videoURL: URL) -> String? {
    guard matches(subtitleURL, videoURL: videoURL) else { return nil }
    let videoStem = normalized(videoURL.deletingPathExtension().lastPathComponent)
    let subtitleStem = normalized(subtitleURL.deletingPathExtension().lastPathComponent)
    guard subtitleStem != videoStem else { return nil }
    let suffix = String(subtitleStem.dropFirst(videoStem.count))
    guard let first = suffix.components(separatedBy: CharacterSet(charactersIn: ". _-[]()"))
      .first(where: { !$0.isEmpty }) else { return nil }
    return canonicalLanguage(first)
  }

  static func language(of track: SubtitleTrack) -> String? {
    for value in [track.name, track.id] {
      let language = canonicalLanguage(value)
      if languages.contains(language) || languageAliases.values.contains(language) { return language }
    }
    return nil
  }

  static func ranked(_ urls: [URL], videoURL: URL, preferredLanguage: String) -> [URL] {
    let formatRank = ["srt": 0, "vtt": 1, "smi": 2, "sami": 3]
    func rank(_ url: URL) -> Int {
      guard let language = language(of: url, videoURL: videoURL) else { return 1 }
      return language == preferredLanguage ? 0 : 2
    }
    return urls.filter { matches($0, videoURL: videoURL) }.sorted { lhs, rhs in
      if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
      let leftFormat = formatRank[lhs.pathExtension.lowercased()] ?? 4
      let rightFormat = formatRank[rhs.pathExtension.lowercased()] ?? 4
      if leftFormat != rightFormat { return leftFormat < rightFormat }
      return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }
  }

  /// Require the whole video stem followed only by a recognized language tag
  /// and optional accessibility/forced markers. Episode 1 must not pick up 10.
  static func matches(_ subtitleURL: URL, videoURL: URL) -> Bool {
    guard extensions.contains(subtitleURL.pathExtension.lowercased()) else { return false }
    let videoStem = normalized(videoURL.deletingPathExtension().lastPathComponent)
    let subtitleStem = normalized(subtitleURL.deletingPathExtension().lastPathComponent)
    guard !videoStem.isEmpty else { return false }
    if subtitleStem == videoStem { return true }
    guard subtitleStem.hasPrefix(videoStem) else { return false }
    let suffix = String(subtitleStem.dropFirst(videoStem.count))
    let separators = CharacterSet(charactersIn: ". _-[]()")
    guard let first = suffix.unicodeScalars.first, separators.contains(first) else { return false }
    let parts = suffix.components(separatedBy: separators).filter { !$0.isEmpty }
    guard let language = parts.first, languages.contains(language) else { return false }
    // BCP-47 script/region subtags are only accepted after a recognized language.
    var remaining = Array(parts.dropFirst())
    if let first = remaining.first, scripts.contains(first) {
      remaining.removeFirst()
    }
    if let first = remaining.first,
      regions.contains(first) || (first.count == 3 && first.allSatisfy(\.isNumber)) {
      remaining.removeFirst()
    }
    return remaining.allSatisfy { modifiers.contains($0) }
  }

  static func discover(for videoURL: URL) throws -> [URL] {
    try Task.checkCancellation()
    guard videoURL.isFileURL else { return [] }
    let directory = videoURL.deletingLastPathComponent()
    let hasAccess = directory.startAccessingSecurityScopedResource()
    defer { if hasAccess { directory.stopAccessingSecurityScopedResource() } }
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
    let contents = try FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
    var result: [URL] = []
    for url in contents {
      try Task.checkCancellation()
      guard matches(url, videoURL: videoURL) else { continue }
      let values = try url.resourceValues(forKeys: keys)
      guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
      result.append(url)
    }
    return result.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
  }

  private static func normalized(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping.lowercased()
  }
}
