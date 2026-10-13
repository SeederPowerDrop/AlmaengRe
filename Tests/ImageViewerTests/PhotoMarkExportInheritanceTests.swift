import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

@Suite("내보내기 분류 상속", .serialized)
@MainActor
struct PhotoMarkExportInheritanceTests {
  @Test("편집 사본은 기본 미분류이며 설정을 켠 경우에만 원본 분류를 상속한다", arguments: [false, true])
  func editedImage(inherit: Bool) async throws {
    let fixture = try Fixture()
    let store = fixture.store()
    defer { fixture.remove(store) }
    let sources = try await fixture.open(store)
    let original = try Data(contentsOf: sources[0].url)
    store.photoMarks.set(.q, enabled: true, for: [sources[0]])
    #expect(!store.photoMarkPreferences.inheritOnExport)
    store.photoMarkPreferences.inheritOnExport = inherit
    let destination = fixture.output.appendingPathComponent("edited.png")
    try await store.exportEditedImage(sources[0], to: destination, format: .png,
      quality: 1, adjustments: .identity)
    let output = try #require(try await ImageLibrary().assets(from: [destination]).first)
    #expect(store.photoMarks.marks(for: output) == (inherit ? [.q] : []))
    #expect(store.photoMarks.marks(for: sources[0]) == [.q])
    #expect(try Data(contentsOf: sources[0].url) == original)
    await store.photoMarks.flushAsync()
    let reopened = PhotoMarkStore(databaseURL: fixture.database)
    await reopened.waitUntilReady()
    #expect(reopened.marks(for: output) == (inherit ? [.q] : []))
  }

  @Test("일괄 크기·워터마크 내보내기는 각 원본의 분류만 성공한 사본으로 전달한다", arguments: [false, true])
  func resizedWatermarkBatch(inherit: Bool) async throws {
    let fixture = try Fixture()
    let store = fixture.store()
    defer { fixture.remove(store) }
    let sources = try await fixture.open(store)
    store.photoMarks.set(.one, enabled: true, for: [sources[0]])
    store.photoMarks.set(.w, enabled: true, for: [sources[1]])
    store.photoMarks.set(.four, enabled: true, for: [sources[2]])
    store.photoMarkPreferences.inheritOnExport = inherit
    let items = try BatchImageExporter.plan(urls: sources.map(\.url),
      destinationFolder: fixture.output, format: .png)
    // A failed, already-existing destination must not acquire source marks.
    try Data(contentsOf: sources[2].url).write(to: items[2].destinationURL)
    var watermark = WatermarkOptions()
    watermark.isEnabled = true
    watermark.text = "TEST"
    let result = await store.convertSelectedFiles(items: items, format: .png, quality: 1,
      resize: .percentage(50), watermark: watermark) { _, _ in }
    #expect(result.completed.count == 2 && result.failures.count == 1)
    let outputs = try await ImageLibrary().assets(from: items.map(\.destinationURL))
    for (index, expected) in [Set([PhotoMarkSlot.one]), Set([.w]), Set<PhotoMarkSlot>()].enumerated() {
      let output = try #require(outputs.first { $0.url == items[index].destinationURL })
      #expect(store.photoMarks.marks(for: output) == (inherit ? expected : []))
    }
    #expect(store.photoMarks.marks(for: sources[0]) == [.one])
    #expect(store.photoMarks.marks(for: sources[1]) == [.w])
    #expect(store.photoMarks.marks(for: sources[2]) == [.four])
  }

  @Test("중간 취소 시 이미 완성된 출력의 분류는 저장하고 나머지 파일은 건드리지 않는다")
  func cancelledBatch() async throws {
    let fixture = try Fixture()
    let store = fixture.store()
    defer { fixture.remove(store) }
    let sources = try await fixture.open(store)
    store.photoMarks.set(.r, enabled: true, for: sources)
    store.photoMarkPreferences.inheritOnExport = true
    let items = try BatchImageExporter.plan(urls: sources.map(\.url),
      destinationFolder: fixture.output, format: .png)
    let result = await Task {
      await store.convertSelectedFiles(items: items, format: .png, quality: 1) { finished, _ in
        if finished == 1 { withUnsafeCurrentTask { $0?.cancel() } }
      }
    }.value
    #expect(result.wasCancelled && result.completed.count == 1 && result.failures.isEmpty)
    let output = try #require(try await ImageLibrary().assets(from: [items[0].destinationURL]).first)
    let reopened = PhotoMarkStore(databaseURL: fixture.database)
    await reopened.waitUntilReady()
    #expect(reopened.marks(for: output) == [.r])
    #expect(!FileManager.default.fileExists(atPath: items[1].destinationURL.path))
    for source in sources {
      #expect(FileManager.default.fileExists(atPath: source.url.path))
      #expect(store.photoMarks.marks(for: source) == [.r])
    }
  }

