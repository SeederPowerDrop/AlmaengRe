import AppKit
@preconcurrency import MapKit
import SwiftUI

/// MapKit clusters metadata for the whole folder; only visible cards request small thumbnails.
struct NativePhotoMapView: NSViewRepresentable {
  let assets: [ImageAsset]
  let thumbnailPipeline: ThumbnailPipeline
  let viewportState: PhotoMapViewportState
  let isLoading: Bool
  let selection: GeographicSelection?
  let matchingAssetURLs: Set<URL>
  let drawingMode: PhotoMapDrawingMode
  let fitRequest: Int
  let viewportRequest: Int
  let activeAreaIndex: Int?
  let creationRequest: Int
  let creationMode: PhotoMapDrawingMode
  let onSelectionChange: (GeographicSelection?) -> Void
  let onEditArea: (Int, GeographicSelection) -> Void
  let onSelectArea: (Int) -> Void
  let onPickAssets: ([ImageAsset]) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> PhotoMapSurface {
    let surface = PhotoMapSurface()
    surface.restoreViewport(from: viewportState)
    context.coordinator.didFitInitialLocations = viewportState.camera != nil
    surface.map.delegate = context.coordinator
    context.coordinator.surface = surface
    surface.map.mapType = .standard
    surface.map.isRotateEnabled = false
    surface.map.isPitchEnabled = false
    surface.map.showsZoomControls = true
    surface.map.showsCompass = false
    surface.map.showsScale = true
    surface.map.pointOfInterestFilter = .excludingAll
    surface.map.register(PhotoMapThumbnailAnnotationView.self, forAnnotationViewWithReuseIdentifier: "photo")
    surface.map.register(PhotoMapThumbnailAnnotationView.self, forAnnotationViewWithReuseIdentifier: "cluster")
    surface.drawing.onFinish = { [weak coordinator = context.coordinator, weak surface] points, mode in
      guard let surface,
        let selection = surface.selection(for: points, mode: mode) else { return }
      coordinator?.onSelectionChange?(selection)
    }
    surface.onEditArea = { [weak coordinator = context.coordinator] index, area in
      coordinator?.onEditArea?(index, area)
    }
    surface.onSelectArea = { [weak coordinator = context.coordinator] index in
      coordinator?.onSelectArea?(index)
    }
    return surface
  }

