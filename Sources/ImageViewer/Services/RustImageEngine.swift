import CAlmaengCore
import CoreGraphics
import Foundation

struct ImageMatchPair: Decodable, Equatable, Sendable {
  let firstIndex: Int?
  let secondIndex: Int?
}

struct RustImageEngineError: LocalizedError {
  let detail: String
  var errorDescription: String? { L10n.format("이미지 엔진 작업을 완료하지 못했습니다: %@", detail) }
}

/// The FFI owns returned buffers until this wrapper copies and releases them. No borrowed
/// pointer escapes a call. Calls are synchronous: library work runs in ImageLibrary's actor.
enum RustImageEngine {
  private struct Reply<T: Decodable>: Decodable { let ok: Bool; let data: T?; let error: String? }
  struct Record: Codable {
    let path: String
    let name: String
    let size: Int64?
    let modified: Double?
    let created: Double?
    let latitude: Double?
    let longitude: Double?
    let entryPath: String?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let captured: Double?
    let exposureTime: Double?
    let cameraMake: String?
    let cameraModel: String?
    let aperture: Double?
    let colorSpace: String?
    init(_ asset: ImageAsset) {
      path = asset.url.path; name = asset.filename; size = asset.byteCount
      modified = asset.modificationDate?.timeIntervalSince1970
      created = asset.creationDate?.timeIntervalSince1970
      latitude = asset.location?.latitude; longitude = asset.location?.longitude; entryPath = nil
      pixelWidth = asset.sortMetadata?.pixelWidth; pixelHeight = asset.sortMetadata?.pixelHeight
      captured = asset.sortMetadata?.capturedAt?.timeIntervalSince1970
      exposureTime = asset.sortMetadata?.exposureTime
      cameraMake = asset.sortMetadata?.cameraMake; cameraModel = asset.sortMetadata?.cameraModel
      aperture = asset.sortMetadata?.aperture; colorSpace = asset.sortMetadata?.colorSpace
    }
    func asset(origin: ArchiveImageOrigin? = nil) -> ImageAsset {
      ImageAsset(url: URL(fileURLWithPath: path), byteCount: size,
        modificationDate: modified.map(Date.init(timeIntervalSince1970:)),
        creationDate: created.map(Date.init(timeIntervalSince1970:)), archiveOrigin: origin)
    }
  }
  private struct LimitsRequest: Encodable {
    let op = "limits"; let mode: String; let snapshot: ImageResourceSnapshot; let storage: ImageStorageKind
  }
  static func limits(mode: ImageLoadingMode, snapshot: ImageResourceSnapshot,
    storage: ImageStorageKind) throws -> ImageResourceLimits {
    var snapshot = snapshot
    if snapshot.cpuBusyFraction?.isFinite == false { snapshot.cpuBusyFraction = nil }
    return try call(LimitsRequest(mode: mode.rawValue, snapshot: snapshot, storage: storage))
  }

  private struct QueryRequest: Encodable { let op = "query"; let assets: [Record]; let options: LibraryQuery }
  private struct MatchRequest: Encodable { let op = "match"; let first: [Record]; let second: [Record]; let sort: LibrarySort }
  private struct ScanRequest: Encodable { let op = "scan"; let path: String }
  private struct ZIPRequest: Encodable { let op = "zip"; let path: String; let destination: String; let extensions: [String] }

  static func query(_ assets: [ImageAsset], options: LibraryQuery,
    session: RustQuerySession? = nil) throws -> [ImageAsset] {
    try query(assets, options: options, legacyJSON: false,session: session)
  }

  #if DEBUG
  /// Differential oracle for transport changes, never selected by production.
  static func queryUsingLegacyJSON(_ assets: [ImageAsset], options: LibraryQuery) throws -> [ImageAsset] {
    try query(assets, options: options, legacyJSON: true)
  }
  #endif

