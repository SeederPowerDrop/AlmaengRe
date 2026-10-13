import AppKit
import Testing
import UniformTypeIdentifiers

@testable import ImageViewer

@Suite("기본 이미지 앱 연결", .serialized)
@MainActor
struct DefaultAppAssociationTests {
  private let defaultsSuite = "ImageViewer.DefaultAppAssociationTests"
  private let applicationURL = URL(fileURLWithPath: "/Applications/알맹Re.app")
  private var formats: [DefaultImageFormat] {
    [
      .init(id: "jpeg", titleKey: "JPEG 이미지", filenameExtensions: ["jpg", "jpeg"],
        typeIdentifiers: [UTType.jpeg.identifier]),
      .init(id: "png", titleKey: "PNG / APNG 이미지", filenameExtensions: ["png"],
        typeIdentifiers: [UTType.png.identifier]),
    ]
  }

  @Test("선택한 이미지 형식만 연결하고 실제 기본 앱을 다시 확인한다")
  func appliesOnlySelection() async throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }
    var handlers: [String: URL] = [:]
    var requested: [String] = []
    let store = DefaultAppAssociationStore(defaults: defaults, applicationURL: applicationURL,
      formats: formats, defaultApplication: { handlers[$0.identifier] },
      setDefaultApplication: { url, type in
        requested.append(type.identifier)
        handlers[type.identifier] = url
      })
    store.setSelected(true, format: formats[0])
    try await store.applySelected()
    #expect(requested == [UTType.jpeg.identifier])
    #expect(store.coverage(for: formats[0]) == .all)
    #expect(store.coverage(for: formats[1]) == .none)
    #expect(store.statusMessage != nil && !store.isApplying)
  }

  @Test("API가 성공해도 다른 앱이 기본값이면 성공으로 표시하지 않는다")
  func verifiesAppliedHandler() async throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }
    var handlers = [UTType.png.identifier: URL(fileURLWithPath: "/System/Applications/Preview.app")]
    let store = DefaultAppAssociationStore(defaults: defaults, applicationURL: applicationURL,
      formats: formats, defaultApplication: { handlers[$0.identifier] },
      setDefaultApplication: { url, type in
        if type == .jpeg { handlers[type.identifier] = url }
      })
    store.selectAll()
    do {
      try await store.applySelected()
      Issue.record("Verification must reject the unchanged PNG handler")
    } catch DefaultAppAssociationError.someTypesFailed(let success, let failure, let failedFormats) {
      #expect(success == 1 && failure == 1)
      #expect(failedFormats == [formats[1].title])
    }
    #expect(store.statusMessage == nil && !store.isApplying)
    #expect(store.coverage(for: formats[0]) == .all)
    #expect(store.coverage(for: formats[1]) == .none)
  }

  @Test("같은 번들 ID를 가진 이전 빌드도 다른 경로이면 현재 앱으로 오판하지 않는다")
  func distinguishesOtherAppCopies() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let current = root.appendingPathComponent("Installed.app")
    let backup = root.appendingPathComponent("Backup.app")
    for url in [current, backup] {
      let contents = url.appendingPathComponent("Contents")
      try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
      let data = try PropertyListSerialization.data(fromPropertyList: [
        "CFBundleIdentifier": "org.openimageviewer.ImageViewer", "CFBundlePackageType": "APPL"
      ], format: .xml, options: 0)
      try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
    #expect(Bundle(url: current)?.bundleIdentifier == Bundle(url: backup)?.bundleIdentifier)
    var handler = backup
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }
    let store = DefaultAppAssociationStore(defaults: defaults, applicationURL: current,
      formats: formats, defaultApplication: { _ in handler }, setDefaultApplication: { _, _ in })
    #expect(store.defaultTypeIdentifiers.isEmpty)
    handler = current
    store.refresh()
    #expect(store.coverage(for: formats[0]) == .all)
  }

  @Test("일부 연결 실패 뒤에도 나머지 형식을 처리하고 적용 상태를 해제한다")
  func continuesAfterFailure() async throws {
    var requested: [String] = []
    var handlers: [String: URL] = [:]
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }
    let store = DefaultAppAssociationStore(defaults: defaults, applicationURL: applicationURL,
      formats: formats, defaultApplication: { handlers[$0.identifier] },
      setDefaultApplication: { url, type in
        requested.append(type.identifier)
        if type == .jpeg { throw CocoaError(.fileWriteNoPermission) }
        handlers[type.identifier] = url
      })
    store.selectAll()
    do {
      try await store.applySelected()
      Issue.record("Expected the failed JPEG request")
    } catch DefaultAppAssociationError.someTypesFailed(let success, let failure, _) {
      #expect(success == 1 && failure == 1)
    }
    #expect(requested == [UTType.jpeg.identifier, UTType.png.identifier])
    #expect(store.coverage(for: formats[1]) == .all && !store.isApplying)
  }

  @Test("연결 목록은 RAW 별칭과 이 Mac의 이미지 디코더 확장자를 포함한다")
  func includesNativeImageAliases() {
    let all = DefaultImageFormat.all
    let extensions = Set(all.flatMap(\.filenameExtensions))
    #expect(ImageFormatRegistry.cameraRAWExtensions.isSubset(of: extensions))
    #expect(ImageFormatRegistry.nativeFilenameExtensions.isSubset(of: extensions))
    #expect(Set(["jif", "jfi", "jpc", "j2c", "qoi", "pcx"]).isSubset(of: extensions))
    let identifiers = all.flatMap(\.typeIdentifiers)
    #expect(identifiers.count == Set(identifiers).count)
    #expect(!identifiers.contains(UTType.image.identifier))
    #expect(!identifiers.contains(UTType.movie.identifier))
    #expect(!identifiers.contains(UTType.folder.identifier))
    for ext in extensions {
      if let type = UTType(filenameExtension: ext), type.isDynamic || type.conforms(to: .image) {
        #expect(identifiers.contains(type.identifier), "Uncovered alias: \(ext)")
      }
    }
  }

  private func makeDefaults() throws -> UserDefaults {
    let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
    defaults.removePersistentDomain(forName: defaultsSuite)
    return defaults
  }
}
