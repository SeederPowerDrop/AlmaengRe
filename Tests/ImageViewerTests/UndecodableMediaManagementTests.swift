import AppKit
import Testing

@testable import ImageViewer

@Suite("읽을 수 없는 미디어 파일 관리", .serialized)
@MainActor
struct UndecodableMediaManagementTests {
  @Test("손상 이미지·영상·빈 음성·거부된 MKV도 이유를 표시한 뒤 분류·이름 변경·파일 작업이 가능하다",
    arguments: [BatchFileOperation.copy, .move, .trash])
  func previewFailureDoesNotDisableManagement(operation: BatchFileOperation) async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await fixture.open(store)
    let selected = Array(store.assets.prefix(4))
    let pipeline = ImagePipeline(maxConcurrentDecodes: 1)
    do {
      _ = try await pipeline.renderFrame(url: selected[0].url, maxPixelSize: 64,
        adjustments: .identity, prefersHDR: false)
      Issue.record("The deliberately corrupt PNG must fail decoding")
    } catch {
      let reason = await MediaLoadFailure.message(for: error, url: selected[0].url)
      #expect(reason?.isEmpty == false)
      #expect(reason?.contains(fixture.root.path) == false)
    }
    for asset in selected.dropFirst() {
      let state = VideoPlaybackState()
      await state.monitor(asset)
      #expect(state.errorMessage?.isEmpty == false)
      #expect(state.errorMessage?.contains(fixture.root.path) == false)
      #expect(state.document == nil && state.player.currentItem == nil)
      if asset.isAudio { #expect(state.errorMessage == MediaLoadFailure.empty.message) }
    }
    store.selectForBatch(index: 0, modifiers: [])
    store.selectForBatch(index: 3, modifiers: .shift)
    store.togglePhotoMarking()
    try #require(store.canMarkPhoto)
    store.togglePhotoMark(.s)
    store.presentBatchRename()
    try #require(store.batchSheet == .rename && store.batchAssets == selected)
    var options = BatchRenameOptions()
    options.prefix = "checked_"
    let rename = BatchRenamePlanner.plan(urls: store.batchAssets.map(\.url), options: options)
    try #require(rename.canApply)
    try await store.renameSelectedFiles(using: rename)
    store.batchSheet = nil
    try #require(store.selectedAssets.count == 4)
    #expect(store.selectedURLs == Set(rename.entries.map(\.destinationURL)))
    for entry in rename.entries {
      #expect(try Data(contentsOf: entry.destinationURL) == fixture.bytes[entry.sourceURL.lastPathComponent])
    }
    for asset in store.selectedAssets { #expect(store.photoMarks.marks(for: asset) == [.s]) }
    store.photoMarkPreferences.inheritOnCopy = true
    store.presentFileOperation(operation)
    let request = try #require(store.fileOperationRequest)
    try #require(request.assets.count == 4)
    let plan = try BatchFileOperationPlanner.plan(assets: request.assets, operation: operation,
      destinationFolder: operation == .trash ? nil : fixture.destination)
    let result = await store.performFileOperation(plan)
    try #require(result.completed.count == 4 && result.failures.isEmpty && !result.wasCancelled)
    for entry in result.completed {
      let destination = try #require(entry.destinationURL)
      let originalName = String(entry.displayName.dropFirst("checked_".count))
      #expect(try Data(contentsOf: destination) == fixture.bytes[originalName])
    }
    try fixture.assertControlsAndSeedsUnchanged()
    #expect(!store.isBatchBusy && !store.isRenaming)
  }

  @Test("부분 파일 시스템 실패는 이유를 반환하고 실패한 파일과 분류·선택을 보존한다",
    arguments: [BatchFileOperation.copy, .move, .trash])
  func partialFileFailurePreservesFailedSelection(operation: BatchFileOperation) async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore(failing: operation)
    defer { fixture.cleanup(store) }
    try await fixture.open(store)
    store.selectForBatch(index: 0, modifiers: [])
    store.selectForBatch(index: 3, modifiers: .shift)
    let selected = store.selectedAssets
    let failed = selected[1]
    store.togglePhotoMarking()
    store.togglePhotoMark(.q)
    store.presentFileOperation(operation)
    let request = try #require(store.fileOperationRequest)
    let plan = try BatchFileOperationPlanner.plan(assets: request.assets, operation: operation,
      destinationFolder: operation == .trash ? nil : fixture.destination)
    let result = await store.performFileOperation(plan)
    try #require(result.completed.count == 3 && result.failures.count == 1)
    #expect(result.failures[0].sourceURL == failed.url.standardizedFileURL)
    #expect(result.failures[0].message == CocoaError(.fileWriteNoPermission).localizedDescription)
    #expect(!result.failures[0].message.isEmpty)
    #expect(try Data(contentsOf: failed.url) == fixture.bytes[failed.filename])
    #expect(store.photoMarks.marks(for: failed) == [.q])
    #expect(store.selectedURLs == (operation == .copy ? Set(selected.map(\.url)) : [failed.url]))
    #expect(!store.isBatchBusy)
    try fixture.assertControlsAndSeedsUnchanged()
  }

