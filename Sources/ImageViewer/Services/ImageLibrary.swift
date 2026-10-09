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
  func open(urls: [URL], allowsEmptyFolder: Bool = false) throws -> OpenedImageLibrary {
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
        let images = try directoryAssets(first.url)
        guard allowsEmptyFolder || !images.isEmpty else { throw ImageLibraryError.noImages(first.url) }
        return OpenedImageLibrary(assets: images, folderURL: first.url,
          focusedURL: nil, access: access)
      }
      if first.url.pathExtension.lowercased() == "zip" {
        let images = try RustImageEngine.openArchive(first.url)
        guard !images.isEmpty else { throw ImageLibraryError.noImages(first.url) }
        return OpenedImageLibrary(assets: images, folderURL: nil, focusedURL: nil, access: access)
      }
      // Reject an unsupported selected file rather than opening unrelated neighboring photos.
      guard let selected = makeAsset(url: first.url) else { throw ImageLibraryError.noImages(first.url) }
      let parent = first.url.deletingLastPathComponent()
      access.append(ImageLibraryAccess([parent]))
      var images: [ImageAsset]
      do {
        images = try scan(folder: parent)
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
        candidates = try directoryAssets(input.url)
        locations.insert(input.url.standardizedFileURL)
      } else if input.url.pathExtension.lowercased() == "zip" {
        candidates = try RustImageEngine.openArchive(input.url)
        locations.insert(input.url.deletingLastPathComponent().standardizedFileURL)
      } else {
        guard let image = makeAsset(url: input.url) else { throw ImageLibraryError.noImages(input.url) }
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

  func scan(folder: URL) throws -> [ImageAsset] {
    let assets = try directoryAssets(folder)
    guard !assets.isEmpty else { throw ImageLibraryError.noImages(folder) }
    return assets
  }

  private func directoryAssets(_ folder: URL) throws -> [ImageAsset] {
    try Task.checkCancellation()
    let assets = try RustImageEngine.scan(folder: folder)
    try Task.checkCancellation()
    return assets
  }

  /// GPS is read lazily only for location sorting. ImageIO handles EXIF variants and no
  /// pixel decode occurs. Keep the scan actor off the UI thread and check between files.
  func enrichLocations(_ assets: [ImageAsset]) async throws -> [ImageAsset] {
    var result = assets
    for index in result.indices {
      try Task.checkCancellation()
      if result[index].location != nil { continue }
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
    }
    return result
  }

  func assets(from urls: [URL]) throws -> [ImageAsset] {
    try Task.checkCancellation()

    let assets = try sorted(urls.compactMap(makeAsset))

    guard !assets.isEmpty else {
      throw ImageLibraryError.noImages(urls.first ?? URL(fileURLWithPath: "/"))
    }

    return assets
  }

  private func sorted(_ assets: [ImageAsset]) throws -> [ImageAsset] {
    try RustImageEngine.query(assets, options: LibraryQuery())
  }

  private func makeAsset(url: URL) -> ImageAsset? {
    var values = try? url.resourceValues(forKeys: resourceKeys)
    let metadataURL: URL
    if values?.isSymbolicLink == true {
      metadataURL = url.resolvingSymlinksInPath()
      guard let targetValues = try? metadataURL.resourceValues(forKeys: resourceKeys) else { return nil }
      values = targetValues
    } else {
      metadataURL = url
    }
    guard ImageFormatRegistry.canAttemptToDecode(url)
      || ImageFormatRegistry.canAttemptToDecode(metadataURL) else { return nil }
    guard values?.isRegularFile != false, values?.isDirectory != true else { return nil }

    return ImageAsset(
      // Metadata follows the link, but selection identity and the user's grant keep
      // the original URL (including /private path aliases and symlink filenames).
      url: url,
      byteCount: values?.fileSize.map(Int64.init),
      modificationDate: values?.contentModificationDate,
      creationDate: values?.creationDate
    )
  }
}