  func updateNSView(_ surface: PhotoMapSurface, context: Context) {
    let coordinator = context.coordinator
    coordinator.onSelectionChange = onSelectionChange
    coordinator.onEditArea = onEditArea
    coordinator.onSelectArea = onSelectArea
    coordinator.onPickAssets = onPickAssets
    coordinator.thumbnailPipeline = thumbnailPipeline
    surface.drawing.mode = drawingMode
    surface.isEditingEnabled = !isLoading && drawingMode == .move

    if coordinator.lastAssets != assets {
      coordinator.lastAssets = assets
      let validAssets = assets.filter {
        guard let location = $0.location else { return false }
        return CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(
          latitude: location.latitude, longitude: location.longitude))
      }
      let incoming = Dictionary(validAssets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let removed = coordinator.annotations.filter { incoming[$0.key] != $0.value.asset }
      surface.map.removeAnnotations(Array(removed.values))
      for id in removed.keys { coordinator.annotations.removeValue(forKey: id) }
      let added = validAssets.filter { coordinator.annotations[$0.id] == nil }.map(PhotoMapAnnotation.init)
      for annotation in added { coordinator.annotations[annotation.asset.id] = annotation }
      surface.map.addAnnotations(added)
    }

    let selectionChanged = coordinator.selection != selection
    let matchesChanged = coordinator.matchingAssetURLs != matchingAssetURLs
    coordinator.selection = selection
    if selectionChanged { coordinator.pendingSelectionRequest += 1 }
    coordinator.matchingAssetURLs = matchingAssetURLs
    surface.configure(areas: selection?.areas ?? [], activeAreaIndex: activeAreaIndex)

    if selectionChanged || matchesChanged {
      // Offscreen metadata does not need styling. Existing cards only change
      // their highlight; their thumbnail configuration is still valid.
      for view in coordinator.thumbnailViews.allObjects {
        guard let annotation = view.annotation else { continue }
        view.setMatchesSelection(coordinator.matchesSelection(annotation))
      }
    }

    let firstLocations = !coordinator.didFitInitialLocations && !isLoading && !coordinator.annotations.isEmpty
    if firstLocations || coordinator.fitRequest != fitRequest {
      let requestedFit = coordinator.fitRequest != fitRequest
      coordinator.fitRequest = fitRequest
      coordinator.didFitInitialLocations = !coordinator.annotations.isEmpty
      surface.updateViewport { [weak coordinator] map in
        guard let coordinator else { return }
        if !requestedFit, let selection {
          coordinator.fit(map, selection: selection)
        } else {
          coordinator.fit(map, annotations: Array(coordinator.annotations.values))
        }
      }
    }

    if coordinator.creationRequest != creationRequest {
      coordinator.creationRequest = creationRequest
      coordinator.pendingSelectionRequest += 1
      let request = coordinator.pendingSelectionRequest
      if let selected = surface.centeredSelection(mode: creationMode) {
        // Defer state publication until after SwiftUI finishes updating this native surface.
        DispatchQueue.main.async { [weak coordinator] in
          guard let coordinator, coordinator.pendingSelectionRequest == request else { return }
          coordinator.onSelectionChange?(selected)
        }
      }
    }
    if coordinator.viewportRequest != viewportRequest {
      coordinator.viewportRequest = viewportRequest
      coordinator.pendingSelectionRequest += 1
      let request = coordinator.pendingSelectionRequest
      let selected = surface.viewportSelection()
      // SwiftUI must receive the completed selection outside its representable update.
      DispatchQueue.main.async { [weak coordinator] in
        guard let coordinator, coordinator.pendingSelectionRequest == request else { return }
        coordinator.onSelectionChange?(selected)
      }
    }
    coordinator.updateVisibleThumbnails(in: surface.map)
  }

  static func dismantleNSView(_ surface: PhotoMapSurface, coordinator: Coordinator) {
    surface.rememberViewport()
    for view in coordinator.thumbnailViews.allObjects { view.stopThumbnailLoading() }
    coordinator.thumbnailViews.removeAllObjects()
    surface.map.delegate = nil
    surface.drawing.onFinish = nil
    surface.drawing.onCancel = nil
    surface.onEditArea = nil
    surface.onSelectArea = nil
    coordinator.surface = nil
    coordinator.onEditArea = nil
    coordinator.onSelectArea = nil
    coordinator.onSelectionChange = nil
    coordinator.onPickAssets = nil
  }

  @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
    var lastAssets: [ImageAsset] = []
    var annotations: [URL: PhotoMapAnnotation] = [:]
    var selection: GeographicSelection?
    var matchingAssetURLs: Set<URL> = []
    var thumbnailPipeline: ThumbnailPipeline?
    let thumbnailViews = NSHashTable<PhotoMapThumbnailAnnotationView>.weakObjects()
    var onSelectionChange: ((GeographicSelection?) -> Void)?
    var onEditArea: ((Int, GeographicSelection) -> Void)?
    var onSelectArea: ((Int) -> Void)?
    weak var surface: PhotoMapSurface?
    var creationRequest = 0
    var pendingSelectionRequest = 0
    var onPickAssets: (([ImageAsset]) -> Void)?
    var fitRequest = 0
    var viewportRequest = 0
    var didFitInitialLocations = false

    func fit(_ map: MKMapView, annotations: [PhotoMapAnnotation]) {
      guard let first = annotations.first else { return }
      let firstCoordinate = first.coordinate
      if annotations.allSatisfy({
        abs($0.coordinate.latitude - firstCoordinate.latitude) < 0.0001
          && abs($0.coordinate.longitude - firstCoordinate.longitude) < 0.0001
      }) {
        map.setRegion(MKCoordinateRegion(
          center: firstCoordinate, latitudinalMeters: 2_000, longitudinalMeters: 2_000), animated: false)
      } else {
        map.showAnnotations(annotations, animated: false)
      }
    }

