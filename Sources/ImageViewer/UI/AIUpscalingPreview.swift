import AppKit
import SwiftUI

enum AIUpscalingComparisonAxis: String, CaseIterable, Identifiable, Sendable {
  case leftRight
  case topBottom

  var id: String { rawValue }
}

struct AIUpscalingPreview: NSViewRepresentable {
  let original: CGImage
  let upscaled: CGImage
  let comparesOriginal: Bool
  let comparisonAxis: AIUpscalingComparisonAxis
  @Binding var zoom: CGFloat
  @Binding var fitsWindow: Bool
  @Binding var splitFraction: CGFloat

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> AIUpscalingPreviewSurface {
    let surface = AIUpscalingPreviewSurface()
    surface.onChange = { [weak coordinator = context.coordinator] surface in
      coordinator?.publish(surface)
    }
    return surface
  }

  func updateNSView(_ surface: AIUpscalingPreviewSurface, context: Context) {
    context.coordinator.preview = self
    surface.configure(original: original, upscaled: upscaled, comparesOriginal: comparesOriginal,
      zoom: zoom, fitsWindow: fitsWindow, splitFraction: splitFraction, comparisonAxis: comparisonAxis)
  }

  @MainActor final class Coordinator {
    var preview: AIUpscalingPreview
    private var publication = 0
    init(_ preview: AIUpscalingPreview) { self.preview = preview }

    func publish(_ surface: AIUpscalingPreviewSurface) {
      publication += 1
      let request = publication
      // Layout and updateNSView may both change the fit scale. Publish the latest
      // native state after SwiftUI's update, and coalesce repeated layout events.
      DispatchQueue.main.async { [weak self, weak surface] in
        guard let self, let surface, self.publication == request else { return }
        if self.preview.zoom != surface.geometry.zoom { self.preview.zoom = surface.geometry.zoom }
        if self.preview.fitsWindow != surface.geometry.fitsWindow {
          self.preview.fitsWindow = surface.geometry.fitsWindow
        }
        if self.preview.splitFraction != surface.splitFraction {
          self.preview.splitFraction = surface.splitFraction
        }
      }
    }
  }
}

/// A viewport-sized backing store draws the two source CGImages directly. Even
/// at 800%, no enlarged bitmap or oversized view/layer is allocated.
@MainActor final class AIUpscalingPreviewSurface: NSView {
  private var original: CGImage?
  private var upscaled: CGImage?
  private var comparesOriginal = false
  private(set) var geometry = AIUpscalingPreviewGeometry(imageSize: CGSize(width: 1, height: 1))
  private(set) var splitFraction: CGFloat = 0.5
  private(set) var comparisonAxis: AIUpscalingComparisonAxis = .leftRight
  private var inputZoom: CGFloat?
  private var inputFit: Bool?
  private var inputSplit: CGFloat?
  private var lastDragPoint: CGPoint?
  private let divider = AIUpscalingComparisonDivider()
  var onChange: ((AIUpscalingPreviewSurface) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = true
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(L10n.text("미리보기"))
    divider.onMove = { [weak self] fraction in self?.moveDivider(to: fraction) }
    addSubview(divider)
  }

  required init?(coder: NSCoder) { nil }
  override var acceptsFirstResponder: Bool { true }
  override var isOpaque: Bool { true }

  private var displayScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

  func configure(original: CGImage, upscaled: CGImage, comparesOriginal: Bool,
    zoom: CGFloat, fitsWindow: Bool, splitFraction: CGFloat,
    comparisonAxis: AIUpscalingComparisonAxis = .leftRight) {
    let imageChanged = self.upscaled !== upscaled
    self.original = original
    self.upscaled = upscaled
    self.comparesOriginal = comparesOriginal
    self.comparisonAxis = comparisonAxis
    if imageChanged {
      geometry = AIUpscalingPreviewGeometry(
        imageSize: CGSize(width: upscaled.width, height: upscaled.height),
        viewportSize: bounds.size, backingScale: displayScale)
    }
    if imageChanged || inputFit != fitsWindow || inputZoom != zoom {
      if fitsWindow { geometry.fit() } else { geometry.setZoom(zoom) }
    }
    inputZoom = zoom
    inputFit = fitsWindow
    if inputSplit != splitFraction {
      self.splitFraction = splitFraction.isFinite ? min(1, max(0, splitFraction)) : 0.5
    }
    inputSplit = splitFraction
    updateDivider()
    refresh()
  }

