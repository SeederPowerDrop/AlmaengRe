import AppKit
import ImageIO
import Testing

@testable import ImageViewer

@Suite("전자 앨범과 안전한 바탕화면 설정")
@MainActor
struct SlideshowAndWallpaperTests {
  @Test("간격 범위·저장·반복은 유지하고 재생 상태는 복원하지 않는다")
  func preferences() throws {
    #expect(SlideshowSettings.normalized(.nan) == 5)
    #expect(SlideshowSettings.normalized(.infinity) == 5)
    #expect(SlideshowSettings.normalized(-20) == 1)
    #expect(SlideshowSettings.normalized(999) == 300)
    #expect(SlideshowSettings.normalized(4.6) == 5)
    let suite = "AlbumTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    #expect(store.slideshowInterval == 5)
    #expect(store.slideshowRepeats)
    store.slideshowInterval = 17
    store.slideshowRepeats = false
    let restored = AppStore(defaults: defaults, monitorsSystemResources: false)
    #expect(restored.slideshowInterval == 17)
    #expect(!restored.slideshowRepeats)
    #expect(!restored.isSlideshowPlaying)
    store.slideshowInterval = .nan
    #expect(store.slideshowInterval == 5)
    #expect(defaults.double(forKey: "ImageViewer.SlideshowInterval.v1") == 5)
  }

