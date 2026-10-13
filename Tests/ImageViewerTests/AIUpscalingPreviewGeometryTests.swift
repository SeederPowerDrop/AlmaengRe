import Foundation
import Testing
@testable import ImageViewer

@Suite("AI 확대 미리보기 좌표")
struct AIUpscalingPreviewGeometryTests {
  @Test("100%는 출력 이미지 픽셀과 디스플레이 픽셀의 1:1 비율이다")
  func actualPixelsUsesDisplayScale() {
    for backingScale: CGFloat in [1, 2] {
      var geometry = AIUpscalingPreviewGeometry(imageSize: CGSize(width: 4000, height: 3000),
        viewportSize: CGSize(width: 1000, height: 800), backingScale: backingScale)
      geometry.setZoom(1)
      #expect(geometry.imageRect.width * backingScale == 4000)
      #expect(geometry.imageRect.height * backingScale == 3000)
      #expect(geometry.zoom == 1)
      #expect(!geometry.fitsWindow)
    }
  }

  @Test("100%에서 소수점 이동 후에도 이미지 원점이 디스플레이 픽셀에 맞는다")
  func actualPixelsSnapsRenderedOrigin() {
    for backingScale: CGFloat in [1, 2] {
      var geometry = AIUpscalingPreviewGeometry(imageSize: CGSize(width: 4000, height: 3000),
        viewportSize: CGSize(width: 999, height: 799), backingScale: backingScale)
      geometry.setZoom(1)
      geometry.pan(by: CGSize(width: 12.13, height: -9.37))
      let center = geometry.center
      let rect = geometry.drawingRect
      #expect(rect.minX * backingScale == (rect.minX * backingScale).rounded())
      #expect(rect.minY * backingScale == (rect.minY * backingScale).rounded())
      #expect(rect.size == geometry.imageRect.size)
      #expect(geometry.center == center)
      geometry.setZoom(1.25)
      #expect(geometry.drawingRect == geometry.imageRect)
    }
  }

  @Test("맞춤은 비율을 유지하며 창과 디스플레이 변화에 맞춰 다시 계산한다")
  func fitFollowsViewport() {
    var geometry = AIUpscalingPreviewGeometry(imageSize: CGSize(width: 4000, height: 2000),
      viewportSize: CGSize(width: 1000, height: 800), backingScale: 2)
    #expect(geometry.zoom == 0.5)
    #expect(geometry.imageRect == CGRect(x: 0, y: 150, width: 1000, height: 500))
    geometry.resize(to: CGSize(width: 600, height: 600), backingScale: 1)
    #expect(geometry.zoom == 0.15)
    #expect(geometry.imageRect == CGRect(x: 0, y: 150, width: 600, height: 300))
    #expect(geometry.fitsWindow)
  }

  @Test("핀치 위치의 동일한 이미지 지점이 확대 후에도 유지된다")
  func cursorAnchorSurvivesZoom() {
    var geometry = AIUpscalingPreviewGeometry(imageSize: CGSize(width: 4000, height: 3000),
      viewportSize: CGSize(width: 1000, height: 800), backingScale: 2)
    geometry.setZoom(1)
    let cursor = CGPoint(x: 750, y: 250)
    let originalPoint = geometry.imagePoint(at: cursor)
    geometry.setZoom(2.5, around: cursor)
    let newPoint = geometry.imagePoint(at: cursor)
    #expect(abs(originalPoint.x - newPoint.x) < 0.000_001)
    #expect(abs(originalPoint.y - newPoint.y) < 0.000_001)
  }

  @Test("버튼 확대와 창 크기 변경은 보고 있던 이미지 중심을 유지한다")
  func centerSurvivesToolbarZoomAndResize() {
    var geometry = AIUpscalingPreviewGeometry(imageSize: CGSize(width: 4000, height: 3000),
      viewportSize: CGSize(width: 1000, height: 800), backingScale: 2)
    geometry.setZoom(1)
    geometry.pan(by: CGSize(width: 150, height: -100))
    let center = geometry.center
    geometry.setZoom(2)
    #expect(geometry.center == center)
    geometry.resize(to: CGSize(width: 1200, height: 900), backingScale: 1)
    #expect(geometry.center == center)
    #expect(geometry.zoom == 2)
    #expect(!geometry.fitsWindow)
  }

  @Test("확대 중 이동은 네 모서리에서 제한되고 작은 이미지는 중앙에 남는다")
  func panClampsToImageBounds() {
    var geometry = AIUpscalingPreviewGeometry(imageSize: CGSize(width: 4000, height: 2000),
      viewportSize: CGSize(width: 1000, height: 800), backingScale: 2)
    geometry.setZoom(1)
    geometry.pan(by: CGSize(width: 100_000, height: -100_000))
    #expect(geometry.imageRect.minX == 0)
    #expect(geometry.imageRect.maxY == geometry.viewportSize.height)
    geometry.pan(by: CGSize(width: -100_000, height: 100_000))
    #expect(geometry.imageRect.maxX == geometry.viewportSize.width)
    #expect(geometry.imageRect.minY == 0)
    geometry.setZoom(0.25)
    geometry.pan(by: CGSize(width: 100_000, height: -100_000))
    #expect(geometry.imageRect.midX == geometry.viewportSize.width / 2)
    #expect(geometry.imageRect.midY == geometry.viewportSize.height / 2)
  }

  @Test("아주 작거나 큰 이미지도 맞춤이 가능하고 수동 배율은 제한된다")
  func zoomBoundsPreserveFit() {
    var small = AIUpscalingPreviewGeometry(imageSize: CGSize(width: 20, height: 20),
      viewportSize: CGSize(width: 1000, height: 800), backingScale: 2)
    #expect(small.zoom == 80)
    #expect(small.imageRect.size == CGSize(width: 800, height: 800))
    small.setZoom(1)
    #expect(small.zoom == 1)
    small.setZoom(0.00001)
    #expect(small.zoom == AIUpscalingPreviewGeometry.minimumZoom)
    var large = AIUpscalingPreviewGeometry(imageSize: CGSize(width: 200_000, height: 100_000),
      viewportSize: CGSize(width: 500, height: 500), backingScale: 2)
    #expect(large.zoom == 0.005)
    large.setZoom(10_000)
    #expect(large.zoom == AIUpscalingPreviewGeometry.maximumZoom)
    large.setZoom(.infinity)
    large.setZoom(.nan)
    large.pan(by: CGSize(width: CGFloat.infinity, height: CGFloat.nan))
    #expect(large.zoom == AIUpscalingPreviewGeometry.maximumZoom)
    #expect(large.center.x.isFinite && large.center.y.isFinite)
  }
}
