import AppKit
import SQLite3
import Testing

@testable import ImageViewer

@Suite("선택한 원본 파일 복사·이동·휴지통 통합")
@MainActor
struct BatchFileOperationIntegrationTests {
  @Test("뷰어와 몽땅보기의 직접 선택 복사는 분류 상속 설정을 따르고 원본을 보존한다",
    arguments: [false, true], [false, true])
  func directSelectionCopiesOnlyChosenOriginals(overview: Bool, inherit: Bool) async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    #expect(!store.photoMarkPreferences.inheritOnCopy)
    store.photoMarkPreferences.inheritOnCopy = inherit
    try await openPhotos(store, fixture: fixture)
    store.presentationMode = overview ? .overview : .viewer
    let originalAssets = store.assets
    store.selectForBatch(index: 0, modifiers: [])
    store.selectForBatch(index: 2, modifiers: .command)
    store.photoMarks.toggle(.one, for: originalAssets[0])
    try await ready(store)
    let expected = [originalAssets[0], originalAssets[2]]
    try #require(store.canPerformFileOperation(.copy))
    store.presentFileOperation(.copy)
    let request = try #require(store.fileOperationRequest)
    #expect(request.assets.map(\.url) == expected.map(\.url))
    #expect(store.batchSheet == .fileOperation)

    // A sheet retains its confirmed targets even if selection commands arrive.
    store.selectAllAssets()
    store.select(index: 1)
    #expect(store.selectedAssets.map(\.url) == expected.map(\.url))
    #expect(store.fileOperationRequest?.id == request.id)
    let plan = try BatchFileOperationPlanner.plan(assets: request.assets,
      operation: .copy, destinationFolder: fixture.destination)
    let result = await store.performFileOperation(plan)
    #expect(result.failures.isEmpty && result.completed.count == 2 && !result.wasCancelled)
    #expect(store.allAssets.map(\.url) == originalAssets.map(\.url))
    #expect(try fixture.names(in: fixture.destination) == ["photo1.png", "photo3.png"])
    for original in originalAssets { #expect(try Data(contentsOf: original.url) == fixture.png) }
    for entry in result.completed {
      let destination = try #require(entry.destinationURL)
      #expect(try Data(contentsOf: destination) == fixture.png)
    }
    let copied = try await ImageLibrary().assets(from: result.completed.compactMap(\.destinationURL))
    let markedCopy = try #require(copied.first { $0.filename == "photo1.png" })
    #expect(store.photoMarks.marks(for: markedCopy) == (inherit ? [.one] : []))
    #expect(store.photoMarks.marks(for: originalAssets[0]) == [.one])
    #expect(!store.isManagingFiles && !store.isBatchBusy)
    await store.photoMarks.flushAsync()
    let reopened = PhotoMarkStore(databaseURL: fixture.database)
    await reopened.waitUntilReady()
    #expect(reopened.marks(for: markedCopy) == (inherit ? [.one] : []))
    #expect(reopened.marks(for: originalAssets[0]) == [.one])
  }

