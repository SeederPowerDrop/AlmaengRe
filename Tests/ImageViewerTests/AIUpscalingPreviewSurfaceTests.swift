import AppKit
import Testing
@testable import ImageViewer

@Suite("AI 확대 네이티브 미리보기", .serialized)
@MainActor
struct AIUpscalingPreviewSurfaceTests {
  @Test("투명한 원본을 비교할 때 AI 결과 위에 겹쳐 그리지 않는다")
  func comparisonKeepsAlphaIndependent() throws {
    let original = try solidImage(width: 50, height: 50,
      color: CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
    let upscaled = try solidImage(width: 100, height: 100,
      color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    let surface = AIUpscalingPreviewSurface(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    surface.configure(original: original, upscaled: upscaled, comparesOriginal: true,
      zoom: 1, fitsWindow: true, splitFraction: 0.5)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100,
      pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 400, bitsPerPixel: 32))
    let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    surface.draw(surface.bounds)
    NSGraphicsContext.restoreGraphicsState()
    let left = try #require(bitmap.colorAt(x: 25, y: 50)?.usingColorSpace(.deviceRGB))
    let right = try #require(bitmap.colorAt(x: 75, y: 50)?.usingColorSpace(.deviceRGB))
    #expect(left.redComponent > 0.45)
    #expect(left.blueComponent < 0.1)
    #expect(right.blueComponent > 0.95)
    #expect(right.redComponent < 0.05)
  }

  @Test("가로 경계선은 원본을 위에, AI 결과를 아래에 독립적으로 그린다")
  func topBottomComparisonKeepsAlphaIndependent() throws {
    let original = try solidImage(width: 50, height: 50,
      color: CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
    let upscaled = try solidImage(width: 100, height: 100,
      color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    let surface = AIUpscalingPreviewSurface(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    surface.configure(original: original, upscaled: upscaled, comparesOriginal: true,
      zoom: 1, fitsWindow: true, splitFraction: 0.25, comparisonAxis: .topBottom)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100,
      pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 400, bitsPerPixel: 32))
    let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    surface.draw(surface.bounds)
    NSGraphicsContext.restoreGraphicsState()
    // Drawing uses AppKit's unflipped, upward y axis, but colorAt samples bitmap
    // rows from the top. The original occupies the first 25 rows here.
    let top = try #require(bitmap.colorAt(x: 50, y: 10)?.usingColorSpace(.deviceRGB))
    let middle = try #require(bitmap.colorAt(x: 50, y: 50)?.usingColorSpace(.deviceRGB))
    let bottom = try #require(bitmap.colorAt(x: 50, y: 90)?.usingColorSpace(.deviceRGB))
    #expect(top.redComponent > 0.45)
    #expect(top.blueComponent < 0.1)
    #expect(middle.blueComponent > 0.95)
    #expect(middle.redComponent < 0.05)
    #expect(bottom.blueComponent > 0.95)
    #expect(bottom.redComponent < 0.05)
  }

  @Test("비교 전환과 경계 이동은 확대와 이미지 위치를 유지한다")
  func comparisonPreservesViewport() throws {
    let original = try solidImage(width: 500, height: 400,
      color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    let upscaled = try solidImage(width: 1000, height: 800,
      color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    let surface = AIUpscalingPreviewSurface(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
    surface.configure(original: original, upscaled: upscaled, comparesOriginal: false,
      zoom: 2, fitsWindow: false, splitFraction: 0.5)
    let press = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
      location: CGPoint(x: 100, y: 100), modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged,
      location: CGPoint(x: 140, y: 80), modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
    surface.mouseDown(with: press)
    surface.mouseDragged(with: drag)
    surface.mouseUp(with: drag)
    let imageRect = surface.geometry.imageRect
    #expect(surface.geometry.center != CGPoint(x: 500, y: 400))
    for axis: AIUpscalingComparisonAxis in [.leftRight, .topBottom, .leftRight] {
      for split: CGFloat in [0, 0.25, 0.8, 1] {
        surface.configure(original: original, upscaled: upscaled, comparesOriginal: true,
          zoom: 2, fitsWindow: false, splitFraction: split, comparisonAxis: axis)
        #expect(surface.geometry.imageRect == imageRect)
        #expect(surface.geometry.zoom == 2)
        #expect(surface.splitFraction == split)
      }
    }
    surface.configure(original: original, upscaled: upscaled, comparesOriginal: false,
      zoom: 2, fitsWindow: false, splitFraction: 0.8)
    #expect(surface.geometry.imageRect == imageRect)
  }

  @Test("가로 경계선을 드래그하면 이미지 위치를 유지하며 위에서 아래로 비교 비율을 바꾼다")
  func topBottomDividerFollowsPointer() throws {
    let image = try solidImage(width: 100, height: 100,
      color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    let surface = AIUpscalingPreviewSurface(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
    surface.configure(original: image, upscaled: image, comparesOriginal: true,
      zoom: 2, fitsWindow: false, splitFraction: 0.5, comparisonAxis: .topBottom)
    let divider = try #require(surface.subviews.first)
    let imageRect = surface.geometry.imageRect
    divider.mouseDown(with: try mouseEvent(.leftMouseDown, x: 100, y: 50))
    divider.mouseDragged(with: try mouseEvent(.leftMouseDragged, x: 170, y: 20))
    divider.mouseUp(with: try mouseEvent(.leftMouseUp, x: 170, y: 20))
    #expect(abs(surface.splitFraction - 0.8) < 0.0001)
    #expect(surface.geometry.imageRect == imageRect)

    divider.mouseDown(with: try mouseEvent(.leftMouseDown, x: 100, y: 20))
    divider.mouseDragged(with: try mouseEvent(.leftMouseDragged, x: 100, y: -30))
    #expect(surface.splitFraction == 1)
    divider.mouseDragged(with: try mouseEvent(.leftMouseDragged, x: 100, y: 130))
    divider.mouseUp(with: try mouseEvent(.leftMouseUp, x: 100, y: 130))
    #expect(surface.splitFraction == 0)
    #expect(surface.geometry.imageRect == imageRect)
  }

  @Test("비교 방향에 맞는 화살표 키와 접근성 동작으로 경계선을 조절한다")
  func dividerSupportsDirectionalKeysAndAccessibility() throws {
    let image = try solidImage(width: 100, height: 100,
      color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    let surface = AIUpscalingPreviewSurface(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
    for (axis, increase, decrease): (AIUpscalingComparisonAxis, UInt16, UInt16) in [
      (.leftRight, 124, 123), (.topBottom, 125, 126)
    ] {
      surface.configure(original: image, upscaled: image, comparesOriginal: true,
        zoom: 1, fitsWindow: true, splitFraction: 0.5, comparisonAxis: axis)
      let divider = try #require(surface.subviews.first)
      divider.keyDown(with: try keyEvent(increase))
      #expect(abs(surface.splitFraction - 0.52) < 0.0001)
      divider.keyDown(with: try keyEvent(decrease))
      #expect(abs(surface.splitFraction - 0.5) < 0.0001)
      #expect(divider.accessibilityPerformIncrement())
      #expect(abs(surface.splitFraction - 0.55) < 0.0001)
      #expect(divider.accessibilityPerformDecrement())
      #expect(abs(surface.splitFraction - 0.5) < 0.0001)
    }
  }

  @Test("가로와 세로 경계선 모두 끝까지 이동해도 손잡이를 다시 잡을 수 있다")
  func dividerRemainsReachableAtBothExtremes() throws {
    let image = try solidImage(width: 100, height: 100,
      color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    let surface = AIUpscalingPreviewSurface(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
    for axis: AIUpscalingComparisonAxis in [.leftRight, .topBottom] {
      for split: CGFloat in [0, 1] {
        surface.configure(original: image, upscaled: image, comparesOriginal: true,
          zoom: 1, fitsWindow: true, splitFraction: split, comparisonAxis: axis)
        let divider = try #require(surface.subviews.first)
        #expect(!divider.isHidden)
        #expect(surface.bounds.contains(divider.frame))
        #expect(divider.frame.width >= 28)
        #expect(divider.frame.height >= 28)
        let handleCenter = CGPoint(x: divider.frame.midX, y: divider.frame.midY)
        #expect(surface.hitTest(handleCenter) === divider)
        if split == 0 {
          #expect(divider.accessibilityPerformDecrement())
          #expect(surface.splitFraction == 0)
          #expect(divider.accessibilityPerformIncrement())
          #expect(abs(surface.splitFraction - 0.05) < 0.0001)
        } else {
          #expect(divider.accessibilityPerformIncrement())
          #expect(surface.splitFraction == 1)
          #expect(divider.accessibilityPerformDecrement())
          #expect(abs(surface.splitFraction - 0.95) < 0.0001)
        }
      }
    }
  }

  private func mouseEvent(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y),
      modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
      eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
  }

  private func keyEvent(_ keyCode: UInt16) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: keyCode))
  }

  private func solidImage(width: Int, height: Int, color: CGColor) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
  }
}
