import Foundation
import Testing

@testable import ImageViewer

@Suite("워터마크 드래그 위치와 캔버스 확장")
struct WatermarkPlacementTests {
  @Test("9개 기준 위치는 짧은 변 기준 여백과 가로·세로 중앙을 사용한다")
  func nineAnchors() throws {
    let positions: [(WatermarkPosition, CGFloat, CGFloat)] = [
      (.topLeading, 10, 10), (.top, 80, 10), (.topTrailing, 150, 10),
      (.leading, 10, 40), (.center, 80, 40), (.trailing, 150, 40),
      (.bottomLeading, 10, 70), (.bottom, 80, 70), (.bottomTrailing, 150, 70),
    ]
    for (position, x, y) in positions {
      let result = try layout(position: position)
      #expect(result.requestedRect == CGRect(x: x, y: y, width: 40, height: 20))
      #expect(result.effectiveRect == result.requestedRect)
      #expect(result.canvasBounds == CGRect(x: 0, y: 0, width: 200, height: 100))
      #expect(!result.isOutsideOriginal)
    }
  }

  @Test("사용자 위치는 여러 종횡비에서도 원본을 기준으로 정규화한 중심이다")
  func normalizedCentersAndRoundTrip() throws {
    let point = WatermarkPoint(x: 0.25, y: 0.75)
    #expect(try JSONDecoder().decode(WatermarkPoint.self, from: JSONEncoder().encode(point)) == point)
    for size in [CGSize(width: 800, height: 200), CGSize(width: 200, height: 800), CGSize(width: 300, height: 300)] {
      let result = try layout(original: size, custom: point)
      #expect(result.requestedRect.midX == size.width * 0.25)
      #expect(result.requestedRect.midY == size.height * 0.75)
      #expect(result.effectiveRect == result.requestedRect)
    }
  }

  @Test("확장하지 않을 때 사용자가 드래그한 블록은 여백과 무관하게 네 모서리까지 이동한다")
  func clampsAtPhysicalEdges() throws {
    let cases: [(WatermarkPoint, CGPoint)] = [
      (WatermarkPoint(x: -1, y: -1), .zero),
      (WatermarkPoint(x: 2, y: -1), CGPoint(x: 160, y: 0)),
      (WatermarkPoint(x: -1, y: 2), CGPoint(x: 0, y: 80)),
      (WatermarkPoint(x: 2, y: 2), CGPoint(x: 160, y: 80)),
    ]
    for (point, origin) in cases {
      let result = try layout(custom: point)
      #expect(result.isOutsideOriginal)
      #expect(result.effectiveRect.origin == origin)
      #expect(result.originalRectInCanvas == CGRect(x: 0, y: 0, width: 200, height: 100))
    }
  }

  @Test("드래그한 좌표는 정수로 반올림하지 않고 기준 위치와 여백을 무시한다")
  func fractionalDragIsPreserved() throws {
    let point = WatermarkPoint(x: 0.333, y: 0.427)
    let first = try layout(position: .topLeading, margin: 0, custom: point)
    let second = try layout(position: .bottomTrailing, margin: 0.2, custom: point)
    #expect(first == second)
    #expect(abs(first.effectiveRect.minX - 46.6) < 0.000_001)
    #expect(abs(first.effectiveRect.minY - 32.7) < 0.000_001)
  }

  @Test("캔버스는 넘어간 방향으로만 확장하며 음수 원점을 원본의 출력 위치로 변환한다")
  func extendsEachSide() throws {
    let cases: [(WatermarkPoint, CGRect, CGRect)] = [
      (WatermarkPoint(x: 0, y: 0.5), CGRect(x: -20, y: 0, width: 220, height: 100), CGRect(x: 20, y: 0, width: 200, height: 100)),
      (WatermarkPoint(x: 1, y: 0.5), CGRect(x: 0, y: 0, width: 220, height: 100), CGRect(x: 0, y: 0, width: 200, height: 100)),
      (WatermarkPoint(x: 0.5, y: 0), CGRect(x: 0, y: -10, width: 200, height: 110), CGRect(x: 0, y: 10, width: 200, height: 100)),
      (WatermarkPoint(x: 0.5, y: 1), CGRect(x: 0, y: 0, width: 200, height: 110), CGRect(x: 0, y: 0, width: 200, height: 100)),
    ]
    for (point, canvas, source) in cases {
      let result = try layout(custom: point, expands: true)
      #expect(result.canvasBounds == canvas)
      #expect(result.originalRectInCanvas == source)
      #expect(result.effectiveRect == result.requestedRect && result.isOutsideOriginal)
    }
  }

  @Test("바깥쪽 정수 경계는 원본과 블록을 포함하는 최소 크기이며 모든 방향을 동시에 확장한다")
  func integralOutwardUnion() throws {
    let corner = try layout(custom: WatermarkPoint(x: 0.001, y: 0.001), expands: true)
    #expect(abs(corner.requestedRect.minX + 19.8) < 0.000_001)
    #expect(abs(corner.requestedRect.minY + 9.9) < 0.000_001)
    #expect(corner.canvasBounds == CGRect(x: -20, y: -10, width: 220, height: 110))
    let allSides = try layout(overlay: CGSize(width: 240.5, height: 120.25),
      custom: WatermarkPoint(x: 0.5, y: 0.5), expands: true)
    #expect(allSides.requestedRect == CGRect(x: -20.25, y: -10.125, width: 240.5, height: 120.25))
    #expect(allSides.canvasBounds == CGRect(x: -21, y: -11, width: 242, height: 122))
    #expect(allSides.originalRectInCanvas.origin == CGPoint(x: 21, y: 11))
  }

