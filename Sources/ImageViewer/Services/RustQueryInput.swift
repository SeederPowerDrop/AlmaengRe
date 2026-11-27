import CAlmaengCore
import Foundation

/// Bounded scalar records and UTF-8 offsets. A query session may reuse this
/// immutable storage; native pointers are borrowed only during one call.
struct RustQueryInput {
  private(set) var records: [AmQueryRecord] = []
  private(set) var strings = Data()
  var byteCount: Int { records.count * MemoryLayout<AmQueryRecord>.stride + strings.count }

  func selecting(_ indices: [Int]) -> RustQueryInput {
    RustQueryInput(records: indices.map { records[$0] },strings: strings)
  }

  private init(records: [AmQueryRecord], strings: Data) {
    self.records = records; self.strings = strings
  }

  init(_ assets: [ImageAsset]) throws {
    guard assets.count <= 100_000 else { throw RustImageEngineError(detail: "Too many images") }
    records.reserveCapacity(assets.count)
    strings.reserveCapacity(min(16 * 1024 * 1024, assets.count * 128))
    for asset in assets {
      try Task.checkCancellation()
      let metadata = asset.sortMetadata
      var row = AmQueryRecord()
      let path = asset.url.path
      row.path = try append(path)
      let name = asset.filename
      let nameBytes = name.utf8.count
      // Ordinary names already occupy the end of the path. Reuse those exact
      // UTF-8 bytes; archive display names may differ and use their own span.
      if path.utf8.suffix(nameBytes).elementsEqual(name.utf8) {
        row.name = AmQueryString(offset: row.path.offset + row.path.len - nameBytes,len: nameBytes)
      } else {
        row.name = try append(name)
      }
      row.camera_make = try append(metadata?.cameraMake)
      row.camera_model = try append(metadata?.cameraModel)
      row.color_space = try append(metadata?.colorSpace)
      if let value = asset.byteCount { row.size = value; row.present |= 1 }
      if let value = asset.modificationDate { row.modified = value.timeIntervalSince1970; row.present |= 2 }
      if let value = asset.creationDate { row.created = value.timeIntervalSince1970; row.present |= 4 }
      if let value = asset.location { row.latitude = value.latitude; row.longitude = value.longitude; row.present |= 8 | 16 }
      if let value = metadata?.pixelWidth { row.pixel_width = Int64(value); row.present |= 32 }
      if let value = metadata?.pixelHeight { row.pixel_height = Int64(value); row.present |= 64 }
      if let value = metadata?.capturedAt { row.captured = value.timeIntervalSince1970; row.present |= 128 }
      if let value = metadata?.exposureTime { row.exposure_time = value; row.present |= 256 }
      if let value = metadata?.aperture { row.aperture = value; row.present |= 512 }
      records.append(row)
    }
    guard records.count * MemoryLayout<AmQueryRecord>.stride + strings.count <= 64 * 1024 * 1024
    else { throw RustImageEngineError(detail: "Invalid query request") }
  }

  private mutating func append(_ value: String?) throws -> AmQueryString {
    guard let value else { return AmQueryString(offset: -1, len: 0) }
    let offset = strings.count
    let count = value.utf8.count
    guard count <= 64 * 1024 * 1024 - offset else { throw RustImageEngineError(detail: "Invalid query string") }
    if value.utf8.withContiguousStorageIfAvailable({ bytes in
      strings.append(contentsOf: bytes)
    }) == nil {
      strings.append(contentsOf: value.utf8)
    }
    return AmQueryString(offset: offset, len: count)
  }
}