  private static func query(_ assets: [ImageAsset], options: LibraryQuery,
    legacyJSON: Bool, session: RustQuerySession? = nil) throws -> [ImageAsset] {
    let totalStarted = QueryPerformanceTrace.start()
    defer { QueryPerformanceTrace.record("engine.query_total", since: totalStarted, count: assets.count, synchronous: true) }
    try Task.checkCancellation()
    let request = QueryPerformanceTrace.measure("ffi.query.reuse_lookup",count: assets.count) { session?.begin(assets) }
    let predicateStarted = QueryPerformanceTrace.start()
    let nameMatcher = LibraryTextMatcher(pattern: options.searchText)
    var filtered: [ImageAsset]
    var selectedIndices: [Int]?
    if legacyJSON {
      // Preserve the old filtering path as the debug differential oracle.
      let searchPredicate = LibrarySearchPredicate(filters: options.searchFilters)
      filtered = []; filtered.reserveCapacity(assets.count)
      for asset in assets {
        try Task.checkCancellation()
        if nameMatcher.matches(asset.filename), LibraryMediaFilter.matches(asset, query: options),
          searchPredicate.matches(asset) { filtered.append(asset) }
      }
    } else {
      try Task.checkCancellation()
      let mediaPredicate = PreparedLibraryMediaPredicate(query: options)
      let searchPredicate = options.searchFilters.isActive ? LibrarySearchPredicate(filters: options.searchFilters) : nil
      if nameMatcher.isEmpty && !mediaPredicate.isActive && searchPredicate == nil {
        // Share the source buffer. A plain sort needs no Swift filename reads,
        // per-item predicate calls or a second whole-library asset array.
        filtered = assets
      } else {
        filtered = []; filtered.reserveCapacity(assets.count)
        if request?.snapshot != nil { selectedIndices = []; selectedIndices?.reserveCapacity(assets.count) }
        for (index,asset) in assets.enumerated() {
          try Task.checkCancellation()
          if (nameMatcher.isEmpty || nameMatcher.matches(asset.filename)),
            mediaPredicate.matches(asset), searchPredicate?.matches(asset) ?? true {
            filtered.append(asset)
            selectedIndices?.append(index)
          }
        }
      }
    }
    QueryPerformanceTrace.record("engine.swift_predicates", since: predicateStarted, count: assets.count, synchronous: true)
    // The native engine still owns ordering, format families and map geometry.
    // Names were matched above, including glob syntax the engine does not parse.
    var nativeOptions = options
    nativeOptions.searchText = ""
    let indices: [Int]
    if legacyJSON {
      let records = QueryPerformanceTrace.measure("engine.make_records", count: filtered.count) { filtered.map(Record.init) }
      indices = try call(QueryRequest(assets: records, options: nativeOptions), profile: "query")
    } else {
      let input: RustQueryInput
      if let snapshot = request?.snapshot {
        input = QueryPerformanceTrace.measure("ffi.query.reuse_input",count: filtered.count) {
          filtered.count == assets.count ? snapshot.input
            : selectedIndices.map { snapshot.input.selecting($0) } ?? snapshot.input
        }
      } else {
        input = try QueryPerformanceTrace.measure("ffi.query.pack_records",count: filtered.count) { try RustQueryInput(filtered) }
      }
      indices = try queryRecords(filtered, options: nativeOptions,input: input)
      // A narrow first search keeps the old cheap path. Cache only input that
      // already covers the source, rather than packing hidden files up front.
      if request?.snapshot == nil, filtered.count == assets.count, let request {
        session?.remember(input,source: assets,request: request)
      }
    }
    var preservesOrder = indices.count == filtered.count
    for (position,index) in indices.enumerated() {
      guard filtered.indices.contains(index) else { throw RustImageEngineError(detail: "Invalid image index") }
      if index != position { preservesOrder = false }
    }
    return QueryPerformanceTrace.measure("engine.map_results", count: indices.count) {
      preservesOrder ? filtered : indices.map { filtered[$0] }
    }
  }