    func fit(_ map: MKMapView, selection: GeographicSelection) {
      let rect = selection.areas.compactMap { $0.mapOverlay?.boundingMapRect }
        .reduce(MKMapRect.null) { $0.union($1) }
      guard !rect.isNull, !rect.isEmpty else { return }
      map.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 48, left: 48, bottom: 48, right: 48),
        animated: false)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
      guard annotation is PhotoMapAnnotation || annotation is MKClusterAnnotation else { return nil }
      let identifier = annotation is MKClusterAnnotation ? "cluster" : "photo"
      guard let view = mapView.dequeueReusableAnnotationView(
        withIdentifier: identifier, for: annotation) as? PhotoMapThumbnailAnnotationView else { return nil }
      view.canShowCallout = false
      view.clusteringIdentifier = annotation is PhotoMapAnnotation ? "folder-photos" : nil
      view.displayPriority = annotation is MKClusterAnnotation ? .defaultHigh : .defaultLow
      view.onAccessibilityPress = { [weak mapView, weak view] in
        guard let annotation = view?.annotation else { return }
        mapView?.selectAnnotation(annotation, animated: false)
      }
      thumbnailViews.add(view)
      style(view, annotation: annotation)
      return view
    }

    func style(_ view: PhotoMapThumbnailAnnotationView, annotation: any MKAnnotation) {
      guard let thumbnailPipeline else { return }
      let photos = photoAnnotations(in: annotation)
      view.configure(assets: photos.map(\.asset), pipeline: thumbnailPipeline,
        matchesSelection: matchesSelection(annotation))
    }

    func matchesSelection(_ annotation: any MKAnnotation) -> Bool {
      guard selection != nil else { return true }
      if let photo = annotation as? PhotoMapAnnotation {
        return matchingAssetURLs.contains(photo.asset.id)
      }
      return (annotation as? MKClusterAnnotation)?.memberAnnotations.contains {
        guard let photo = $0 as? PhotoMapAnnotation else { return false }
        return matchingAssetURLs.contains(photo.asset.id)
      } ?? false
    }

    func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
      updateVisibleThumbnails(in: mapView)
    }

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
      surface?.rememberViewport()
      surface?.updateHandlePositions()
      updateVisibleThumbnails(in: mapView)
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
      surface?.rememberViewport()
      surface?.updateHandlePositions()
      updateVisibleThumbnails(in: mapView)
    }

    func updateVisibleThumbnails(in mapView: MKMapView) {
      for view in thumbnailViews.allObjects { view.updateThumbnailVisibility(in: mapView) }
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
      guard let annotation = view.annotation else { return }
      let photos = photoAnnotations(in: annotation)
      let assets = photos.map(\.asset).sorted {
        $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
      }
      guard !assets.isEmpty else { return }
      onPickAssets?(assets)
      if annotation is MKClusterAnnotation {
        mapView.deselectAnnotation(annotation, animated: false)
        fit(mapView, annotations: photos)
      }
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
      let renderer: MKOverlayPathRenderer
      if let circle = overlay as? MKCircle {
        renderer = MKCircleRenderer(circle: circle)
      } else if let polygon = overlay as? MKPolygon {
        renderer = MKPolygonRenderer(polygon: polygon)
      } else {
        return MKOverlayRenderer(overlay: overlay)
      }
      let isActive = (overlay as? MKShape)?.title == surface?.activeAreaIndex.map(String.init)
      renderer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(isActive ? 1 : 0.65)
      renderer.fillColor = NSColor.controlAccentColor.withAlphaComponent(isActive ? 0.18 : 0.09)
      renderer.lineWidth = isActive ? 3 : 2
      if !isActive { renderer.lineDashPattern = [6, 3] }
      return renderer
    }

    private func photoAnnotations(in annotation: any MKAnnotation) -> [PhotoMapAnnotation] {
      if let photo = annotation as? PhotoMapAnnotation { return [photo] }
      return (annotation as? MKClusterAnnotation)?.memberAnnotations.compactMap {
        $0 as? PhotoMapAnnotation
      } ?? []
    }
  }
}

