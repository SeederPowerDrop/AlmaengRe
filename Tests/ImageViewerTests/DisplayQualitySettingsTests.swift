import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ImageViewer

@Suite("몽땅보기와 확대 품질 설정")
@MainActor
struct DisplayQualitySettingsTests {
  private let thumbnailSizeKey = "ImageViewer.OverviewThumbnailSize.v1"
  private let interpolationModeKey = "ImageViewer.ImageInterpolationMode.v1"

  @Test("몽땅보기 크기는 작은 아이콘부터 큰 미리보기까지 지원한다")
  func overviewThumbnailRangeAndResolution() {
    #expect(OverviewThumbnailSizing.range.lowerBound == 64 * 0.7)
    #expect(OverviewThumbnailSizing.range.upperBound == 512 * 1.3)
    #expect(OverviewThumbnailSizing.normalized(.nan) == 150)
    #expect(OverviewThumbnailSizing.normalized(.infinity) == 150)
    #expect(OverviewThumbnailSizing.normalized(-1) == 44.8)

    let small = OverviewThumbnailSizing.requestedPixelSize(for: 64, displayScale: 2)
    let large = OverviewThumbnailSizing.requestedPixelSize(for: 512, displayScale: 2)
    #expect(large > small)
    #expect(large <= 4_096)
    let maximum = OverviewThumbnailSizing.requestedPixelSize(for: 665.6, displayScale: 2)
    #expect(maximum >= Int(ceil(665.6 * 1.35 * 2)))
    #expect(OverviewThumbnailSizing.requestedPixelSize(for: .nan, displayScale: .nan) <= 4_096)
  }

