import AppKit
import ImageIO
import UniformTypeIdentifiers

struct WallpaperDisplay: Identifiable, Sendable {
  let id: UInt32
  let name: String
  let pixelSize: CGSize
}

enum WallpaperScaling: String, CaseIterable, Identifiable {
  case fit, fill
  var id: Self { self }
  var title: String { L10n.text(self == .fit ? "사진 전체 맞춤" : "화면 채우기") }
}

struct WallpaperRequest: Identifiable {
  let id = UUID()
  let asset: ImageAsset
  let adjustments: ImageAdjustments
  let displays: [WallpaperDisplay]
  let currentDisplayID: UInt32
}

enum WallpaperError: LocalizedError {
  case displayUnavailable
  var errorDescription: String? { L10n.text("선택한 화면을 찾을 수 없습니다.") }
}

/// 실제 바탕화면 변경을 분리해 자동 테스트가 사용자 환경을 바꾸지 않게 합니다.
@MainActor
protocol DesktopWallpaperClient {
  var displays: [WallpaperDisplay] { get }
  func setImage(at url: URL, displayID: UInt32, scaling: WallpaperScaling) throws
}

@MainActor
struct WorkspaceWallpaperClient: DesktopWallpaperClient {
  static func displayID(_ screen: NSScreen) -> UInt32? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }

  var displays: [WallpaperDisplay] {
    NSScreen.screens.compactMap { screen in
      guard let id = Self.displayID(screen) else { return nil }
      return WallpaperDisplay(id: id, name: screen.localizedName,
        pixelSize: CGSize(width: screen.frame.width * screen.backingScaleFactor,
          height: screen.frame.height * screen.backingScaleFactor))
    }
  }

  func setImage(at url: URL, displayID: UInt32, scaling: WallpaperScaling) throws {
    // 준비 중 케이블이 빠진 화면은 다른 화면에 대신 적용하지 않고 실패를 알립니다.
    guard let screen = NSScreen.screens.first(where: { Self.displayID($0) == displayID }) else {
      throw WallpaperError.displayUnavailable
    }
    try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
      .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
      .allowClipping: scaling == .fill,
      .fillColor: NSColor.black,
    ])
  }
}

struct WallpaperResult {
  let imageURL: URL
  let appliedCount: Int
  let failures: [String]
}

/// AppKit 호출만 메인 스레드에서 처리합니다. 디코딩·PNG 기록은 별도 actor가 맡습니다.
@MainActor
final class WallpaperService {
  private let client: any DesktopWallpaperClient
  private let renderer: WallpaperRenderer
  var displays: [WallpaperDisplay] { client.displays }

  init(pipeline: ImagePipeline, directory: URL? = nil,
    client: any DesktopWallpaperClient = WorkspaceWallpaperClient()) {
    self.client = client
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let directory = directory ?? support
      .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.openimageviewer.ImageViewer")
      .appendingPathComponent("Wallpapers", isDirectory: true)
    renderer = WallpaperRenderer(pipeline: pipeline, directory: directory)
  }

  /// 화면보다 큰 원본은 제한해서 만들며 HDR·애니메이션은 SDR 첫 프레임으로 고정합니다.
  static func pixelLimit(for displays: [WallpaperDisplay]) -> Int {
    let longest = displays.map { max($0.pixelSize.width, $0.pixelSize.height) }.max() ?? 2048
    guard longest.isFinite else { return 2048 }
    return Int(min(8192, max(512, longest.rounded(.up))))
  }

  func apply(request: WallpaperRequest, displayIDs: Set<UInt32>,
    scaling: WallpaperScaling, appliesAdjustments: Bool) async throws -> WallpaperResult {
    let targets = request.displays.filter { displayIDs.contains($0.id) }
    guard !targets.isEmpty else { throw WallpaperError.displayUnavailable }
    let imageURL = try await renderer.prepare(asset: request.asset,
      adjustments: appliesAdjustments ? request.adjustments : .identity,
      maxPixelSize: Self.pixelLimit(for: targets))
    var applied = 0
    var failures: [String] = []
    for target in targets {
      do {
        try client.setImage(at: imageURL, displayID: target.id, scaling: scaling)
        applied += 1
      } catch {
        failures.append("\(target.name): \(error.localizedDescription)")
      }
    }
    // 다른 화면이나 Space가 참조할 수 있는 성공한 사본은 절대 자동 정리하지 않습니다.
    if applied == 0 { await renderer.discard(imageURL) }
    return WallpaperResult(imageURL: imageURL, appliedCount: applied, failures: failures)
  }
}

/// 원본·EXIF/GPS를 복사하지 않고 화면에 필요한 픽셀만 영구 지원 폴더에 저장합니다.
/// 임시 폴더나 원본 외장 드라이브가 사라져도 바탕화면 사본은 유지됩니다.
private actor WallpaperRenderer {
  let pipeline: ImagePipeline
  let directory: URL

  init(pipeline: ImagePipeline, directory: URL) {
    self.pipeline = pipeline
    self.directory = directory
  }

  func prepare(asset: ImageAsset, adjustments: ImageAdjustments, maxPixelSize: Int) async throws -> URL {
    let frame = try await pipeline.renderFrame(url: asset.url, frameIndex: 0,
      maxPixelSize: maxPixelSize, adjustments: adjustments, prefersHDR: false)
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
    do {
      guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw ImageExportError.destinationCreationFailed
      }
      CGImageDestinationAddImage(destination, frame.image,
        [kCGImagePropertyOrientation: 1] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { throw ImageExportError.finalizationFailed }
      try Task.checkCancellation()
      return url
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }

  func discard(_ url: URL) {
    // 호출자가 전달하는 임의의 원본 경로를 제거할 수 없게 전용 폴더·이름까지 확인합니다.
    guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
      UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
      url.pathExtension == "png" else { return }
    try? FileManager.default.removeItem(at: url)
  }
}
