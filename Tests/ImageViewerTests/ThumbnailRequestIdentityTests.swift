import Foundation
import Testing

@testable import ImageViewer

@Suite("썸네일 요청의 원본·픽셀 식별")
struct ThumbnailRequestIdentityTests {
  private let url = URL(fileURLWithPath: "/tmp/thumbnail-request/photo.dng")
  private let modified = Date(timeIntervalSinceReferenceDate: 123_456)

  @Test("위치·분류·EXIF 보강은 요청 해시와 기존 비트맵 유효성을 바꾸지 않는다")
  func displayMetadataEnrichmentKeepsPixelIdentity() {
    let original = ImageAsset(url: url, byteCount: 1_024, modificationDate: modified)
    var enriched = original
    enriched.creationDate = modified.addingTimeInterval(-10)
    enriched.location = ImageLocation(latitude: 37.5, longitude: 127.1, altitude: 50)
    enriched.hasReadLocation = true
    enriched.photoMarkIdentity = "logical-mark-identity"
    enriched.sortMetadata = LibrarySortMetadata(pixelWidth: 4_032, pixelHeight: 3_024,
      cameraMake: "Example", cameraModel: "Camera", colorSpace: "Display P3")
    enriched.sortMetadataVersion = LibrarySortFileVersion(url: url)
    #expect(original != enriched)
    let first = request(original)
    let second = request(enriched)
    #expect(first.hasSameContent(as: second))
    #expect(first == second)
    #expect(Set([first, second]).count == 1)
    var gate = LatestRequestGate<ThumbnailRequest>()
    let generation = gate.begin(first)
    #expect(gate.accepts(generation, for: second), "Metadata completion must not discard an in-flight pixel result")
  }

  @Test("파일 버전·폴더·압축 항목·편집·HDR가 바뀌면 이전 비트맵을 새 요청에 재사용하지 않는다")
  func changedPixelContentRejectsPreviousRequest() {
    let asset = ImageAsset(url: url, byteCount: 1_024, modificationDate: modified)
    let original = request(asset)
    var archiveAsset = asset
    archiveAsset.archiveOrigin = ArchiveImageOrigin(
      archiveURL: URL(fileURLWithPath: "/tmp/library.zip"), entryPath: "A/photo.dng")
    var otherArchive = archiveAsset
    otherArchive.archiveOrigin = ArchiveImageOrigin(
      archiveURL: URL(fileURLWithPath: "/tmp/library.zip"), entryPath: "B/photo.dng")
    var adjustments = ImageAdjustments.identity
    adjustments.brightness = 0.2
    let edited = ThumbnailRequest(asset: asset, maxPixelSize: 768,
      adjustments: adjustments, prefersHDR: false)
    let hdr = ThumbnailRequest(asset: asset, maxPixelSize: 768,
      adjustments: .identity, prefersHDR: true)
    let variants = [
      request(ImageAsset(url: url, byteCount: 2_048, modificationDate: modified)),
      request(ImageAsset(url: url, byteCount: 1_024, modificationDate: modified.addingTimeInterval(1))),
      request(ImageAsset(url: url, byteCount: nil, modificationDate: modified)),
      request(asset.replacingURL(URL(fileURLWithPath: "/tmp/other/photo.dng"))),
      request(archiveAsset), request(otherArchive), edited, hdr,
    ]
    for changed in variants {
      #expect(!original.hasSameContent(as: changed))
      #expect(original != changed)
      #expect(Set([original, changed]).count == 2)
      var gate = LatestRequestGate<ThumbnailRequest>()
      let previous = gate.begin(original)
      let current = gate.begin(changed)
      #expect(!gate.accepts(previous, for: original))
      #expect(gate.accepts(current, for: changed))
    }
    #expect(!request(archiveAsset).hasSameContent(as: request(otherArchive)))
  }

  @Test("같은 압축 항목의 메타데이터 보강과 크기 변경은 기존 표시 픽셀을 유지한다")
  func archiveIdentityAndDisplaySizeHaveSeparateSemantics() {
    var asset = ImageAsset(url: url, byteCount: 1_024, modificationDate: modified)
    asset.archiveOrigin = ArchiveImageOrigin(
      archiveURL: URL(fileURLWithPath: "/tmp/library.zip"), entryPath: "A/photo.dng")
    let original = request(asset)
    var enriched = asset
    enriched.archiveOrigin = ArchiveImageOrigin(
      archiveURL: URL(fileURLWithPath: "/tmp/library.zip"), entryPath: "A/photo.dng")
    enriched.hasReadLocation = true
    #expect(original == request(enriched))
    let larger = ThumbnailRequest(asset: asset, maxPixelSize: 1_024,
      adjustments: .identity, prefersHDR: false)
    #expect(original != larger)
    #expect(original.hasSameContent(as: larger))
    let precise = ThumbnailRequest(asset: asset, maxPixelSize: 768,
      adjustments: .identity, prefersHDR: false, prefersPreciseImage: true)
    #expect(original != precise)
    #expect(original.hasSameContent(as: precise))
  }

  private func request(_ asset: ImageAsset) -> ThumbnailRequest {
    ThumbnailRequest(asset: asset, maxPixelSize: 768, adjustments: .identity, prefersHDR: false)
  }
}