  private static func queryRecords(_ assets: [ImageAsset], options: LibraryQuery,input: RustQueryInput) throws -> [Int] {
    let optionsData = try QueryPerformanceTrace.measure("ffi.query.options_encode") { try JSONEncoder().encode(options) }
    let result = QueryPerformanceTrace.measure("ffi.query.rust_call", count: assets.count) {
      input.records.withUnsafeBufferPointer { records in
        input.strings.withUnsafeBytes { strings in
          optionsData.withUnsafeBytes { options in
            am_query_records(records.baseAddress, records.count,
              strings.bindMemory(to: UInt8.self).baseAddress, strings.count,
              options.bindMemory(to: UInt8.self).baseAddress, options.count)
          }
        }
      }
    }
    defer { am_query_indices_free(result) }
    try Task.checkCancellation()
    if let error = result.error.ptr {
      throw RustImageEngineError(detail: String(decoding: UnsafeBufferPointer(start: error,
        count: result.error.len), as: UTF8.self))
    }
    guard result.len >= 0, result.len <= assets.count,
      result.len == 0 || result.ptr != nil else { throw RustImageEngineError(detail: "Invalid query response") }
    return QueryPerformanceTrace.measure("ffi.query.copy_indices", count: result.len) {
      Array(UnsafeBufferPointer(start: result.ptr, count: result.len))
    }
  }

  static func match(first: [ImageAsset], second: [ImageAsset], sort: LibrarySort = .nameAscending) throws -> [ImageMatchPair] {
    try call(MatchRequest(first: first.map(Record.init), second: second.map(Record.init), sort: sort))
  }

  static func scan(folder: URL, includesVideos: Bool = false) throws -> [ImageAsset] {
    let records: [Record] = try call(ScanRequest(path: folder.path))
    return records.map { $0.asset() }.filter {
      MediaFormatRegistry.canAttemptToOpen($0.url, includesVideos: includesVideos)
    }
  }

  static func openArchive(_ url: URL) throws -> [ImageAsset] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AlmaengRe-ZIP-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let lease = ArchiveImageLease(directory: directory)
    let records: [Record] = try call(ZIPRequest(path: url.path, destination: directory.path,
      extensions: Array(ImageFormatRegistry.knownExtensions)))
    return records.compactMap { record in
      guard let entry = record.entryPath else { return nil }
      return record.asset(origin: ArchiveImageOrigin(archiveURL: url, entryPath: entry, lease: lease))
    }
  }

  static func decode(_ data: Data, format: UInt32) throws -> CGImage {
    let raster = data.withUnsafeBytes { bytes in am_decode(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, format) }
    defer { am_buffer_free(raster.pixels); am_buffer_free(raster.error) }
    guard let pointer = raster.pixels.ptr, raster.error.len == 0 else {
      let message = raster.error.ptr.map { String(decoding: UnsafeBufferPointer(start: $0, count: raster.error.len), as: UTF8.self) } ?? "Image decode failed"
      throw RustImageEngineError(detail: message)
    }
    let pixels = Data(bytes: pointer, count: raster.pixels.len)
    guard let provider = CGDataProvider(data: pixels as CFData),
      let space = CGColorSpace(name: raster.linear == 1 ? CGColorSpace.linearSRGB : CGColorSpace.sRGB),
      let image = CGImage(width: Int(raster.width), height: Int(raster.height), bitsPerComponent: 8,
        bitsPerPixel: 32, bytesPerRow: Int(raster.width) * 4, space: space,
        bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { throw BitmapDecoderError.imageCreationFailed }
    return image
  }

  private static func call<Request: Encodable, Response: Decodable>(_ request: Request,
    profile: String = "other") throws -> Response {
    let input = try QueryPerformanceTrace.measure("ffi.\(profile).json_encode") { try JSONEncoder().encode(request) }
    let buffer = QueryPerformanceTrace.measure("ffi.\(profile).rust_call", count: input.count) {
      input.withUnsafeBytes { bytes in am_engine_json(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
    }
    defer { am_buffer_free(buffer) }
    guard let pointer = buffer.ptr else { throw RustImageEngineError(detail: "Empty engine response") }
    let reply = try QueryPerformanceTrace.measure("ffi.\(profile).json_decode", count: buffer.len) {
      try JSONDecoder().decode(Reply<Response>.self, from: Data(bytes: pointer, count: buffer.len))
    }
    guard reply.ok, let data = reply.data else { throw RustImageEngineError(detail: reply.error ?? "Unknown engine error") }
    return data
  }
}
