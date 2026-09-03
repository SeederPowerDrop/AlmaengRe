import Foundation

enum ImageLibraryError: LocalizedError {
  case noImages(URL)

  var errorDescription: String? {
    switch self {
    case .noImages(let url):
      "‘\(url.lastPathComponent)’에서 읽을 수 있는 이미지를 찾지 못했습니다."
    }
  }
}

/// 디렉터리 열거는 UI 스레드와 분리해 큰 폴더에서도 스크롤과 애니메이션을 보호합니다.
actor ImageLibrary {
  private let resourceKeys: Set<URLResourceKey> = [
    .isRegularFileKey,
    .isDirectoryKey,
    .fileSizeKey,
    .contentModificationDateKey,
    .contentTypeKey,
  ]

  func scan(folder: URL) throws -> [ImageAsset] {
    try Task.checkCancellation()

    let urls = try FileManager.default.contentsOfDirectory(
      at: folder,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    )

    let assets = urls.compactMap(makeAsset)
      .sorted { lhs, rhs in
        lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
      }

    guard !assets.isEmpty else { throw ImageLibraryError.noImages(folder) }
    return assets
  }

  func assets(from urls: [URL]) throws -> [ImageAsset] {
    try Task.checkCancellation()

    let assets = urls.compactMap(makeAsset)
      .sorted { lhs, rhs in
        lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
      }

    guard !assets.isEmpty else {
      throw ImageLibraryError.noImages(urls.first ?? URL(fileURLWithPath: "/"))
    }

    return assets
  }

  private func makeAsset(url: URL) -> ImageAsset? {
    guard ImageFormatRegistry.canAttemptToDecode(url) else { return nil }

    let values = try? url.resourceValues(forKeys: resourceKeys)
    guard values?.isRegularFile != false, values?.isDirectory != true else { return nil }

    return ImageAsset(
      url: url,
      byteCount: values?.fileSize.map(Int64.init),
      modificationDate: values?.contentModificationDate
    )
  }
}