  override func layout() {
    super.layout()
    guard geometry.viewportSize != bounds.size || geometry.backingScale != displayScale else { return }
    geometry.resize(to: bounds.size, backingScale: displayScale)
    updateDivider()
    refresh()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    needsLayout = true
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsLayout = true
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor(calibratedWhite: 0.035, alpha: 1).setFill()
    bounds.fill()
    guard let context = NSGraphicsContext.current?.cgContext, let upscaled else { return }
    let imageRect = geometry.drawingRect
    context.interpolationQuality = .high
    context.draw(upscaled, in: imageRect)
    if comparesOriginal, let original {
      context.saveGState()
      switch comparisonAxis {
      case .leftRight:
        context.clip(to: CGRect(x: 0, y: 0, width: bounds.width * splitFraction, height: bounds.height))
      case .topBottom:
        // AppKit's unflipped coordinates start at the bottom. The fraction is
        // always the amount of original image visible, measured from the top.
        context.clip(to: CGRect(x: 0, y: bounds.height * (1 - splitFraction),
          width: bounds.width, height: bounds.height * splitFraction))
      }
      context.setFillColor(NSColor(calibratedWhite: 0.035, alpha: 1).cgColor)
      context.fill(bounds)
      // Ordinary high-quality interpolation is the honest baseline for comparing
      // the original at the output extent; nearest-neighbor would exaggerate it.
      context.draw(original, in: imageRect)
      context.restoreGState()
    }
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    lastDragPoint = convert(event.locationInWindow, from: nil)
    NSCursor.closedHand.set()
  }

  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let lastDragPoint else { return }
    geometry.pan(by: CGSize(width: point.x - lastDragPoint.x, height: point.y - lastDragPoint.y))
    self.lastDragPoint = point
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    lastDragPoint = nil
    NSCursor.openHand.set()
  }

  override func scrollWheel(with event: NSEvent) {
    let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
    // AppKit's vertical scrolling delta is expressed in flipped document axes.
    geometry.pan(by: CGSize(width: event.scrollingDeltaX * multiplier,
      height: -event.scrollingDeltaY * multiplier))
    needsDisplay = true
  }

  override func magnify(with event: NSEvent) {
    geometry.setZoom(geometry.zoom * max(0.05, 1 + event.magnification),
      around: convert(event.locationInWindow, from: nil))
    refresh()
  }

  private func moveDivider(to fraction: CGFloat) {
    splitFraction = min(1, max(0, fraction))
    updateDivider()
    refresh()
  }

  private func updateDivider() {
    divider.isHidden = !comparesOriginal
    divider.axis = comparisonAxis
    divider.fraction = splitFraction
    // Keep the handle reachable even when an accessible slider requests 0/100%.
    switch comparisonAxis {
    case .leftRight:
      let position = bounds.width * splitFraction
      let handleX = min(max(0, bounds.width - 28), max(0, position - 14))
      divider.frame = CGRect(x: handleX, y: 0, width: min(28, bounds.width), height: bounds.height)
      divider.linePosition = position - handleX
    case .topBottom:
      let position = bounds.height * (1 - splitFraction)
      let handleY = min(max(0, bounds.height - 28), max(0, position - 14))
      divider.frame = CGRect(x: 0, y: handleY, width: bounds.width, height: min(28, bounds.height))
      divider.linePosition = position - handleY
    }
    divider.needsDisplay = true
    window?.invalidateCursorRects(for: self)
    window?.invalidateCursorRects(for: divider)
  }

  private func refresh() {
    needsDisplay = true
    setAccessibilityValue(String(format: "%.0f%%", geometry.zoom * 100))
    onChange?(self)
  }
}

