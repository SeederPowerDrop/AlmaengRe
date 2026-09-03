import AppKit
import QuartzCore
import SwiftUI

/// 16-bit float CGImage를 macOS의 EDR 표시 레이어에 직접 올립니다.
///
/// SwiftUI의 색상 모드만으로는 디스플레이 headroom 사용 여부가 명시적이지 않으므로,
/// 이미지가 실제로 올라가는 CALayer에 동적 범위 선호도를 함께 설정합니다.
struct ExtendedRangeImageView: NSViewRepresentable {
  let image: CGImage
  let prefersHDR: Bool

  func makeNSView(context: Context) -> ExtendedRangeBackingView {
    let view = ExtendedRangeBackingView()
    view.update(image: image, prefersHDR: prefersHDR)
    return view
  }

  func updateNSView(_ nsView: ExtendedRangeBackingView, context: Context) {
    nsView.update(image: image, prefersHDR: prefersHDR)
  }
}

final class ExtendedRangeBackingView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureLayer()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureLayer()
  }

  override func makeBackingLayer() -> CALayer {
    CALayer()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
  }

  func update(image: CGImage, prefersHDR: Bool) {
    guard let layer else { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.contents = image
    layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

    if #available(macOS 26.0, *) {
      layer.preferredDynamicRange = prefersHDR ? .high : .standard
    } else {
      layer.wantsExtendedDynamicRangeContent = prefersHDR
    }
    CATransaction.commit()
  }

  private func configureLayer() {
    wantsLayer = true
    layer?.contentsGravity = .resize
    layer?.minificationFilter = .trilinear
    layer?.magnificationFilter = .linear
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.masksToBounds = true
  }
}
