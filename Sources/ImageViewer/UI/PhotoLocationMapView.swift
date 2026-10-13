import MapKit
import SwiftUI

/// The inspector embeds the system map immediately; opening a separate app is optional.
struct PhotoLocationMapView: View {
  let location: ImageLocation
  @State private var position: MapCameraPosition = .automatic

  var body: some View {
    Map(position: $position, interactionModes: [.pan, .zoom]) {
      Marker(L10n.text("사진 위치"), coordinate: coordinate)
        .tint(ViewerTheme.accent)
    }
    .mapStyle(.standard(elevation: .flat))
    .mapControls { MapZoomStepper() }
    .frame(minWidth: 180, idealWidth: 240, maxWidth: .infinity)
    .frame(height: 170)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .accessibilityLabel(L10n.text("사진 위치 Apple 지도"))
    .onChange(of: location, initial: true) { _, _ in
      position = .region(MKCoordinateRegion(
        center: coordinate, latitudinalMeters: 1_200, longitudinalMeters: 1_200))
    }
  }

  private var coordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
  }
}