  @Test("몽땅보기 크기를 다음 실행에서 복원하고 잘못된 값은 제한한다")
  func thumbnailSizePersistenceAndClamping() throws {
    let suite = "ImageViewer.DisplayQualitySettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    #expect(store.thumbnailSize == OverviewThumbnailSizing.defaultSize)

    store.thumbnailSize = 420
    #expect(defaults.double(forKey: thumbnailSizeKey) == 420)
    #expect(AppStore(defaults: defaults, monitorsSystemResources: false).thumbnailSize == 420)

    for size in [
      OverviewThumbnailSizing.range.lowerBound, OverviewThumbnailSizing.range.upperBound,
    ] {
      store.thumbnailSize = size
      #expect(AppStore(defaults: defaults, monitorsSystemResources: false).thumbnailSize == size)
    }

    store.thumbnailSize = 9_000
    #expect(store.thumbnailSize == OverviewThumbnailSizing.range.upperBound)

    defaults.set(9_000, forKey: thumbnailSizeKey)
    #expect(
      AppStore(defaults: defaults, monitorsSystemResources: false).thumbnailSize
        == OverviewThumbnailSizing.range.upperBound)
  }

  @Test("부드러운 안티앨리어싱이 기본이며 원본 픽셀 방식도 기억한다")
  func interpolationModePersistence() throws {
    let suite = "ImageViewer.DisplayQualitySettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = AppStore(defaults: defaults, monitorsSystemResources: false)
    #expect(store.imageInterpolationMode == .smooth)

    store.imageInterpolationMode = .pixelated
    #expect(
      defaults.string(forKey: interpolationModeKey)
        == ImageInterpolationMode.pixelated.rawValue)
    #expect(
      AppStore(defaults: defaults, monitorsSystemResources: false).imageInterpolationMode
        == .pixelated)
  }

  @Test("부드러운 확대는 선형 보간을 실제 표시 레이어에 적용한다")
  func backingLayerFilters() {
    let view = ExtendedRangeBackingView(frame: .zero)

    view.apply(.smooth)
    #expect(view.layer?.magnificationFilter == .linear)
    #expect(view.layer?.minificationFilter == .trilinear)

    view.apply(.pixelated)
    #expect(view.layer?.magnificationFilter == .nearest)
    #expect(view.layer?.minificationFilter == .nearest)
  }

  @Test("비교 전환과 AA 끄기는 배율·위치를 보존하고 Esc는 비교부터 종료한다")
  func comparisonLifecycle() async throws {
    let suite = "ImageViewer.ComparisonTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("comparison-lifecycle-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let photoURL = directory.appendingPathComponent("synthetic.png")
    let context = try #require(CGContext(data: nil, width: 8, height: 4,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(
      photoURL as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    let marksURL = directory.appendingPathComponent("marks.sqlite")
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: marksURL)
    store.open(urls: [photoURL])
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while (store.isLoading || store.isFiltering), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!store.isLoading && !store.isFiltering && store.assets.count == 1)
    try #require(!store.showsHome)
    store.zoom = 4
    store.panOffset = CGSize(width: 37, height: -24)
    store.baseScaleMode = .actualPixels
    store.isFocusMode = true
    store.isAntialiasingEnabled = false

    store.perform(.compareSideBySide)
    #expect(store.isAntialiasingEnabled)
    #expect(store.comparisonLayout == .sideBySide)
    store.perform(.compareStacked)
    #expect(store.comparisonLayout == .stacked)
    #expect(store.zoom == 4)
    #expect(store.panOffset == CGSize(width: 37, height: -24))
    #expect(store.baseScaleMode == .actualPixels)
    #expect(AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: marksURL).comparisonLayout == .off)

    #expect(store.handleEscapeKey())
    #expect(store.comparisonLayout == .off)
    #expect(store.isFocusMode)
    #expect(store.presentationMode == .viewer)
    #expect(store.zoom == 4)
    #expect(store.panOffset == CGSize(width: 37, height: -24))
    #expect(store.handleEscapeKey())
    #expect(!store.isFocusMode)
    #expect(store.presentationMode == .viewer)

    store.perform(.compareSideBySide)
    store.perform(.endMagnificationComparison)
    #expect(store.comparisonLayout == .off)
    #expect(store.isAntialiasingEnabled)
    store.perform(.compareStacked)
    store.perform(.toggleAntialiasing)
    #expect(!store.isAntialiasingEnabled)
    #expect(store.comparisonLayout == .off)
    #expect(!AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: marksURL).isAntialiasingEnabled)
  }

  @Test("비교 칸은 구분선을 제외한 같은 크기를 쓰며 작은 창에서도 양수다")
  func comparisonGeometry() {
    let size = CGSize(width: 1_002, height: 802)
    #expect(MagnificationComparisonLayout.off.paneSize(in: size) == size)
    #expect(
      MagnificationComparisonLayout.sideBySide.paneSize(in: size) == CGSize(width: 500, height: 802)
    )
    #expect(
      MagnificationComparisonLayout.stacked.paneSize(in: size) == CGSize(width: 1_002, height: 400))
    for layout in [MagnificationComparisonLayout.sideBySide, .stacked] {
      let pane = layout.paneSize(in: .zero)
      #expect(pane.width > 0 && pane.height > 0)
    }
  }

  @Test("큰 몽땅보기만 원본을 보강하며 크기 변경 중 다른 폴더의 미리보기를 재사용하지 않는다")
  func thumbnailContentIdentity() {
    let asset = ImageAsset(
      url: URL(fileURLWithPath: "/A/icon.png"), byteCount: 123, modificationDate: .distantPast)
    let small = ThumbnailRequest(
      asset: asset, maxPixelSize: 128, adjustments: .identity, prefersHDR: false,
      prefersPreciseImage: true)
    // 요청은 값 타입이므로 표시 품질과 내용 동일성을 따로 검증합니다.
    let large = ThumbnailRequest(
      asset: asset, maxPixelSize: 2_048, adjustments: .identity, prefersHDR: false,
      prefersPreciseImage: true)
    #expect(!small.needsPreciseImage)
    #expect(large.needsPreciseImage)
    #expect(large.hasSameContent(as: small))
    #expect(large != small)
    let otherFolder = ImageAsset(
      url: URL(fileURLWithPath: "/B/icon.png"), byteCount: 123, modificationDate: .distantPast)
    let changedFile = ImageAsset(url: asset.url, byteCount: 124, modificationDate: .distantFuture)
    for other in [otherFolder, changedFile] {
      let request = ThumbnailRequest(
        asset: other, maxPixelSize: 2_048, adjustments: .identity, prefersHDR: false)
      #expect(!request.hasSameContent(as: large))
    }
    var edited = ImageAdjustments.identity
    edited.brightness = 0.2
    let editRequest = ThumbnailRequest(
      asset: asset, maxPixelSize: 2_048, adjustments: edited, prefersHDR: false)
    #expect(!editRequest.hasSameContent(as: large))
    #expect(!editRequest.needsPreciseImage)
    let hdrRequest = ThumbnailRequest(
      asset: asset, maxPixelSize: 2_048, adjustments: .identity, prefersHDR: true)
    #expect(!hdrRequest.hasSameContent(as: large))
  }

  @Test("RAW 몽땅보기는 충분한 썸네일 뒤 원본을 중복 디코딩하지 않고 편집·HDR은 보강한다")
  func rawThumbnailAvoidsDuplicateSourceDecode() {
    let asset = ImageAsset(url: URL(fileURLWithPath: "/raw/photo.DNG"),
      byteCount: 33_000_000, modificationDate: .distantPast)
    for pixels in [512, 1_024, 2_048] {
      let request = ThumbnailRequest(asset: asset, maxPixelSize: pixels,
        adjustments: .identity, prefersHDR: false, prefersPreciseImage: true)
      #expect(!request.needsPreciseImage)
    }
    var adjusted = ImageAdjustments.identity
    adjusted.brightness = 0.2
    #expect(ThumbnailRequest(asset: asset, maxPixelSize: 1_024,
      adjustments: adjusted, prefersHDR: false, prefersPreciseImage: true).needsPreciseImage)
    #expect(ThumbnailRequest(asset: asset, maxPixelSize: 1_024,
      adjustments: .identity, prefersHDR: true, prefersPreciseImage: true).needsPreciseImage)
  }
}
