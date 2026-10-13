import Combine
import Foundation

/// Pointer deltas belong to the canvas, not the library/sidebar observation tree.
@MainActor
final class ViewerPanState: ObservableObject {
  @Published private(set) var offset: CGSize = .zero
  private var geometry: ImagePanGeometry?
  private var assetID: URL?
  private var zoom: CGFloat = 1

  func focus(on assetID: URL?) {
    guard self.assetID != assetID else { return }
    self.assetID = assetID
    clearGeometry()
  }

  func clearGeometry() { geometry = nil }

  func setGeometry(_ value: ImagePanGeometry, for assetID: URL) {
    guard self.assetID == assetID, value.isValid else { return }
    geometry = value
    setOffset(offset)
  }

  func setZoom(_ value: CGFloat) {
    guard value.isFinite, value > 0 else { return }
    zoom = value
    setOffset(offset)
  }

  func setOffset(_ value: CGSize) {
    guard value.width.isFinite, value.height.isFinite else { return }
    let bounded = geometry?.constrained(value, zoom: zoom) ?? value
    guard bounded != offset else { return }
    offset = bounded
  }
}
