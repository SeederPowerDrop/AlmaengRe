import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

@Suite("폴더 트리를 통한 이미지 탐색")
@MainActor
struct FolderTreeNavigationTests {
  @Test("일반 열기로 현재 폴더를 기록하고 빈 폴더를 거쳐 다른 폴더로 이동한다")
  func navigateThroughEmptyFolder() async throws {
    let a = try fixture(count: 3), empty = try fixture(count: 0), b = try fixture(count: 2)
    defer { remove([a, empty, b]) }
    let suite = "FolderTreeNavigationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)

    store.open(urls: [a])
    try await wait { !store.isLoading }
    #expect(sameFolder(store.currentFolderURL, a))
    #expect(store.assets.count == 3)
    store.select(index: 2)
    store.zoom = 3
    store.panOffset = CGSize(width: 30, height: 20)

    store.openFolderFromTree(empty)
    try await wait { !store.isLoading }
    #expect(sameFolder(store.currentFolderURL, empty))
    #expect(store.assets.isEmpty && store.currentAsset == nil && store.selectedURLs.isEmpty)
    #expect(store.currentIndex == 0 && store.pageStartIndex == 0)
    #expect(store.zoom == 1 && store.panOffset == .zero)
    #expect(store.alert == nil && store.presentationMode == .viewer)

    store.openFolderFromTree(b)
    try await wait { !store.isLoading }
    #expect(sameFolder(store.currentFolderURL, b))
    #expect(store.assets.count == 2 && store.currentIndex == 0)
    #expect(store.assets.allSatisfy { sameFolder($0.url.deletingLastPathComponent(), b) })
    #expect(store.selectedURLs == Set(store.assets.prefix(1).map(\.url)))
    #expect(store.alert == nil)
  }

  @Test("모아보기에서 폴더를 바꾸거나 빈 폴더를 열어도 보기 방식을 유지한다")
  func preserveOverviewWhileNavigating() async throws {
    let a = try fixture(count: 3), b = try fixture(count: 2), empty = try fixture(count: 0)
    defer { remove([a, b, empty]) }
    let suite = "FolderTreeOverviewTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    store.open(urls: [a])
    try await wait { !store.isLoading }
    store.presentationMode = .overview
    store.select(index: 2)
    let previousSelection = store.selectedURLs

    store.openFolderFromTree(b)
    try await wait { !store.isLoading }
    #expect(store.presentationMode == .overview && store.assets.count == 2)
    #expect(store.selectedURLs.isDisjoint(with: previousSelection))
    #expect(sameFolder(store.currentFolderURL, b))
    store.openFolderFromTree(empty)
    try await wait { !store.isLoading }
    #expect(store.presentationMode == .overview && store.assets.isEmpty)
    #expect(sameFolder(store.currentFolderURL, empty) && store.alert == nil)
  }

  @Test("빠른 연속 탐색에서 취소된 폴더의 목록이나 빈 폴더 결과가 마지막 폴더를 덮지 않는다")
  func latestFolderWins() async throws {
    let a = try fixture(count: 48), b = try fixture(count: 2), empty = try fixture(count: 0)
    defer { remove([a, b, empty]) }
    let suite = "FolderTreeLatestTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    store.presentationMode = .overview

    store.openFolderFromTree(a)
    await Task.yield()
    store.openFolderFromTree(empty)
    store.openFolderFromTree(b)
    try await wait { !store.isLoading }
    // 이전 스캔의 완료 처리도 실행할 시간을 주어 최종 상태가 유지되는지 확인합니다.
    try await Task.sleep(for: .milliseconds(100))
    #expect(sameFolder(store.currentFolderURL, b))
    #expect(store.assets.count == 2 && store.presentationMode == .overview)
    #expect(store.assets.allSatisfy { sameFolder($0.url.deletingLastPathComponent(), b) })
    #expect(store.alert == nil)
  }

