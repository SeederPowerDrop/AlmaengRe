import AppKit
import Testing

@testable import ImageViewer

@Suite("사진·영상·음성 범위 선택 후 일괄 파일 작업", .serialized)
@MainActor
struct MixedMediaRangeBatchIntegrationTests {
  @Test("Shift·Command+Shift로 고른 혼합 파일만 분류·복사·이동·휴지통 처리한다",
    arguments: [BatchFileOperation.copy, .move, .trash], [false, true])
  func rangeSelectionFeedsMixedFileOperations(operation: BatchFileOperation, inherit: Bool) async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer {
      store.batchSheet = nil
      store.folderComparison.cancelLoads()
      store.saveSessionNow()
      fixture.cleanup()
    }
    await store.photoMarks.waitUntilReady()
    store.showsVideos = true
    store.photoMarkPreferences.inheritOnCopy = inherit
    store.open(urls: [fixture.working])
    try await ready(store)
    try #require(store.photoMarks.isReady && store.assets.count == fixture.names.count)
    try #require(store.assets.map(\.filename) == fixture.names)
    store.presentationMode = .overview
    store.overviewColumnCount = 2
    let assets = store.assets
    let shortcuts = ShortcutStore(defaults: fixture.defaults)

    // A three-item range crosses a row and contains one of each media kind.
    store.selectForBatch(index: 0, modifiers: [])
    #expect(store.handleViewerKeyDown(try key(125, modifiers: .shift), shortcuts: shortcuts))
    #expect(store.currentIndex == 2 && store.selectedURLs == Set(assets[0...2].map(\.url)))
    #expect(store.selectOverviewCard(url: assets[5].url, modifiers: .command))
    #expect(store.handleViewerKeyDown(try key(123, modifiers: [.command, .shift]), shortcuts: shortcuts))
    let selectedIndices: Set<Int> = [0, 1, 2, 4, 5]
    let selected = assets.enumerated().filter { selectedIndices.contains($0.offset) }.map(\.element)
    let unselected = assets.enumerated().filter { !selectedIndices.contains($0.offset) }.map(\.element)
    try #require(store.selectedAssets == selected)
    try #require(selected.contains(where: \.isAudio) && selected.contains(where: \.isVideo)
      && selected.contains { !$0.isAudio && !$0.isVideo })

    store.photoMarks.set(.e, enabled: true, for: unselected)
    store.togglePhotoMarking()
    store.togglePhotoMark(.s)
    store.togglePhotoMark(.q)
    for asset in selected { #expect(store.photoMarks.marks(for: asset) == [.s, .q]) }
    for asset in unselected { #expect(store.photoMarks.marks(for: asset) == [.e]) }
    // Classifications belong to the isolated database; no original bytes or
    // unselected metadata sidecars are changed by either selection or marking.
    for asset in assets {
      #expect(try Data(contentsOf: asset.url) == fixture.bytes[asset.filename])
    }
    #expect(try fixture.filenames(in: fixture.working) == fixture.names)

    try #require(store.canPerformFileOperation(operation))
    store.presentFileOperation(operation)
    let request = try #require(store.fileOperationRequest)
    #expect(request.assets == selected)
    let plan = try BatchFileOperationPlanner.plan(assets: request.assets,
      operation: operation, destinationFolder: operation == .trash ? nil : fixture.destination)
    // Deliberately do not flush marks first. Moving/trashing must preserve a
    // classification applied immediately before opening the operation sheet.
    let result = await store.performFileOperation(plan)
    try await ready(store)
    try #require(result.completed.count == selected.count && result.failures.isEmpty && !result.wasCancelled)
    #expect(Set(result.completed.map(\.displayName)) == Set(selected.map(\.filename)))
    let outputFolder = operation == .trash ? fixture.trash : fixture.destination
    #expect(try fixture.filenames(in: outputFolder) == selected.map(\.filename))
    for asset in selected {
      #expect(try Data(contentsOf: outputFolder.appendingPathComponent(asset.filename)) == fixture.bytes[asset.filename])
      #expect(FileManager.default.fileExists(atPath: asset.url.path) == (operation == .copy))
    }
    for asset in unselected {
      #expect(try Data(contentsOf: asset.url) == fixture.bytes[asset.filename])
      #expect(store.photoMarks.marks(for: asset) == [.e])
    }
    #expect(store.allAssets.map(\.filename) == (operation == .copy ? fixture.names : unselected.map(\.filename)))
    #expect(!store.isManagingFiles && !store.isBatchBusy)
    try #require(await store.photoMarks.flushAsync())

    // A new store proves classifications survived persistence. Simulated Trash
    // stays inside this UUID directory, and restore uses only working copies.
    let restarted = PhotoMarkStore(databaseURL: fixture.database)
    await restarted.waitUntilReady()
    try #require(restarted.isReady)
    var checkedURLs = result.completed.compactMap(\.destinationURL)
    if operation == .trash {
      for asset in selected {
        try FileManager.default.moveItem(at: fixture.trash.appendingPathComponent(asset.filename), to: asset.url)
      }
      checkedURLs = selected.map(\.url)
    }
    let checked = try await ImageLibrary().assets(from: checkedURLs, includesVideos: true)
    try #require(checked.count == selected.count)
    await restarted.reconcileAssets(checked)?.wait()
    try #require(await restarted.flushAsync())
    for asset in checked {
      #expect(restarted.marks(for: asset) == (operation != .copy || inherit ? [.s, .q] : []))
      #expect(try Data(contentsOf: asset.url) == fixture.bytes[asset.filename])
    }
    for asset in unselected { #expect(restarted.marks(for: asset) == [.e]) }
    if operation == .copy {
      for asset in selected {
        #expect(restarted.marks(for: asset) == [.s, .q])
        #expect(try Data(contentsOf: asset.url) == fixture.bytes[asset.filename])
      }
    }
    for name in fixture.names {
      #expect(try Data(contentsOf: fixture.seeds.appendingPathComponent(name)) == fixture.bytes[name])
    }
    #expect(try fixture.filenames(in: fixture.seeds) == fixture.names)
  }

  private func ready(_ store: AppStore) async throws {
    await Task.yield()
    let deadline = ContinuousClock.now + .seconds(10)
    while store.isLoading || store.isFiltering {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: code))
  }

  private struct Fixture {
    let suite = "MixedMediaRangeBatchTests.\(UUID())"
    let root: URL
    let seeds: URL
    let working: URL
    let destination: URL
    let trash: URL
    let database: URL
    let defaults: UserDefaults
    let names = ["00-recording.wav", "01-photo.png", "02-movie.mp4", "03-unselected.wav",
      "04-second.mp4", "05-second.png", "06-unselected.mp4", "07-unselected.png"]
    let bytes: [String: Data]

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
      seeds = root.appendingPathComponent("Seeds", isDirectory: true)
      working = root.appendingPathComponent("WorkingCopies", isDirectory: true)
      destination = root.appendingPathComponent("Destination", isDirectory: true)
      trash = root.appendingPathComponent("SyntheticTrash", isDirectory: true)
      database = root.appendingPathComponent("marks.sqlite")
      defaults = try #require(UserDefaults(suiteName: suite))
      for folder in [seeds, working, destination, trash] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      }
      let png = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII="))
      // Codec playback has separate real-media tests. File selection, identity,
      // classification and byte-for-byte transfers must also work for files
      // whose streams cannot be decoded, so these media payloads are synthetic.
      bytes = Dictionary(uniqueKeysWithValues: names.map { name in
        (name, name.hasSuffix(".png") ? png : Data("Synthetic mixed-media transfer: \(name)".utf8))
      })
      for name in names {
        try bytes[name]!.write(to: seeds.appendingPathComponent(name))
        try FileManager.default.copyItem(at: seeds.appendingPathComponent(name), to: working.appendingPathComponent(name))
      }
    }

    @MainActor func makeStore() -> AppStore {
      let trash = trash
      let fileOperator = BatchFileOperator(trashFile: { source in
        let destination = trash.appendingPathComponent(source.lastPathComponent)
        try BatchFileOperator.moveExclusively(source, destination)
        return destination
      })
      return AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: database, batchFileOperator: fileOperator)
    }

    func filenames(in folder: URL) throws -> [String] {
      try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func cleanup() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