final class PhotoMapAnnotation: NSObject, MKAnnotation {
  let asset: ImageAsset
  @objc dynamic var coordinate: CLLocationCoordinate2D
  var title: String? { asset.filename }

  init(asset: ImageAsset) {
    self.asset = asset
    coordinate = CLLocationCoordinate2D(
      latitude: asset.location?.latitude ?? 0, longitude: asset.location?.longitude ?? 0)
    super.init()
  }
}

@MainActor final class PhotoMapSurface: NSView {
  let map = MKMapView()
  let drawing = PhotoMapDrawingSurface()
  var onEditArea: ((Int, GeographicSelection) -> Void)?
  var onSelectArea: ((Int) -> Void)?
  private var viewportState: PhotoMapViewportState?
  private var pendingCamera: MKMapCamera?
  private var pendingViewportUpdate: ((MKMapView) -> Void)?
  private var hasAppliedViewport = false
  var isEditingEnabled = true {
    didSet { if oldValue != isEditingEnabled { updateHandlePositions() } }
  }
  private(set) var activeAreaIndex: Int?
  private var areas: [GeographicSelection] = []
  private var displayedAreas: [GeographicSelection] = []
  private var moveHandles: [PhotoMapAreaHandle] = []
  private let resizeHandle = PhotoMapAreaHandle()
  private var edit: AreaEdit?

  private struct AreaEdit {
    let index: Int
    let original: GeographicSelection
    let origin: GeoCoordinate
    let originInWindow: CGPoint
    let isResize: Bool
    var changed = false
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    addSubview(map)
    addSubview(drawing)
    map.autoresizingMask = [.width, .height]
    drawing.autoresizingMask = [.width, .height]
    drawing.onCancel = { [weak self] in self?.cancelAreaEdit() }
    resizeHandle.isResize = true
    drawing.addSubview(resizeHandle)
    wire(resizeHandle)
  }

  required init?(coder: NSCoder) { nil }

  override func layout() {
    super.layout()
    map.frame = bounds
    drawing.frame = bounds
    if let pendingCamera, bounds.width > 0, bounds.height > 0 {
      map.setCamera(pendingCamera, animated: false)
      self.pendingCamera = nil
      hasAppliedViewport = true
      rememberViewport()
    }
    if let pendingViewportUpdate, bounds.width > 0, bounds.height > 0 {
      pendingViewportUpdate(map)
      self.pendingViewportUpdate = nil
      hasAppliedViewport = true
      rememberViewport()
    }
    updateHandlePositions()
  }

  func restoreViewport(from state: PhotoMapViewportState) {
    viewportState = state
    pendingCamera = state.camera?.copy() as? MKMapCamera
    hasAppliedViewport = false
    needsLayout = true
  }

  func rememberViewport() {
    // Default zero-sized map callbacks must not replace the saved camera before layout restores it.
    guard hasAppliedViewport, pendingCamera == nil, pendingViewportUpdate == nil,
      map.bounds.width > 0, map.bounds.height > 0,
      CLLocationCoordinate2DIsValid(map.camera.centerCoordinate),
      map.camera.centerCoordinateDistance.isFinite, map.camera.centerCoordinateDistance > 0 else { return }
    viewportState?.camera = map.camera.copy() as? MKMapCamera
  }

  func updateViewport(_ update: @escaping (MKMapView) -> Void) {
    // Initial SwiftUI updates can arrive before this native map has a usable size.
    // Fitting a region at zero size otherwise falls back to the entire world.
    pendingCamera = nil
    pendingViewportUpdate = update
    if map.bounds.width > 0, map.bounds.height > 0 {
      update(map)
      pendingViewportUpdate = nil
      hasAppliedViewport = true
      rememberViewport()
    } else {
      needsLayout = true
    }
  }

