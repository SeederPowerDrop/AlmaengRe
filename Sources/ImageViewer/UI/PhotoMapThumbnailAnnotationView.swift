import AppKit
@preconcurrency import MapKit

enum PhotoMapThumbnailRepresentatives {
  /// MapKit may reorder cluster members during a pan. Keep the visible cover stable.
  static func assets(from assets: [ImageAsset]) -> [ImageAsset] {
    // A cluster can contain the whole library, but a card displays only three
    // covers. Keep those three in order without allocating and sorting a copy.
    var covers: [ImageAsset] = []
    covers.reserveCapacity(3)
    for asset in assets {
      let index = covers.firstIndex { precedes(asset, $0) } ?? covers.endIndex
      guard index < 3 else { continue }
      covers.insert(asset, at: index)
      if covers.count > 3 { covers.removeLast() }
    }
    return covers
  }

  private static func precedes(_ lhs: ImageAsset, _ rhs: ImageAsset) -> Bool {
    let order = lhs.filename.localizedStandardCompare(rhs.filename)
    if order != .orderedSame { return order == .orderedAscending }
    return lhs.url.standardizedFileURL.absoluteString < rhs.url.standardizedFileURL.absoluteString
  }
}

/// Only visible map cards own requests. A generation also protects against a late
/// completion from a cancelled request when MapKit reuses the same native view.
@MainActor final class PhotoMapThumbnailLoader {
  typealias Load = @Sendable (ImageAsset) async throws -> CGImage
  private let load: Load
  private var assets: [ImageAsset] = []
  private var keys: [ThumbnailCacheKey] = []
  private var tasks: [Int: Task<Void, Never>] = [:]
  private var generation: UInt64 = 0
  private(set) var isVisible = false
  private(set) var images: [CGImage?] = []
  var onImageChange: (() -> Void)?

  init(load: @escaping Load) { self.load = load }

  deinit {
    for task in tasks.values { task.cancel() }
  }

  func configure(assets: [ImageAsset]) {
    let keys = assets.map { ThumbnailCacheKey(asset: $0, pixelSize: 128) }
    guard self.keys != keys else { return }
    cancelRequests()
    self.assets = assets
    self.keys = keys
    images = Array(repeating: nil, count: assets.count)
    if isVisible { startRequests() }
  }

  func setVisible(_ visible: Bool) {
    guard isVisible != visible else { return }
    isVisible = visible
    if visible {
      startRequests()
    } else {
      cancelRequests()
      // Reuse the shared bounded cache when this card returns to the viewport.
      images = Array(repeating: nil, count: assets.count)
    }
  }

  func invalidate() {
    setVisible(false)
    configure(assets: [])
  }

  private func cancelRequests() {
    generation &+= 1
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
  }

  private func startRequests() {
    let generation = generation
    for (index, asset) in assets.enumerated() where images[index] == nil && tasks[index] == nil {
      tasks[index] = Task { [weak self, load] in
        do {
          let image = try await load(asset)
          guard !Task.isCancelled, let self, self.isVisible, self.generation == generation else { return }
          self.tasks[index] = nil
          self.images[index] = image
          self.onImageChange?()
        } catch {
          guard let self, self.generation == generation else { return }
          self.tasks[index] = nil
          // A broken or unsupported thumbnail keeps a recognizable photo placeholder.
        }
      }
    }
  }
}

/// A small photo stack remains a normal MapKit annotation, retaining clustering,
/// hit testing, selection, and native map navigation.
@MainActor final class PhotoMapThumbnailAnnotationView: MKAnnotationView {
  // MapKit's annotation container is flipped; these AppKit drawing coordinates
  // place the geographic pointer at the bottom and the count at the top.
  override var isFlipped: Bool { false }
  private var loader: PhotoMapThumbnailLoader?
  private var pipeline: ThumbnailPipeline?
  private var photoCount = 1
  private var matchesSelection = true
  private var cardCount = 1
  var onAccessibilityPress: (() -> Void)?

