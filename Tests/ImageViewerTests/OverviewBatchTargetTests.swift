import AppKit
import Testing

@testable import ImageViewer

@Suite("몽땅보기 키 조합 선택과 일괄 작업 대상", .serialized)
@MainActor
struct OverviewBatchTargetTests {
  @Test("⌘·⇧로 고른 일부 파일만 모든 일괄 작업 창에 고정한다")
  func modifierSelectionFreezesEveryBatchTarget() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await open(store, fixture: fixture)
    let assets = store.assets
    let expected = [assets[1], assets[2], assets[4], assets[5]]

    for action in Action.allCases {
      // Replace, toggle, range and additive range all feed the same ordered set.
      store.selectForBatch(index: 1, modifiers: [])
      store.selectForBatch(index: 4, modifiers: .command)
      store.selectForBatch(index: 5, modifiers: .shift)
      #expect(store.selectedAssets == [assets[4], assets[5]])
      store.selectForBatch(index: 1, modifiers: .command)
      store.selectForBatch(index: 2, modifiers: [.command, .shift])
      try #require(store.selectedAssets == expected)

      switch action {
      case .rename: store.presentBatchRename()
      case .export: store.presentBatchExport()
      case .watermark: store.presentWatermark()
      case .copy: store.presentFileOperation(.copy)
      case .move: store.presentFileOperation(.move)
      case .trash: store.presentFileOperation(.trash)
      }
      try #require(store.batchSheet == action.sheet)
      #expect(store.batchAssets == expected)
      let requestID = store.fileOperationRequest?.id
      if let operation = action.operation {
        #expect(store.fileOperationRequest?.operation == operation)
        #expect(store.fileOperationRequest?.assets == expected)
      }

      // A dialog must retain its reviewed targets when selection commands arrive.
      store.selectForBatch(index: 0, modifiers: [])
      store.selectAllAssets()
      store.clearSelection()
      store.presentSelectionClassification()
      #expect(!store.isPhotoMarking)
      #expect(store.selectedAssets == expected)
      #expect(store.batchAssets == expected)
      #expect(store.fileOperationRequest?.id == requestID)
      store.batchSheet = nil
      #expect(store.fileOperationRequest == nil)
    }

    // These are target-routing checks only; no copy/move/trash/export is executed.
    for asset in assets { #expect(try Data(contentsOf: asset.url) == fixture.imageBytes) }
  }

  @Test("범위 선택에서 ⌘로 뺀 파일은 일괄 분류에도 포함되지 않는다")
  func classificationUsesExactlyTheCommittedSelection() async throws {
    let fixture = try Fixture()
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await open(store, fixture: fixture)
    let assets = store.assets
    store.selectForBatch(index: 1, modifiers: [])
    store.selectForBatch(index: 4, modifiers: .shift)
    store.selectForBatch(index: 2, modifiers: .command)
    let expected = [assets[1], assets[3], assets[4]]
    try #require(store.selectedAssets == expected)
    store.presentSelectionClassification()
    try #require(store.canMarkPhoto)
    store.presentSelectionClassification()
    #expect(store.isPhotoMarking && store.selectedAssets == expected)
    #expect(store.photoMarkAssets == expected)
    store.togglePhotoMark(.s)

    for asset in assets {
      #expect(store.photoMarks.marks(for: asset) == (expected.contains(asset) ? [.s] : []))
      #expect(try Data(contentsOf: asset.url) == fixture.imageBytes)
    }
    #expect(store.photoMarkSelectionState(for: .s) == .all)
    store.clearSelection()
    store.togglePhotoMark(.e)
    #expect(!store.canMarkPhoto)
    #expect(assets.allSatisfy { !store.photoMarks.marks(for: $0).contains(.e) })
  }