  @Test("완료 후 출력 폴더가 사라져도 오류·취소 뒤 이미 내보낸 파일의 분류가 복구된다", arguments: [false, true])
  func unavailableOutputAfterCommit(cancel: Bool) async throws {
    let fixture = try Fixture()
    let store = fixture.store()
    defer { fixture.remove(store) }
    let sources = try await fixture.open(store)
    store.photoMarks.set(.d, enabled: true, for: sources)
    store.photoMarkPreferences.inheritOnExport = true
    let items = try BatchImageExporter.plan(urls: sources.map(\.url),
      destinationFolder: fixture.output, format: .png)
    let outputFolder = fixture.output
    let offlineFolder = fixture.root.appendingPathComponent("offline-output")
    let result = await Task {
      await store.convertSelectedFiles(items: items, format: .png, quality: 1) { finished, _ in
        guard finished == 1 else { return }
        try? FileManager.default.moveItem(at: outputFolder, to: offlineFolder)
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
      }
    }.value
    #expect(result.completed.count == 1)
    #expect(result.wasCancelled == cancel)
    #expect(result.failures.count == (cancel ? 0 : 2))
    #expect(!FileManager.default.fileExists(atPath: outputFolder.path))
    let completed = try #require(result.completed.first)
    let captured = try #require(completed.destinationAsset)
    _ = try #require(completed.destinationReference)
    #expect(store.photoMarks.marks(for: captured) == [.d])
    #expect(store.alert == nil)
    try FileManager.default.moveItem(at: offlineFolder, to: outputFolder)
    let reopened = PhotoMarkStore(databaseURL: fixture.database)
    await reopened.waitUntilReady()
    let output = try #require(try await ImageLibrary().assets(from: [items[0].destinationURL]).first)
    #expect(reopened.marks(for: output) == [.d])
    for source in sources {
      #expect(FileManager.default.fileExists(atPath: source.url.path))
      #expect(reopened.marks(for: source) == [.d])
    }
  }