  @Test("분류 직후 휴지통으로 보내고 앱을 재시작한 뒤 복원해도 분류가 돌아온다",
    arguments: [false, true])
  func immediateTrashAndRestoreRetainsMarks(overview: Bool) async throws {
    let fixture = try Fixture(count: 1)
    let store = fixture.makeStore(operator: fixture.fakeTrashOperator())
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture, count: 1)
    store.presentationMode = overview ? .overview : .viewer
    let original = try #require(store.currentAsset)
    store.presentFileOperation(.trash)
    let request = try #require(store.fileOperationRequest)
    let plan = try BatchFileOperationPlanner.plan(assets: request.assets, operation: .trash)
    // Do not flush here: the operation must drain a just-enqueued mark itself.
    store.photoMarks.set(.q, enabled: true, for: [original])
    store.photoMarks.set(.one, enabled: true, for: [original])
    let result = await store.performFileOperation(plan)
    try #require(result.completed.count == 1 && result.failures.isEmpty)
    let trashURL = try #require(result.completed.first?.destinationURL)
    #expect(!FileManager.default.fileExists(atPath: original.url.path))
    #expect(try Data(contentsOf: trashURL) == fixture.png)
    let restarted = PhotoMarkStore(databaseURL: fixture.database)
    await restarted.waitUntilReady()
    try #require(restarted.isReady)
    #expect(restarted.marksByAssetID[original.photoMarkID] == [.q, .one])
    try FileManager.default.moveItem(at: trashURL, to: original.url)
    let restoredAssets = try await ImageLibrary().assets(from: [original.url])
    let restored = try #require(restoredAssets.first)
    await restarted.reconcileAssets([restored])?.wait()
    await restarted.flushAsync()
    #expect(restarted.marks(for: restored) == [.q, .one])
    let reopened = PhotoMarkStore(databaseURL: fixture.database)
    await reopened.waitUntilReady()
    #expect(reopened.marks(for: restored) == [.q, .one])
    #expect(try Data(contentsOf: original.url) == fixture.png)
  }

  @Test("분류 필터의 모두 선택은 보이는 파일에만 복사·이동·휴지통을 적용한다",
    arguments: [false, true], [BatchFileOperation.copy, .move, .trash])
  func classifiedSelectionAppliesOnlyVisibleFiles(overview: Bool, operation: BatchFileOperation) async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore(operator: fixture.fakeTrashOperator())
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    store.presentationMode = overview ? .overview : .viewer
    let originals = store.assets
    store.photoMarks.toggle(.q, for: originals[0])
    store.photoMarks.toggle(.q, for: originals[2])
    store.photoMarkFilter = PhotoMarkFilter(slots: [.q])
    try await ready(store)
    try #require(store.assets.map(\.filename) == ["photo1.png", "photo3.png"])
    store.selectAllAssets()
    store.presentFileOperation(operation)
    let request = try #require(store.fileOperationRequest)
    #expect(request.assets.map(\.filename) == ["photo1.png", "photo3.png"])
    let plan = try BatchFileOperationPlanner.plan(assets: request.assets, operation: operation,
      destinationFolder: operation == .trash ? nil : fixture.destination)
    let result = await store.performFileOperation(plan)
    try await ready(store)
    #expect(result.completed.count == 2 && result.failures.isEmpty)
    #expect(Set(result.completed.map(\.displayName)) == ["photo1.png", "photo3.png"])
    for index in [1, 3] { #expect(try Data(contentsOf: originals[index].url) == fixture.png) }
    let outputFolder = operation == .trash ? fixture.fakeTrash : fixture.destination
    #expect(try fixture.names(in: outputFolder) == ["photo1.png", "photo3.png"])
    for name in ["photo1.png", "photo3.png"] {
      #expect(try Data(contentsOf: outputFolder.appendingPathComponent(name)) == fixture.png)
    }
    if operation != .trash {
      let outputs = try await ImageLibrary().assets(from: result.completed.compactMap(\.destinationURL))
      for output in outputs {
        #expect(store.photoMarks.marks(for: output) == (operation == .move ? [.q] : []))
      }
    }
    if operation == .copy {
      #expect(store.allAssets.count == 4 && store.assets.count == 2)
      #expect(try fixture.names(in: fixture.photos).count == 4)
    } else {
      #expect(store.allAssets.map(\.filename) == ["photo2.png", "photo4.png"])
      #expect(store.assets.isEmpty && store.currentAsset == nil && store.selectedURLs.isEmpty)
      #expect(try fixture.names(in: fixture.photos) == ["photo2.png", "photo4.png"])
    }
    store.batchSheet = nil
    store.resetLibraryQuery()
    try await ready(store)
    #expect(store.assets.count == (operation == .copy ? 4 : 2))
    #expect(store.fileOperationRequest == nil)
  }

  @Test("부분 이동 실패 시 성공한 파일만 목록에서 빼고 분류를 목적지에 유지한다")
  func partialMoveKeepsFailuresAndPreservesMarks() async throws {
    let fixture = try Fixture()
    let fileOperator = BatchFileOperator(moveFile: { source, destination in
      if source.lastPathComponent == "photo2.png" { throw CocoaError(.fileWriteNoPermission) }
      try BatchFileOperator.moveExclusively(source, destination)
    })
    let store = fixture.makeStore(operator: fileOperator)
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    let originals = store.assets
    store.photoMarks.toggle(.one, for: originals[0])
    store.photoMarks.toggle(.w, for: originals[0])
    store.photoMarks.toggle(.f, for: originals[1])
    try await ready(store)
    store.selectForBatch(index: 0, modifiers: [])
    store.selectForBatch(index: 1, modifiers: .command)
    store.presentFileOperation(.move)
    let request = try #require(store.fileOperationRequest)
    let plan = try BatchFileOperationPlanner.plan(assets: request.assets,
      operation: .move, destinationFolder: fixture.destination)
    let result = await store.performFileOperation(plan)
    #expect(result.completed.map(\.displayName) == ["photo1.png"])
    #expect(result.failures.map { $0.sourceURL.lastPathComponent } == ["photo2.png"])
    #expect(store.allAssets.map(\.filename) == ["photo2.png", "photo3.png", "photo4.png"])
    #expect(store.currentAsset?.filename == "photo2.png")
    #expect(store.selectedAssets.map(\.filename) == ["photo2.png"])
    #expect(try Data(contentsOf: originals[1].url) == fixture.png)
    #expect(!FileManager.default.fileExists(atPath: originals[0].url.path))
    let movedURL = try #require(result.completed.first?.destinationURL)
    let movedAssets = try await ImageLibrary().assets(from: [movedURL])
    let moved = try #require(movedAssets.first)
    #expect(try Data(contentsOf: movedURL) == fixture.png)
    #expect(store.photoMarks.marks(for: moved) == [.one, .w])
    #expect(store.photoMarks.marks(for: originals[1]) == [.f])
    store.saveSessionNow()
    let restoredMarks = PhotoMarkStore(databaseURL: fixture.database)
    await restoredMarks.waitUntilReady()
    #expect(restoredMarks.marks(for: moved) == [.one, .w])
    #expect(restoredMarks.marks(for: originals[1]) == [.f])
  }

  @Test("이동 후 분류 저장 실패는 별도 오류로 알리고 저장된 파일은 보존한다")
  func failedClassificationCommitIsVisibleAfterSafeMove() async throws {
    let fixture = try Fixture(count: 1)
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture, count: 1)
    let original = try #require(store.currentAsset)
    store.photoMarks.toggle(.one, for: original)
    try #require(await store.photoMarks.flushAsync())
    try await ready(store)
    store.presentFileOperation(.move)
    let request = try #require(store.fileOperationRequest)
    let plan = try BatchFileOperationPlanner.plan(assets: request.assets,
      operation: .move, destinationFolder: fixture.destination)
    var database: OpaquePointer?
    try #require(sqlite3_open(fixture.database.path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    try #require(sqlite3_exec(database,
      "CREATE TRIGGER reject_transfer BEFORE INSERT ON asset_marks BEGIN SELECT RAISE(ABORT, 'simulated mark write failure'); END",
      nil, nil, nil) == SQLITE_OK)
    let result = await store.performFileOperation(plan)
    try #require(result.completed.count == 1 && result.failures.isEmpty)
    let destination = try #require(result.completed.first?.destinationURL)
    #expect(try Data(contentsOf: destination) == fixture.png)
    #expect(!store.photoMarks.isReady)
    #expect(store.alert?.title == PhotoMarkL10n.text("storage.error"))
    #expect(store.alert?.message.contains("simulated mark write failure") == true)
  }

  @Test("마지막 파일을 휴지통으로 보낸 뒤 빈 뷰어와 몽땅보기 이동은 안전하다", arguments: [false, true])
  func lastFileTrashLeavesSafeEmptyNavigation(overview: Bool) async throws {
    let fixture = try Fixture(count: 1)
    let store = fixture.makeStore(operator: fixture.fakeTrashOperator())
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture, count: 1)
    store.presentationMode = overview ? .overview : .viewer
    store.presentFileOperation(.trash)
    let request = try #require(store.fileOperationRequest)
    let plan = try BatchFileOperationPlanner.plan(assets: request.assets, operation: .trash)
    let result = await store.performFileOperation(plan)
    #expect(result.completed.count == 1 && result.failures.isEmpty)
    #expect(store.assets.isEmpty && store.allAssets.isEmpty && store.mapAssets.isEmpty)
    #expect(store.currentIndex == 0 && store.pageStartIndex == 0 && store.currentAsset == nil)
    #expect(store.selectedURLs.isEmpty)
    store.batchSheet = nil
    store.navigatePage(1)
    store.navigatePage(-1)
    store.navigateOverview(by: 1)
    store.select(index: 0)
    store.selectAllAssets()
    #expect(store.currentAsset == nil && store.selectedURLs.isEmpty)
    for operation in [BatchFileOperation.copy, .move, .trash] {
      #expect(!store.canPerformFileOperation(operation))
      store.presentFileOperation(operation)
      #expect(store.fileOperationRequest == nil)
    }
    #expect(try Data(contentsOf: fixture.fakeTrash.appendingPathComponent("photo1.png")) == fixture.png)
  }

  @Test("홈·다른 모드·모달·드래그 선택 중에는 파일 작업을 시작하지 않는다")
  func modalAndPresentationGatesProtectFileOperations() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    assertCannotStart(store)
    try await openPhotos(store, fixture: fixture)
    try #require(store.canPerformFileOperation(.copy))
    store.batchSheet = .rename
    assertCannotStart(store)
    store.batchSheet = nil
    store.showsAIUpscaling = true
    assertCannotStart(store)
    store.showsAIUpscaling = false
    store.showsPhotoMarkEditor = true
    assertCannotStart(store)
    store.showsPhotoMarkEditor = false
    store.showsPhotoMarkTrackingReport = true
    assertCannotStart(store)
    store.showsPhotoMarkTrackingReport = false
    store.presentationMode = .map
    try await ready(store)
    assertCannotStart(store)
    store.presentationMode = .folderComparison
    assertCannotStart(store)
    store.presentationMode = .overview
    let drag = try #require(store.beginOverviewSelection(modifiers: []))
    assertCannotStart(store)
    store.cancelOverviewSelection(drag)
    #expect(store.canPerformFileOperation(.copy))
    #expect(!store.canPerformFileOperation(.copy, urls: [fixture.root.appendingPathComponent("missing.png")]))
  }

  @Test("시트의 선택·작업과 다른 계획 및 중복 계획은 파일에 손대지 않는다")
  func unrelatedAndDuplicatePlansAreRejected() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    let originals = store.assets
    store.select(index: 0)
    store.presentFileOperation(.copy)
    let sourcePlan = try BatchFileOperationPlanner.plan(assets: [originals[0]],
      operation: .copy, destinationFolder: fixture.destination)
    let unrelated = try BatchFileOperationPlanner.plan(assets: [originals[1]],
      operation: .copy, destinationFolder: fixture.destination)
    let wrongOperation = try BatchFileOperationPlanner.plan(assets: [originals[0]],
      operation: .move, destinationFolder: fixture.destination)
    let duplicate = BatchFileOperationPlan(operation: .copy, entries: sourcePlan.entries + sourcePlan.entries,
      destinationFolder: sourcePlan.destinationFolder, destinationSnapshot: sourcePlan.destinationSnapshot,
      retainedAssets: sourcePlan.retainedAssets)
    for plan in [unrelated, wrongOperation, duplicate] {
      let result = await store.performFileOperation(plan)
      #expect(result.completed.isEmpty && result.failures.count == plan.entries.count)
      #expect(result.failures.allSatisfy { $0.message == FileOperationsL10n.text("error.selectionChanged") })
    }
    store.batchSheet = nil
    let noSheet = await store.performFileOperation(sourcePlan)
    #expect(noSheet.completed.isEmpty && noSheet.failures.count == 1)
    #expect(try fixture.names(in: fixture.destination).isEmpty)
    #expect(store.allAssets.map(\.url) == originals.map(\.url))
    for original in originals { #expect(try Data(contentsOf: original.url) == fixture.png) }
  }

  @Test("미리보기 후 바뀐 원본은 이동하지 않고 목록과 분류를 유지한다")
  func changedSourceRemainsInSourceCollection() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    let original = try #require(store.currentAsset)
    store.photoMarks.toggle(.q, for: original)
    try await ready(store)
    store.presentFileOperation(.move)
    let request = try #require(store.fileOperationRequest)
    let plan = try BatchFileOperationPlanner.plan(assets: request.assets,
      operation: .move, destinationFolder: fixture.destination)
    let changedBytes = fixture.png + Data("source changed after preview".utf8)
    try changedBytes.write(to: original.url, options: .atomic)
    let result = await store.performFileOperation(plan)
    #expect(result.completed.isEmpty && result.failures.count == 1)
    #expect(result.failures.first?.message == FileOperationsL10n.text("error.sourceChanged"))
    #expect(store.allAssets.count == 4 && store.assets.count == 4)
    #expect(store.currentAsset?.url == original.url)
    #expect(store.photoMarks.marks(for: original) == [.q])
    #expect(try Data(contentsOf: original.url) == changedBytes)
    #expect(try fixture.names(in: fixture.destination).isEmpty)
  }

  @Test("같은 폴더의 복사본은 분류 상속을 켠 경우에만 현재 분류 필터에 들어온다", arguments: [false, true])
  func sameFolderCopyInheritsMarksAndJoinsFilteredCollection(inherit: Bool) async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    store.photoMarkPreferences.inheritOnCopy = inherit
    try await openPhotos(store, fixture: fixture)
    let original = try #require(store.currentAsset)
    store.photoMarks.toggle(.one, for: original)
    store.photoMarks.toggle(.f, for: original)
    store.photoMarkFilter = PhotoMarkFilter(slots: [.one, .f], matchesAll: true)
    try await ready(store)
    store.selectAllAssets()
    store.presentFileOperation(.copy)
    let request = try #require(store.fileOperationRequest)
    let plan = try BatchFileOperationPlanner.plan(assets: request.assets,
      operation: .copy, destinationFolder: fixture.photos)
    let result = await store.performFileOperation(plan)
    try await ready(store)
    #expect(result.completed.count == 1 && result.failures.isEmpty)
    #expect(store.allAssets.count == 5 && store.assets.count == (inherit ? 2 : 1))
    let copied = try #require(store.allAssets.first { $0.filename == "photo1 (2).png" })
    #expect(copied.photoMarkID != original.photoMarkID)
    #expect(store.photoMarks.marks(for: copied) == (inherit ? [.one, .f] : []))
    #expect(store.photoMarks.marks(for: original) == [.one, .f])
    #expect(store.currentAsset?.url == original.url)
    #expect(try Data(contentsOf: copied.url) == fixture.png)
    #expect(try Data(contentsOf: original.url) == fixture.png)
  }

  @Test("작업 취소 후에도 이미 이동한 파일을 목록과 분류에 반영한다")
  func cancelledMoveReconcilesCompletedFilesAndMarks() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    let originals = store.assets
    store.photoMarks.toggle(.one, for: originals[0])
    store.photoMarks.toggle(.q, for: originals[1])
    try await ready(store)
    store.selectAllAssets()
    store.presentFileOperation(.move)
    let request = try #require(store.fileOperationRequest)
    let plan = try BatchFileOperationPlanner.plan(assets: request.assets,
      operation: .move, destinationFolder: fixture.destination)
    let task = Task {
      await store.performFileOperation(plan) { finished, _ in
        if finished == 1 { withUnsafeCurrentTask { $0?.cancel() } }
      }
    }
    let result = await task.value
    #expect(result.wasCancelled && result.failures.isEmpty)
    #expect(result.completed.map(\.displayName) == ["photo1.png"])
    #expect(store.allAssets.map(\.filename) == ["photo2.png", "photo3.png", "photo4.png"])
    #expect(store.assets.map(\.filename) == ["photo2.png", "photo3.png", "photo4.png"])
    #expect(store.selectedAssets.map(\.filename) == ["photo2.png", "photo3.png", "photo4.png"])
    #expect(store.currentAsset?.filename == "photo2.png")
    #expect(!store.isManagingFiles && !store.isBatchBusy)
    #expect(!FileManager.default.fileExists(atPath: originals[0].url.path))
    for original in originals.dropFirst() { #expect(try Data(contentsOf: original.url) == fixture.png) }
    let destination = try #require(result.completed.first?.destinationURL)
    let movedAssets = try await ImageLibrary().assets(from: [destination])
    let moved = try #require(movedAssets.first)
    #expect(try Data(contentsOf: destination) == fixture.png)
    #expect(store.photoMarks.marks(for: moved) == [.one])
    #expect(store.photoMarks.marks(for: originals[1]) == [.q])
    store.saveSessionNow()
    let restoredMarks = PhotoMarkStore(databaseURL: fixture.database)
    await restoredMarks.waitUntilReady()
    #expect(restoredMarks.marks(for: moved) == [.one])
  }

  @Test("Command-Delete는 검토 창만 열고 일반 Delete나 선택 해제는 삭제하지 않는다",
    arguments: [false, true])
  func trashShortcutRequiresReviewAndSelection(overview: Bool) async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore(operator: fixture.fakeTrashOperator())
    defer { cleanup(store, fixture: fixture) }
    try await openPhotos(store, fixture: fixture)
    store.presentationMode = overview ? .overview : .viewer
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    let plainDelete = try key(51)
    let commandDelete = try key(51, modifiers: .command)
    _ = store.handleViewerKeyDown(plainDelete, shortcuts: shortcuts)
    #expect(store.fileOperationRequest == nil && store.batchSheet == nil)
    #expect(try fixture.names(in: fixture.photos).count == 4)
    #expect(store.handleViewerKeyDown(commandDelete, shortcuts: shortcuts))
    let request = try #require(store.fileOperationRequest)
    #expect(request.operation == .trash && request.assets.count == 1)
    #expect(store.batchSheet == .fileOperation)
    #expect(try fixture.names(in: fixture.photos).count == 4)
    #expect(try fixture.names(in: fixture.fakeTrash).isEmpty)
    #expect(!store.isManagingFiles)

    store.batchSheet = nil
    store.clearSelection()
    #expect(store.selectedURLs.isEmpty)
    _ = store.handleViewerKeyDown(plainDelete, shortcuts: shortcuts)
    _ = store.handleViewerKeyDown(commandDelete, shortcuts: shortcuts)
    #expect(store.fileOperationRequest == nil && store.batchSheet == nil)
    #expect(try fixture.names(in: fixture.photos).count == 4)
    #expect(try fixture.names(in: fixture.fakeTrash).isEmpty)
    for asset in store.allAssets { #expect(try Data(contentsOf: asset.url) == fixture.png) }
  }

  @Test("직접 연 파일을 이동한 뒤에도 남은 폴더를 저장하고 다시 이어본다")
  func movingExplicitSourceFileRetainsFolderSession() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    await store.photoMarks.waitUntilReady()
    let source = fixture.photos.appendingPathComponent("photo1.png")
    store.open(urls: [source])
    try await ready(store)
    try #require(store.assets.count == 4 && store.currentAsset?.filename == "photo1.png")
    store.presentFileOperation(.move)
    let request = try #require(store.fileOperationRequest)
    let plan = try BatchFileOperationPlanner.plan(assets: request.assets,
      operation: .move, destinationFolder: fixture.destination)
    let result = await store.performFileOperation(plan)
    try #require(result.completed.count == 1 && result.failures.isEmpty)
    store.batchSheet = nil
    store.saveSessionNow()
    let saved = try #require(ViewerSessionPersistence(defaults: fixture.defaults).loadSession())
    #expect(saved.sources.map { $0.url.standardizedFileURL } == [fixture.photos.standardizedFileURL])

    let restored = fixture.makeStore()
    defer { restored.folderComparison.cancelLoads(); restored.saveSessionNow() }
    try #require(restored.showsHome && restored.canResumeWorkspace)
    await restored.resumeWorkspace()
    try await ready(restored)
    #expect(!restored.showsHome && restored.alert == nil)
    #expect(restored.assets.map(\.filename) == ["photo2.png", "photo3.png", "photo4.png"])
    #expect(restored.currentFolderURL?.standardizedFileURL == fixture.photos.standardizedFileURL)
    #expect(restored.currentAsset?.filename == "photo2.png")
    for asset in restored.assets { #expect(try Data(contentsOf: asset.url) == fixture.png) }
  }

  @Test("private 임시 경로의 파일을 모두 이동·휴지통 처리해도 별칭 목록과 세션이 정리된다",
    arguments: [BatchFileOperation.move, .trash])
  func privatePathAliasesReconcileAfterSourcesDisappear(operation: BatchFileOperation) async throws {
    let fixture = try Fixture(count: 2, baseDirectory: URL(fileURLWithPath: "/private/tmp", isDirectory: true))
    let store = fixture.makeStore(operator: fixture.fakeTrashOperator())
    defer { cleanup(store, fixture: fixture) }
    await store.photoMarks.waitUntilReady()
    store.open(urls: [fixture.photos.appendingPathComponent("photo1.png")])
    try await ready(store)
    try #require(store.assets.count == 2)
    let originals = store.assets
    try #require(originals.allSatisfy { $0.url.path.hasPrefix("/private/tmp/") })
    store.photoMarks.toggle(.one, for: originals[0])
    store.photoMarks.toggle(.q, for: originals[1])
    try await ready(store)
    store.selectAllAssets()
    store.presentFileOperation(operation)
    let request = try #require(store.fileOperationRequest)
    let plan = try BatchFileOperationPlanner.plan(assets: request.assets, operation: operation,
      destinationFolder: operation == .move ? fixture.destination : nil)
    let result = await store.performFileOperation(plan)
    #expect(result.completed.count == 2 && result.failures.isEmpty)
    #expect(store.allAssets.isEmpty && store.assets.isEmpty && store.mapAssets.isEmpty)
    #expect(store.currentAsset == nil && store.selectedURLs.isEmpty)
    #expect(store.currentIndex == 0 && store.pageStartIndex == 0)
    #expect(try fixture.names(in: fixture.photos).isEmpty)
    for original in originals { #expect(!FileManager.default.fileExists(atPath: original.url.path)) }

    if operation == .move {
      let moved = try await ImageLibrary().assets(from: result.completed.compactMap(\.destinationURL))
      try #require(moved.count == 2)
      #expect(store.photoMarks.marks(for: moved[0]) == [.one])
      #expect(store.photoMarks.marks(for: moved[1]) == [.q])
      for asset in moved { #expect(try Data(contentsOf: asset.url) == fixture.png) }
      store.saveSessionNow()
      let restoredMarks = PhotoMarkStore(databaseURL: fixture.database)
      await restoredMarks.waitUntilReady()
      #expect(restoredMarks.marks(for: moved[0]) == [.one])
      #expect(restoredMarks.marks(for: moved[1]) == [.q])
    } else {
      #expect(try fixture.names(in: fixture.fakeTrash) == ["photo1.png", "photo2.png"])
    }

    store.batchSheet = nil
    store.saveSessionNow()
    let saved = try #require(ViewerSessionPersistence(defaults: fixture.defaults).loadSession())
    #expect(saved.sources.map { $0.url.standardizedFileURL } == [fixture.photos.standardizedFileURL])
    #expect(saved.selectedID == nil && saved.selectedIDs.isEmpty)
    let restored = fixture.makeStore()
    defer { restored.folderComparison.cancelLoads(); restored.saveSessionNow() }
    await restored.resumeWorkspace()
    try await ready(restored)
    #expect(!restored.showsHome && restored.alert == nil)
    #expect(restored.assets.isEmpty && restored.currentAsset == nil)
    #expect(restored.currentFolderURL?.standardizedFileURL == fixture.photos.standardizedFileURL)
  }

  private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: 0, context: nil, characters: "\u{7f}",
      charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: code))
  }

  private func assertCannotStart(_ store: AppStore) {
    for operation in [BatchFileOperation.copy, .move, .trash] {
      #expect(!store.canPerformFileOperation(operation))
      store.presentFileOperation(operation)
      #expect(store.fileOperationRequest == nil)
    }
  }

  private func openPhotos(_ store: AppStore, fixture: Fixture, count: Int = 4) async throws {
    await store.photoMarks.waitUntilReady()
    try #require(store.photoMarks.isReady)
    store.open(urls: [fixture.photos])
    try await ready(store)
    try #require(store.assets.count == count && store.alert == nil)
  }

  private func ready(_ store: AppStore) async throws {
    await Task.yield()
    for _ in 0..<500 {
      if !store.isLoading && !store.isFiltering { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.loadingTimedOut
  }

  private func cleanup(_ store: AppStore, fixture: Fixture) {
    store.batchSheet = nil
    store.folderComparison.cancelLoads()
    store.saveSessionNow()
    fixture.defaults.removePersistentDomain(forName: fixture.suite)
    try? FileManager.default.removeItem(at: fixture.root)
  }

  private enum FixtureError: Error { case loadingTimedOut }

  private struct Fixture {
    let root: URL
    let photos: URL
    let destination: URL
    let fakeTrash: URL
    let database: URL
    let suite: String
    let defaults: UserDefaults
    let png: Data

    init(count: Int = 4, baseDirectory: URL = FileManager.default.temporaryDirectory) throws {
      root = baseDirectory.appendingPathComponent("BatchFileOperationIntegration-\(UUID())")
      photos = root.appendingPathComponent("Photos")
      destination = root.appendingPathComponent("Destination")
      fakeTrash = root.appendingPathComponent("SyntheticTrash")
      database = root.appendingPathComponent("marks.sqlite")
      suite = "BatchFileOperationIntegration.\(UUID())"
      defaults = try #require(UserDefaults(suiteName: suite))
      let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
      for x in 0..<2 {
        for y in 0..<2 { bitmap.setColor(.systemTeal, atX: x, y: y) }
      }
      png = try #require(bitmap.representation(using: .png, properties: [:]))
      for folder in [photos, destination, fakeTrash] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      }
      for index in 1...count { try png.write(to: photos.appendingPathComponent("photo\(index).png")) }
    }

    @MainActor func makeStore(operator fileOperator: BatchFileOperator = BatchFileOperator()) -> AppStore {
      AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: database, batchFileOperator: fileOperator)
    }

    func fakeTrashOperator() -> BatchFileOperator {
      let destination = fakeTrash
      // Exercise AppStore reconciliation without ever touching the user's Trash.
      return BatchFileOperator(trashFile: { source in
        let target = destination.appendingPathComponent(source.lastPathComponent)
        try BatchFileOperator.moveExclusively(source, target)
        return target
      })
    }

    func names(in folder: URL) throws -> [String] {
      try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }
  }
}
