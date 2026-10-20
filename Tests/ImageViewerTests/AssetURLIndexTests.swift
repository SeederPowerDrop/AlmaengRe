import Foundation
import Testing

@testable import ImageViewer

@Suite("대량 목록의 선택 조회")
struct AssetURLIndexTests {
  @Test("드문 선택과 넓은 선택 모두 원래 목록의 순서와 중복 항목을 보존한다")
  func preservesCollectionOrderAndDuplicates() {
    let assets = (0..<1_000).map { index in
      ImageAsset(url: URL(fileURLWithPath: "/index-test/\(index / 2).jpg"),
        byteCount: Int64(index), modificationDate: nil)
    }
    let index = AssetURLIndex(assets)
    let missing = URL(fileURLWithPath: "/index-test/missing.jpg")
    let sparse: Set<URL> = [assets[900].url, missing, assets[8].url]
    #expect(index.assets(matching: sparse, in: assets).map(\.byteCount) == [8, 9, 900, 901])
    #expect(index.firstIndex(for: assets[901].url) == 900)
    #expect(index.firstIndex(for: missing) == nil)
    let broad = Set(assets.map(\.url)).union([missing])
    #expect(index.assets(matching: broad, in: assets) == assets)
    #expect(index.assets(matching: [], in: assets).isEmpty)
  }
}