  @Test("식별 정보를 확보하지 못한 출력은 오류를 알리고 다른 완료 파일의 분류는 먼저 저장한다")
  func uncapturedMissingOutputStillPersistsOtherOutputs() async throws {
    let fixture = try Fixture()
    let store = fixture.store()
    defer { fixture.remove(store) }
    let sources = try await fixture.open(store)
    store.photoMarks.set(.one, enabled: true, for: [sources[0]])
    store.photoMarks.set(.q, enabled: true, for: [sources[1]])
    store.photoMarkPreferences.inheritOnExport = true
    let context = try await store.prepareExportPhotoMarks(for: sources)
    let missing = fixture.output.appendingPathComponent("missing.png")
    let saved = fixture.output.appendingPathComponent("saved.png")
    _ = try await AnimatedImageExporter().extractFrame(sourceURL: sources[1].url,
      destinationURL: saved, frameIndex: 0)
    await #expect(throws: PhotoMarkExportError.self) {
      try await context.commit([
        BatchExportItem(sourceURL: sources[0].url, destinationURL: missing),
        BatchExportItem(sourceURL: sources[1].url, destinationURL: saved),
      ])
    }
    #expect(store.photoMarks.isReady)
    let output = try #require(try await ImageLibrary().assets(from: [saved]).first)
    let reopened = PhotoMarkStore(databaseURL: fixture.database)
    await reopened.waitUntilReady()
    #expect(reopened.marks(for: output) == [.q])
    #expect(reopened.marks(for: sources[0]) == [.one])
    #expect(reopened.marks(for: sources[1]) == [.q])
    // A later unrelated file at the missing path must not inherit a ghost mark.
    try Data(contentsOf: sources[2].url).write(to: missing)
    let replacement = try #require(try await ImageLibrary().assets(from: [missing]).first)
    #expect(reopened.marks(for: replacement).isEmpty)
  }

  @Test("출력 완료 시점에 선택이나 설정을 바꾸어도 시작할 때의 분류를 적용한다")
  func snapshotSurvivesSelectionAndPreferenceChanges() async throws {
    let fixture = try Fixture()
    let store = fixture.store()
    defer { fixture.remove(store) }
    let sources = try await fixture.open(store)
    store.photoMarks.set(.e, enabled: true, for: [sources[0]])
    store.photoMarkPreferences.inheritOnExport = true
    let snapshot = try await store.prepareExportPhotoMarks(for: [sources[0]])
    store.photoMarks.set(.e, enabled: false, for: [sources[0]])
    store.photoMarks.set(.f, enabled: true, for: [sources[1]])
    store.select(index: 1)
    store.photoMarkPreferences.inheritOnExport = false
    let destination = fixture.output.appendingPathComponent("frame.png")
    _ = try await AnimatedImageExporter().extractFrame(sourceURL: sources[0].url,
      destinationURL: destination, frameIndex: 0)
    try await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await snapshot.commit([BatchExportItem(sourceURL: sources[0].url, destinationURL: destination)])
    }.value
    let output = try #require(try await ImageLibrary().assets(from: [destination]).first)
    #expect(store.photoMarks.marks(for: output) == [.e])
    #expect(store.photoMarks.marks(for: sources[0]).isEmpty)
    #expect(store.photoMarks.marks(for: sources[1]) == [.f])
  }

  @Test("실패한 단일 내보내기는 기존 대상 파일이나 원본의 분류를 바꾸지 않는다")
  func failedSingleExport() async throws {
    let fixture = try Fixture()
    let store = fixture.store()
    defer { fixture.remove(store) }
    let sources = try await fixture.open(store)
    store.photoMarks.set(.a, enabled: true, for: [sources[0]])
    store.photoMarkPreferences.inheritOnExport = true
    await #expect(throws: ImageExportError.self) {
      try await store.exportEditedImage(sources[0], to: sources[0].url, format: .png,
        quality: 1, adjustments: .identity)
    }
    #expect(store.photoMarks.marks(for: sources[0]) == [.a])
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).isEmpty)
  }

  @Test("AI 확대 저장도 같은 선택적 분류 상속을 사용한다")
  func aiOutput() async throws {
    let fixture = try Fixture()
    let store = fixture.store()
    defer { fixture.remove(store) }
    let sources = try await fixture.open(store)
    store.photoMarks.set(.s, enabled: true, for: [sources[0]])
    let ai = AIUpscalingStore(pipeline: store.pipeline, service: AIUpscalingService(usesCPUOnly: true))
    ai.prepare(sourceURL: sources[0].url)
    ai.start()
    let deadline = ContinuousClock.now + .seconds(40)
    while ai.isRunning {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(ai.result != nil, "AI failed: \(ai.errorMessage ?? "unknown")")
    for inherit in [false, true] {
      store.photoMarkPreferences.inheritOnExport = inherit
      let destination = fixture.output.appendingPathComponent("AI-\(inherit).png")
      ai.save(to: destination, preparePhotoMarks: { try await store.prepareExportPhotoMarks(sourceURLs: [$0]) })
      while ai.isSaving {
        try #require(ContinuousClock.now < deadline)
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(ai.errorMessage == nil && ai.savedURL == destination)
      let output = try #require(try await ImageLibrary().assets(from: [destination]).first)
      #expect(store.photoMarks.marks(for: output) == (inherit ? [.s] : []))
    }
    ai.cancel()
  }

  private struct Fixture {
    let root: URL
    let input: URL
    let output: URL
    let database: URL
    let suite = "PhotoMarkExportInheritanceTests.\(UUID())"

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-mark-export-\(UUID())")
      input = root.appendingPathComponent("input")
      output = root.appendingPathComponent("output")
      database = root.appendingPathComponent("marks.sqlite")
      try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      for index in 0..<3 {
        let context = try #require(CGContext(data: nil, width: 32, height: 24,
          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: CGFloat(index) / 3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let image = try #require(context.makeImage())
        let url = input.appendingPathComponent("source-\(index).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
          UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
      }
    }

    @MainActor func store() -> AppStore {
      AppStore(defaults: UserDefaults(suiteName: suite)!, monitorsSystemResources: false,
        photoMarkDatabaseURL: database)
    }

    @MainActor func open(_ store: AppStore) async throws -> [ImageAsset] {
      store.open(urls: [input])
      let deadline = ContinuousClock.now + .seconds(10)
      while store.isLoading || store.isFiltering {
        try #require(ContinuousClock.now < deadline)
        try await Task.sleep(for: .milliseconds(10))
      }
      await store.photoMarks.waitUntilReady()
      try #require(store.assets.count == 3 && store.photoMarks.isReady)
      return store.assets
    }

    @MainActor func remove(_ store: AppStore) {
      store.folderComparison.cancelLoads()
      store.saveSessionNow()
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
