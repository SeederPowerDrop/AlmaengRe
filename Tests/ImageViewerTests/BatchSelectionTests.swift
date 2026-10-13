import AppKit
import Foundation
import Testing

@testable import ImageViewer

@Suite("다중 선택과 이름 변경 연결")
@MainActor
struct BatchSelectionTests {
  @Test("우클릭 후 목록이 바뀌어도 원래 파일을 선택하고 사라진 대상은 중단한다")
  func contextMenuKeepsFileIdentity() async throws {
    let folder = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(defaults: UserDefaults(suiteName: "BatchSelectionTests-\(UUID())")!,
      monitorsSystemResources: false)
    store.open(urls: [folder])
    try await waitForLoad(store)
    let target = store.assets[1].url
    store.libraryQuery.sort = .nameDescending
    #expect(!store.prepareBatchContextSelection(url: target))
    try await waitForQuery(store)
    #expect(store.assets[1].url != target)
    #expect(store.prepareBatchContextSelection(url: target))
    #expect(store.selectedURLs == [target])

    store.selectAllAssets()
    let group = store.selectedURLs
    #expect(store.prepareBatchContextSelection(url: target))
    #expect(store.selectedURLs == group)

    store.libraryQuery.searchText = "photo4"
    try await waitForQuery(store)
    store.selectAllAssets()
    let remaining = store.selectedURLs
    #expect(!store.prepareBatchContextSelection(url: target))
    #expect(store.selectedURLs == remaining)
    #expect(!remaining.contains(target))
    #expect(store.batchSheet == nil)
  }

  @Test("⌘ 선택, ⇧ 범위, 전체 선택과 해제가 목록 순서를 유지한다")
  func selectionGestures() async throws {
    let folder = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(defaults: UserDefaults(suiteName: "BatchSelectionTests-\(UUID())")!,
      monitorsSystemResources: false)
    store.open(urls: [folder])
    try await waitForLoad(store)
    let urls = store.assets.map(\.url)
    #expect(store.selectedURLs == [urls[0]])
    store.selectForBatch(index: 2, modifiers: .command)
    #expect(store.selectedAssets.map(\.url) == [urls[0], urls[2]])
    store.selectForBatch(index: 0, modifiers: .command)
    #expect(store.selectedURLs == [urls[2]])
    store.selectForBatch(index: 3, modifiers: .shift)
    #expect(store.selectedURLs == Set(urls))
    store.select(index: 1)
    store.selectForBatch(index: 3, modifiers: .shift)
    #expect(store.selectedAssets.map(\.url) == Array(urls[1...3]))
    store.clearSelection()
    #expect(!store.canStartBatchOperation)
    store.selectAllAssets()
    #expect(store.selectedURLs == Set(urls))
    store.presentBatchRename()
    store.select(index: 0)
    store.clearSelection()
    store.open(urls: [folder])
    #expect(store.selectedURLs == Set(urls))
    #expect(!store.isLoading)
    #expect(!store.canStartBatchOperation)
  }

  @Test("여러 폴더의 선택 파일만 이름을 바꾸고 활성 사진과 보정값을 보존한다")
  func renamePreservesLibraryAndAdjustments() async throws {
    let first = try makeLibrary()
    let second = try makeLibrary()
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    let inputs = [first.appendingPathComponent("photo1.qoi"), second.appendingPathComponent("photo3.qoi")]
    let store = AppStore(defaults: UserDefaults(suiteName: "BatchSelectionTests-\(UUID())")!,
      monitorsSystemResources: false)
    store.open(urls: inputs)
    try await waitForLoad(store)
    store.select(index: 1)
    store.rotateClockwise()
    store.selectAllAssets()
    var options = BatchRenameOptions()
    options.prefix = "여행_"
    options.addsNumber = true
    let plan = BatchRenamePlanner.plan(urls: store.selectedAssets.map(\.url), options: options)
    #expect(plan.canApply)
    try await store.renameSelectedFiles(using: plan)
    #expect(store.assets.count == 2)
    #expect(store.selectedURLs == Set(plan.entries.map(\.destinationURL)))
    #expect(store.currentAsset?.url == plan.entries[1].destinationURL)
    #expect(store.currentAdjustments.normalizedQuarterTurns == 1)
    #expect(store.assets.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    #expect(!store.isRenaming)
    #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("photo2.qoi").path))
  }

  @Test("폴더에서 읽은 /private 경로도 이름 변경 뒤 목록·보정·변환 원본에 반영된다")
  func folderRenameUpdatesLibraryThroughPathAliases() async throws {
    let folder = try makeLibrary(in: URL(fileURLWithPath: "/private/tmp", isDirectory: true))
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(defaults: UserDefaults(suiteName: "BatchSelectionTests-\(UUID())")!,
      monitorsSystemResources: false)
    store.open(urls: [folder])
    try await waitForLoad(store)
    let originalURLs = store.assets.map(\.url)
    try #require(originalURLs.count == 4)
    // Directory enumeration returns /private/tmp, while rename planning standardizes it to /tmp.
    // Both URLs access the same image but are unequal dictionary keys.
    #expect(originalURLs.contains { $0 != $0.standardizedFileURL })
    store.select(index: 2)
    store.rotateClockwise()
    store.selectAllAssets()
    var options = BatchRenameOptions()
    options.prefix = "folder_"
    options.addsNumber = true
    let renamePlan = BatchRenamePlanner.plan(urls: store.selectedAssets.map(\.url), options: options)
    try #require(renamePlan.canApply)

    try await store.renameSelectedFiles(using: renamePlan)

    let destinations = renamePlan.entries.map(\.destinationURL)
    // Stop here on stale mappings; later conversion checks require the renamed library snapshot.
    try #require(store.assets.map(\.url) == destinations)
    try #require(store.selectedURLs == Set(destinations))
    #expect(store.currentAsset?.url == destinations[2])
    #expect(store.currentAdjustments.normalizedQuarterTurns == 1)
    #expect(originalURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    try #require(store.assets.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })

    let exportPlan = try BatchImageExporter.plan(
      urls: store.selectedAssets.map(\.url), destinationFolder: folder, format: .png
    )
    try #require(exportPlan.map(\.sourceURL) == destinations)
    try #require(exportPlan.allSatisfy { FileManager.default.fileExists(atPath: $0.sourceURL.path) })
    #expect(exportPlan.allSatisfy { $0.destinationURL.lastPathComponent.hasPrefix("folder_") })
  }

  private func waitForLoad(_ store: AppStore) async throws {
    for _ in 0..<200 {
      if !store.isLoading { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!store.isLoading)
    try #require(!store.assets.isEmpty)
  }

  private func waitForQuery(_ store: AppStore) async throws {
    for _ in 0..<200 {
      if !store.isFiltering { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!store.isFiltering)
  }

  private func makeLibrary(in parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
    let folder = parent
      .appendingPathComponent("batch-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let qoi = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
      0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    for number in 1...4 {
      try qoi.write(to: folder.appendingPathComponent("photo\(number).qoi"))
    }
    return folder
  }
}
