import AppKit
import SwiftUI
import Testing

@testable import ImageViewer

/// Exercises the real home view with synthetic, persisted previews only. The
/// optional PNG output is a development artifact, never a user-guide capture.
@Suite("최근 폴더 홈 화면 배치", .serialized)
@MainActor
struct HomeLayoutTests {
  @Test("긴 이름과 합성 미리보기를 밝은·어두운 실제 홈 화면으로 렌더한다", arguments: [false, true])
  func recentFoldersRenderAtMinimumWindow(isDark: Bool) async throws {
    _ = NSApplication.shared
    let suite = "HomeLayoutTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("HomeLayout-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: temporary)
    }
    let folders = try syntheticFolders()
    defaults.set(try JSONEncoder().encode(folders), forKey: RecentPhotoStore.defaultsKey)
    let store = AppStore(defaults: defaults, monitorsSystemResources: false,
      photoMarkDatabaseURL: temporary.appendingPathComponent("marks.sqlite"))
    defer { store.clearRecentPhotos() }
    try #require(store.recentPhotos.folders.count == 3)
    try #require(store.recentPhotos.folders.prefix(2).allSatisfy { $0.photos.count == 5 })
    try #require(store.recentPhotos.folders.last?.photos.isEmpty == true)
    try #require(store.recentPhotos.homeFolders.count == 3)
    try #require(store.recentPhotos.homeFolders.prefix(2).allSatisfy { $0.photos.count == 4 })

    let size = CGSize(width: 960, height: 800)
    let root = HomeView(store: store)
      .environment(\.colorScheme, isDark ? .dark : .light)
      .frame(width: size.width, height: size.height)
    let host = NSHostingView(rootView: root)
    host.frame = NSRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    let window = NSWindow(contentRect: NSRect(x: -3_000, y: -3_000,
      width: size.width, height: size.height), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = host.appearance
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }

    // SwiftUI does not publish accessibility children for an offscreen hosting
    // window. Inspect the actual rendered synthetic previews instead of waiting
    // for AX nodes that need a visible app window or an accessibility client.
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try export(bitmap, isDark: isDark)

    #expect(bitmap.pixelsWide >= Int(size.width) && bitmap.pixelsHigh >= Int(size.height))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(png.count > 10_000, "The home render must contain its real content and synthetic previews")
    let background = try #require(bitmap.colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB))
    #expect(background.alphaComponent > 0.99)
    let brightness = (background.redComponent + background.greenComponent + background.blueComponent) / 3
    #expect(isDark ? brightness < 0.4 : brightness > 0.85,
      "The home surface must follow the requested appearance")
    #expect(store.assets.isEmpty && store.currentFolderURL == nil && store.showsHome,
      "Rendering persisted previews must not load synthetic source folders")
    print("HOME_LAYOUT scheme=\(isDark ? "dark" : "light") viewport=960x800 pngBytes=\(png.count)")
  }

  private func syntheticFolders() throws -> [RecentFolder] {
    let date = Date(timeIntervalSince1970: 1_791_633_600)
    let names = [
      "사진 모음 — 아주 긴 이름의 폴더에서도 네 장이 편안하게 보이는지 확인합니다",
      "작은 앨범",
    ]
    let filenames = ["a.jpg", "가을빛.jpg", "산과 바다 — 합성 이미지.jpg",
      "a-very-long-synthetic-photo-filename-that-must-truncate-without-widening-the-card.jpg",
      "05.jpg"]
    var folders: [RecentFolder] = []
    for (folderIndex, name) in names.enumerated() {
      let url = URL(fileURLWithPath: "/synthetic/Home Layout/\(name)", isDirectory: true)
      let photos = try filenames.enumerated().map { index, filename in
        let asset = ImageAsset(url: url.appendingPathComponent(filename),
          byteCount: 1_024, modificationDate: date)
        return RecentPhoto(asset: asset, lastViewed: date.addingTimeInterval(Double(-index)),
          thumbnailData: try preview(index: index + folderIndex * 5))
      }
      folders.append(RecentFolder(location: SessionLocation(url: url),
        lastOpened: date.addingTimeInterval(Double(-folderIndex)), isArchive: false, photos: photos))
    }
    folders.append(RecentFolder(location: SessionLocation(
      url: URL(fileURLWithPath: "/synthetic/Home Layout/아직 본 사진이 없는 폴더", isDirectory: true)),
      lastOpened: date.addingTimeInterval(-2), isArchive: false))
    return folders
  }

  private func preview(index: Int) throws -> Data {
    let width = index % 3 == 0 ? 200 : 300
    let height = index % 3 == 0 ? 300 : 200
    let context = try #require(CGContext(data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let hue = CGFloat(index) / 10
    let background = NSColor(calibratedHue: hue, saturation: 0.35, brightness: 0.9, alpha: 1)
    let foreground = NSColor(calibratedHue: hue + 0.08, saturation: 0.6, brightness: 0.58, alpha: 1)
    context.setFillColor(background.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(foreground.cgColor)
    context.move(to: CGPoint(x: 0, y: 0))
    context.addLine(to: CGPoint(x: CGFloat(width) * 0.42, y: CGFloat(height) * 0.72))
    context.addLine(to: CGPoint(x: width, y: 0))
    context.closePath()
    context.fillPath()
    context.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.85).cgColor)
    context.fillEllipse(in: CGRect(x: CGFloat(width) * 0.68, y: CGFloat(height) * 0.68,
      width: 38, height: 38))
    let image = try #require(context.makeImage())
    return try #require(NSBitmapImageRep(cgImage: image).representation(using: .jpeg,
      properties: [.compressionFactor: 0.8]))
  }

  private func export(_ bitmap: NSBitmapImageRep, isDark: Bool) throws {
    guard let path = ProcessInfo.processInfo.environment["IMAGEVIEWER_HOME_LAYOUT_OUTPUT"],
      !path.isEmpty else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: directory.appendingPathComponent(isDark ? "home-dark.png" : "home-light.png"))
  }

}
