@preconcurrency import MapKit

/// In-memory browsing position belongs to the source collection, not a map view's lifetime.
@MainActor
final class PhotoMapViewportState {
  var camera: MKMapCamera?
}