  @Test("영상·음성 혼합 선택은 파일 관리·분류를 허용하고 이미지 변환을 차단한다")
  func mixedMediaKeepsFileActionsButDoesNotEnterImageExport() async throws {
    let fixture = try Fixture(includesPlaybackMedia: true)
    let store = fixture.makeStore()
    defer { cleanup(store, fixture: fixture) }
    try await open(store, fixture: fixture)
    let imageIndex = try #require(store.assets.firstIndex { !$0.isPlaybackMedia })
    let audioIndex = try #require(store.assets.firstIndex { $0.isAudio })
    let videoIndex = try #require(store.assets.firstIndex { $0.isVideo })
    store.selectForBatch(index: imageIndex, modifiers: [])
    #expect(store.canExportBatchImages())
    store.selectForBatch(index: audioIndex, modifiers: .command)
    store.selectForBatch(index: videoIndex, modifiers: .command)
    let selected = store.selectedAssets
    try #require(selected.count == 3)
    #expect(!store.canExportBatchImages())
    store.presentBatchExport()
    #expect(store.batchSheet == nil)
    store.presentWatermark()
    #expect(store.batchSheet == nil)

    store.presentBatchRename()
    #expect(store.batchSheet == .rename && store.batchAssets == selected)
    store.batchSheet = nil
    for operation in [BatchFileOperation.copy, .move, .trash] {
      #expect(store.canPerformFileOperation(operation))
      store.presentFileOperation(operation)
      #expect(store.fileOperationRequest?.assets == selected)
      store.batchSheet = nil
    }
    store.presentSelectionClassification()
    try #require(store.canMarkPhoto)
    store.togglePhotoMark(.s)
    #expect(selected.allSatisfy { store.photoMarks.marks(for: $0) == [.s] })
    #expect(store.assets.filter { !selected.contains($0) }.allSatisfy {
      store.photoMarks.marks(for: $0).isEmpty
    })
  }

  private enum Action: CaseIterable {
    case rename, export, watermark, copy, move, trash
    var sheet: BatchSheet {
      switch self {
      case .rename: .rename
      case .export: .export
      case .watermark: .watermark
      case .copy, .move, .trash: .fileOperation
      }
    }
    var operation: BatchFileOperation? {
      switch self {
      case .copy: .copy
      case .move: .move
      case .trash: .trash
      default: nil
      }
    }
  }

  private func open(_ store: AppStore, fixture: Fixture) async throws {
    await store.photoMarks.waitUntilReady()
    try #require(store.photoMarks.isReady)
    store.showsVideos = true
    store.open(urls: [fixture.folder])
    let deadline = ContinuousClock.now + .seconds(10)
    while store.isLoading || store.isFiltering {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(store.assets.count == fixture.count && store.alert == nil)
    store.presentationMode = .overview
  }

  private func cleanup(_ store: AppStore, fixture: Fixture) {
    store.folderComparison.cancelLoads()
    store.saveSessionNow()
    fixture.defaults.removePersistentDomain(forName: fixture.suite)
    try? FileManager.default.removeItem(at: fixture.root)
  }

  private struct Fixture {
    let root: URL
    let folder: URL
    let defaults: UserDefaults
    let count: Int
    let suite = "OverviewBatchTargetTests.\(UUID())"
    let imageBytes = Data([
      0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
      0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
    ])

    init(includesPlaybackMedia: Bool = false) throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("overview-batch-\(UUID())")
      folder = root.appendingPathComponent("media", isDirectory: true)
      defaults = try #require(UserDefaults(suiteName: suite))
      count = includesPlaybackMedia ? 8 : 6
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for number in 1...6 {
        try imageBytes.write(to: folder.appendingPathComponent("photo\(number).qoi"))
      }
      if includesPlaybackMedia {
        // Playback decoding is tested separately; only management identity matters here.
        for name in ["recording.wav", "video.mp4"] {
          try Data("Synthetic media selection fixture".utf8).write(to: folder.appendingPathComponent(name))
        }
      }
    }

    @MainActor func makeStore() -> AppStore {
      AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: root.appendingPathComponent("marks.sqlite"))
    }
  }
}
