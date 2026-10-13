import AppKit
import Testing

@testable import ImageViewer

@Suite("몽땅보기 번호와 드래그 영역 선택")
@MainActor
struct OverviewInteractionTests {
  @Test("실제 사진 면적의 ¼ 경계와 가로·세로 사진을 판정한다")
  func numberPlacement() {
    let badge = CGSize(width: 40, height: 20)
    #expect(OverviewNumberPlacement.isOutside(badge: badge, image: CGSize(width: 80, height: 40)))
    #expect(!OverviewNumberPlacement.isOutside(badge: badge, image: CGSize(width: 81, height: 40)))
    #expect(OverviewNumberPlacement.isOutside(badge: badge, image: nil))
    #expect(OverviewNumberPlacement.isOutside(badge: badge, image: .zero))
    let bounds = CGSize(width: 100, height: 100)
    let portrait = OverviewNumberPlacement.fittedImageSize(pixels: CGSize(width: 20, height: 100), in: bounds)
    #expect(portrait == CGSize(width: 20, height: 100))
    #expect(OverviewNumberPlacement.isOutside(badge: badge, image: portrait))
    let landscape = OverviewNumberPlacement.fittedImageSize(pixels: CGSize(width: 100, height: 20), in: bounds)
    #expect(landscape == CGSize(width: 100, height: 20))
    #expect(OverviewNumberPlacement.isOutside(badge: badge, image: landscape))
    #expect(!OverviewNumberPlacement.isOutside(badge: badge, image: bounds))
    #expect(OverviewNumberPlacement.fittedImageSize(pixels: .zero, in: bounds) == nil)
    #expect(OverviewNumberPlacement.fittedImageSize(pixels: bounds, in: .zero) == nil)
  }

  @Test("한 자리부터 긴 번호까지 배지 면적에 따라 배치하고 숨김을 저장한다")
  func badgeSizeAndPersistence() throws {
    let image = CGSize(width: 60, height: 60)
    #expect(!OverviewNumberPlacement.isOutside(badge: CGSize(width: 18, height: 20), image: image))
    #expect(OverviewNumberPlacement.isOutside(badge: CGSize(width: 50, height: 20), image: image))
    let suite = "ImageViewer.OverviewNumbersTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    #expect(store.showsOverviewNumbers)
    store.showsOverviewNumbers = false
    #expect(!AppStore(defaults: defaults, monitorsSystemResources: false).showsOverviewNumbers)
    store.showsOverviewNumbers = true
    #expect(AppStore(defaults: defaults, monitorsSystemResources: false).showsOverviewNumbers)
  }

  @Test("역방향·셀 사이 여백·스크롤된 좌표에서도 사각형 교차를 계산한다")
  func marqueeGeometry() {
    let a = URL(fileURLWithPath: "/A/a.png"), b = URL(fileURLWithPath: "/A/b.png")
    let frames = [a: CGRect(x: 18, y: 600, width: 70, height: 90),
      b: CGRect(x: 100, y: 600, width: 70, height: 90)]
    let rect = OverviewMarqueeGeometry.rectangle(from: CGPoint(x: 169, y: 685), to: CGPoint(x: 19, y: 601))
    #expect(rect == CGRect(x: 19, y: 601, width: 150, height: 84))
    #expect(OverviewMarqueeGeometry.hits(in: rect, frames: frames) == [a, b])
    #expect(OverviewMarqueeGeometry.hits(in: CGRect(x: 88, y: 600, width: 12, height: 90), frames: frames).isEmpty)
    #expect(OverviewMarqueeGeometry.hits(in: .zero, frames: frames).isEmpty)
  }

  @Test("10개 언어에 번호 설정과 드래그 안내가 존재한다")
  func localization() {
    for locale in L10n.supportedLocalizations {
      for key in ["몽땅보기 번호 표시", "번호가 이미지 면적의 ¼ 이상을 차지하면 사진 밖 카드의 왼쪽 위로 옮깁니다.",
        "드래그로 영역 선택 · Shift로 추가 · ⌘로 반전 · Esc로 취소"] {
        #expect(L10n.keys(localeIdentifier: locale).contains(key))
        #expect(!L10n.text(key, localeIdentifier: locale).isEmpty)
      }
    }
  }