@MainActor private final class AIUpscalingComparisonDivider: NSView {
  var fraction: CGFloat = 0.5 {
    didSet { setAccessibilityValue(Double(fraction * 100)) }
  }
  var axis: AIUpscalingComparisonAxis = .leftRight {
    didSet {
      setAccessibilityOrientation(axis == .leftRight ? .horizontal : .vertical)
      setAccessibilityLabel(L10n.text(axis == .leftRight
        ? "aiPreview.verticalSplit" : "aiPreview.horizontalSplit"))
    }
  }
  var linePosition: CGFloat = 14
  var onMove: ((CGFloat) -> Void)?
  override var acceptsFirstResponder: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(true)
    setAccessibilityRole(.slider)
    setAccessibilityOrientation(.horizontal)
    setAccessibilityLabel(L10n.text("aiPreview.split"))
    setAccessibilityMinValue(0)
    setAccessibilityMaxValue(100)
  }
  required init?(coder: NSCoder) { nil }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: axis == .leftRight ? .resizeLeftRight : .resizeUpDown)
  }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    move(with: event)
  }
  override func mouseDragged(with event: NSEvent) { move(with: event) }
  override func mouseUp(with event: NSEvent) { move(with: event) }
  override func scrollWheel(with event: NSEvent) { superview?.scrollWheel(with: event) }
  override func magnify(with event: NSEvent) { superview?.magnify(with: event) }
  override func accessibilityPerformIncrement() -> Bool { onMove?(fraction + 0.05); return true }
  override func accessibilityPerformDecrement() -> Bool { onMove?(fraction - 0.05); return true }
  override func keyDown(with event: NSEvent) {
    switch (axis, event.keyCode) {
    case (.leftRight, 123), (.topBottom, 126): onMove?(fraction - 0.02)
    case (.leftRight, 124), (.topBottom, 125): onMove?(fraction + 0.02)
    default: super.keyDown(with: event)
    }
  }

  private func move(with event: NSEvent) {
    guard let superview else { return }
    let point = superview.convert(event.locationInWindow, from: nil)
    switch axis {
    case .leftRight:
      guard superview.bounds.width > 0 else { return }
      onMove?(point.x / superview.bounds.width)
    case .topBottom:
      guard superview.bounds.height > 0 else { return }
      onMove?(1 - point.y / superview.bounds.height)
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    let lineShadow: CGRect
    let line: CGRect
    let handleRect: CGRect
    switch axis {
    case .leftRight:
      lineShadow = CGRect(x: linePosition - 2, y: 0, width: 4, height: bounds.height)
      line = CGRect(x: linePosition - 0.5, y: 0, width: 1, height: bounds.height)
      handleRect = CGRect(x: bounds.midX - 12, y: bounds.midY - 19, width: 24, height: 38)
    case .topBottom:
      lineShadow = CGRect(x: 0, y: linePosition - 2, width: bounds.width, height: 4)
      line = CGRect(x: 0, y: linePosition - 0.5, width: bounds.width, height: 1)
      handleRect = CGRect(x: bounds.midX - 19, y: bounds.midY - 12, width: 38, height: 24)
    }
    NSColor.black.withAlphaComponent(0.45).setFill()
    lineShadow.fill()
    NSColor.white.setFill()
    line.fill()
    let handle = NSBezierPath(roundedRect: handleRect, xRadius: 9, yRadius: 9)
    NSColor(calibratedWhite: 0.15, alpha: 0.95).setFill()
    handle.fill()
    NSColor.white.setStroke()
    handle.lineWidth = 1.5
    handle.stroke()
    let grip = NSBezierPath()
    switch axis {
    case .leftRight:
      for x in [bounds.midX - 3, bounds.midX + 3] {
        grip.move(to: CGPoint(x: x, y: bounds.midY - 6))
        grip.line(to: CGPoint(x: x, y: bounds.midY + 6))
      }
    case .topBottom:
      for y in [bounds.midY - 3, bounds.midY + 3] {
        grip.move(to: CGPoint(x: bounds.midX - 6, y: y))
        grip.line(to: CGPoint(x: bounds.midX + 6, y: y))
      }
    }
    grip.lineWidth = 1.5
    grip.stroke()
  }
}