  func configure(areas: [GeographicSelection], activeAreaIndex: Int?) {
    let changed = self.areas != areas
    let activeChanged = self.activeAreaIndex != activeAreaIndex
    let previousHandleCount = moveHandles.count
    self.activeAreaIndex = activeAreaIndex
    if changed {
      edit = nil
      self.areas = areas
      displayedAreas = areas
    }
    if changed || activeChanged { updateOverlays() }
    while moveHandles.count < areas.count {
      let handle = PhotoMapAreaHandle()
      wire(handle)
      drawing.addSubview(handle)
      moveHandles.append(handle)
    }
    while moveHandles.count > areas.count { moveHandles.removeLast().removeFromSuperview() }
    if activeChanged || previousHandleCount != moveHandles.count { updateHandleOrder() }
    updateHandlePositions()
  }

  private func wire(_ handle: PhotoMapAreaHandle) {
    handle.onPress = { [weak self, weak handle] in
      guard let handle else { return }
      self?.onSelectArea?(handle.areaIndex)
    }
    handle.onBegin = { [weak self, weak handle] point in
      guard let self, let handle, self.isEditingEnabled,
        self.areas.indices.contains(handle.areaIndex) else { return }
      self.window?.makeFirstResponder(self.drawing)
      self.edit = AreaEdit(index: handle.areaIndex, original: self.areas[handle.areaIndex],
        origin: self.coordinate(self.drawing.convert(point, from: nil)), originInWindow: point,
        isResize: handle.isResize)
      self.onSelectArea?(handle.areaIndex)
    }
    handle.onDrag = { [weak self] point in self?.dragArea(to: point) }
    handle.onEnd = { [weak self] point in
      guard let self, self.edit != nil else { return }
      self.dragArea(to: point)
      guard let edit = self.edit else { return }
      self.edit = nil
      if edit.changed, self.displayedAreas.indices.contains(edit.index) {
        self.onEditArea?(edit.index, self.displayedAreas[edit.index])
      }
    }
    handle.onCancel = { [weak self] in self?.cancelAreaEdit() }
  }

  private func dragArea(to windowPoint: CGPoint) {
    guard var edit, areas.indices.contains(edit.index) else { return }
    if hypot(windowPoint.x - edit.originInWindow.x, windowPoint.y - edit.originInWindow.y) < 1 {
      if edit.changed {
        edit.changed = false
        self.edit = edit
        displayedAreas[edit.index] = edit.original
        updateOverlays()
        updateHandlePositions()
      }
      return
    }
    var point = drawing.convert(windowPoint, from: nil)
    point.x = min(drawing.bounds.maxX, max(drawing.bounds.minX, point.x))
    point.y = min(drawing.bounds.maxY, max(drawing.bounds.minY, point.y))
    if edit.isResize, case .rectangle(let southWest, let northEast) = edit.original {
      let corner = screenPoint(GeoCoordinate(latitude: northEast.latitude, longitude: southWest.longitude))
      // Prevent dragging through the fixed corner from turning a tiny box into a world-sized one.
      point.x = max(corner.x + 4, point.x)
      point.y = max(corner.y + 4, point.y)
    }
    let destination = coordinate(point)
    let updated = edit.isResize
      ? PhotoMapDrawingGeometry.resized(edit.original, to: destination)
      : PhotoMapDrawingGeometry.translated(edit.original, from: edit.origin, to: destination)
    guard let updated else { return }
    edit.changed = edit.changed || updated != edit.original
    self.edit = edit
    displayedAreas[edit.index] = updated
    updateOverlays()
    updateHandlePositions()
  }

  private func cancelAreaEdit() {
    guard edit != nil else { return }
    edit = nil
    displayedAreas = areas
    updateOverlays()
    updateHandlePositions()
  }

  private func updateOverlays() {
    map.removeOverlays(map.overlays)
    for (index, area) in displayedAreas.enumerated() {
      guard let overlay = area.mapOverlay else { continue }
      (overlay as? MKShape)?.title = String(index)
      map.addOverlay(overlay)
    }
  }

