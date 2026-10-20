import Foundation
import Testing

@testable import ImageViewer

@Suite("Prepared overview fixture isolation")
struct OverviewPreparedFixtureTests {
  @Test("Independent product identities may share one verified fixture")
  func differentProductsUseTheSameFixtureWithoutClaimingIdentity() throws {
    let first = try certificate(product: String(repeating: "a", count: 64))
    let second = try certificate(product: String(repeating: "b", count: 64))
    #expect(first.productSourceDigestSHA256 != second.productSourceDigestSHA256)
    #expect(first.fixtureManifestSHA256 == second.fixtureManifestSHA256)
    #expect(first.initialFailure(initialDisk: snapshot(), executableSHA256: digest) == nil)
    #expect(second.initialFailure(initialDisk: snapshot(), executableSHA256: digest) == nil)
  }

  @Test("Wrong executable, changed sources and unverified copies are rejected")
  func provenanceFailuresAreRejected() throws {
    #expect(try certificate().initialFailure(initialDisk: snapshot(), executableSHA256: "wrong") != nil)
    #expect(try certificate(overrides: ["sourceMetadataUnchangedSinceFixture": false])
      .initialFailure(initialDisk: snapshot(), executableSHA256: digest) != nil)
    #expect(try certificate(overrides: ["sourceAndDestinationPreviewManifestsIdentical": false])
      .initialFailure(initialDisk: snapshot(), executableSHA256: digest) != nil)
    #expect(try certificate(overrides: ["fixtureManifestSHA256": "not-a-digest"])
      .initialFailure(initialDisk: snapshot(), executableSHA256: digest) != nil)
  }

  @Test("Only the exact compact seed is accepted before product work starts")
  func exactSeedAndCompactInventoryAreRejected() throws {
    let proof = try certificate()
    #expect(proof.initialFailure(initialDisk: snapshot(entries: 718, exact: 1), executableSHA256: digest) != nil)
    #expect(proof.initialFailure(initialDisk: snapshot(entries: 716), executableSHA256: digest) != nil)
    #expect(proof.initialFailure(initialDisk: snapshot(preview: 999), executableSHA256: digest) != nil)
  }

  private var digest: String { String(repeating: "c", count: 64) }
  private func snapshot(entries: Int = 717, preview: Int = 1_000, exact: Int = 0) -> ThumbnailDiskCacheSnapshot {
    ThumbnailDiskCacheSnapshot(entryCount: entries, byteCount: preview + exact,
      byteLimit: 512 * 1_024 * 1_024, previewBytes: preview, exactBytes: exact, hits: 0, misses: 0)
  }
  private func certificate(product: String? = nil, overrides: [String: Any] = [:]) throws -> PreparedOverviewFixtureCertificate {
    var fields: [String: Any] = ["schemaVersion": 1, "fixtureManifestSHA256": digest,
      "sourceDirectory": "/source", "destinationCacheDirectory": "/private-runtime/thumbnails",
      "currentExecutableSHA256": digest, "productSourceDigestSHA256": product ?? digest,
      "measurementSourceDigestSHA256": digest, "sourceFileMetadataSHA256": digest,
      "sourceMetadataUnchangedSinceFixture": true, "verifiedPNGCount": 717, "uniqueSourceHashes": 717,
      "pngCRCAndDimensionsVerified": true, "sourceAndDestinationPreviewManifestsIdentical": true,
      "compactPreviewBytes": 1_000]
    fields.merge(overrides) { _, new in new }
    return try JSONDecoder().decode(PreparedOverviewFixtureCertificate.self,
      from: JSONSerialization.data(withJSONObject: fields))
  }
}
