import AppKit
import QuartzCore
import Testing

@testable import ImageViewer

@Suite("이미지 표시 레이어의 픽셀 재사용")
@MainActor
struct ImageLayerReuseTests {
  private final class CountingLayer: CALayer {
    var uploads = 0
    override var contents: Any? {
      didSet { uploads += 1 }
    }
  }

  @Test("이동·선택·품질 설정 갱신은 같은 이미지 픽셀을 다시 제출하지 않는다")
  func unchangedBitmapDoesNotUploadAgain() throws {
    let view = ExtendedRangeBackingView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
    let layer = CountingLayer()
    view.layer = layer
    let context = try #require(CGContext(data: nil, width: 64, height: 32,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.systemBlue.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
    let first = try #require(context.makeImage())
    view.update(image: first, prefersHDR: true, interpolationMode: .smooth)
    let firstUploadCount = layer.uploads
    #expect(firstUploadCount == 1)
    for index in 0..<600 {
      view.frame.origin = CGPoint(x: index, y: -index)
      view.update(image: first, prefersHDR: true, interpolationMode: .smooth)
    }
    #expect(layer.uploads == firstUploadCount)
    view.update(image: first, prefersHDR: false, interpolationMode: .pixelated)
    #expect(layer.uploads == firstUploadCount)
    #expect(layer.minificationFilter == .nearest && layer.magnificationFilter == .nearest)
    if #available(macOS 26.0, *) {
      #expect(layer.preferredDynamicRange == .standard)
    } else {
      #expect(!layer.wantsExtendedDynamicRangeContent)
    }

    context.setFillColor(NSColor.systemRed.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
    let second = try #require(context.makeImage())
    view.update(image: second, prefersHDR: true, interpolationMode: .smooth)
    #expect(layer.uploads == firstUploadCount + 1)
    #expect((layer.contents as AnyObject?) === second)
    #expect(layer.minificationFilter == .trilinear && layer.magnificationFilter == .linear)
    if #available(macOS 26.0, *) { #expect(layer.preferredDynamicRange == .high) }
    else { #expect(layer.wantsExtendedDynamicRangeContent) }
  }
}