  func updateHandlePositions() {
    for (index, handle) in moveHandles.enumerated() {
      handle.areaIndex = index
      handle.isActive = index == activeAreaIndex
      guard displayedAreas.indices.contains(index), let center = displayedAreas[index].handleCenter else {
        handle.isHidden = true
        continue
      }
      place(handle, at: screenPoint(center), size: 34)
    }
    resizeHandle.isHidden = true
    if let activeAreaIndex, displayedAreas.indices.contains(activeAreaIndex),
      let edge = displayedAreas[activeAreaIndex].resizeCoordinate {
      resizeHandle.areaIndex = activeAreaIndex
      resizeHandle.isActive = true
      place(resizeHandle, at: screenPoint(edge), size: 22)
    }
    window?.invalidateCursorRects(for: drawing)
  }

  private func updateHandleOrder() {
    // Moving the map only changes coordinates; it must not repeatedly mutate
    // the view hierarchy or schedule layout just to preserve the same order.
    if let activeAreaIndex, moveHandles.indices.contains(activeAreaIndex) {
      drawing.addSubview(moveHandles[activeAreaIndex], positioned: .above, relativeTo: nil)
    }
    drawing.addSubview(resizeHandle, positioned: .above, relativeTo: nil)
  }

  private func place(_ handle: PhotoMapAreaHandle, at point: CGPoint, size: CGFloat) {
    handle.frame = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    handle.isHidden = !isEditingEnabled || !point.x.isFinite || !point.y.isFinite
      || !drawing.bounds.insetBy(dx: size / 2, dy: size / 2).contains(point)
    handle.needsDisplay = true
  }

  private func screenPoint(_ coordinate: GeoCoordinate) -> CGPoint {
    map.convert(coordinate.mapCoordinate, toPointTo: drawing)
  }

  func selection(for points: [CGPoint], mode: PhotoMapDrawingMode) -> GeographicSelection? {
    PhotoMapDrawingGeometry.selection(for: points, mode: mode, coordinateAt: coordinate)
  }

  func centeredSelection(mode: PhotoMapDrawingMode) -> GeographicSelection? {
    PhotoMapDrawingGeometry.centeredSelection(in: drawing.bounds, mode: mode, coordinateAt: coordinate)
  }

  func viewportSelection() -> GeographicSelection {
    let rect = map.visibleMapRect
    let topLeft = MKMapPoint(x: rect.minX, y: rect.minY).coordinate
    let bottomRight = MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate
    let wholeWorld = rect.width >= MKMapSize.world.width
    return .rectangle(
      southWest: GeoCoordinate(latitude: max(-90, bottomRight.latitude),
        longitude: wholeWorld ? -180 : PhotoMapDrawingGeometry.normalizedLongitude(topLeft.longitude)),
      northEast: GeoCoordinate(latitude: min(90, topLeft.latitude),
        longitude: wholeWorld ? 180 : PhotoMapDrawingGeometry.normalizedLongitude(bottomRight.longitude)))
  }

  private func coordinate(_ point: CGPoint) -> GeoCoordinate {
    let value = map.convert(point, toCoordinateFrom: drawing)
    return GeoCoordinate(latitude: max(-90, min(90, value.latitude)),
      longitude: PhotoMapDrawingGeometry.normalizedLongitude(value.longitude))
  }
}