  @Test("영역을 줄여도 선택이 누적되지 않고 초점·보정을 유지하며 취소할 수 있다")
  func selectionSession() async throws {
    let folder = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(monitorsSystemResources: false)
    store.open(urls: [folder])
    try await waitForLoad(store)
    let urls = store.assets.map(\.url)
    store.select(index: 2)
    store.rotateClockwise()
    store.presentationMode = .overview
    let session = try #require(store.beginOverviewSelection(modifiers: []))
    store.updateOverviewSelection(session, hits: Set(urls[0...1]))
    #expect(store.selectedURLs == Set(urls[0...1]))
    #expect(store.currentIndex == 2)
    #expect(store.currentAdjustments.normalizedQuarterTurns == 1)
    #expect(!store.canStartBatchOperation)
    store.updateOverviewSelection(session, hits: [urls[1]])
    #expect(store.selectedURLs == [urls[1]])
    #expect(store.handleEscapeKey())
    #expect(store.selectedURLs == [urls[2]])
    store.updateOverviewSelection(session, hits: Set(urls))
    #expect(store.selectedURLs == [urls[2]])

    let added = try #require(store.beginOverviewSelection(modifiers: .shift))
    store.updateOverviewSelection(added, hits: [urls[1]])
    store.finishOverviewSelection(added)
    #expect(store.selectedURLs == [urls[1], urls[2]])
    let toggled = try #require(store.beginOverviewSelection(modifiers: .command))
    store.updateOverviewSelection(toggled, hits: [urls[0], urls[1]])
    #expect(store.selectedURLs == [urls[0], urls[2]])
    store.updateOverviewSelection(toggled, hits: [urls[1]])
    #expect(store.selectedURLs == [urls[2]])
    store.finishOverviewSelection(toggled)
    #expect(store.canStartBatchOperation)
    // 다음 Shift 클릭은 확정된 선택 위치를 기준으로 합니다.
    store.selectForBatch(index: 3, modifiers: .shift)
    #expect(store.selectedURLs == [urls[2], urls[3]])
  }

  @Test("빈 영역·시트 중 금지·폴더 전환 뒤 늦은 이벤트를 처리한다")
  func selectionSafety() async throws {
    let a = try makeLibrary(), b = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    let store = AppStore(monitorsSystemResources: false)
    store.open(urls: [a])
    try await waitForLoad(store)
    let oldURLs = Set(store.assets.map(\.url))
    store.presentationMode = .overview
    let empty = try #require(store.beginOverviewSelection(modifiers: []))
    store.updateOverviewSelection(empty, hits: [URL(fileURLWithPath: "/not-in-library.png")])
    store.finishOverviewSelection(empty)
    #expect(store.selectedURLs.isEmpty)
    store.selectAllAssets()
    store.presentBatchRename()
    #expect(store.beginOverviewSelection(modifiers: []) == nil)
    store.batchSheet = nil
    let stale = try #require(store.beginOverviewSelection(modifiers: []))
    store.open(urls: [b])
    try await waitForLoad(store)
    let currentSelection = store.selectedURLs
    store.updateOverviewSelection(stale, hits: oldURLs)
    store.cancelOverviewSelection(stale)
    #expect(store.selectedURLs == currentSelection)
    #expect(store.overviewSelectionSession == nil)
    #expect(store.selectedURLs.isDisjoint(with: oldURLs))
  }

  private func makeLibrary() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("overview-test-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let qoi = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
      0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    for i in 1...4 { try qoi.write(to: folder.appendingPathComponent("photo\(i).qoi")) }
    return folder
  }

  private func waitForLoad(_ store: AppStore) async throws {
    for _ in 0..<200 {
      if !store.isLoading { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!store.isLoading && store.assets.count == 4)
  }
}