  @Test("혼합 손상 파일 이름 변경의 부분 실패는 원래 이름·내용을 복원하고 원인을 알린다")
  func partialRenameRollsBackWithReason() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await fixture.open(store)
    store.selectForBatch(index: 0, modifiers: [])
    store.selectForBatch(index: 3, modifiers: .shift)
    let selection = store.selectedURLs
    var options = BatchRenameOptions()
    options.prefix = "checked_"
    let plan = BatchRenamePlanner.plan(urls: store.selectedAssets.map(\.url), options: options)
    let failureTarget = "checked_02-corrupt.mp4"
    let renamer = BatchRenamer { source, destination in
      if destination.lastPathComponent == failureTarget { throw CocoaError(.fileWriteNoPermission) }
      try BatchRenamer.moveExclusively(source, destination)
    }
    do {
      _ = try await renamer.apply(plan)
      Issue.record("The injected filesystem error must be reported")
    } catch BatchRenameError.applyFailed(let reason) {
      #expect(reason == CocoaError(.fileWriteNoPermission).localizedDescription)
      #expect(!BatchRenameError.applyFailed(reason).localizedDescription.isEmpty)
    }
    #expect(store.selectedURLs == selection)
    for name in fixture.names {
      #expect(try Data(contentsOf: fixture.working.appendingPathComponent(name)) == fixture.bytes[name])
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.working.path).sorted() == fixture.names)
    try fixture.assertControlsAndSeedsUnchanged()
  }

  @Test("이름 변경 직전 충돌은 AppStore에서도 원인과 선택을 유지하고 알 수 없는 확장자는 목록을 넓히지 않는다")
  func renameConflictAndUnknownExtension() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { fixture.cleanup(store) }
    try await fixture.open(store)
    let unknown = fixture.working.appendingPathComponent(fixture.names[5])
    #expect(!MediaFormatRegistry.canAttemptToOpen(unknown, includesVideos: true))
    do {
      _ = try await ImageLibrary().open(urls: [unknown], includesVideos: true)
      Issue.record("An unrelated unknown extension must not become a photo")
    } catch {
      #expect(!error.localizedDescription.isEmpty)
      #expect(error.localizedDescription.contains(unknown.lastPathComponent))
    }
    store.selectForBatch(index: 0, modifiers: [])
    store.selectForBatch(index: 3, modifiers: .shift)
    let selection = store.selectedURLs
    store.presentBatchRename()
    var options = BatchRenameOptions()
    options.prefix = "checked_"
    let plan = BatchRenamePlanner.plan(urls: store.batchAssets.map(\.url), options: options)
    let conflict = try #require(plan.entries.first?.destinationURL)
    let external = Data("External file created after preview".utf8)
    try external.write(to: conflict)
    do {
      try await store.renameSelectedFiles(using: plan)
      Issue.record("A late destination collision must be reported")
    } catch {
      #expect(!error.localizedDescription.isEmpty)
      #expect(error.localizedDescription == L10n.text("같은 이름의 파일 또는 폴더가 이미 있습니다."))
    }
    #expect(!store.isRenaming && store.selectedURLs == selection)
    #expect(try Data(contentsOf: conflict) == external)
    for name in fixture.names {
      #expect(try Data(contentsOf: fixture.working.appendingPathComponent(name)) == fixture.bytes[name])
    }
    try fixture.assertControlsAndSeedsUnchanged()
  }

  private struct Fixture {
    let suite = "UndecodableMediaManagementTests.\(UUID())"
    let root: URL
    let seeds: URL
    let working: URL
    let destination: URL
    let trash: URL
    let defaults: UserDefaults
    let names = ["01-corrupt.png", "02-corrupt.mp4", "03-empty.wav", "04-rejected.mkv",
      "05-control.png", "06-unknown.almaengunsupportedfixture"]
    let bytes: [String: Data]

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
      seeds = root.appendingPathComponent("Seeds", isDirectory: true)
      working = root.appendingPathComponent("WorkingCopies", isDirectory: true)
      destination = root.appendingPathComponent("Destination", isDirectory: true)
      trash = root.appendingPathComponent("SyntheticTrash", isDirectory: true)
      defaults = try #require(UserDefaults(suiteName: suite))
      for folder in [seeds, working, destination, trash] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      }
      let png = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII="))
      bytes = Dictionary(uniqueKeysWithValues: names.enumerated().map { index, name in
        (name, index == 2 ? Data() : index == 4 ? png : Data("Deliberately undecodable fixture: \(name)".utf8))
      })
      for name in names {
        try bytes[name]!.write(to: seeds.appendingPathComponent(name))
        try FileManager.default.copyItem(at: seeds.appendingPathComponent(name), to: working.appendingPathComponent(name))
      }
    }

    @MainActor func makeStore(failing operation: BatchFileOperation? = nil) -> AppStore {
      let trash = trash
      let failedName = names[1]
      let fileOperator = BatchFileOperator(trashFile: { source in
        if operation == .trash && source.lastPathComponent == failedName { throw CocoaError(.fileWriteNoPermission) }
        let destination = trash.appendingPathComponent(source.lastPathComponent)
        try BatchFileOperator.moveExclusively(source, destination)
        return destination
      }, moveFile: { source, destination in
        if operation == .move && source.lastPathComponent == failedName { throw CocoaError(.fileWriteNoPermission) }
        try BatchFileOperator.moveExclusively(source, destination)
      }, copyFile: { source, destination in
        if operation == .copy && source.lastPathComponent == failedName { throw CocoaError(.fileWriteNoPermission) }
        try BatchFileOperator.copyExclusively(source, destination)
      })
      return AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: root.appendingPathComponent("marks.sqlite"), batchFileOperator: fileOperator)
    }

    @MainActor func open(_ store: AppStore) async throws {
      await store.photoMarks.waitUntilReady()
      store.showsVideos = true
      store.open(urls: [working])
      let deadline = ContinuousClock.now + .seconds(10)
      while store.isLoading || store.isFiltering {
        try #require(ContinuousClock.now < deadline)
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(store.assets.map(\.filename) == Array(names.prefix(5)))
      store.presentationMode = .overview
    }

    func assertControlsAndSeedsUnchanged() throws {
      for name in names {
        #expect(try Data(contentsOf: seeds.appendingPathComponent(name)) == bytes[name])
      }
      for name in names.suffix(2) {
        #expect(try Data(contentsOf: working.appendingPathComponent(name)) == bytes[name])
      }
    }

    @MainActor func cleanup(_ store: AppStore) {
      store.batchSheet = nil
      store.folderComparison.cancelLoads()
      store.saveSessionNow()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
