import AppKit
import SwiftUI
import Testing

@testable import ImageViewer

/// App-wrapped localization runs render the production card menu and library
/// filter together. Only generated files and synthetic custom names are used.
@Suite("사진 분류 이름과 상단 분류 필터의 다국어 배치", .serialized)
@MainActor
struct PhotoMarkLabelLayoutTests {
  @Test("긴 분류 이름 1·2·3개가 좁은 카드 밖으로 넘치지 않고 필터와 구분된다",
    arguments: [80, 120, 180, 360], [false, true])
  func customNamesFitCardAndLibraryFilter(cardWidth: Int, isDark: Bool) async throws {
    _ = NSApplication.shared
    let language = L10n.languageIdentifier
    if let expected = ProcessInfo.processInfo.environment["EXPECTED_APP_LANGUAGE"] {
      try #require(language == expected, "Render the actual requested app language")
    }
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try await fixture.prepare(language: language)
    let store = fixture.store
    let assets = store.assets
    try #require(assets.count == 3)
    for index in assets.indices {
      #expect(store.photoMarks.marks(for: assets[index]).count == index + 1)
      #expect(store.canMarkPhoto(assets[index]))
    }
    #expect(store.photoMarkFilter.slots == [.one])

    let width: CGFloat = 660
    let outerGutter: CGFloat = 32
    let cardGutter: CGFloat = 24
    let cardHeight: CGFloat = 44
    let captionHeight: CGFloat = 16
    let captionSpacing: CGFloat = 4
    let rowSpacing: CGFloat = 16
    let cardsInset: CGFloat = 16
    let rowHeight = captionHeight + captionSpacing + cardHeight
    let direction: LayoutDirection = language == "ar" ? .rightToLeft : .leftToRight
    let controls = LibraryControlsView(store: store)
      .padding(.horizontal, 16).padding(.vertical, 12)
      .frame(width: width)
      .environment(\.locale, Locale(identifier: language))
      .environment(\.layoutDirection, direction)
      .environment(\.colorScheme, isDark ? .dark : .light)
    let controlsHost = NSHostingView(rootView: controls)
    let controlsHeight = controlsHost.fittingSize.height
    #expect(controlsHeight > 25 && controlsHeight <= 150,
      "Translated collection controls should reorganize within the narrow window")

    let root = VStack(spacing: 0) {
      controls
      VStack(spacing: rowSpacing) {
        ForEach(assets.indices, id: \.self) { index in
          VStack(spacing: captionSpacing) {
            Text(verbatim: "\(index + 1) · \(cardWidth) pt")
              .font(.system(size: 11, weight: .medium).monospacedDigit())
              .frame(height: captionHeight)
            PhotoMarkCardMenu(store: store, asset: assets[index])
              .font(.system(size: 12, weight: .medium))
              .frame(width: CGFloat(cardWidth), height: cardHeight)
              .background(ViewerTheme.chrome)
              // Intentionally do not clip the menu: a fixed intrinsic label
              // must paint into the magenta gutter and fail this test.
              .padding(.horizontal, cardGutter)
              .background(Color(.sRGB, red: 1, green: 0, blue: 1, opacity: 1))
          }
        }
      }
      .padding(.vertical, cardsInset)
    }
    .frame(width: width)
    .background(ViewerTheme.panel)
    .padding(outerGutter)
    .background(Color(.sRGB, red: 1, green: 0, blue: 1, opacity: 1))
    .environment(\.locale, Locale(identifier: language))
    .environment(\.layoutDirection, direction)
    .environment(\.colorScheme, isDark ? .dark : .light)

