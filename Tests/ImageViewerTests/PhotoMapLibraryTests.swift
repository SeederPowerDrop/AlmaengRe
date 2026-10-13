import AppKit
import ImageIO
import MapKit
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

@Suite("폴더 지도 색인과 위치 선택 통합")
@MainActor
struct PhotoMapLibraryTests {
  @Test("지도 영역의 몽땅보기는 뷰어 장수와 관계없이 방향키로 선택 사진만 이동한다")
  func filteredOverviewArrowNavigation() async throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let defaults = UserDefaults(suiteName: "PhotoMapLibraryTests-\(UUID())")!
    let store = makeStore(defaults)
    let shortcuts = ShortcutStore(defaults: defaults)
    store.open(urls: [folder])
    try await wait { !store.isLoading }
    store.setImagesPerPage(7)
    store.presentationMode = .map
    store.libraryQuery.geographicSelection = .radius(
      center: GeoCoordinate(latitude: 48.8584, longitude: 2.2945), meters: 1_000)
    try await wait { !store.isFiltering && !store.isIndexingLocations }
    let selection = store.libraryQuery.geographicSelection
    let viewport = store.photoMapViewport
    viewport.camera = MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: 48.8584, longitude: 2.2945),
      fromDistance: 2_000, pitch: 0, heading: 0)
    store.showMapSelection(in: .overview)
    #expect(store.photoMapViewport === viewport)
    store.wrapsNavigation = false
    #expect(store.currentIndex == 0)
    for (code, index) in [(UInt16(124), 1), (123, 0), (125, 1), (126, 0)] {
      let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
      #expect(store.handleViewerKeyDown(event, shortcuts: shortcuts))
      #expect(store.currentIndex == index)
      #expect(store.currentAsset?.filename == (index == 0 ? "01-paris.jpg" : "02-paris.jpg"))
      let currentURL = try #require(store.currentAsset?.url)
      #expect(store.selectedURLs == [currentURL])
      #expect(store.libraryQuery.geographicSelection == selection)
    }
    #expect(store.assets.count == 2 && store.mapAssets.count == 4)
    store.presentationMode = .map
    try await wait { !store.isFiltering }
    #expect(store.photoMapViewport === viewport)
    #expect(store.photoMapViewport.camera?.centerCoordinate.latitude == 48.8584)
  }

  @Test("지도 영역과 영역 밖 핀의 일괄 작업은 명시한 파일만 대상으로 한다")
  func batchMapTargetsAreExplicit() async throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = makeStore()
    store.open(urls: [folder])
    try await wait { !store.isLoading }
    store.presentationMode = .map
    store.libraryQuery.geographicSelection = .radius(
      center: GeoCoordinate(latitude: 48.8584, longitude: 2.2945), meters: 1_000)
    try await wait { !store.isFiltering && !store.isIndexingLocations }
    let paris = Set(store.assets.map(\.url))
    let tokyo = try #require(store.mapAssets.first { $0.filename == "03-tokyo.jpg" })
    store.clearSelection()
    #expect(!store.canStartBatchOperation)
    #expect(store.canStartBatchOperation(urls: paris))
    store.presentBatchExport(urls: paris)
    #expect(Set(store.batchAssets.map(\.url)) == paris)
    store.batchSheet = nil
    #expect(store.batchAssets.isEmpty)
    #expect(store.canStartBatchOperation(urls: [tokyo.url]))
    store.presentBatchRename(urls: [tokyo.url])
    #expect(store.batchAssets.map(\.url) == [tokyo.url])
    #expect(Set(store.assets.map(\.url)) == paris)
    #expect(store.libraryQuery.geographicSelection != nil)
    store.batchSheet = nil
    #expect(!store.canStartBatchOperation(urls: []))
    #expect(!store.canStartBatchOperation(urls: [folder.appendingPathComponent("unknown.jpg")]))
  }

  @Test("지도 진입은 GPS를 읽고 반경 선택은 다른 핀을 보존하며 사진 목록만 제한한다")
  func mapFilterAndOpenOutsideSelection() async throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = makeStore()
    store.open(urls: [folder])
    try await wait { !store.isLoading }
    #expect(store.assets.count == 4)
    #expect(store.allAssets.allSatisfy { !$0.hasReadLocation })
    store.presentationMode = .map
    try await wait { !store.isFiltering && !store.isIndexingLocations }
    #expect(store.mapAssets.compactMap(\.location).count == 3)
    #expect(store.allAssets.allSatisfy { $0.hasReadLocation })
    #expect(store.locationScanCount == 4)
    let collection = store.mapCollectionID
    store.libraryQuery.geographicSelection = .radius(
      center: GeoCoordinate(latitude: 48.8584, longitude: 2.2945), meters: 1_000)
    try await wait { !store.isFiltering }
    #expect(store.assets.map(\.filename) == ["01-paris.jpg", "02-paris.jpg"])
    #expect(store.allAssets.count == 4 && store.mapAssets.count == 4)
    #expect(store.mapCollectionID == collection)
    store.showMapSelection()
    #expect(store.presentationMode == .overview)
    let tokyo = try #require(store.mapAssets.first { $0.filename == "03-tokyo.jpg" })
    store.openAssetFromMap(tokyo)
    try await wait { !store.isFiltering }
    #expect(store.presentationMode == .viewer)
    #expect(store.libraryQuery.geographicSelection == nil)
    #expect(store.currentAsset?.id == tokyo.id)
    #expect(store.assets.count == 4)
  }

  @Test("지도의 빈 선택과 빠른 변경은 전체 폴더와 최신 검색 조건을 보존한다")
  func emptyAndLatestFilter() async throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = makeStore()
    store.open(urls: [folder])
    try await wait { !store.isLoading }
    store.presentationMode = .map
    try await wait { !store.isFiltering }
    store.libraryQuery.geographicSelection = .rectangle(
      southWest: GeoCoordinate(latitude: -1, longitude: -1),
      northEast: GeoCoordinate(latitude: 1, longitude: 1))
    try await wait { !store.isFiltering }
    #expect(store.assets.isEmpty && store.mapAssets.count == 4)
    #expect(store.presentationMode == .map)
    store.libraryQuery.geographicSelection = .radius(
      center: GeoCoordinate(latitude: 48.8584, longitude: 2.2945), meters: 1_000)
    store.libraryQuery.geographicSelection = .radius(
      center: GeoCoordinate(latitude: 35.6812, longitude: 139.7671), meters: 1_000)
    store.libraryQuery.searchText = "tokyo"
    try await wait { !store.isFiltering }
    #expect(store.assets.map(\.filename) == ["03-tokyo.jpg"])
    #expect(store.mapAssets.map(\.filename) == ["03-tokyo.jpg"])
    store.resetLibraryQuery()
    try await wait { !store.isFiltering }
    #expect(store.assets.count == 4)
  }

  @Test("다른 폴더를 열면 이전 위치 제한과 지도 수명을 초기화한다")
  func folderSwitchClearsArea() async throws {
    let folder = try fixture()
    let next = try fixture()
    defer {
      try? FileManager.default.removeItem(at: folder)
      try? FileManager.default.removeItem(at: next)
    }
    let store = makeStore()
    store.open(urls: [folder])
    try await wait { !store.isLoading }
    store.presentationMode = .map
    store.libraryQuery.geographicSelection = .radius(
      center: GeoCoordinate(latitude: 0, longitude: 0), meters: 10)
    let old = store.mapCollectionID
    let oldViewport = store.photoMapViewport
    oldViewport.camera = MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: 48.8584, longitude: 2.2945),
      fromDistance: 2_000, pitch: 0, heading: 0)
    store.open(urls: [next])
    try await wait { !store.isLoading && !store.isFiltering }
    #expect(store.libraryQuery.geographicSelection == nil)
    #expect(store.mapCollectionID != old)
    #expect(store.photoMapViewport !== oldViewport)
    #expect(store.photoMapViewport.camera == nil)
    // Folder URLs created before the directory exists omit the trailing slash;
    // parent URLs include it. Compare canonical filesystem paths, not URL hints.
    let expectedParent = next.standardizedFileURL.resolvingSymlinksInPath().path
    let allParents = Set(store.allAssets.map {
      $0.url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
    })
    let mapParents = Set(store.mapAssets.map {
      $0.url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
    })
    #expect(allParents == [expectedParent])
    #expect(mapParents == [expectedParent])
    #expect(store.assets.count == 4)
  }

  @Test("저장된 지도 모드와 영역은 재실행 시 GPS 색인 및 선택과 함께 복원한다")
  func restoreMapSelection() async throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let defaults = UserDefaults(suiteName: "PhotoMapLibraryTests-\(UUID())")!
    let store = makeStore(defaults)
    store.open(urls: [folder])
    try await wait { !store.isLoading }
    store.presentationMode = .map
    store.libraryQuery.geographicSelection = .radius(
      center: GeoCoordinate(latitude: 48.8584, longitude: 2.2945), meters: 1_000)
    try await wait { !store.isFiltering }
    store.saveSessionNow()
    let restored = makeStore(defaults)
    await restored.restoreLastSession()
    try await wait { !restored.isFiltering && !restored.isIndexingLocations }
    #expect(restored.presentationMode == .map)
    #expect(restored.libraryQuery.geographicSelection == store.libraryQuery.geographicSelection)
    #expect(restored.assets.count == 2)
    #expect(restored.mapAssets.compactMap(\.location).count == 3)
  }

  @Test("여러 영역의 합집합은 뷰어와 몽땅보기, 복원에서 유지하고 개별 해제를 반영한다")
  func multipleAreasBrowseAndRestore() async throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let defaults = UserDefaults(suiteName: "PhotoMapLibraryTests-\(UUID())")!
    let store = makeStore(defaults)
    store.open(urls: [folder])
    try await wait { !store.isLoading }
    store.presentationMode = .map
    try await wait { !store.isFiltering }
    let paris = GeographicSelection.radius(
      center: GeoCoordinate(latitude: 48.8584, longitude: 2.2945), meters: 1_000)
    let tokyo = GeographicSelection.rectangle(
      southWest: GeoCoordinate(latitude: 35.67, longitude: 139.75),
      northEast: GeoCoordinate(latitude: 35.69, longitude: 139.78))
    let selected = GeographicSelection.combining([paris, paris, tokyo])
    store.libraryQuery.geographicSelection = selected
    try await wait { !store.isFiltering }
    #expect(store.assets.count == 3)
    #expect(Set(store.assets.map(\.filename)).count == 3)
    #expect(store.mapAssets.count == 4)
    store.showMapSelection(in: .viewer)
    #expect(store.presentationMode == .viewer)
    #expect(store.libraryQuery.geographicSelection == selected)
    for _ in 0..<4 {
      store.navigatePage(1)
      #expect(store.currentAsset?.location != nil)
      #expect(store.currentAsset?.filename != "04-no-gps.jpg")
    }
    store.showMapSelection(in: .overview)
    #expect(store.presentationMode == .overview)
    #expect(store.assets.count == 3)
    store.saveSessionNow()
    let restored = makeStore(defaults)
    await restored.restoreLastSession()
    try await wait { !restored.isFiltering && !restored.isIndexingLocations }
    #expect(restored.presentationMode == .overview)
    #expect(restored.libraryQuery.geographicSelection == selected)
    #expect(restored.assets.count == 3)
    restored.libraryQuery.geographicSelection = .combining([tokyo])
    try await wait { !restored.isFiltering }
    #expect(restored.assets.map(\.filename) == ["03-tokyo.jpg"])
    restored.libraryQuery.geographicSelection = nil
    try await wait { !restored.isFiltering }
    #expect(restored.assets.count == 4)
  }

  @Test("선택 결과가 비었거나 처리 중일 때 보기 전환을 실행하지 않는다")
  func cannotOpenUnreadySelection() async throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = makeStore()
    store.open(urls: [folder])
    try await wait { !store.isLoading }
    store.presentationMode = .map
    store.libraryQuery.geographicSelection = .radius(
      center: GeoCoordinate(latitude: 0, longitude: 0), meters: 10)
    store.showMapSelection(in: .viewer)
    #expect(store.presentationMode == .map)
    try await wait { !store.isFiltering }
    #expect(store.assets.isEmpty)
    store.showMapSelection(in: .overview)
    #expect(store.presentationMode == .map)
  }

  @Test("GPS 없는 파일도 색인 완료로 기억하고 새 폴더 스캔에서는 변경된 메타데이터를 읽는다")
  func negativeLocationLookupDoesNotRepeat() async throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let library = ImageLibrary()
    let source = try await library.scan(folder: folder)
    let first = try await library.enrichLocations(source)
    let missing = try #require(first.first { $0.filename == "04-no-gps.jpg" })
    #expect(missing.hasReadLocation && missing.location == nil)
    try writeJPEG(missing.url, coordinate: GeoCoordinate(latitude: -33.86, longitude: 151.21))
    let cached = try await library.enrichLocations([missing])
    #expect(cached[0].location == nil)
    let refreshed = try await library.enrichLocations(try await library.scan(folder: folder))
    let changed = try #require(refreshed.first { $0.id == missing.id }?.location)
    #expect(abs(changed.latitude + 33.86) < 0.0001)
    #expect(abs(changed.longitude - 151.21) < 0.0001)
  }

  private func makeStore(_ preferences: UserDefaults? = nil) -> AppStore {
    AppStore(defaults: preferences ?? UserDefaults(suiteName: "PhotoMapLibraryTests-\(UUID())")!, monitorsSystemResources: false)
  }

  private func wait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !condition() {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func fixture() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("photo-map-test-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try writeJPEG(folder.appendingPathComponent("01-paris.jpg"), coordinate: GeoCoordinate(latitude: 48.8584, longitude: 2.2945))
    try writeJPEG(folder.appendingPathComponent("02-paris.jpg"), coordinate: GeoCoordinate(latitude: 48.859, longitude: 2.295))
    try writeJPEG(folder.appendingPathComponent("03-tokyo.jpg"), coordinate: GeoCoordinate(latitude: 35.6812, longitude: 139.7671))
    try writeJPEG(folder.appendingPathComponent("04-no-gps.jpg"), coordinate: nil)
    return folder
  }

  private func writeJPEG(_ url: URL, coordinate: GeoCoordinate?) throws {
    let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
      bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.6, green: 0.3, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    var properties: [CFString: Any] = [:]
    if let coordinate {
      properties[kCGImagePropertyGPSDictionary] = [
        kCGImagePropertyGPSLatitude: abs(coordinate.latitude),
        kCGImagePropertyGPSLatitudeRef: coordinate.latitude < 0 ? "S" : "N",
        kCGImagePropertyGPSLongitude: abs(coordinate.longitude),
        kCGImagePropertyGPSLongitudeRef: coordinate.longitude < 0 ? "W" : "E",
      ] as [CFString: Any]
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
  }
}
