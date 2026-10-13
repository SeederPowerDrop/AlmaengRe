import AppKit
import Testing

@testable import ImageViewer

@Suite("비교 폴더 이름과 별칭")
@MainActor
struct ComparisonNamesTests {
  @Test("다른 폴더는 이름으로, 같은 폴더와 심볼릭 링크는 A/B로 구분한다")
  func automaticFolderNamesAndAliases() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults)
    defer { comparison.cancelLoads() }
    #expect(comparison.displayName(for: .first) == "A")
    #expect(comparison.navigationTitle(for: .first) == ComparisonNavigationTarget.first.title)
    #expect(comparison.navigationTitle(for: .both) == ComparisonNavigationTarget.both.title)

    comparison.first.load(fixture.first)
    comparison.second.load(fixture.second)
    try await ready(comparison)
    #expect(comparison.displayName(for: .first) == "Originals")
    #expect(comparison.displayName(for: .second) == "Edited")
    #expect(comparison.navigationTitle(for: .first) == "Originals")

    let alias = fixture.root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.first)
    comparison.second.load(alias)
    try await ready(comparison)
    #expect(comparison.automaticName(for: .first) == "A")
    #expect(comparison.automaticName(for: .second) == "B")
    #expect(comparison.navigationTitle(for: .second) == ComparisonNavigationTarget.second.title)
    comparison.setCustomName("Reference", for: .first)
    #expect(comparison.displayName(for: .first) == "Reference")
    #expect(comparison.automaticName(for: .first) == "A")
  }

  @Test("이름이 같은 다른 폴더와 빈 폴더도 구분한다")
  func repeatedBasenamesAndEmptyFolders() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let a = try fixture.folder("one/Photos", count: 0)
    let b = try fixture.folder("two/Photos", count: 0)
    let comparison = FolderComparisonStore(defaults: fixture.defaults)
    defer { comparison.cancelLoads() }
    comparison.first.load(a)
    comparison.second.load(b)
    try await ready(comparison)
    #expect(comparison.first.assets.isEmpty && comparison.second.assets.isEmpty)
    #expect(comparison.displayName(for: .first) == "Photos (A)")
    #expect(comparison.displayName(for: .second) == "Photos (B)")
    comparison.second.load(a)
    try await ready(comparison)
    #expect(comparison.displayName(for: .first) == "A")
    #expect(comparison.displayName(for: .second) == "B")
  }

  @Test("여러 파일은 공통 폴더를 사용하고 혼합 위치는 A/B로 표시한다")
  func multipleFileSources() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults)
    defer { comparison.cancelLoads() }
    let firstFiles = [fixture.first.appendingPathComponent("01.qoi"),
      fixture.first.appendingPathComponent("02.qoi")]
    comparison.open(urls: firstFiles, for: .first)
    comparison.second.load(fixture.second)
    try await ready(comparison)
    #expect(comparison.displayName(for: .first) == "Originals")
    comparison.setCustomName("Picked photos", for: .first)
    comparison.setCustomName("Finished", for: .second)
    comparison.open(urls: Array(firstFiles.reversed()), for: .first)
    try await ready(comparison)
    #expect(comparison.customName(for: .first) == "Picked photos")

    comparison.open(urls: [firstFiles[0], fixture.second.appendingPathComponent("01.qoi")], for: .first)
    try await ready(comparison)
    #expect(comparison.customName(for: .first).isEmpty)
    #expect(comparison.displayName(for: .first) == "A")
    #expect(comparison.displayName(for: .second) == "Finished")
  }

  @Test("ZIP은 원본 압축 파일 이름을 사용하고 같은 ZIP은 A/B로 표시한다")
  func archiveNames() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let archive = fixture.root.appendingPathComponent("Album.zip")
    let data = try #require(Data(base64Encoded: Self.zipFixture))
    try data.write(to: archive)
    let comparison = FolderComparisonStore(defaults: fixture.defaults)
    defer { comparison.cancelLoads() }
    comparison.open(urls: [archive], for: .first)
    comparison.second.load(fixture.second)
    try await ready(comparison)
    #expect(comparison.displayName(for: .first) == "Album.zip")
    comparison.open(urls: [archive], for: .second)
    try await ready(comparison)
    #expect(comparison.displayName(for: .first) == "A")
    #expect(comparison.displayName(for: .second) == "B")
  }

  @Test("별칭은 공백과 개행을 정리하고 80자로 제한하며 빈 값은 자동 이름이다")
  func normalizedNamesAndReset() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults)
    defer { comparison.cancelLoads() }
    comparison.first.load(fixture.first)
    comparison.second.load(fixture.second)
    try await ready(comparison)
    comparison.setCustomName("  Before\n\r\t and   after  ", for: .first)
    #expect(comparison.customName(for: .first) == "Before and after")
    #expect(comparison.navigationTitle(for: .first) == "Before and after")
    let longName = String(repeating: "가👩🏽‍💻", count: 60)
    comparison.setCustomName(longName, for: .second)
    #expect(comparison.customName(for: .second) == String(longName.prefix(80)))
    #expect(comparison.customName(for: .second).count == 80)
    comparison.setCustomName("\n \t", for: .first)
    #expect(comparison.customName(for: .first).isEmpty)
    #expect(comparison.displayName(for: .first) == "Originals")
    comparison.resetNames()
    #expect(comparison.customName(for: .second).isEmpty)
    #expect(comparison.displayName(for: .second) == "Edited")
  }

  @Test("동일 소스 재열기는 별칭을 유지하고 새 소스와 잠금은 해당 칸에만 적용된다")
  func reloadReplacementAndLock() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let comparison = FolderComparisonStore(defaults: fixture.defaults)
    defer { comparison.cancelLoads() }
    comparison.first.load(fixture.first)
    comparison.second.load(fixture.second)
    try await ready(comparison)
    comparison.setCustomName("Reference", for: .first)
    comparison.setCustomName("Result", for: .second)
    let alias = fixture.root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.first)
    comparison.open(urls: [alias], for: .first)
    try await ready(comparison)
    #expect(comparison.customName(for: .first) == "Reference")
    comparison.toggleLock(on: .first)
    comparison.open(urls: [fixture.second], for: .first)
    #expect(comparison.customName(for: .first) == "Reference")
    comparison.toggleLock(on: .first)
    comparison.open(urls: [fixture.second], for: .first)
    try await ready(comparison)
    #expect(comparison.customName(for: .first).isEmpty)
    #expect(comparison.displayName(for: .first) == "A")
    #expect(comparison.customName(for: .second) == "Result")
  }

  @Test("별칭은 세션과 함께 복원되고 이전 세션의 누락 필드는 자동 이름을 유지한다")
  func sessionRoundTripAndLegacyDecoding() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let original = FolderComparisonStore(defaults: fixture.defaults)
    let restored = FolderComparisonStore(defaults: fixture.defaults)
    defer { original.cancelLoads(); restored.cancelLoads() }
    original.first.load(fixture.first)
    original.second.load(fixture.second)
    try await ready(original)
    original.setCustomName("Before", for: .first)
    original.setCustomName("After", for: .second)
    original.jump(.second, number: 2)
    original.toggleLock(on: .first)
    let captured = try #require(original.captureSession())
    let data = try JSONEncoder().encode(captured)
    let decoded = try JSONDecoder().decode(ComparisonSession.self, from: data)
    await restored.restoreSession(decoded)
    #expect(restored.customName(for: .first) == "Before")
    #expect(restored.customName(for: .second) == "After")
    #expect(restored.second.currentAsset?.filename == "02.qoi")
    #expect(restored.first.isLocked)

    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for side in ["first", "second"] {
      var pane = try #require(legacy[side] as? [String: Any])
      pane.removeValue(forKey: "customName")
      legacy[side] = pane
    }
    let legacyData = try JSONSerialization.data(withJSONObject: legacy)
    let oldSession = try JSONDecoder().decode(ComparisonSession.self, from: legacyData)
    #expect(oldSession.first.customName == nil && oldSession.second.customName == nil)
    await restored.restoreSession(oldSession)
    #expect(restored.customName(for: .first).isEmpty && restored.customName(for: .second).isEmpty)
    #expect(restored.displayName(for: .first) == "Originals")
    #expect(restored.displayName(for: .second) == "Edited")
  }

  @Test("복원이 기다리는 동안 바꾼 별칭은 늦은 결과로 덮어쓰지 않는다")
  func userNameWinsDuringRestore() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let original = FolderComparisonStore(defaults: fixture.defaults)
    let restored = FolderComparisonStore(defaults: fixture.defaults)
    defer { original.cancelLoads(); restored.cancelLoads() }
    original.first.load(fixture.first)
    original.second.load(fixture.second)
    try await ready(original)
    original.setCustomName("Saved name", for: .first)
    let captured = try #require(original.captureSession())
    var edited = false
    let previous = restored.second.onContentsChanged
    restored.second.onContentsChanged = { [weak restored] in
      previous?()
      guard let restored, !restored.second.isLoading, !restored.second.assets.isEmpty,
        !edited else { return }
      edited = true
      restored.setCustomName("New name", for: .first)
    }
    await restored.restoreSession(captured)
    #expect(edited)
    #expect(restored.customName(for: .first) == "New name")
    #expect(restored.captureSession()?.first.customName == "New name")
  }

  @Test("별칭 편집 중 공통 키와 메뉴는 사진 선택이나 비교 화면을 바꾸지 않는다")
  func editingNamesProtectsNavigation() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = AppStore(defaults: fixture.defaults, monitorsSystemResources: false)
    let comparison = store.folderComparison
    defer { comparison.cancelLoads() }
    store.presentationMode = .folderComparison
    comparison.first.load(fixture.first)
    comparison.second.load(fixture.second)
    try await ready(comparison)
    await store.resumeWorkspace()
    try #require(!store.showsHome && store.presentationMode == .folderComparison)
    let firstID = comparison.first.currentAsset?.id
    let secondID = comparison.second.currentAsset?.id
    let shortcuts = ShortcutStore(defaults: fixture.defaults)
    comparison.isEditingNames = true
    for code in [UInt16(124), UInt16(53)] {
      let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, characters: "",
        charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
      #expect(!store.handleViewerKeyDown(event, shortcuts: shortcuts))
    }
    store.perform(.nextPage)
    store.perform(.nextFirstFolder)
    store.navigatePage(1)
    store.toggleOverview()
    store.toggleFolderComparison()
    #expect(!comparison.canNavigate(.first, direction: 1))
    #expect(!comparison.canNavigateBoth(1))
    #expect(!comparison.canNavigateSelection(1))
    comparison.navigateSelection(1)
    comparison.navigateBoth(1)
    comparison.navigate(.first, direction: 1)
    comparison.navigate(.second, direction: 1)
    comparison.jump(.first, number: 2)
    comparison.jump(.second, number: 2)
    comparison.setCustomName("Reference", for: .first)
    comparison.open(urls: [fixture.second], for: .first)
    var chooserCalls = 0
    comparison.chooseItems(for: .first) {
      chooserCalls += 1
      return [fixture.second]
    }
    comparison.choosePair { _, _ in
      chooserCalls += 1
      return fixture.second
    }
    #expect(chooserCalls == 0)
    #expect(comparison.first.sourceURLs == [fixture.first])
    #expect(comparison.customName(for: .first) == "Reference")
    #expect(comparison.first.currentAsset?.id == firstID)
    #expect(comparison.second.currentAsset?.id == secondID)
    #expect(store.presentationMode == .folderComparison)
    comparison.isEditingNames = false
    store.perform(.nextPage)
    #expect(comparison.first.index == 1 && comparison.second.index == 1)
  }

  private func ready(_ comparison: FolderComparisonStore) async throws {
    await comparison.first.waitUntilLoaded()
    await comparison.second.waitUntilLoaded()
    try #require(comparison.first.errorMessage == nil)
    try #require(comparison.second.errorMessage == nil)
  }

  private struct Fixture {
    let root: URL
    let first: URL
    let second: URL
    let defaults: UserDefaults
    let suite: String

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("comparison-names-\(UUID())")
      first = root.appendingPathComponent("Originals")
      second = root.appendingPathComponent("Edited")
      suite = "ComparisonNamesTests.\(UUID())"
      defaults = try #require(UserDefaults(suiteName: suite))
      for folder in [first, second] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["01.qoi", "02.qoi"] {
          try Self.qoi.write(to: folder.appendingPathComponent(name))
        }
      }
    }

    func folder(_ relativePath: String, count: Int) throws -> URL {
      let folder = root.appendingPathComponent(relativePath)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for index in 0..<count {
        try Self.qoi.write(to: folder.appendingPathComponent("\(index).qoi"))
      }
      return folder
    }

    func remove() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }

    private static let qoi = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
      0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
  }

  private static let zipFixture = "UEsDBBQAAAAAAF0CN12P/VI7RAAAAEQAAAAGAAAAMDEucG5niVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYIJQSwMEFAAAAAAAXQI3XY/9UjtEAAAARAAAAAYAAAAwMi5wbmeJUE5HDQoaCgAAAA1JSERSAAAAAQAAAAEIBAAAALUcDAIAAAALSURBVHjaY/z/HwADAwIA75ovWwAAAABJRU5ErkJgglBLAQIUAxQAAAAAAF0CN12P/VI7RAAAAEQAAAAGAAAAAAAAAAAAAACAAQAAAAAwMS5wbmdQSwECFAMUAAAAAABdAjddj/1SO0QAAABEAAAABgAAAAAAAAAAAAAAgAFoAAAAMDIucG5nUEsFBgAAAAACAAIAaAAAANAAAAAAAA=="
}
