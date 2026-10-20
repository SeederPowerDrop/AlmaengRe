import Foundation

/// Positions only: no image pixels, metadata copies or archive leases. Owners
/// must replace the index whenever their source collection changes.
struct AssetURLIndex {
  private let positions: [URL: [Int]]

  init(_ assets: [ImageAsset]) {
    var positions: [URL: [Int]] = [:]
    positions.reserveCapacity(assets.count)
    for (index, asset) in assets.enumerated() {
      positions[asset.url, default: []].append(index)
    }
    self.positions = positions
  }

  func firstIndex(for url: URL) -> Int? { positions[url]?.first }

  func assets(matching urls: Set<URL>, in assets: [ImageAsset]) -> [ImageAsset] {
    guard !urls.isEmpty else { return [] }
    // A broad selection is cheaper to walk once than to sort its positions.
    if urls.count > assets.count / 2 {
      return assets.filter { urls.contains($0.url) }
    }
    return urls.flatMap { positions[$0] ?? [] }.sorted().map { assets[$0] }
  }
}
