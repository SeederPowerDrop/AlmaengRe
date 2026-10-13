import AppKit
import MapKit
import Testing

@testable import ImageViewer

@Suite("지도 화면 위치 복원")
@MainActor
struct PhotoMapViewportTests {
  @Test("지도 생성 직후 기본 세계 지도가 저장된 위치를 덮어쓰지 않고 레이아웃 후 복원한다")
  func restoreAfterLayout() throws {
    let state = PhotoMapViewportState()
    state.camera = MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: 48.8584, longitude: 2.2945),
      fromDistance: 4_000, pitch: 0, heading: 0)
    let saved = try #require(state.camera?.copy() as? MKMapCamera)
    let surface = PhotoMapSurface(frame: .zero)
    surface.restoreViewport(from: state)
    surface.rememberViewport()
    #expect(state.camera?.centerCoordinate.latitude == saved.centerCoordinate.latitude)
    surface.frame = CGRect(x: 0, y: 0, width: 960, height: 640)
    surface.layoutSubtreeIfNeeded()
    expectCamera(surface.map.camera, near: saved)

    surface.map.setCamera(MKMapCamera(
      lookingAtCenter: CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671),
      fromDistance: 8_000, pitch: 0, heading: 0), animated: false)
    surface.rememberViewport()
    let last = try #require(state.camera?.copy() as? MKMapCamera)
    let returned = PhotoMapSurface(frame: .zero)
    returned.restoreViewport(from: state)
    returned.frame = CGRect(x: 0, y: 0, width: 960, height: 640)
    returned.layoutSubtreeIfNeeded()
    expectCamera(returned.map.camera, near: last)
  }

  @Test("저장된 영역은 실제 지도 크기가 생긴 후 맞춰지고 명시적인 전체 위치 보기도 동작한다")
  func initialFitWaitsForLayout() {
    let surface = PhotoMapSurface(frame: .zero)
    let coordinator = NativePhotoMapView.Coordinator()
    let state = PhotoMapViewportState()
    surface.restoreViewport(from: state)
    surface.rememberViewport()
    #expect(state.camera == nil)
    var fits = 0
    surface.updateViewport { map in
      fits += 1
      coordinator.fit(map, selection: .radius(
        center: GeoCoordinate(latitude: 48.8584, longitude: 2.2945), meters: 1_000))
    }
    #expect(fits == 0)
    surface.frame = CGRect(x: 0, y: 0, width: 960, height: 640)
    surface.layoutSubtreeIfNeeded()
    #expect(fits == 1)
    #expect(abs(surface.map.centerCoordinate.latitude - 48.8584) < 0.01)
    #expect(abs(surface.map.centerCoordinate.longitude - 2.2945) < 0.01)
    #expect(surface.map.region.span.latitudeDelta < 0.1)
    #expect(state.camera != nil)
    surface.updateViewport { map in
      fits += 1
      map.setRegion(MKCoordinateRegion(center: .init(latitude: 0, longitude: 0),
        span: .init(latitudeDelta: 120, longitudeDelta: 120)), animated: false)
    }
    #expect(fits == 2)
    #expect(surface.map.region.span.latitudeDelta > 1)
  }

  private func expectCamera(_ actual: MKMapCamera, near expected: MKMapCamera) {
    #expect(abs(actual.centerCoordinate.latitude - expected.centerCoordinate.latitude) < 0.0001)
    #expect(abs(actual.centerCoordinate.longitude - expected.centerCoordinate.longitude) < 0.0001)
    #expect(abs(actual.centerCoordinateDistance - expected.centerCoordinateDistance) < 1)
  }
}