  @Test("재생은 현재 사진에서 한 장 집중 보기로 시작하고 마지막 사진에서 정지·반복한다")
  func playbackSequence() async throws {
    let folder = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (store, suite) = await makeStore(folder)
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    defer { store.pauseSlideshow() }
    store.select(index: 1)
    store.setImagesPerPage(3)
    store.setActualPixels()
    store.setComparisonLayout(.sideBySide)
    store.slideshowRepeats = false
    store.toggleSlideshow()
    #expect(store.isFocusMode && store.isSlideshowPlaying)
    #expect(store.imagesPerPage == 1 && store.pageStartIndex == 1)
    #expect(store.baseScaleMode == .fit && store.comparisonLayout == .off)
    store.slideshowAssetPresented(try #require(store.currentAsset))
    store.advanceSlideshow()
    #expect(store.currentIndex == 2)
    store.slideshowAssetPresented(try #require(store.currentAsset))
    store.advanceSlideshow()
    #expect(store.currentIndex == 2 && !store.isSlideshowPlaying && store.isFocusMode)
    store.slideshowRepeats = true
    store.toggleSlideshow()
    store.advanceSlideshow()
    #expect(store.currentIndex == 0 && store.isSlideshowPlaying)
    #expect(store.handleEscapeKey())
    #expect(!store.isSlideshowPlaying && !store.isFocusMode)
    #expect(SlideshowSettings.nextIndex(after: 0, count: 1, repeats: true) == nil)
    #expect(SlideshowSettings.nextIndex(after: -1, count: 3, repeats: true) == nil)
  }

  @Test("표시 전에는 기다리고 표시 후 한 번만 넘기며 일시정지는 타이머를 취소한다")
  func realTimer() async throws {
    let folder = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (store, suite) = await makeStore(folder)
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    defer { store.pauseSlideshow() }
    store.slideshowInterval = 1
    store.toggleSlideshow()
    try await Task.sleep(for: .milliseconds(1150))
    #expect(store.currentIndex == 0 && store.isSlideshowPlaying)
    let first = try #require(store.currentAsset)
    store.slideshowAssetPresented(first)
    try await waitUntil { store.currentIndex == 1 }
    // 이전 애니메이션이나 이전 파일에서 도착한 결과는 다음 사진 타이머를 열지 못합니다.
    store.slideshowAssetPresented(first)
    try await Task.sleep(for: .milliseconds(1150))
    #expect(store.currentIndex == 1)
    store.slideshowAssetPresented(try #require(store.currentAsset))
    store.pauseSlideshow()
    try await Task.sleep(for: .milliseconds(1150))
    #expect(store.currentIndex == 1 && !store.isSlideshowPlaying)
  }

  @Test("간격 변경과 수동 탐색이 이전 카운트다운을 폐기한다")
  func timerReset() async throws {
    let folder = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (store, suite) = await makeStore(folder)
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    defer { store.pauseSlideshow() }
    store.slideshowInterval = 1
    store.toggleSlideshow()
    store.slideshowAssetPresented(try #require(store.currentAsset))
    store.slideshowInterval = 300
    try await Task.sleep(for: .milliseconds(1150))
    #expect(store.currentIndex == 0)
    store.slideshowInterval = 1
    store.navigatePage(1)
    try await Task.sleep(for: .milliseconds(1150))
    #expect(store.currentIndex == 1 && store.isSlideshowPlaying)
    store.slideshowAssetPresented(try #require(store.currentAsset))
    try await waitUntil { store.currentIndex == 2 }
  }

  @Test("몽땅보기·시트·폴더 변경은 재생을 중지하고 이전 준비 결과를 무시한다")
  func transitionSafety() async throws {
    let a = try makeLibrary(), b = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    let (store, suite) = await makeStore(a)
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    defer { store.pauseSlideshow() }
    store.toggleSlideshow()
    store.presentationMode = .overview
    #expect(!store.isSlideshowPlaying)
    store.toggleSlideshow()
    store.presentBatchRename()
    #expect(!store.isSlideshowPlaying && !store.canStartSlideshow)
    store.batchSheet = nil
    store.toggleSlideshow()
    let old = try #require(store.currentAsset)
    store.open(urls: [b])
    #expect(!store.isSlideshowPlaying)
    try await waitUntil { !store.isLoading }
    store.slideshowAssetPresented(old)
    #expect(!store.isSlideshowPlaying && store.currentAsset != old)
    let empty = AppStore(monitorsSystemResources: false)
    empty.toggleSlideshow()
    #expect(!empty.isSlideshowPlaying && !empty.canSetWallpaper)
  }

  @Test("바탕화면은 보정된 별도 PNG로 지정 화면에만 적용하며 원본과 기존 사본을 보존한다")
  func wallpaperCopy() async throws {
    let folder = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("1.qoi")
    let original = try Data(contentsOf: source)
    let client = FakeDesktopClient()
    let service = WallpaperService(pipeline: ImagePipeline(),
      directory: folder.appendingPathComponent("Wallpapers"), client: client)
    var adjustments = ImageAdjustments.identity
    adjustments.rotateClockwise()
    let request = WallpaperRequest(asset: ImageAsset(url: source, byteCount: nil, modificationDate: nil), adjustments: adjustments,
      displays: client.displays, currentDisplayID: 2)
    let first = try await service.apply(request: request, displayIDs: [2],
      scaling: .fit, appliesAdjustments: true)
    #expect(first.appliedCount == 1 && first.failures.isEmpty)
    #expect(client.calls.map(\.id) == [2])
    #expect(client.calls.first?.scaling == .fit)
    #expect(first.imageURL != source)
    let imageSource = try #require(CGImageSourceCreateWithURL(first.imageURL as CFURL, nil))
    #expect(CGImageSourceGetType(imageSource) as String? == "public.png")
    let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
    #expect(image.width == 1 && image.height == 2)
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any])
    #expect(properties[kCGImagePropertyGPSDictionary as String] == nil)
    let second = try await service.apply(request: request, displayIDs: [1, 2],
      scaling: .fill, appliesAdjustments: false)
    let secondSource = try #require(CGImageSourceCreateWithURL(second.imageURL as CFURL, nil))
    let unrotated = try #require(CGImageSourceCreateImageAtIndex(secondSource, 0, nil))
    #expect(unrotated.width == 2 && unrotated.height == 1)
    #expect(second.appliedCount == 2 && second.imageURL != first.imageURL)
    #expect(FileManager.default.fileExists(atPath: first.imageURL.path))
    #expect(try Data(contentsOf: source) == original)
  }

  @Test("일부 화면 실패는 성공한 사본을 보존하고 전체 실패만 미사용 사본을 정리한다")
  func wallpaperFailure() async throws {
    let folder = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("1.qoi")
    let client = FakeDesktopClient()
    let service = WallpaperService(pipeline: ImagePipeline(),
      directory: folder.appendingPathComponent("Wallpapers"), client: client)
    let request = WallpaperRequest(asset: ImageAsset(url: source, byteCount: nil, modificationDate: nil), adjustments: .identity,
      displays: client.displays, currentDisplayID: 1)
    client.failingIDs = [2]
    let partial = try await service.apply(request: request, displayIDs: [1, 2],
      scaling: .fit, appliesAdjustments: false)
    #expect(partial.appliedCount == 1 && partial.failures.count == 1)
    #expect(FileManager.default.fileExists(atPath: partial.imageURL.path))
    client.failingIDs = [1, 2]
    let failed = try await service.apply(request: request, displayIDs: [1, 2],
      scaling: .fill, appliesAdjustments: false)
    #expect(failed.appliedCount == 0 && failed.failures.count == 2)
    #expect(!FileManager.default.fileExists(atPath: failed.imageURL.path))
    #expect(FileManager.default.fileExists(atPath: partial.imageURL.path))
    #expect(FileManager.default.fileExists(atPath: source.path))
    await #expect(throws: WallpaperError.self) {
      try await service.apply(request: request, displayIDs: [999], scaling: .fit, appliesAdjustments: false)
    }
  }

  @Test("큰 화면도 출력 제한을 지키며 8개 언어와 새 단축키를 제공한다")
  func localizationAndSizing() {
    #expect(WallpaperService.pixelLimit(for: []) == 2048)
    #expect(WallpaperService.pixelLimit(for: [
      WallpaperDisplay(id: 1, name: "Huge", pixelSize: CGSize(width: 50000, height: 10000))
    ]) == 8192)
    let keys = [
      "전자 앨범",
      "전자 앨범 재생/일시정지",
      "전자 앨범 재생",
      "전자 앨범 일시정지",
      "전자 앨범 설정",
      "사진 표시 시간(초)",
      "전자 앨범 반복 재생",
      "%d초 간격",
      "전자 앨범 재생 완료",
      "1~300초. 사진이 표시된 뒤 시간을 셉니다. 집중 보기를 나가거나 다른 앱으로 전환하면 일시정지합니다.",
      "탐색 → 전자 앨범 또는 집중 보기 하단의 재생 버튼으로 시작합니다. 두 장 이상의 사진이 필요합니다.",
      "현재 이미지를 바탕화면으로 설정",
      "사진 전체 맞춤",
      "화면 채우기",
      "선택한 화면을 찾을 수 없습니다.",
      "바탕화면을 설정할 수 없음",
      "%d개 화면의 바탕화면 설정 완료",
      "바탕화면 설정 결과",
      "%d개 화면에 적용했습니다.\n%@",
      "적용할 화면",
      "이 화면: %@",
      "모든 연결된 화면",
      "사진 배치",
      "현재 보정 적용",
      "원본은 변경하지 않습니다. 별도 PNG 사본을 보관하며, 애니메이션은 첫 프레임·HDR은 SDR로 적용합니다. 다른 데스크탑 공간은 macOS 설정을 따릅니다.",
      "바탕화면 이미지 준비 중…",
      "바탕화면에 적용",
    ]
    for locale in L10n.supportedLocalizations {
      for key in keys {
        #expect(L10n.keys(localeIdentifier: locale).contains(key))
        #expect(!L10n.text(key, localeIdentifier: locale).isEmpty)
      }
    }
    #expect(ShortcutAction.toggleSlideshow.defaultBinding == KeyBinding(key: "p", modifiers: [.control, .option]))
    #expect(ShortcutAction.setWallpaper.defaultBinding == KeyBinding(key: "w", modifiers: [.control, .option]))
  }

  private func makeStore(_ folder: URL) async -> (AppStore, String) {
    let suite = "AlbumPlaybackTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    // 각 시험은 별도 설정 영역을 쓰고 반환된 이름으로 종료 시 정리합니다.
    store.slideshowInterval = 300
    store.slideshowRepeats = true
    store.open(urls: [folder])
    for _ in 0..<300 {
      if !store.isLoading { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(store.assets.count == 3)
    return (store, suite)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
  }

  private func makeLibrary() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("album-test-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let data = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 2, 0, 0, 0, 1, 3, 0,
      0xfe, 255, 0, 0, 0xfe, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    for i in 1...3 { try data.write(to: folder.appendingPathComponent("\(i).qoi")) }
    return folder
  }
}

@MainActor
private final class FakeDesktopClient: DesktopWallpaperClient {
  let displays = [
    WallpaperDisplay(id: 1, name: "First", pixelSize: CGSize(width: 1920, height: 1080)),
    WallpaperDisplay(id: 2, name: "Second", pixelSize: CGSize(width: 2560, height: 1440)),
  ]
  var failingIDs: Set<UInt32> = []
  var calls: [(id: UInt32, scaling: WallpaperScaling)] = []
  func setImage(at url: URL, displayID: UInt32, scaling: WallpaperScaling) throws {
    #expect(FileManager.default.fileExists(atPath: url.path))
    if failingIDs.contains(displayID) { throw WallpaperError.displayUnavailable }
    calls.append((displayID, scaling))
  }
}