    let host = NSHostingView(rootView: root)
    host.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    let size = host.fittingSize
    let expectedHeight = controlsHeight + 2 * cardsInset + 3 * rowHeight + 2 * rowSpacing + 2 * outerGutter
    #expect(abs(size.width - width - 2 * outerGutter) < 1)
    #expect(abs(size.height - expectedHeight) < 1)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000,
      width: size.width, height: size.height), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = host.appearance
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    try await Task.sleep(for: .milliseconds(180))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    let captured = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: captured)
    // Convert the full ICC-tagged capture before reading raw colorAt values.
    let bitmap = try #require(captured.converting(to: .sRGB, renderingIntent: .relativeColorimetric))
    let scale = CGFloat(bitmap.pixelsWide) / size.width
    let margin = try pixel(bitmap, at: CGPoint(x: 2, y: 2), scale: scale)
    var outerOverflow = 0
    for y in stride(from: CGFloat(10), to: size.height - 10, by: 3) {
      for x in [CGFloat(10), outerGutter - 9, size.width - outerGutter + 9, size.width - 10] {
        if colorDistance(try pixel(bitmap, at: CGPoint(x: x, y: y), scale: scale), margin) > 0.04 {
          outerOverflow += 1
        }
      }
    }
    #expect(outerOverflow == 0, "Library controls must stay within 660 pt: \(language), dark=\(isDark)")

    let centerX = size.width / 2
    let halfCardWidth = CGFloat(cardWidth) / 2
    let cardTops = assets.indices.map { index in
      outerGutter + controlsHeight + cardsInset
        + CGFloat(index) * (rowHeight + rowSpacing) + captionHeight + captionSpacing
    }
    for index in assets.indices {
      let top = cardTops[index]
      var cardOverflow = 0
      for y in stride(from: top + 4, to: top + cardHeight - 4, by: 2) {
        for distance in [CGFloat(7), 15, 21] {
          for x in [centerX - halfCardWidth - distance, centerX + halfCardWidth + distance] {
            if colorDistance(try pixel(bitmap, at: CGPoint(x: x, y: y), scale: scale), margin) > 0.04 {
              cardOverflow += 1
            }
          }
        }
      }
      #expect(cardOverflow == 0,
        "\(index + 1) custom names must fit a \(cardWidth) pt card, language=\(language), dark=\(isDark)")
    }

    // SwiftUI's native Menu bridge can silently flatten a multi-Text label to
    // only its first name. Geometry and accessibility values still pass in
    // that case. Compare the actual visible controls: a second name, then the
    // additional-marks ellipsis, must each change the rendered label. Captions
    // and gutters are outside these samples, so they cannot mask the bug.
    var changedSampleCounts: [Int] = []
    for firstIndex in 0..<2 {
      var changedSamples = 0
      for x in stride(from: centerX - halfCardWidth + 4, to: centerX + halfCardWidth - 4, by: 2) {
        for offsetY in stride(from: CGFloat(4), to: cardHeight - 4, by: 2) {
          let first = try pixel(bitmap,
            at: CGPoint(x: x, y: cardTops[firstIndex] + offsetY), scale: scale)
          let second = try pixel(bitmap,
            at: CGPoint(x: x, y: cardTops[firstIndex + 1] + offsetY), scale: scale)
          if colorDistance(first, second) > 0.04 { changedSamples += 1 }
        }
      }
      changedSampleCounts.append(changedSamples)
      #expect(changedSamples >= 12,
        "Adding \(firstIndex == 0 ? "the second name" : "the additional-marks ellipsis") must visibly change the card label, language=\(language), width=\(cardWidth)")
    }
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(data.count > 4_000, "Capture the actual translated filter and custom card names")
    if let output = ProcessInfo.processInfo.environment["IMAGEVIEWER_LOCALIZED_CONTROLS_OUTPUT"] {
      let directory = URL(fileURLWithPath: output, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: directory.appendingPathComponent(
        "photo-mark-labels-\(language)-\(cardWidth)-\(isDark ? "dark" : "light").png"))
    }
    print("PHOTO_MARK_LABELS language=\(language) cardWidth=\(cardWidth) dark=\(isDark) outerOverflow=\(outerOverflow) controlsHeight=\(controlsHeight) labelDifferences=\(changedSampleCounts)")
  }

  private func pixel(_ bitmap: NSBitmapImageRep, at point: CGPoint, scale: CGFloat) throws -> NSColor {
    try #require(bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale)))
  }

  private func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
    max(abs(lhs.redComponent - rhs.redComponent),
      abs(lhs.greenComponent - rhs.greenComponent), abs(lhs.blueComponent - rhs.blueComponent))
  }

  @MainActor private struct Fixture {
    let suite = "PhotoMarkLabelLayoutTests.\(UUID())"
    let defaults: UserDefaults
    let root: URL
    let media: URL
    let store: AppStore

    init() throws {
      defaults = try #require(UserDefaults(suiteName: suite))
      root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
      media = root.appendingPathComponent("Synthetic", isDirectory: true)
      try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
      let qoi = Data([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0,
        0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
      for index in 1...3 {
        try qoi.write(to: media.appendingPathComponent("synthetic-\(index).qoi"))
      }
      store = AppStore(defaults: defaults, monitorsSystemResources: false,
        photoMarkDatabaseURL: root.appendingPathComponent("marks.sqlite"))
    }

    func prepare(language: String) async throws {
      await store.photoMarks.waitUntilReady()
      try #require(store.photoMarks.isReady)
      store.open(urls: [media])
      try await waitUntilReady()
      try #require(store.assets.count == 3 && store.alert == nil)
      let names = Self.customNames[language] ?? Self.customNames["ko"]!
      let slots: [PhotoMarkSlot] = [.one, .q, .w]
      store.photoMarks.setDefinitions(labels: Dictionary(uniqueKeysWithValues: zip(slots, names)),
        colors: [.one: .green, .q: .orange, .w: .blue])
      for (index, asset) in store.assets.enumerated() {
        for slot in slots.prefix(index + 1) { store.photoMarks.set(slot, enabled: true, for: [asset]) }
      }
      try #require(await store.photoMarks.flushAsync())
      store.photoMarkFilter = PhotoMarkFilter(slots: [.one])
      try await waitUntilReady()
      store.setImagesPerPage(3)
      store.isPhotoMarking = true
    }

    private func waitUntilReady() async throws {
      let deadline = ContinuousClock.now + .seconds(8)
      while store.isLoading || store.isFiltering {
        try #require(ContinuousClock.now < deadline, "Synthetic classification fixture did not load")
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    func cleanup() {
      store.folderComparison.cancelLoads()
      store.photoMarks.flush()
      store.saveSessionNow()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }

    // Synthetic user-defined labels deliberately exceed the compact card's
    // available width. They are data, not new app UI translation resources.
    private static let customNames: [String: [String]] = [
      "ko": ["가족 여행 사진 중 최종 인화 후보", "색상과 수평을 다시 확인할 사진", "친구들에게 공유하기 전 확인"],
      "en": ["Final family holiday print candidates", "Review colors and horizon alignment", "Check before sharing with friends"],
      "ja": ["家族旅行の写真から選んだ最終印刷候補", "色と水平線をもう一度確認する写真", "友人に共有する前に確認する写真"],
      "zh-Hans": ["家庭旅行照片中的最终打印候选", "需要再次检查颜色和水平线的照片", "分享给朋友之前需要确认的照片"],
      "vi": ["Ảnh du lịch gia đình được chọn để in", "Kiểm tra lại màu sắc và đường chân trời", "Xem lại trước khi chia sẻ với bạn bè"],
      "es": ["Selección final de fotos familiares para imprimir", "Revisar los colores y la línea del horizonte", "Comprobar antes de compartir con amigos"],
      "fr": ["Sélection finale des photos de famille à imprimer", "Vérifier les couleurs et la ligne d’horizon", "Vérifier avant le partage avec les amis"],
      "de": ["Endgültige Druckauswahl der Familienreisefotos", "Farben und Ausrichtung des Horizonts prüfen", "Vor dem Teilen mit Freunden überprüfen"],
      "ru": ["Окончательный выбор семейных фотографий для печати", "Проверить цвета и выравнивание горизонта", "Проверить перед отправкой друзьям"],
      "ar": ["الاختيار النهائي لصور رحلة العائلة للطباعة", "مراجعة الألوان واستقامة خط الأفق", "التحقق قبل المشاركة مع الأصدقاء"],
    ]
  }
}
