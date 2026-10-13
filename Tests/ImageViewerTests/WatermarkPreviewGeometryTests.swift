import Foundation
import Testing
@testable import ImageViewer

@Suite("워터마크 드래그 화면 좌표")
struct WatermarkPreviewGeometryTests {
  @Test("미리보기 여백이나 크기가 달라도 이동은 같은 원본 상대 위치로 바뀐다")
  func dragMapping() {
    let source = CGSize(width: 1200, height: 800)
    let rect = CGRect(x: 780, y: 600, width: 300, height: 120)
    for stage in [CGSize(width: 480, height: 560), CGSize(width: 900, height: 420)] {
      let map = WatermarkPreviewGeometry(originalSize: source,
        canvasBounds: CGRect(origin: .zero, size: source), stageSize: stage)
      let point = map.movedPosition(rect: rect,
        translation: CGSize(width: -120 * map.scale, height: 80 * map.scale))
      #expect(abs(point.x - 0.675) < 0.000_001)
      #expect(abs(point.y - 0.925) < 0.000_001)
      let displayed = map.stageRect(for: rect)
      #expect(displayed.width > 0 && displayed.height > 0)
      #expect(displayed.minX > 0)
    }
  }

  @Test("확장된 음수 원점에서도 원본과 워터마크의 간격이 일치한다")
  func expandedCanvasMapping() {
    let map = WatermarkPreviewGeometry(originalSize: CGSize(width: 1000, height: 600),
      canvasBounds: CGRect(x: -100, y: -80, width: 1100, height: 750),
      stageSize: CGSize(width: 600, height: 500))
    let photo = map.stageRect(for: CGRect(x: 0, y: 0, width: 1000, height: 600))
    let mark = map.stageRect(for: CGRect(x: -100, y: -80, width: 200, height: 160))
    #expect(abs(photo.minX - mark.minX - 100 * map.scale) < 0.000_001)
    #expect(abs(photo.minY - mark.minY - 80 * map.scale) < 0.000_001)
    let point = map.movedPosition(rect: CGRect(x: -100, y: -80, width: 200, height: 160),
      translation: .zero)
    #expect(point.x == 0 && point.y == 0)
  }

  @Test("확장을 거절하면 네 방향에서 사진 안으로 돌아간다")
  func declinedExpansionClamps() {
    let source = CGSize(width: 1000, height: 500)
    let mark = CGSize(width: 200, height: 100)
    let canvas = CGRect(origin: .zero, size: source)
    for point in [WatermarkPoint(x: -0.2, y: 0.5), WatermarkPoint(x: 1.2, y: 0.5),
      WatermarkPoint(x: 0.5, y: -0.2), WatermarkPoint(x: 0.5, y: 1.2)] {
      let clamped = WatermarkPreviewGeometry.clampedPosition(point, overlaySize: mark, originalSize: source)
      let rect = WatermarkPreviewGeometry.rect(center: clamped, overlaySize: mark, originalSize: source)
      #expect(canvas.contains(rect))
      #expect(rect.size == mark)
    }
  }
}