/// A real AppKit control keeps the drag target discoverable to accessibility and leaves pins clickable.
@MainActor private final class PhotoMapAreaHandle: NSView {
  var areaIndex = 0 {
    didSet { if oldValue != areaIndex { updateAccessibility() } }
  }
  var isActive = false
  var isResize = false {
    didSet { if oldValue != isResize { updateAccessibility() } }
  }
  var onPress: (() -> Void)?
  var onBegin: ((CGPoint) -> Void)?
  var onDrag: ((CGPoint) -> Void)?
  var onEnd: ((CGPoint) -> Void)?
  var onCancel: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    updateAccessibility()
  }
  required init?(coder: NSCoder) { nil }
  override var isFlipped: Bool { true }
  override func resetCursorRects() { addCursorRect(bounds, cursor: isResize ? .crosshair : .openHand) }
  override func mouseDown(with event: NSEvent) { onBegin?(event.locationInWindow) }
  override func mouseDragged(with event: NSEvent) { onDrag?(event.locationInWindow) }
  override func mouseUp(with event: NSEvent) { onEnd?(event.locationInWindow) }
  override func cancelOperation(_ sender: Any?) { onCancel?() }
  override func accessibilityPerformPress() -> Bool { onPress?(); return true }

  private func updateAccessibility() {
    setAccessibilityLabel(isResize ? MapSelectionL10n.text("영역 크기 조절")
      : MapSelectionL10n.format("영역 %lld 이동", Int64(areaIndex + 1)))
    let help = MapSelectionL10n.text(isResize ? "드래그해 영역 크기를 조절하세요."
      : "번호 손잡이를 드래그해 영역을 옮기세요.")
    setAccessibilityHelp(help)
    toolTip = help
  }

  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 2, dy: 2)
    let path = NSBezierPath(ovalIn: rect)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 3
    shadow.shadowOffset = .zero
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    (isActive ? NSColor.controlAccentColor : (NSColor.controlAccentColor.blended(withFraction: 0.25, of: .black) ?? .controlAccentColor)).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.setStroke()
    path.lineWidth = 2
    path.stroke()
    if isResize {
      let arrow = NSBezierPath()
      let corner = rect.insetBy(dx: 5, dy: 5)
      arrow.move(to: CGPoint(x: corner.minX, y: corner.minY))
      arrow.line(to: CGPoint(x: corner.maxX, y: corner.maxY))
      arrow.move(to: CGPoint(x: corner.minX, y: corner.minY + 3))
      arrow.line(to: CGPoint(x: corner.minX, y: corner.minY))
      arrow.line(to: CGPoint(x: corner.minX + 3, y: corner.minY))
      arrow.move(to: CGPoint(x: corner.maxX - 3, y: corner.maxY))
      arrow.line(to: CGPoint(x: corner.maxX, y: corner.maxY))
      arrow.line(to: CGPoint(x: corner.maxX, y: corner.maxY - 3))
      arrow.lineWidth = 1.5
      arrow.stroke()
    } else {
      let label = String(areaIndex + 1) as NSString
      let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .bold),
        .foregroundColor: NSColor.white]
      let size = label.size(withAttributes: attributes)
      label.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
        withAttributes: attributes)
    }
  }
}

/// Captures drags only while an area tool is active, leaving ordinary map gestures native.
@MainActor final class PhotoMapDrawingSurface: NSView {
  var mode: PhotoMapDrawingMode = .move {
    didSet {
      if oldValue != mode {
        drawingPath.cancel()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
      }
    }
  }
  var onFinish: (([CGPoint], PhotoMapDrawingMode) -> Void)?
  var onCancel: (() -> Void)?
  private var drawingPath = PhotoMapDrawingPath()
  private var points: [CGPoint] { drawingPath.points }
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    // Only region handles capture clicks in move mode; photo cards and background reach MapKit.
    return mode == .move && hit === self ? nil : hit
  }
  override func resetCursorRects() {
    if mode != .move { addCursorRect(bounds, cursor: .crosshair) }
  }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    drawingPath.begin(at: convert(event.locationInWindow, from: nil), bounds: bounds)
    needsDisplay = true
  }
  override func mouseDragged(with event: NSEvent) {
    append(convert(event.locationInWindow, from: nil))
  }
  override func mouseUp(with event: NSEvent) {
    append(convert(event.locationInWindow, from: nil), final: true)
    let finished = drawingPath.finish()
    needsDisplay = true
    onFinish?(finished, mode)
  }
  override func cancelOperation(_ sender: Any?) {
    drawingPath.cancel()
    onCancel?()
    needsDisplay = true
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      cancelOperation(nil)
    } else {
      super.keyDown(with: event)
    }
  }

  private func append(_ point: CGPoint, final: Bool = false) {
    drawingPath.append(point, mode: mode, bounds: bounds, final: final)
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let first = points.first, let last = points.last, points.count > 1 else { return }
    let path: NSBezierPath
    switch mode {
    case .move: return
    case .radius:
      let radius = hypot(last.x - first.x, last.y - first.y)
      path = NSBezierPath(ovalIn: CGRect(x: first.x - radius, y: first.y - radius,
        width: radius * 2, height: radius * 2))
    case .rectangle:
      path = NSBezierPath(rect: CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
        width: abs(last.x - first.x), height: abs(last.y - first.y)))
    case .polygon:
      path = NSBezierPath()
      path.move(to: first)
      for point in points.dropFirst() { path.line(to: point) }
      path.close()
    }
    NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
    path.fill()
    NSColor.controlAccentColor.setStroke()
    path.lineWidth = 2
    path.setLineDash([5, 3], count: 2, phase: 0)
    path.stroke()
  }
}

