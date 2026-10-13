import AppKit
import Darwin
import Testing

@testable import ImageViewer

@Suite("다른 볼륨 전송의 분류 유지 및 취소·오류 안전성")
@MainActor
struct ExternalFileOperationIntegrationTests {
  @Test("EXDEV 복사 후 삭제 경로에서도 선택한 파일의 새 식별자에 분류를 저장한다",
    arguments: [BatchFileOperation.copy, .move], [false, true])
  func crossVolumeIdentityAndMarksPersist(operation: BatchFileOperation, classified: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await verifySuccessfulTransfer(fixture, operation: operation, classified: classified,
      fileOperator: fixture.crossVolumeOperator())
  }

  // Opt in only with an explicitly provided disposable test directory. A mounted
  // disk image exercises real cross-device I/O; it does not prove physical USB
  // disconnect or controller behavior. No existing volume files are changed.
  @Test("실제 다른 볼륨에 복사·이동한 분류가 새 AppStore에서도 유지된다",
    .enabled(if: ProcessInfo.processInfo.environment["ALMAENG_EXTERNAL_QA_ROOT"] != nil),
    arguments: [BatchFileOperation.copy, .move], [false, true])
  func realExternalVolumePreservesMarks(operation: BatchFileOperation, classified: Bool) async throws {
    let path = try #require(ProcessInfo.processInfo.environment["ALMAENG_EXTERNAL_QA_ROOT"])
    let fixture = try Fixture(destinationParent: URL(fileURLWithPath: path, isDirectory: true))
    defer { fixture.cleanup() }
    let sourceDevice = try deviceID(fixture.photos)
    let destinationDevice = try deviceID(fixture.destination)
    try #require(sourceDevice != destinationDevice,
      "ALMAENG_EXTERNAL_QA_ROOT must be on a different mounted device, not another directory on the source volume")
    try await verifySuccessfulTransfer(fixture, operation: operation, classified: classified,
      fileOperator: BatchFileOperator())
  }

  @Test("실제 외장 볼륨 안의 다른 폴더로 이동해도 선택 및 분류를 유지한다",
    .enabled(if: ProcessInfo.processInfo.environment["ALMAENG_EXTERNAL_QA_ROOT"] != nil))
  func moveBetweenFoldersOnExternalVolumePreservesMarks() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["ALMAENG_EXTERNAL_QA_ROOT"])
    let volume = URL(fileURLWithPath: path, isDirectory: true)
    let fixture = try Fixture(sourceParent: volume, destinationParent: volume)
    defer { fixture.cleanup() }
    let sourceDevice = try deviceID(fixture.photos)
    let destinationDevice = try deviceID(fixture.destination)
    let internalDevice = try deviceID(FileManager.default.temporaryDirectory)
    try #require(sourceDevice == destinationDevice && sourceDevice != internalDevice)
    try await verifySuccessfulTransfer(fixture, operation: .move, classified: true,
      fileOperator: BatchFileOperator(), expectNewIdentity: false)
  }

  @Test("용량 부족·입출력 오류·장치 분리 오류로 부분 복사에 실패해도 원본과 분류는 남는다",
    arguments: [BatchFileOperation.copy, .move], [ENOSPC, EIO, ENODEV])
  func interruptedCopyLeavesOriginalAndMarks(operation: BatchFileOperation, errorCode: Int32) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let fileOperator = fixture.crossVolumeOperator(copyFile: { source, destination in
      if source.lastPathComponent == "photo2.png" {
        // Model copyfile reporting a failure after it has written some bytes.
        try Data(contentsOf: source).prefix(16).write(to: destination)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
      }
      try BatchFileOperator.copyExclusively(source, destination)
    })
    let store = fixture.makeStore(fileOperator)
    defer { finish(store) }
    let originals = try await prepare(store, fixture)
    store.selectAllAssets()
    let plan = try confirmedPlan(store, operation, fixture.destination)
    let result = await store.performFileOperation(plan)
    #expect(!result.wasCancelled)
    #expect(result.completed.map(\.displayName) == ["photo1.png", "photo3.png", "photo4.png"])
    #expect(result.failures.map { $0.sourceURL.lastPathComponent } == ["photo2.png"])
    #expect(try fixture.names(fixture.destination) == ["photo1.png", "photo3.png", "photo4.png"])
    let failed = originals[1]
    #expect(try Data(contentsOf: failed.url) == fixture.bytes[failed.filename])
    #expect(store.photoMarks.marks(for: failed) == fixture.marks[failed.filename])
    #expect(store.allAssets.contains { $0.url == failed.url })
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent(failed.filename).path))
    if operation == .copy {
      for original in originals {
        #expect(try Data(contentsOf: original.url) == fixture.bytes[original.filename])
      }
    } else {
      #expect(try fixture.names(fixture.photos) == ["photo2.png"])
    }
    try await checkPersistedMarks(store, fixture: fixture, result: result, remaining: operation == .copy ? originals : [failed])
  }

  @Test("파일 데이터를 임시 위치에 복사한 직후 취소하면 게시하거나 원본을 삭제하지 않는다",
    arguments: [BatchFileOperation.copy, .move])
  func cancellationDuringFileKeepsOriginal(operation: BatchFileOperation) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let fileOperator = fixture.crossVolumeOperator(copyFile: { source, destination in
      try BatchFileOperator.copyExclusively(source, destination)
      withUnsafeCurrentTask { $0?.cancel() }
    })
    let store = fixture.makeStore(fileOperator)
    defer { finish(store) }
    let originals = try await prepare(store, fixture)
    store.selectAllAssets()
    let plan = try confirmedPlan(store, operation, fixture.destination)
    let transfer = Task { await store.performFileOperation(plan) }
    let result = await transfer.value
    #expect(result.wasCancelled && result.completed.isEmpty && result.failures.isEmpty)
    #expect(try fixture.names(fixture.destination).isEmpty)
    #expect(store.allAssets.map(\.url) == originals.map(\.url))
    for original in originals {
      #expect(try Data(contentsOf: original.url) == fixture.bytes[original.filename])
      #expect(store.photoMarks.marks(for: original) == fixture.marks[original.filename])
    }
    try await checkPersistedMarks(store, fixture: fixture, result: result, remaining: originals)
  }

  @Test("다른 볼륨의 첫 파일 완료 후 취소하면 완료된 분류와 남은 원본 모두 보존한다",
    arguments: [BatchFileOperation.copy, .move])
  func cancellationAfterCommitPreservesBothSides(operation: BatchFileOperation) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let store = fixture.makeStore(fixture.crossVolumeOperator())
    defer { finish(store) }
    let originals = try await prepare(store, fixture)
    store.selectAllAssets()
    let plan = try confirmedPlan(store, operation, fixture.destination)
    let transfer = Task {
      await store.performFileOperation(plan) { finished, _ in
        if finished == 1 { withUnsafeCurrentTask { $0?.cancel() } }
      }
    }
    let result = await transfer.value
    #expect(result.wasCancelled && result.failures.isEmpty)
    #expect(result.completed.map(\.displayName) == ["photo1.png"])
    #expect(try fixture.names(fixture.destination) == ["photo1.png"])
    let remaining = operation == .copy ? originals : Array(originals.dropFirst())
    #expect(store.allAssets.map(\.url) == remaining.map(\.url))
    for original in remaining {
      #expect(try Data(contentsOf: original.url) == fixture.bytes[original.filename])
      #expect(store.photoMarks.marks(for: original) == fixture.marks[original.filename])
    }
    if operation == .move { #expect(!FileManager.default.fileExists(atPath: originals[0].url.path)) }
    try await checkPersistedMarks(store, fixture: fixture, result: result, remaining: remaining)
  }

  @Test("파일·폴더 동기화 오류 시 원본을 지우지 않고 원본 분류를 재시작 후에도 유지한다",
    arguments: [BatchFileOperation.copy, .move], [false, true])
  func flushFailureNeverRemovesOriginal(operation: BatchFileOperation, directoryFailure: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let fileOperator = BatchFileOperator(moveFile: { _, _ in
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))
    }, flushFile: { url in
      if !directoryFailure { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
      try BatchFileOperator.flushDurably(url)
    }, flushDirectory: { _ in
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
    })
    let store = fixture.makeStore(fileOperator)
    defer { finish(store) }
    let originals = try await prepare(store, fixture)
    store.selectForBatch(index: 0, modifiers: [])
    let plan = try confirmedPlan(store, operation, fixture.destination)
    let result = await store.performFileOperation(plan)
    #expect(!result.wasCancelled && result.completed.isEmpty && result.failures.count == 1)
    #expect(store.allAssets.map(\.url) == originals.map(\.url))
    for original in originals {
      #expect(try Data(contentsOf: original.url) == fixture.bytes[original.filename])
      #expect(store.photoMarks.marks(for: original) == fixture.marks[original.filename])
    }
    if directoryFailure {
      // Publication preceded the failed durability barrier. Keep both copies;
      // never delete the source when persistence of the destination is unknown.
      #expect(try fixture.names(fixture.destination) == ["photo1.png"])
      #expect(try Data(contentsOf: fixture.destination.appendingPathComponent("photo1.png")) == fixture.bytes["photo1.png"])
    } else {
      #expect(try fixture.names(fixture.destination).isEmpty)
    }
    try await checkPersistedMarks(store, fixture: fixture, result: result, remaining: originals)
  }

  @Test("실제 다른 볼륨 이동 도중 취소하면 원본을 보존하고 부분 사본을 제거한다",
    .enabled(if: ProcessInfo.processInfo.environment["ALMAENG_COPY_CANCEL_QA_ROOT"] != nil))
  func nativeCopyCallbackObservesCancellation() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["ALMAENG_COPY_CANCEL_QA_ROOT"])
    let destinationParent = URL(fileURLWithPath: path, isDirectory: true)
    try ExternalVolumeTestSafety.requireDisposableDiskImage(destinationParent)
    let fixture = try Fixture(destinationParent: destinationParent)
    defer { fixture.cleanup() }
    let source = fixture.root.appendingPathComponent("callback-source.bin")
    let sourceDevice = try deviceID(fixture.photos)
    let destinationDevice = try deviceID(fixture.destination)
    try #require(sourceDevice != destinationDevice)
    try Data().write(to: source)
    let writer = try FileHandle(forWritingTo: source)
    let block = Data(repeating: 0xa5, count: 1_048_576)
    for _ in 0..<128 { try writer.write(contentsOf: block) }
    try writer.close()
    let snapshot = try BatchFileOperationSourceSnapshot.capture(source)
    let asset = ImageAsset(url: source, byteCount: Int64(128 * block.count), modificationDate: nil,
      photoMarkIdentity: PhotoMarkFileIdentity.read(source)?.key)
    let plan = try BatchFileOperationPlanner.plan(assets: [asset], operation: .move,
      destinationFolder: fixture.destination)
    let transfer = Task.detached(priority: .utility) {
      await BatchFileOperator().execute(plan)
    }
    // Observe the real worker off the MainActor. APFS writes staging/payload;
    // exFAT writes an exclusively reserved final file. Ignore zero-byte probes.
    let destination = fixture.destination
    let observation = Task.detached {
      for _ in 0..<5_000 {
        if let entries = FileManager.default.enumerator(at: destination,
          includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
          for case let url as URL in entries.allObjects {
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) >= 1_048_576 {
              transfer.cancel()
              return true
            }
          }
        }
        try? await Task.sleep(for: .milliseconds(1))
      }
      transfer.cancel()
      return false
    }
    let observedWriting = await observation.value
    let result = await transfer.value
    #expect(observedWriting, "Observe at least 1 MiB actually written before requesting cancellation")
    #expect(result.wasCancelled && result.completed.isEmpty && result.failures.isEmpty,
      "Cancellation result: completed=\(result.completed.count), failures=\(result.failures.map(\.message))")
    #expect(try BatchFileOperationSourceSnapshot.capture(source) == snapshot)
    #expect(try fixture.names(fixture.destination).isEmpty,
      "The worker must remove its staging directory or exclusively created partial final file")
    let reader = try FileHandle(forReadingFrom: source)
    defer { try? reader.close() }
    #expect(try reader.read(upToCount: block.count) == block)
    try reader.seek(toOffset: UInt64(127 * block.count))
    #expect(try reader.read(upToCount: block.count) == block)
  }

  private func verifySuccessfulTransfer(_ fixture: Fixture, operation: BatchFileOperation,
    classified: Bool, fileOperator: BatchFileOperator, expectNewIdentity: Bool = true) async throws {
    let store = fixture.makeStore(fileOperator)
    defer { finish(store) }
    let originals = try await prepare(store, fixture)
    store.presentationMode = classified ? .overview : .viewer
    if classified {
      store.photoMarkFilter = PhotoMarkFilter(slots: [.q])
      try await ready(store)
      try #require(store.assets.map(\.filename) == ["photo1.png", "photo3.png"])
      store.selectAllAssets()
    } else {
      store.selectForBatch(index: 0, modifiers: [])
      store.selectForBatch(index: 2, modifiers: .command)
    }
    // An existing name is deliberately retained. Both its bytes and the source
    // classifications must survive collision handling on the destination FS.
    let existing = fixture.destination.appendingPathComponent("photo1.png")
    let existingBytes = Data("existing destination must not be replaced".utf8)
    try existingBytes.write(to: existing)
    let plan = try confirmedPlan(store, operation, fixture.destination)
    #expect(plan.entries.map(\.displayName) == ["photo1.png", "photo3.png"])
    let result = await store.performFileOperation(plan)
    try #require(result.failures.isEmpty && result.completed.count == 2 && !result.wasCancelled,
      "Transfer failures: \(result.failures.map { $0.sourceURL.lastPathComponent + ": " + $0.message })")
    #expect(try Data(contentsOf: existing) == existingBytes)
    #expect(try fixture.names(fixture.destination) == ["photo1 (2).png", "photo1.png", "photo3.png"])
    let remaining = operation == .copy ? originals : [originals[1], originals[3]]
    #expect(store.allAssets.map(\.url) == remaining.map(\.url))
    for original in remaining {
      #expect(try Data(contentsOf: original.url) == fixture.bytes[original.filename])
      #expect(store.photoMarks.marks(for: original) == fixture.marks[original.filename])
    }
    for index in [0, 2] {
      #expect(FileManager.default.fileExists(atPath: originals[index].url.path) == (operation == .copy))
    }
    for entry in result.completed {
      let url = try #require(entry.destinationURL)
      let destinationIdentity = try #require(PhotoMarkFileIdentity.read(url)?.key)
      let source = try #require(originals.first { $0.filename == entry.displayName })
      if expectNewIdentity { #expect(destinationIdentity != source.photoMarkID) }
      #expect(try Data(contentsOf: url) == fixture.bytes[entry.displayName])
    }
    try await checkPersistedMarks(store, fixture: fixture, result: result, remaining: remaining)
  }

  private func checkPersistedMarks(_ store: AppStore, fixture: Fixture,
    result: BatchFileOperationResult, remaining: [ImageAsset]) async throws {
    store.batchSheet = nil
    store.saveSessionNow()
    #expect(store.photoMarks.errorMessage == nil)
    let destinationURLs = result.completed.compactMap(\.destinationURL)
    let destinations = destinationURLs.isEmpty ? [] : try await ImageLibrary().assets(from: destinationURLs)
    let byURL = Dictionary(uniqueKeysWithValues: destinations.map { ($0.url.standardizedFileURL, $0) })
    for entry in result.completed {
      let url = try #require(entry.destinationURL)
      let asset = try #require(byURL[url.standardizedFileURL])
      #expect(store.photoMarks.marks(for: asset) == fixture.marks[entry.displayName])
      #expect(try Data(contentsOf: asset.url) == fixture.bytes[entry.displayName])
    }
    // Use a new app store and reload from disk, not just the operation's in-memory
    // dictionary. Reopening both folders also revalidates persisted bookmarks.
    let restarted = fixture.makeStore(BatchFileOperator())
    defer { finish(restarted) }
    await restarted.photoMarks.waitUntilReady()
    try #require(restarted.photoMarks.isReady)
    for entry in result.completed {
      let url = try #require(entry.destinationURL)
      let asset = try #require(byURL[url.standardizedFileURL])
      #expect(restarted.photoMarks.marks(for: asset) == fixture.marks[entry.displayName])
    }
    for original in remaining {
      #expect(restarted.photoMarks.marks(for: original) == fixture.marks[original.filename])
    }
    if !destinationURLs.isEmpty {
      restarted.open(urls: destinationURLs)
      try await ready(restarted)
      for entry in result.completed {
        let url = try #require(entry.destinationURL)
        let asset = try #require(restarted.allAssets.first { $0.url.standardizedFileURL == url.standardizedFileURL })
        #expect(restarted.photoMarks.marks(for: asset) == fixture.marks[entry.displayName])
      }
      restarted.photoMarkFilter = PhotoMarkFilter(slots: [.q])
      try await ready(restarted)
      let expected = Set(result.completed.filter { fixture.marks[$0.displayName]?.contains(.q) == true }
        .compactMap { $0.destinationURL?.lastPathComponent })
      #expect(Set(restarted.assets.map(\.filename)) == expected)
    }
  }

  private func confirmedPlan(_ store: AppStore, _ operation: BatchFileOperation,
    _ destination: URL) throws -> BatchFileOperationPlan {
    try #require(store.canPerformFileOperation(operation))
    store.presentFileOperation(operation)
    let request = try #require(store.fileOperationRequest)
    return try BatchFileOperationPlanner.plan(assets: request.assets, operation: operation,
      destinationFolder: destination)
  }

  private func prepare(_ store: AppStore, _ fixture: Fixture) async throws -> [ImageAsset] {
    await store.photoMarks.waitUntilReady()
    try #require(store.photoMarks.isReady)
    store.open(urls: [fixture.photos])
    try await ready(store)
    try #require(store.assets.count == 4 && store.alert == nil)
    let originals = store.assets
    for asset in originals {
      for mark in fixture.marks[asset.filename] ?? [] { store.photoMarks.toggle(mark, for: asset) }
    }
    store.photoMarks.flush()
    try await ready(store)
    return originals
  }

  private func ready(_ store: AppStore) async throws {
    await Task.yield()
    for _ in 0..<500 {
      if !store.isLoading && !store.isFiltering { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.loadingTimedOut
  }

  private func finish(_ store: AppStore) {
    store.batchSheet = nil
    store.folderComparison.cancelLoads()
    store.saveSessionNow()
  }

  private func deviceID(_ url: URL) throws -> dev_t {
    var info = stat()
    guard url.withUnsafeFileSystemRepresentation({ lstat($0!, &info) }) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return info.st_dev
  }

  private enum FixtureError: Error { case loadingTimedOut }

  private struct Fixture {
    let root: URL
    let photos: URL
    let destination: URL
    let database: URL
    let suite: String
    let defaults: UserDefaults
    let bytes: [String: Data]
    let marks: [String: Set<PhotoMarkSlot>] = [
      "photo1.png": [.one, .q], "photo2.png": [.w],
      "photo3.png": [.q, .f], "photo4.png": [.one, .f],
    ]

    init(sourceParent: URL? = nil, destinationParent: URL? = nil) throws {
      root = (sourceParent ?? FileManager.default.temporaryDirectory)
        .appendingPathComponent("ExternalTransferSource-\(UUID())")
      photos = root.appendingPathComponent("Photos")
      destination = destinationParent?.appendingPathComponent("Almaeng-External-Test-\(UUID())")
        ?? root.appendingPathComponent("Destination")
      database = root.appendingPathComponent("marks.sqlite")
      suite = "ExternalFileOperationIntegration.\(UUID())"
      defaults = try #require(UserDefaults(suiteName: suite))
      var images: [String: Data] = [:]
      for index in 1...4 {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 3,
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB, bytesPerRow: 12, bitsPerPixel: 32))
        for x in 0..<3 {
          for y in 0..<3 {
            bitmap.setColor(NSColor(deviceRed: CGFloat(index) / 4, green: CGFloat(x) / 3,
              blue: CGFloat(y) / 3, alpha: 1), atX: x, y: y)
          }
        }
        images["photo\(index).png"] = try #require(bitmap.representation(using: .png, properties: [:]))
      }
      bytes = images
      try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
      // The supplied destination parent must already exist: never create or
      // mount a user volume as a side effect of running tests.
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
      for (name, data) in images { try data.write(to: photos.appendingPathComponent(name)) }
    }

    @MainActor func makeStore(_ fileOperator: BatchFileOperator) -> AppStore {
      let store = AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: database, batchFileOperator: fileOperator)
      // These scenarios specifically exercise opt-in classification inheritance
      // across interrupted transfers. Default-off behavior has separate coverage.
      store.photoMarkPreferences.inheritOnCopy = true
      return store
    }

    func crossVolumeOperator(copyFile: @escaping BatchFileOperator.CopyFile = BatchFileOperator.copyExclusively)
      -> BatchFileOperator {
      BatchFileOperator(moveFile: { _, _ in
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))
      }, copyFile: copyFile)
    }

    func names(_ folder: URL) throws -> [String] {
      try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func cleanup() {
      defaults.removePersistentDomain(forName: suite)
      // Only the UUID-scoped directories created by this fixture are removed.
      try? FileManager.default.removeItem(at: destination)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
