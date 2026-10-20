import Combine
import Foundation

/// Photo transforms are independent of both the map camera and the main viewer.
/// A new pin resets the transform while retaining the chosen image fit mode.
@MainActor
final class PhotoMapPreviewState: ObservableObject {
  static let zoomRange: ClosedRange<CGFloat> = 0.1...16

  @Published private(set) var assetID: URL?
  @Published private(set) var baseScaleMode: BaseScaleMode = .fit
  @Published private(set) var zoom: CGFloat = 1
  @Published private(set) var panOffset: CGSize = .zero
  private var geometry: ImagePanGeometry?

  var hasSelection: Bool { assetID != nil }
  var canPan: Bool { hasSelection && (zoom > 1 || baseScaleMode.canOverflowAtBaseScale) }

  func focus(on assetID: URL?) {
    guard self.assetID != assetID else { return }
    self.assetID = assetID
    geometry = nil
    zoom = 1
    panOffset = .zero
  }

  func clearSelection() { focus(on: nil) }

  func setScaleMode(_ mode: BaseScaleMode) {
    guard hasSelection else { return }
    if baseScaleMode != mode { geometry = nil }
    baseScaleMode = mode
    zoom = 1
    panOffset = .zero
  }

  func centerImage() {
    guard hasSelection else { return }
    panOffset = .zero
  }

  func zoomIn() { setZoom(zoom * 1.25) }
  func zoomOut() { setZoom(zoom / 1.25) }

  func setZoom(_ value: CGFloat) {
    guard hasSelection, value.isFinite else { return }
    zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, value))
    if !canPan { panOffset = .zero }
    else { constrainPan() }
  }

  func setPanOffset(_ value: CGSize) {
    guard canPan, value.width.isFinite, value.height.isFinite else { return }
    panOffset = geometry?.constrained(value, zoom: zoom) ?? value
  }

  func setGeometry(_ value: ImagePanGeometry, for assetID: URL) {
    guard self.assetID == assetID, value.isValid else { return }
    geometry = value
    constrainPan()
  }

  private func constrainPan() {
    if let geometry { panOffset = geometry.constrained(panOffset, zoom: zoom) }
  }
}
