import Darwin
import Foundation

/// A cheap lookup key for an observed file. The key is not a durable locator: saved
/// marks must resolve their bookmark and validate it again after every launch.
struct PhotoMarkFileIdentity: Sendable, Hashable {
  let key: String
  let fileNumber: UInt64
  let birthSeconds: Int64
  let birthNanoseconds: Int64
  let volumeUUID: String?

  static func read(_ url: URL, entryPath: String? = nil) -> Self? {
    guard url.isFileURL else { return nil }
    // Fresh URLs avoid stale URL resource caches after Finder renames or replacements.
    let freshURL = URL(fileURLWithPath: url.path).resolvingSymlinksInPath()
    var info = stat()
    let result = freshURL.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return fstatat(AT_FDCWD, path, &info, 0)
    }
    guard result == 0, info.st_mode & S_IFMT == S_IFREG, info.st_ino != 0,
      info.st_birthtimespec.tv_sec != 0 || info.st_birthtimespec.tv_nsec != 0 else { return nil }

    let values = try? freshURL.resourceValues(forKeys: [.volumeUUIDStringKey])
    let volumeUUID = values?.volumeUUIDString
    let volume = volumeUUID.map { "uuid=\($0)" } ?? "device=\(info.st_dev)"
    let seconds = Int64(info.st_birthtimespec.tv_sec)
    let nanoseconds = Int64(info.st_birthtimespec.tv_nsec)
    let identity = Self(key: "file:v2:\(volume):\(info.st_ino):\(seconds):\(nanoseconds)",
      fileNumber: UInt64(info.st_ino), birthSeconds: seconds,
      birthNanoseconds: nanoseconds, volumeUUID: volumeUUID)
    return entryPath.map { identity.forArchiveEntry($0) } ?? identity
  }

  /// Archive members share the container's identity, never their temporary extraction path.
  func forArchiveEntry(_ entryPath: String) -> Self {
    Self(key: "archive-\(key):entry:\(Data(entryPath.utf8).base64EncodedString())",
      fileNumber: fileNumber, birthSeconds: birthSeconds,
      birthNanoseconds: birthNanoseconds, volumeUUID: volumeUUID)
  }
}

/// Only marked files need a persistent bookmark. No image bytes or extended attributes
/// are changed. File number and birth time reject a different file reusing the saved path.
struct PhotoMarkFileReference: Codable, Sendable {
  let sourceURL: URL
  let entryPath: String?
  let bookmark: Data?
  /// Optional for compatibility with references saved before version 4.
  let fileNumber: UInt64?
  let birthSeconds: Int64
  let birthNanoseconds: Int64
  let volumeUUID: String?

  static func capture(for asset: ImageAsset) -> Self? {
    let sourceURL = asset.archiveOrigin?.archiveURL ?? asset.url
    let entryPath = asset.archiveOrigin?.entryPath
    guard let identity = PhotoMarkFileIdentity.read(sourceURL, entryPath: entryPath),
      asset.photoMarkIdentity == nil || asset.photoMarkIdentity == identity.key else { return nil }

    let bookmark = try? sourceURL.bookmarkData(options: [],
      includingResourceValuesForKeys: nil, relativeTo: nil)
    // Do not attach the old photo's marks if its file changed while capturing the bookmark.
    guard PhotoMarkFileIdentity.read(sourceURL, entryPath: entryPath)?.key == identity.key else { return nil }
    return Self(sourceURL: sourceURL, entryPath: entryPath, bookmark: bookmark,
      fileNumber: identity.fileNumber, birthSeconds: identity.birthSeconds, birthNanoseconds: identity.birthNanoseconds,
      volumeUUID: identity.volumeUUID)
  }

  func resolve() -> (id: String, reference: Self)? {
    let resolvedURL: URL
    var stale = false
    if let bookmark {
      guard let url = try? URL(resolvingBookmarkData: bookmark,
        options: [.withoutUI, .withoutMounting], relativeTo: nil,
        bookmarkDataIsStale: &stale) else { return nil }
      resolvedURL = url
    } else {
      resolvedURL = sourceURL
    }

    guard let identity = PhotoMarkFileIdentity.read(resolvedURL, entryPath: entryPath),
      identity.birthSeconds == birthSeconds, identity.birthNanoseconds == birthNanoseconds,
      fileNumber == nil || identity.fileNumber == fileNumber,
      volumeUUID == nil || identity.volumeUUID == volumeUUID else { return nil }

    let refreshedBookmark: Data?
    if stale || bookmark == nil {
      refreshedBookmark = (try? resolvedURL.bookmarkData(options: [],
        includingResourceValuesForKeys: nil, relativeTo: nil)) ?? bookmark
    } else {
      refreshedBookmark = bookmark
    }
    guard PhotoMarkFileIdentity.read(resolvedURL, entryPath: entryPath)?.key == identity.key else { return nil }
    return (identity.key, Self(sourceURL: resolvedURL, entryPath: entryPath,
      bookmark: refreshedBookmark, fileNumber: identity.fileNumber, birthSeconds: identity.birthSeconds,
      birthNanoseconds: identity.birthNanoseconds, volumeUUID: identity.volumeUUID))
  }
}
