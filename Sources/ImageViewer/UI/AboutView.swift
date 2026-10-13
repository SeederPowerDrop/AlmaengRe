import AppKit
import SwiftUI

/// 앱 언어를 따르는 소개와 후원을 제공하는, 초기 Windows 스타일의 정보 창입니다.
struct AboutView: View {
  static let windowID = "about-almaeng-re"

  @Environment(\.dismiss) private var dismiss
  @Environment(\.openWindow) private var openWindow
  @State private var showsBitcoin = false
  @State private var supportStatus: String?
  @State private var showsLicenses = false
  @State private var selectedLicense = "app"

  private static let profile: NSImage? = resource("AboutProfile", extension: "jpg").flatMap(NSImage.init(contentsOf:))

  private static let bitcoinQR = AboutSupport.makeBitcoinQRCode()

  private var layoutDirection: LayoutDirection {
    AboutContent.languageIdentifier == "ar" ? .rightToLeft : .leftToRight
  }

  private func text(_ key: String) -> String {
    AboutContent.text(key)
  }

  private static func resource(_ name: String, extension ext: String, subdirectory: String? = nil) -> URL? {
    if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
      return url
    }
    // SwiftPM resources are flattened; packaged apps keep the source directories.
    return Bundle.module.url(forResource: name, withExtension: ext)
  }

  var body: some View {
    VStack(spacing: 0) {
      titleBar
      if showsLicenses {
        licenseContent
      } else {
        introduction
      }
      footer
    }
    .foregroundStyle(RetroAboutTheme.text)
    .background(RetroAboutTheme.paper)
    .overlay { Rectangle().strokeBorder(Color(red: 0.10, green: 0.28, blue: 0.65), lineWidth: 1) }
    .background(AboutWindowChrome(title: showsLicenses ? text("licenses") : text("windowTitle")))
    .environment(\.layoutDirection, layoutDirection)
    .frame(minWidth: 720, idealWidth: 820, maxWidth: .infinity,
      minHeight: 540, idealHeight: 800, maxHeight: .infinity)
    .ignoresSafeArea()
  }

  private var titleBar: some View {
    HStack(spacing: 12) {
      Text(verbatim: showsLicenses ? text("licenses") : text("windowTitle"))
        .font(.system(size: 17, weight: .bold))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 0, x: 1, y: 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 13)
        .background(AboutTitlebarDragArea())
      Button { dismiss() } label: {
        Image(systemName: "xmark")
          .font(.system(size: 16, weight: .bold))
          .foregroundStyle(.white)
          .shadow(color: .black.opacity(0.3), radius: 0, x: 1, y: 1)
          .frame(width: 29, height: 29)
          .background(LinearGradient(colors: [Color(red: 1, green: 0.55, blue: 0.43),
            Color(red: 0.82, green: 0.12, blue: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing))
          .clipShape(RoundedRectangle(cornerRadius: 4))
          .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.95), lineWidth: 1.5) }
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.cancelAction)
      .accessibilityLabel(text("close"))
      .help(text("close"))
      .padding(.trailing, 7)
    }
    .frame(height: 42)
    .background {
      LinearGradient(colors: [RetroAboutTheme.titleStart, RetroAboutTheme.titleEnd],
        startPoint: .leading, endPoint: .trailing)
        .overlay(alignment: .top) { Color.white.opacity(0.3).frame(height: 1) }
        .overlay(alignment: .bottom) { Color(red: 0.02, green: 0.20, blue: 0.68).frame(height: 1) }
    }
  }

  private var introduction: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 24) {
          Group {
            if let profile = Self.profile {
              Image(nsImage: profile).resizable().scaledToFit()
            }
          }
          .frame(width: 144, height: 144)
          .padding(4)
          .background(.white)
          .overlay { RetroBevel(inset: true) }
          .accessibilityLabel(text("profile"))

          VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
              Text(verbatim: appHeading)
                .font(.system(size: 22, weight: .bold))
              Text(verbatim: text("subtitle"))
                .foregroundStyle(RetroAboutTheme.secondaryText)
            }
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 16) { introductionLinks }
                .foregroundStyle(RetroAboutTheme.link)
              VStack(alignment: .leading, spacing: 8) { introductionLinks }
                .foregroundStyle(RetroAboutTheme.link)
            }
            paragraph("opening")
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        paragraph("story")
        paragraph("philosophy")
        paragraph("thanks")
        paragraph("closing")
        supportSection
      }
      .font(.system(size: 13))
      .padding(24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var appHeading: String {
    guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
      return "알맹Re"
    }
    return "알맹Re \(version)"
  }

  @ViewBuilder private var introductionLinks: some View {
    Button { openWindow(id: BasicUsageView.windowID) } label: {
      Text(verbatim: text("guide")).underline()
    }
    .buttonStyle(.plain)
    Link(destination: URL(string: "https://github.com/SeederPowerDrop/AlmaengRe")!) {
      Text(verbatim: "GitHub · SeederPowerDrop").underline()
    }
    .environment(\.layoutDirection, .leftToRight)
  }

  private func paragraph(_ key: String) -> some View {
    Text(verbatim: text(key))
      .lineSpacing(4)
      .fixedSize(horizontal: false, vertical: true)
      .textSelection(.enabled)
  }

  private var supportSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      Rectangle().fill(RetroAboutTheme.separator).frame(height: 1)
        .padding(.vertical, 4)
      Text(verbatim: text("supportTitle"))
        .font(.system(size: 16, weight: .bold))
      paragraph("supportMessage")
      HStack(spacing: 10) {
        Link(destination: AboutSupport.buyMeACoffeeURL) {
          supportCard("Buy Me a Coffee", symbol: "cup.and.saucer",
            tint: Color(red: 0.99, green: 0.85, blue: 0.35))
        }
        Link(destination: AboutSupport.koFiURL) {
          supportCard("Ko-fi", symbol: "heart.fill",
            tint: Color(red: 1, green: 0.86, blue: 0.9))
        }
        Button {
          showsBitcoin.toggle()
          supportStatus = nil
        } label: {
          supportCard("BlueWallet", symbol: "wallet.bifold",
            tint: Color(red: 0.84, green: 0.9, blue: 1), subtitle: "Bitcoin (BTC)",
            expanded: showsBitcoin)
        }
        .accessibilityValue(showsBitcoin ? text("bitcoinDescription") : "Bitcoin (BTC)")
      }
      .buttonStyle(.plain)
      .environment(\.layoutDirection, .leftToRight)
      if showsBitcoin { bitcoinDetails }
    }
  }

  private func supportCard(_ title: String, symbol: String, tint: Color,
    subtitle: String? = nil, expanded: Bool? = nil) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 21, weight: .medium))
        .foregroundStyle(Color(white: 0.15))
        .frame(width: 38, height: 38)
        .background(tint, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(verbatim: title).font(.system(size: 15, weight: .bold))
          .fixedSize(horizontal: false, vertical: true)
        if let subtitle {
          Text(verbatim: subtitle).font(.system(size: 12)).foregroundStyle(RetroAboutTheme.secondaryText)
        }
      }
      Spacer(minLength: 0)
      if let expanded {
        Image(systemName: expanded ? "chevron.up" : "chevron.down")
          .font(.system(size: 11, weight: .bold))
          .accessibilityHidden(true)
      }
    }
    .foregroundStyle(RetroAboutTheme.cardText)
    .padding(12)
    .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
    .background(RetroAboutTheme.card, in: RoundedRectangle(cornerRadius: 6))
    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(RetroAboutTheme.cardBorder, lineWidth: 1) }
    .contentShape(RoundedRectangle(cornerRadius: 6))
  }

  private var bitcoinDetails: some View {
    HStack(alignment: .top, spacing: 18) {
      if let qr = Self.bitcoinQR {
        Image(qr, scale: 1, label: Text(verbatim: text("bitcoinQR")))
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .frame(width: 144, height: 144)
          .padding(16)
          .background(.white)
          .accessibilityLabel(text("bitcoinQR"))
      }
      VStack(alignment: .leading, spacing: 12) {
        paragraph("bitcoinDescription")
        Text(verbatim: AboutSupport.bitcoinAddress)
          .font(.system(size: 12, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(RetroAboutTheme.surface)
          .overlay { RetroBevel(inset: true) }
          .environment(\.layoutDirection, .leftToRight)
          .accessibilityLabel(text("bitcoinAddress"))
          .accessibilityValue(AboutSupport.bitcoinAddress)
        HStack(spacing: 10) {
          Button(text("copyAddress")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(AboutSupport.bitcoinAddress, forType: .string)
            supportStatus = text("addressCopied")
          }
          Button(text("openWallet")) {
            if !NSWorkspace.shared.open(AboutSupport.bitcoinURL) {
              supportStatus = text("walletUnavailable")
            }
          }
        }
        .buttonStyle(RetroAboutButtonStyle())
        if let supportStatus {
          Text(verbatim: supportStatus).font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(RetroAboutTheme.details)
    .overlay { RetroBevel(inset: true) }
  }

  private var footer: some View {
    HStack(spacing: 14) {
      Spacer(minLength: 0)
      Button(text(showsLicenses ? "back" : "licenses")) { showsLicenses.toggle() }
        .buttonStyle(RetroAboutButtonStyle())
      Button(text("confirm")) { dismiss() }
        .buttonStyle(RetroAboutButtonStyle())
        .keyboardShortcut(.defaultAction)
    }
    .fixedSize(horizontal: false, vertical: true)
    .font(.system(size: 14, weight: .semibold))
    .padding(.horizontal, 24)
    .padding(.bottom, 18)
    .padding(.top, 10)
  }

  private struct LicenseDocument: Identifiable {
    let id: String
    let name: String
    let url: URL
  }

  private var licenses: [LicenseDocument] {
    var documents: [LicenseDocument] = []
    if let url = Self.resource("AlmaengRe-LICENSE", extension: "txt") {
      documents.append(LicenseDocument(id: "app", name: "알맹Re · MIT", url: url))
    }
    if let url = Self.resource("QuickSRNet-LICENSE", extension: "txt", subdirectory: "AIModels") {
      documents.append(LicenseDocument(id: "model", name: "QuickSRNet · BSD-3-Clause", url: url))
    }
    // This notice is copied from the engine by the app packaging script.
    if let url = Bundle.main.url(forResource: "RustThirdPartyNotices", withExtension: "txt") {
      documents.append(LicenseDocument(id: "engine", name: "Rust · Third-party notices", url: url))
    }
    return documents
  }

  private var licenseContent: some View {
    VStack(alignment: .leading, spacing: 14) {
      Picker(text("licenses"), selection: $selectedLicense) {
        ForEach(licenses) { Text(verbatim: $0.name).tag($0.id) }
      }
      .labelsHidden()
      .frame(maxWidth: .infinity, alignment: .leading)
      let document = licenses.first { $0.id == selectedLicense }
      AboutLicenseTextView(text: document.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } ?? "")
        .overlay { RetroBevel(inset: true) }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Retain the original cream-and-blue palette in light mode while making the
/// same retro surfaces legible when the application follows a dark appearance.
private enum RetroAboutTheme {
  static let paperColor = adaptive("paper", light: (0.925, 0.914, 0.847), dark: (0.155, 0.165, 0.18))
  static let textColor = adaptive("text", light: (0, 0, 0), dark: (0.93, 0.93, 0.93))
  static let surfaceColor = adaptive("surface", light: (1, 1, 1), dark: (0.115, 0.125, 0.14))
  static let paper = Color(nsColor: paperColor)
  static let text = Color(nsColor: textColor)
  static let surface = Color(nsColor: surfaceColor)
  static let secondaryText = color("secondaryText", light: (0.35, 0.35, 0.35), dark: (0.72, 0.73, 0.75))
  static let link = color("link", light: (0, 0.25, 0.9), dark: (0.48, 0.70, 1))
  static let card = color("card", light: (0.98, 0.975, 0.955), dark: (0.205, 0.215, 0.235))
  static let cardText = color("cardText", light: (0.15, 0.15, 0.15), dark: (0.93, 0.93, 0.93))
  static let cardBorder = color("cardBorder", light: (0.74, 0.74, 0.74), dark: (0.38, 0.39, 0.41))
  static let separator = color("separator", light: (0.68, 0.68, 0.68), dark: (0.35, 0.36, 0.38))
  static let bevelLight = color("bevelLight", light: (1, 1, 1), dark: (0.42, 0.44, 0.47))
  static let bevelDark = color("bevelDark", light: (0.48, 0.48, 0.48), dark: (0.08, 0.09, 0.10))
  static let titleStart = color("titleStart", light: (0.015, 0.25, 0.82), dark: (0.025, 0.16, 0.42))
  static let titleEnd = color("titleEnd", light: (0.18, 0.53, 0.98), dark: (0.10, 0.30, 0.60))
  static let details = Color(nsColor: NSColor(name: "AlmaengAbout.details") { appearance in
    NSColor(white: 1, alpha: isDark(appearance) ? 0.035 : 0.4)
  })

  private static func color(_ name: String, light: (CGFloat, CGFloat, CGFloat),
    dark: (CGFloat, CGFloat, CGFloat)) -> Color {
    Color(nsColor: adaptive(name, light: light, dark: dark))
  }

  private static func adaptive(_ name: String, light: (CGFloat, CGFloat, CGFloat),
    dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
    NSColor(name: "AlmaengAbout.\(name)") { appearance in
      let components = isDark(appearance) ? dark : light
      return NSColor(srgbRed: components.0, green: components.1, blue: components.2, alpha: 1)
    }
  }

  private static func isDark(_ appearance: NSAppearance) -> Bool {
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }
}

private struct RetroAboutButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(RetroAboutTheme.text)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(RetroAboutTheme.paper)
      .overlay { RetroBevel(inset: configuration.isPressed) }
      .contentShape(Rectangle())
      .offset(x: configuration.isPressed ? 1 : 0, y: configuration.isPressed ? 1 : 0)
  }
}

private struct RetroBevel: View {
  var inset = false
  var body: some View {
    GeometryReader { geometry in
      let rect = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 1, dy: 1)
      Path { path in
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: rect.origin)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
      }
      .stroke(inset ? RetroAboutTheme.bevelDark : RetroAboutTheme.bevelLight, lineWidth: 2)
      Path { path in
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
      }
      .stroke(inset ? RetroAboutTheme.bevelLight : RetroAboutTheme.bevelDark, lineWidth: 2)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct AboutWindowChrome: NSViewRepresentable {
  let title: String
  func makeNSView(context: Context) -> ChromeView {
    let view = ChromeView()
    view.windowTitle = title
    return view
  }
  func updateNSView(_ nsView: ChromeView, context: Context) {
    nsView.windowTitle = title
    nsView.updateWindowChrome()
  }
  final class ChromeView: NSView {
    var windowTitle = ""
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      updateWindowChrome()
    }
    override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      updateWindowChrome()
    }
    func updateWindowChrome() {
      guard let window else { return }
      window.title = windowTitle
      window.backgroundColor = RetroAboutTheme.paperColor
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.styleMask.insert(.fullSizeContentView)
      for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        window.standardWindowButton(button)?.isHidden = true
      }
    }
  }
}

private struct AboutTitlebarDragArea: NSViewRepresentable {
  func makeNSView(context: Context) -> DragView { DragView() }
  func updateNSView(_ nsView: DragView, context: Context) {}
  final class DragView: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override var acceptsFirstResponder: Bool { false }
  }
}

private struct AboutLicenseTextView: NSViewRepresentable {
  let text: String
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = true
    scroll.backgroundColor = RetroAboutTheme.surfaceColor
    let view = LicenseTextView(frame: scroll.contentView.bounds)
    view.isEditable = false
    view.isSelectable = true
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.textContainer?.widthTracksTextView = true
    view.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
    view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    view.textContainerInset = NSSize(width: 12, height: 12)
    view.updateAppearanceColors()
    scroll.documentView = view
    return scroll
  }
  func updateNSView(_ nsView: NSScrollView, context: Context) {
    guard let view = nsView.documentView as? LicenseTextView else { return }
    nsView.backgroundColor = RetroAboutTheme.surfaceColor
    view.updateAppearanceColors()
    guard view.string != text else { return }
    view.string = text
    nsView.contentView.scroll(to: .zero)
    nsView.reflectScrolledClipView(nsView.contentView)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 600, height: proposal.height ?? 400)
  }
  final class LicenseTextView: NSTextView {
    override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      updateAppearanceColors()
    }
    func updateAppearanceColors() {
      backgroundColor = RetroAboutTheme.surfaceColor
      textColor = RetroAboutTheme.textColor
      needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
      if [36, 76].contains(event.keyCode),
        event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty {
        window?.performClose(nil)
        return
      }
      super.keyDown(with: event)
    }
  }
}
