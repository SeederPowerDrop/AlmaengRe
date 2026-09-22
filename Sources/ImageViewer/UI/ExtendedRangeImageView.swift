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
  let interpolationMode: ImageInterpolationMode

  func makeNSView(context: Context) -> ExtendedRangeBackingView {
    let view = ExtendedRangeBackingView()
    view.update(
      image: image,
      prefersHDR: prefersHDR,
      interpolationMode: interpolationMode
    )
    return view
  }

  func updateNSView(_ nsView: ExtendedRangeBackingView, context: Context) {
    nsView.update(
      image: image,
      prefersHDR: prefersHDR,
      interpolationMode: interpolationMode
    )
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

  func update(
    image: CGImage,
    prefersHDR: Bool,
    interpolationMode: ImageInterpolationMode
  ) {
    guard let layer else { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.contents = image
    layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    apply(interpolationMode)

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
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.masksToBounds = true
  }

  /// 렌더링과 테스트가 동일한 Core Animation 필터 선택을 공유합니다.
  func apply(_ interpolationMode: ImageInterpolationMode) {
    switch interpolationMode {
    case .smooth:
      // 축소에는 mipmap 사이를, 확대에는 인접 픽셀 사이를 보간해
      // 고배율에서도 계단 모양과 깨진 경계를 줄입니다.
      layer?.minificationFilter = .trilinear
      layer?.magnificationFilter = .linear
    case .pixelated:
      // 아이콘과 픽셀 아트의 원본 격자를 확인할 때는 인접 픽셀을 섞지 않습니다.
      layer?.minificationFilter = .nearest
      layer?.magnificationFilter = .nearest
    }
  }
}
