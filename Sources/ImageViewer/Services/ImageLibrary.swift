import Foundation
import ImageIO

enum ImageLibraryError: LocalizedError {
  case noImages(URL)

  var errorDescription: String? {
    switch self {
    case .noImages(let url):
      L10n.format("‘%@’에서 읽을 수 있는 이미지를 찾지 못했습니다.", url.lastPathComponent)
    }
  }
}

/// 선택을 바꿔도 진행 중인 읽기와 열린 목록이 사용하는 접근 권한은 유지합니다.
final class ImageLibraryAccess: @unchecked Sendable {
  private let scopedURLs: [URL]

  init(_ urls: [URL]) {
    var seen: Set<URL> = []
    scopedURLs = urls.filter {
      seen.insert($0.standardizedFileURL).inserted && $0.startAccessingSecurityScopedResource()
    }
  }

  deinit {
    for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
  }
}

struct OpenedImageLibrary: Sendable {
  let assets: [ImageAsset]
  let folderURL: URL?
  let focusedURL: URL?
  let access: [ImageLibraryAccess]
}

/// 디렉터리 열거는 UI 스레드와 분리해 큰 폴더에서도 스크롤과 애니메이션을 보호합니다.
actor ImageLibrary {
  private let resourceKeys: Set<URLResourceKey> = [
    .isRegularFileKey,
    .isDirectoryKey,
    .isSymbolicLinkKey,
    .fileSizeKey,
    .contentModificationDateKey,
    .creationDateKey,
  ]

  /// URL의 경로 힌트 대신 실제 파일 정보를 확인합니다. 여러 폴더는 바로 아래
  /// 이미지만 모으고, 한 이미지를 열면 같은 폴더의 목록에서 그 이미지에 초점을 둡니다.
  func open(urls: [URL], allowsEmptyFolder: Bool = false,
    includesVideos: Bool = false) throws -> OpenedImageLibrary {
    try Task.checkCancellation()
    var access = [ImageLibraryAccess(urls)]
    var seenInputs: Set<URL> = []
    var inputs: [(url: URL, isDirectory: Bool)] = []
    for url in urls {
      try Task.checkCancellation()
      let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
      guard seenInputs.insert(resolvedURL).inserted else { continue }
      let values = try resolvedURL.resourceValues(forKeys: [.isDirectoryKey])
      inputs.append((url, values.isDirectory == true))
    }

    guard let first = inputs.first else {
      throw ImageLibraryError.noImages(URL(fileURLWithPath: "/"))
    }
    if inputs.count == 1 {
      if first.isDirectory {
        let images = try directoryAssets(first.url, includesVideos: includesVideos)
        guard allowsEmptyFolder || !images.isEmpty else { throw ImageLibraryError.noImages(first.url) }
        return OpenedImageLibrary(assets: images, folderURL: first.url,
          focusedURL: nil, access: access)
      }
      if first.url.pathExtension.lowercased() == "zip" {
        let images = try archiveAssets(first.url)
        guard !images.isEmpty else { throw ImageLibraryError.noImages(first.url) }
        return OpenedImageLibrary(assets: images, folderURL: nil, focusedURL: nil, access: access)
      }
      // Reject an unsupported selected file rather than opening unrelated neighboring photos.
      guard let selected = makeAsset(url: first.url, includesVideos: includesVideos) else {
        throw ImageLibraryError.noImages(first.url)
      }
      let parent = first.url.deletingLastPathComponent()
      access.append(ImageLibraryAccess([parent]))
      var images: [ImageAsset]
      do {
        images = try scan(folder: parent, includesVideos: includesVideos)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // A file grant may not allow reading its parent in a sandbox. The selected image
        // remains usable with its own grant, even when its neighbors cannot be listed.
        images = [selected]
      }
      if !images.contains(where: { $0.url.standardizedFileURL == selected.url.standardizedFileURL }) {
        images = try sorted(images + [selected])
      }
      return OpenedImageLibrary(assets: images, folderURL: parent,
        focusedURL: first.url, access: access)
    }

    var images: [ImageAsset] = []
    var locations: Set<URL> = []
    var seenAssets: Set<URL> = []
    for input in inputs {
      try Task.checkCancellation()
      let candidates: [ImageAsset]
      if input.isDirectory {
        candidates = try directoryAssets(input.url, includesVideos: includesVideos)
        locations.insert(input.url.standardizedFileURL)
      } else if input.url.pathExtension.lowercased() == "zip" {
        candidates = try archiveAssets(input.url)
        locations.insert(input.url.deletingLastPathComponent().standardizedFileURL)
      } else {
        guard let image = makeAsset(url: input.url, includesVideos: includesVideos) else {
          throw ImageLibraryError.noImages(input.url)
        }
        candidates = [image]
        locations.insert(input.url.deletingLastPathComponent().standardizedFileURL)
      }
      for image in candidates {
        try Task.checkCancellation()
        if seenAssets.insert(image.url.standardizedFileURL.resolvingSymlinksInPath()).inserted {
          images.append(image)
        }
      }
    }
    guard !images.isEmpty else { throw ImageLibraryError.noImages(first.url) }
    return OpenedImageLibrary(assets: try sorted(images),
      folderURL: locations.count == 1 ? locations.first : nil,
      focusedURL: first.isDirectory ? nil : first.url, access: access)
  }

  func scan(folder: URL, includesVideos: Bool = false) throws -> [ImageAsset] {
    let assets = try directoryAssets(folder, includesVideos: includesVideos)
    guard !assets.isEmpty else { throw ImageLibraryError.noImages(folder) }
    return assets
  }

  private func archiveAssets(_ url: URL) throws -> [ImageAsset] {
    try Task.checkCancellation()
    let assets = try RustImageEngine.openArchive(url)
    return try enrichPhotoMarkIdentities(assets)
  }

  private func enrichPhotoMarkIdentities(_ assets: [ImageAsset]) throws -> [ImageAsset] {
    var result = assets
    var archiveIdentities: [URL: PhotoMarkFileIdentity] = [:]
    var checkedArchives: Set<URL> = []
    for index in result.indices {
      try Task.checkCancellation()
      if let origin = result[index].archiveOrigin {
        let archiveURL = origin.archiveURL.standardizedFileURL
        if checkedArchives.insert(archiveURL).inserted {
          archiveIdentities[archiveURL] = PhotoMarkFileIdentity.read(archiveURL)
        }
        result[index].photoMarkIdentity = archiveIdentities[archiveURL]?
          .forArchiveEntry(origin.entryPath).key
      } else {
        result[index].photoMarkIdentity = PhotoMarkFileIdentity.read(result[index].url)?.key
      }
    }
    return result
  }

  private func directoryAssets(_ folder: URL, includesVideos: Bool) throws -> [ImageAsset] {
    try Task.checkCancellation()
    let assets = try RustImageEngine.scan(folder: folder, includesVideos: includesVideos)
    try Task.checkCancellation()
    return try enrichPhotoMarkIdentities(assets)
  }

  /// GPS is read lazily for map viewing, filtering and sorting, without pixel decoding.
  /// Negative lookups travel with the file-versioned asset to avoid rescanning on every draw.
  func enrichLocations(_ assets: [ImageAsset],
    progress: (@Sendable (Int) async -> Void)? = nil
  ) async throws -> [ImageAsset] {
    var result = assets
    for index in result.indices {
      try Task.checkCancellation()
      if index.isMultiple(of: 32) {
        await progress?(index)
        await Task.yield()
        try Task.checkCancellation()
      }
      if result[index].hasReadLocation || result[index].location != nil { continue }
      if result[index].isVideo {
        // Video GPS metadata is outside the supported map scope. Do not feed a
        // movie into ImageIO or retry a negative lookup on every filter change.
        result[index].hasReadLocation = true
        continue
      }
      result[index].location = autoreleasepool {
        guard let source = CGImageSourceCreateWithURL(result[index].url as CFURL,
          [kCGImageSourceShouldCache: false] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
          let latitude = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
          let longitude = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue,
          latitude.isFinite, longitude.isFinite, latitude >= 0, latitude <= 90,
          longitude >= 0, longitude <= 180 else { return nil }
        let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased()
        let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased()
        guard ["N", "S"].contains(latRef ?? ""), ["E", "W"].contains(lonRef ?? "") else { return nil }
        return ImageLocation(latitude: latRef == "S" ? -latitude : latitude,
          longitude: lonRef == "W" ? -longitude : longitude)
      }
      result[index].hasReadLocation = true
    }
    await progress?(result.count)
    return result
  }

  func assets(from urls: [URL], includesVideos: Bool = false) throws -> [ImageAsset] {
    try Task.checkCancellation()

    var candidates: [ImageAsset] = []
    for url in urls {
      try Task.checkCancellation()
      if let asset = makeAsset(url: url, includesVideos: includesVideos) { candidates.append(asset) }
    }
    let assets = try sorted(candidates)

    guard !assets.isEmpty else {
      throw ImageLibraryError.noImages(urls.first ?? URL(fileURLWithPath: "/"))
    }

    return assets
  }

  /// Header/track metadata is lazy. File identity and version are checked again even
  /// when the caller retained an enriched asset through a previous query.
  func enrichSortMetadata(_ assets: [ImageAsset], for sort: LibrarySort,
    governor: ImageResourceGovernor? = nil,
    cache: LibrarySortMetadataCache = .shared
  ) async throws -> [ImageAsset] {
    try await enrichQueryMetadata(assets, for: LibraryQuery(sort: sort), governor: governor, cache: cache)
  }

  /// Search reuses the same bounded, version-aware metadata cache as sorting.
  /// Filename, extension, file dates and size searches do not open source files.
  func enrichQueryMetadata(_ assets: [ImageAsset], for query: LibraryQuery,
    governor: ImageResourceGovernor? = nil,
    cache: LibrarySortMetadataCache = .shared
  ) async throws -> [ImageAsset] {
    try Task.checkCancellation()
    guard query.requiresMetadata else { return assets }
    var result = assets
    for index in result.indices {
      try Task.checkCancellation()
      if index.isMultiple(of: 32) { await Task.yield() }
      let version = LibrarySortFileVersion(url: result[index].url)
      if result[index].sortMetadata != nil, result[index].sortMetadataVersion == version { continue }
      let metadata = try await cache.metadata(for: version, isVideo: result[index].isVideo,
        governor: governor)
      try Task.checkCancellation()
      // A file replaced during inspection must not receive metadata from its old bytes.
      guard LibrarySortFileVersion(url: result[index].url) == version else {
        result[index].sortMetadata = nil
        result[index].sortMetadataVersion = nil
        continue
      }
      result[index].sortMetadata = metadata
      result[index].sortMetadataVersion = version
    }
    return result
  }

  private func sorted(_ assets: [ImageAsset]) throws -> [ImageAsset] {
    try RustImageEngine.query(assets, options: LibraryQuery())
  }

  private func makeAsset(url: URL, includesVideos: Bool) -> ImageAsset? {
    var values = try? url.resourceValues(forKeys: resourceKeys)
    let metadataURL: URL
    if values?.isSymbolicLink == true {
      metadataURL = url.resolvingSymlinksInPath()
      guard let targetValues = try? metadataURL.resourceValues(forKeys: resourceKeys) else { return nil }
      values = targetValues
    } else {
      metadataURL = url
    }
    let isAcceptedVideo = MediaFormatRegistry.isVideo(url) && includesVideos
    // A video-named input is never admitted through a misleading image UTI
    // when the user has disabled videos. Extensionless image symlinks retain
    // the existing ImageIO behavior without misclassifying video symlinks.
    guard isAcceptedVideo || (!MediaFormatRegistry.isVideo(url)
      && (ImageFormatRegistry.canAttemptToDecode(url)
        || ImageFormatRegistry.canAttemptToDecode(metadataURL))) else { return nil }
    guard values?.isRegularFile != false, values?.isDirectory != true else { return nil }

    return ImageAsset(
      // Metadata follows the link, but selection identity and the user's grant keep
      // the original URL (including /private path aliases and symlink filenames).
      url: url,
      byteCount: values?.fileSize.map(Int64.init),
      modificationDate: values?.contentModificationDate,
      creationDate: values?.creationDate,
      photoMarkIdentity: PhotoMarkFileIdentity.read(url)?.key
    )
  }
}