private extension GeographicSelection {
  var mapOverlay: (any MKOverlay)? {
    switch self {
    case .radius(let center, let meters):
      guard center.isValid, meters.isFinite, meters > 0 else { return nil }
      return MKCircle(center: center.mapCoordinate, radius: meters)
    case .rectangle(let southWest, let northEast):
      guard southWest.isValid && northEast.isValid else { return nil }
      let southWestPoint = MKMapPoint(southWest.mapCoordinate)
      var northEastPoint = MKMapPoint(northEast.mapCoordinate)
      if southWest.longitude > northEast.longitude { northEastPoint.x += MKMapSize.world.width }
      var points = [
        southWestPoint, MKMapPoint(x: southWestPoint.x, y: northEastPoint.y),
        northEastPoint, MKMapPoint(x: northEastPoint.x, y: southWestPoint.y),
      ]
      return MKPolygon(points: &points, count: points.count)
    case .polygon(let points):
      return polygonOverlay(points)
    case .multiple: return nil
    }
  }

  var handleCenter: GeoCoordinate? {
    switch self {
    case .radius(let center, _): return center
    case .rectangle(let southWest, let northEast):
      let south = MKMapPoint(southWest.mapCoordinate), north = MKMapPoint(northEast.mapCoordinate)
      let width = northEast.longitude < southWest.longitude
        ? north.x + MKMapSize.world.width - south.x : north.x - south.x
      let center = MKMapPoint(x: south.x + width / 2, y: (south.y + north.y) / 2).coordinate
      return GeoCoordinate(latitude: center.latitude,
        longitude: PhotoMapDrawingGeometry.normalizedLongitude(center.longitude))
    case .polygon(let points):
      guard let overlay = polygonOverlay(points) else { return nil }
      let rect = overlay.boundingMapRect
      let center = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
      return GeoCoordinate(latitude: center.latitude,
        longitude: PhotoMapDrawingGeometry.normalizedLongitude(center.longitude))
    case .multiple: return nil
    }
  }

  var resizeCoordinate: GeoCoordinate? {
    switch self {
    case .radius(let center, let meters):
      // Eastward geodesic endpoint is stable at every map zoom and latitude.
      let angularDistance = meters / 6_371_000
      let latitude = center.latitude * .pi / 180
      let longitude = center.longitude * .pi / 180
      let edgeLatitude = asin(sin(latitude) * cos(angularDistance))
      let edgeLongitude = longitude + atan2(sin(angularDistance) * cos(latitude),
        cos(angularDistance) - sin(latitude) * sin(edgeLatitude))
      return GeoCoordinate(latitude: edgeLatitude * 180 / .pi,
        longitude: PhotoMapDrawingGeometry.normalizedLongitude(edgeLongitude * 180 / .pi))
    case .rectangle(let southWest, let northEast):
      return GeoCoordinate(latitude: southWest.latitude, longitude: northEast.longitude)
    case .polygon, .multiple: return nil
    }
  }

  func polygonOverlay(_ coordinates: [GeoCoordinate]) -> MKPolygon? {
    guard coordinates.count >= 3 && coordinates.allSatisfy(\.isValid) else { return nil }
    let worldWidth = MKMapSize.world.width
    var points: [MKMapPoint] = []
    for coordinate in coordinates {
      var point = MKMapPoint(coordinate.mapCoordinate)
      if let previous = points.last {
        while point.x - previous.x > worldWidth / 2 { point.x -= worldWidth }
        while point.x - previous.x < -worldWidth / 2 { point.x += worldWidth }
      }
      points.append(point)
    }
    return MKPolygon(points: &points, count: points.count)
  }
}

private extension GeoCoordinate {
  var mapCoordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }
}