  @Test("블록이 원본보다 크면 확장 없이 잘라내지 않고 명시적 맞춤 비율을 제공한다")
  func oversizedOverlayReportsFittingScale() {
    #expect(throws: WatermarkError.contentOverflow(fittingScale: 0.5)) {
      try layout(overlay: CGSize(width: 400, height: 30))
    }
    #expect(throws: WatermarkError.contentOverflow(fittingScale: 0.25)) {
      try layout(overlay: CGSize(width: 300, height: 400))
    }
  }

  @Test("원본과 같은 블록은 여백이 있어도 확대 없이 이미지 전체에 맞춘다")
  func fullImageOverlayFits() throws {
    let result = try layout(overlay: CGSize(width: 200, height: 100), position: .topLeading)
    #expect(result.requestedRect.origin == CGPoint(x: 10, y: 10))
    #expect(result.isOutsideOriginal)
    #expect(result.effectiveRect == CGRect(x: 0, y: 0, width: 200, height: 100))
  }

  @Test("유한한 양수 크기와 여백 및 제한 범위의 사용자 좌표만 허용한다")
  func invalidInputs() {
    for size in [CGSize.zero, CGSize(width: -1, height: 100), CGSize(width: CGFloat.nan, height: 100), CGSize(width: 100, height: CGFloat.infinity)] {
      #expect(throws: WatermarkError.invalidOptions) { try layout(original: size) }
      #expect(throws: WatermarkError.invalidOptions) { try layout(overlay: size) }
    }
    for margin in [-0.1, 0.201, Double.nan, Double.infinity] {
      #expect(throws: WatermarkError.invalidOptions) { try layout(margin: margin) }
    }
    for point in [WatermarkPoint(x: .nan, y: 0), WatermarkPoint(x: 0, y: .infinity),
      WatermarkPoint(x: -4.01, y: 0), WatermarkPoint(x: 0, y: 5.01)] {
      #expect(throws: WatermarkError.invalidOptions) { try layout(custom: point) }
    }
  }

  @Test("확장 안전 한도는 축과 총 픽셀을 각각 검사하고 한도에 정확히 맞는 크기는 허용한다")
  func expansionLimits() throws {
    let axisLimit = try layout(original: CGSize(width: 32_760, height: 10), overlay: CGSize(width: 16, height: 2),
      custom: WatermarkPoint(x: 1, y: 0.5), expands: true)
    #expect(axisLimit.canvasBounds.width == 32_768)
    #expect(throws: WatermarkError.unsafeCanvas) {
      try layout(original: CGSize(width: 32_761, height: 10), overlay: CGSize(width: 16, height: 2),
        custom: WatermarkPoint(x: 1, y: 0.5), expands: true)
    }
    let pixelLimit = try layout(original: CGSize(width: 7_990, height: 8_000), overlay: CGSize(width: 20, height: 20),
      custom: WatermarkPoint(x: 1, y: 0.5), expands: true)
    #expect(pixelLimit.canvasBounds.size == CGSize(width: 8_000, height: 8_000))
    #expect(throws: WatermarkError.unsafeCanvas) {
      try layout(original: CGSize(width: 7_991, height: 8_000), overlay: CGSize(width: 20, height: 20),
        custom: WatermarkPoint(x: 1, y: 0.5), expands: true)
    }
  }

  @Test("확장하지 않는 큰 원본에는 새 캔버스 한도를 적용하지 않는다")
  func unexpandedLargeOriginalIsAllowed() throws {
    let size = CGSize(width: 40_000, height: 20_000)
    for expands in [false, true] {
      let result = try layout(original: size, custom: WatermarkPoint(x: 0.5, y: 0.5), expands: expands)
      #expect(result.canvasBounds.size == size)
      #expect(!result.isOutsideOriginal)
    }
    #expect(throws: WatermarkError.unsafeCanvas) {
      try layout(original: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 100),
        custom: WatermarkPoint(x: 5, y: 0.5), expands: true)
    }
  }

  @Test("허용한 사용자 좌표 범위의 양끝은 확장하지 않을 때 이미지 가장자리로 제한한다")
  func customRangeEndpoints() throws {
    let result = try layout(custom: WatermarkPoint(x: -4, y: 5))
    #expect(result.effectiveRect.origin == CGPoint(x: 0, y: 80))
  }

  private func layout(original: CGSize = CGSize(width: 200, height: 100),
    overlay: CGSize = CGSize(width: 40, height: 20), position: WatermarkPosition = .center,
    margin: Double = 0.1, custom: WatermarkPoint? = nil, expands: Bool = false
  ) throws -> WatermarkLayout {
    try WatermarkLayout.make(originalSize: original, overlaySize: overlay,
      position: position, marginFraction: margin, customPosition: custom, expandsCanvas: expands)
  }
}