  @Test("비교 보기의 활성 칸만 바꾸고 잠긴 칸과 일반 보기의 폴더는 보존한다")
  func routeToActiveComparisonPaneAndRespectLock() async throws {
    let normal = try fixture(count: 3), a = try fixture(count: 2), b = try fixture(count: 4)
    defer { remove([normal, a, b]) }
    let suite = "FolderTreeComparisonTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    store.open(urls: [normal])
    try await wait { !store.isLoading }
    store.select(index: 2)
    let normalAsset = store.currentAsset
    store.presentationMode = .folderComparison
    let comparison = store.folderComparison

    comparison.activeSide = .first
    store.openFolderFromTree(a)
    try await wait { !comparison.first.isLoading && !comparison.isMatching }
    #expect(comparison.first.assets.count == 2 && comparison.second.assets.isEmpty)
    comparison.activeSide = .second
    store.openFolderFromTree(b)
    try await wait { !comparison.second.isLoading && !comparison.isMatching }
    #expect(sameFolder(comparison.first.folderURL, a) && sameFolder(comparison.second.folderURL, b))
    #expect(comparison.second.assets.count == 4)

    comparison.toggleLock(on: .first)
    // 잠금 전환은 다른 칸에 포커스를 옮기므로 잠긴 칸을 다시 활성화해 거부 경로를 검사합니다.
    comparison.activeSide = .first
    let lockedAsset = comparison.first.currentAsset
    #expect(!store.canOpenFolderFromTree)
    store.openFolderFromTree(b)
    #expect(!comparison.first.isLoading && comparison.first.currentAsset == lockedAsset)
    #expect(sameFolder(comparison.first.folderURL, a))

    comparison.activeSide = .second
    #expect(store.canOpenFolderFromTree)
    store.openFolderFromTree(a)
    try await wait { !comparison.second.isLoading && !comparison.isMatching }
    #expect(comparison.second.assets.count == 2 && sameFolder(comparison.second.folderURL, a))
    #expect(comparison.first.currentAsset == lockedAsset)
    #expect(store.presentationMode == .folderComparison)
    #expect(sameFolder(store.currentFolderURL, normal) && store.currentAsset == normalAsset)
    #expect(store.currentIndex == 2 && store.assets.count == 3)
  }

  @Test("일괄 작업 창이 열려 있을 때 트리로 편집 대상 폴더를 교체하지 않는다")
  func preserveFolderDuringBatchSheet() async throws {
    let a = try fixture(count: 2), b = try fixture(count: 3)
    defer { remove([a, b]) }
    let suite = "FolderTreeBatchTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    store.open(urls: [a])
    try await wait { !store.isLoading }
    let originalSelection = store.selectedURLs
    store.batchSheet = .rename
    #expect(!store.canOpenFolderFromTree)
    store.openFolderFromTree(b)
    #expect(!store.isLoading && sameFolder(store.currentFolderURL, a))
    #expect(store.assets.count == 2 && store.selectedURLs == originalSelection)
    store.batchSheet = nil
    #expect(store.canOpenFolderFromTree)
  }

  @Test("폴더 트리는 기본적으로 닫혀 있고 표시 설정은 다시 실행해도 유지한다")
  func persistFolderTreeVisibility() throws {
    let suite = "FolderTreePreferenceTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    #expect(!store.showsFolderTree)
    store.showsFolderTree = true
    let reopened = AppStore(defaults: defaults, monitorsSystemResources: false)
    #expect(reopened.showsFolderTree)
    reopened.showsFolderTree = false
    let hidden = AppStore(defaults: defaults, monitorsSystemResources: false)
    #expect(!hidden.showsFolderTree)
  }

  @Test("폴더 트리와 빈 폴더 안내를 지원하는 모든 언어로 제공한다")
  func localizeFolderTree() {
    let keys = [
      "폴더 트리", "폴더 트리 표시", "폴더를 펼쳐 다른 폴더로 이동합니다.",
      "탐색할 폴더 선택…", "상위 폴더 보기", "폴더 트리 새로고침", "하위 폴더 없음",
      "폴더를 읽을 수 없습니다.", "폴더 펼치기", "폴더 접기", "이 폴더 열기",
      "잠긴 칸은 폴더를 바꿀 수 없습니다.", "폴더 이름을 누르면 해당 폴더의 사진을 엽니다.",
      "이미지가 없는 폴더입니다.", "폴더 트리에서 다른 폴더를 선택하거나 파일을 열어 주세요.",
      "폴더 트리 닫기",
    ]
    for locale in L10n.supportedLocalizations {
      let available = L10n.keys(localeIdentifier: locale)
      #expect(keys.allSatisfy { available.contains($0) }, "Missing folder tree translations in \(locale)")
    }
  }

  private func wait(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition(), "Folder loading did not finish within three seconds")
  }

  private func sameFolder(_ actual: URL?, _ expected: URL) -> Bool {
    actual?.standardizedFileURL.resolvingSymlinksInPath()
      == expected.standardizedFileURL.resolvingSymlinksInPath()
  }

  private func remove(_ folders: [URL]) {
    for folder in folders { try? FileManager.default.removeItem(at: folder) }
  }

  private func fixture(count: Int) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("folder-tree-navigation-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    guard count > 0 else { return folder }
    let context = try #require(CGContext(data: nil, width: 8, height: 8,
      bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data,
      UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    for index in 1...count {
      try (data as Data).write(to: folder.appendingPathComponent("photo\(index).png"))
    }
    return folder
  }
}