  override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
    super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
    frame.size = NSSize(width: 76, height: 84)
    centerOffset = NSPoint(x: 2, y: -39)
    collisionMode = .rectangle
    canShowCallout = false
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) { nil }

  func configure(assets: [ImageAsset], pipeline: ThumbnailPipeline, matchesSelection: Bool) {
    if self.pipeline !== pipeline {
      loader?.invalidate()
      self.pipeline = pipeline
      let loader = PhotoMapThumbnailLoader { asset in
        try await pipeline.thumbnail(for: asset, maxPixelSize: 128, priority: .visible)
      }
      loader.onImageChange = { [weak self] in self?.needsDisplay = true }
      self.loader = loader
    }
    let representatives = PhotoMapThumbnailRepresentatives.assets(from: assets)
    loader?.configure(assets: representatives)
    photoCount = assets.count
    cardCount = max(1, representatives.count)
    setMatchesSelection(matchesSelection)
    let label = photoCount == 1 ? assets.first?.filename ?? L10n.text("사진 위치")
      : L10n.format("GPS 사진 %lld장", Int64(photoCount))
    setAccessibilityLabel(label)
    toolTip = label
    needsDisplay = true
  }

  /// Highlight changes do not change the cover or restart thumbnail requests.
  func setMatchesSelection(_ matches: Bool) {
    guard matchesSelection != matches else { return }
    matchesSelection = matches
    alphaValue = matches ? 1 : 0.45
    needsDisplay = true
  }

  func updateThumbnailVisibility(in map: MKMapView) {
    let visible = window != nil && superview != nil && !isHiddenOrHasHiddenAncestor
      && convert(bounds, to: map).intersects(map.bounds)
    loader?.setVisible(visible)
  }

  func stopThumbnailLoading() { loader?.setVisible(false) }

  override func prepareForReuse() {
    super.prepareForReuse()
    loader?.invalidate()
    onAccessibilityPress = nil
    toolTip = nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateVisibilityFromSuperview()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    updateVisibilityFromSuperview()
  }

  override func prepareForDisplay() {
    super.prepareForDisplay()
    updateVisibilityFromSuperview()
  }

  private func updateVisibilityFromSuperview() {
    var ancestor = superview
    while let view = ancestor {
      if let map = view as? MKMapView {
        updateThumbnailVisibility(in: map)
        return
      }
      ancestor = view.superview
    }
    stopThumbnailLoading()
  }

  override func setSelected(_ selected: Bool, animated: Bool) {
    super.setSelected(selected, animated: animated)
    needsDisplay = true
  }

  override func accessibilityPerformPress() -> Bool {
    guard let onAccessibilityPress else { return false }
    onAccessibilityPress()
    return true
  }

  override func draw(_ dirtyRect: NSRect) {
    let accent: NSColor = matchesSelection ? .controlAccentColor : .systemGray
    let front = NSRect(x: 8, y: 14, width: 56, height: 56)
    let pointer = NSBezierPath()
    pointer.move(to: NSPoint(x: 30, y: 15))
    pointer.line(to: NSPoint(x: 36, y: 3))
    pointer.line(to: NSPoint(x: 42, y: 15))
    pointer.close()
    accent.setFill()
    pointer.fill()

    for index in (0..<cardCount).reversed() {
      let offset = CGFloat(index) * 4
      let rect = front.offsetBy(dx: offset, dy: offset)
      drawCard(at: rect, image: loader?.images.indices.contains(index) == true ? loader?.images[index] : nil,
        border: index == 0 && isSelected ? accent : .white)
    }

    if photoCount > 1 {
      let text = String(photoCount) as NSString
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .bold),
        .foregroundColor: NSColor.white,
      ]
      let size = text.size(withAttributes: attributes)
      let width = max(24, size.width + 12)
      let badge = NSRect(x: bounds.maxX - width - 1, y: 62, width: width, height: 21)
      let shape = NSBezierPath(roundedRect: badge, xRadius: 10.5, yRadius: 10.5)
      accent.setFill()
      shape.fill()
      NSColor.white.setStroke()
      shape.lineWidth = 1.5
      shape.stroke()
      text.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2),
        withAttributes: attributes)
    }
  }

  private func drawCard(at rect: NSRect, image: CGImage?, border: NSColor) {
    let shape = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.shadowBlurRadius = 4
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.set()
    NSColor.windowBackgroundColor.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    if let image {
      let size = NSSize(width: image.width, height: image.height)
      let scale = max(rect.width / size.width, rect.height / size.height)
      let target = NSRect(x: rect.midX - size.width * scale / 2,
        y: rect.midY - size.height * scale / 2, width: size.width * scale, height: size.height * scale)
      NSImage(cgImage: image, size: size).draw(in: target, from: .zero,
        operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    } else {
      NSColor.controlBackgroundColor.setFill()
      shape.fill()
      NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?.draw(
        in: NSRect(x: rect.midX - 12, y: rect.midY - 10, width: 24, height: 20))
    }
    NSGraphicsContext.restoreGraphicsState()
    border.setStroke()
    shape.lineWidth = isSelected ? 3 : 2
    shape.stroke()
  }
}
