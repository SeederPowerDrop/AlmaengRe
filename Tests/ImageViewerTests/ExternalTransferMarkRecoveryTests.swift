import AppKit
import Darwin
import Testing

@testable import ImageViewer

@Suite("완료 후 외장 경로가 사라져도 분류 복구")
@MainActor
struct ExternalTransferMarkRecoveryTests {
  @Test("앞 파일 완료 뒤 목적지가 사라져도 취소·오류 후 재시작에서 분류가 복구된다",
    arguments: [BatchFileOperation.copy, .move], [false, true])
  func committedMarksSurviveUnavailableDestination(operation: BatchFileOperation,
    cancel: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TransferMarkRecovery-\(UUID())")
    let source = root.appendingPathComponent("Source")
    let destination = root.appendingPathComponent("Destination")
    let offline = root.appendingPathComponent("Offline")
    let database = root.appendingPathComponent("marks.sqlite")
    let suite = "TransferMarkRecovery.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
    for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.systemBlue, atX: x, y: y) } }
    let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
    for name in ["photo1.png", "photo2.png"] { try bytes.write(to: source.appendingPathComponent(name)) }

    let fileOperator = BatchFileOperator(moveFile: { _, _ in
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))
    })
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: database, batchFileOperator: fileOperator)
    store.photoMarkPreferences.inheritOnCopy = true
    defer { finish(store) }
    await store.photoMarks.waitUntilReady()
    try #require(store.photoMarks.isReady)
    store.open(urls: [source])
    try await ready(store)
    try #require(store.assets.count == 2)
    let originals = store.assets
    for asset in originals {
      store.photoMarks.toggle(.q, for: asset)
      store.photoMarks.toggle(.one, for: asset)
    }
    store.photoMarks.flush()
    try await ready(store)
    store.selectAllAssets()
    store.presentFileOperation(operation)
    let request = try #require(store.fileOperationRequest)
    let plan = try BatchFileOperationPlanner.plan(assets: request.assets,
      operation: operation, destinationFolder: destination)
    let task = Task {
      await store.performFileOperation(plan) { completed, _ in
        guard completed == 1 else { return }
        // Hiding the destination directory after commit reproduces unavailable
        // paths before AppStore reconciliation, without disconnecting user media.
        try? FileManager.default.moveItem(at: destination, to: offline)
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
      }
    }
    let result = await task.value
    try #require(FileManager.default.fileExists(atPath: offline.path))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(result.wasCancelled == cancel)
    #expect(result.completed.count == 1)
    #expect(result.failures.count == (cancel ? 0 : 1))
    let completed = try #require(result.completed.first)
    let captured = try #require(completed.destinationAsset)
    _ = try #require(completed.destinationReference)
    #expect(captured.photoMarkID != originals[0].photoMarkID)
    #expect(store.photoMarks.marks(for: captured) == [.q, .one])
    #expect(try Data(contentsOf: offline.appendingPathComponent("photo1.png")) == bytes)
    #expect(try Data(contentsOf: originals[1].url) == bytes)
    #expect(store.photoMarks.marks(for: originals[1]) == [.q, .one])
    #expect(FileManager.default.fileExists(atPath: originals[0].url.path) == (operation == .copy))
    store.photoMarks.flush()

    // Restore the same files and create a fresh store using the persisted DB.
    // In-memory marks from the first app must not be needed for recovery.
    try FileManager.default.moveItem(at: offline, to: destination)
    let restarted = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: database)
    defer { finish(restarted) }
    await restarted.photoMarks.waitUntilReady()
    try #require(restarted.photoMarks.isReady)
    restarted.open(urls: [destination])
    try await ready(restarted)
    let recovered = try #require(restarted.assets.first)
    #expect(recovered.filename == "photo1.png")
    #expect(restarted.photoMarks.marks(for: recovered) == [.q, .one])
    #expect(restarted.photoMarks.marks(for: originals[1]) == [.q, .one])
    if operation == .copy {
      #expect(restarted.photoMarks.marks(for: originals[0]) == [.q, .one])
    }
    restarted.photoMarkFilter = PhotoMarkFilter(slots: [.q])
    try await ready(restarted)
    #expect(restarted.assets.map(\.filename) == ["photo1.png"])
  }

  @Test("분류 해제 후 다른 볼륨으로 이동한 파일은 재시작·재분류해도 해제 전 이력을 보존한다")
  func clearedHistorySurvivesCrossVolumeMoveAndRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClearedMarkTransfer-\(UUID())")
    let source = root.appendingPathComponent("Source")
    let destination = root.appendingPathComponent("Destination")
    let database = root.appendingPathComponent("marks.sqlite")
    let suite = "ClearedMarkTransfer.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
    for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.systemBlue, atX: x, y: y) } }
    let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
    for name in ["cleared.png", "never-marked.png"] { try bytes.write(to: source.appendingPathComponent(name)) }
    let fileOperator = BatchFileOperator(moveFile: { _, _ in
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))
    })
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: database, batchFileOperator: fileOperator)
    defer { finish(store) }
    await store.photoMarks.waitUntilReady()
    store.open(urls: [source])
    try await ready(store)
    let original = try #require(store.assets.first { $0.filename == "cleared.png" })
    store.photoMarks.toggle(.q, for: original)
    let classified = try #require(try await store.photoMarks.classificationRecords().first?.current)
    let clearingStarted = Date()
    store.photoMarks.toggle(.q, for: original)
    #expect(await store.photoMarks.flushAsync())
    let clearingFinished = Date()
    #expect(try await store.photoMarks.classificationRecords().isEmpty)
    store.selectAllAssets()
    store.presentFileOperation(.move)
    let request = try #require(store.fileOperationRequest)
    let plan = try BatchFileOperationPlanner.plan(assets: request.assets,
      operation: .move, destinationFolder: destination)
    let result = await store.performFileOperation(plan) { _, _ in }
    #expect(result.failures.isEmpty && result.completed.count == 2)
    let moved = try #require(result.completed.first { $0.sourceURL.lastPathComponent == "cleared.png" }?.destinationAsset)
    #expect(moved.photoMarkID != original.photoMarkID)
    #expect(!FileManager.default.fileExists(atPath: original.url.path))
    #expect(try Data(contentsOf: moved.url) == bytes)
    #expect(try await store.photoMarks.classificationRecords().isEmpty)
    let statistics = try store.photoMarks.storageStatistics()
    #expect(statistics.taggedFileCount == 0 && statistics.trackedFileCount == 0)
    #expect(statistics.cachedReferenceCount == 0)
    #expect(store.photoMarks.marksByAssetID.isEmpty)

    let restarted = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: database)
    defer { finish(restarted) }
    await restarted.photoMarks.waitUntilReady()
    restarted.open(urls: [destination])
    try await ready(restarted)
    let recovered = try #require(restarted.assets.first { $0.filename == "cleared.png" })
    let untouched = try #require(restarted.assets.first { $0.filename == "never-marked.png" })
    restarted.photoMarks.toggle(.w, for: recovered)
    restarted.photoMarks.toggle(.w, for: untouched)
    let rows = try await restarted.photoMarks.classificationRecords()
    let row = try #require(rows.first { $0.assetID == recovered.photoMarkID })
    #expect(row.current.marks == [.w])
    try #require(row.previous.count == 2)
    #expect(row.previous[0].marks.isEmpty)
    let clearedAt = try #require(row.previous[0].changedAt)
    #expect(clearedAt >= clearingStarted && clearedAt <= clearingFinished)
    #expect(row.previous[1] == classified)
    #expect(rows.first { $0.assetID == untouched.photoMarkID }?.previous.isEmpty == true)
  }

  private func ready(_ store: AppStore) async throws {
    await Task.yield()
    for _ in 0..<500 {
      if !store.isLoading && !store.isFiltering { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CocoaError(.fileReadUnknown)
  }

  private func finish(_ store: AppStore) {
    store.batchSheet = nil
    store.folderComparison.cancelLoads()
    store.saveSessionNow()
  }
}
