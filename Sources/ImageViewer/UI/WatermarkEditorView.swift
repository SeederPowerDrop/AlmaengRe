import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A bounded preview of the first captured target. Changes never touch source pixels.
struct WatermarkEditorView: View {
  @Binding private var committedOptions: WatermarkOptions
  @State private var options: WatermarkOptions
  private let close: () -> Void
  private let asset: ImageAsset?
  private let adjustments: ImageAdjustments
  private let pipeline: ImagePipeline
  @State private var renderer = WatermarkRenderer()
  @StateObject private var fontPicker = WatermarkFontPickerController()
  @State private var baseImage: CGImage?
  @State private var previewResult: WatermarkRenderResult?
  @State private var previewedOptions: WatermarkOptions?
  @State private var proposedPosition: WatermarkPoint?
  @State private var showsCanvasConfirmation = false
  @State private var canvasDecision: CanvasDecision?
  @State private var lastDeclinedOverflow: WatermarkOptions?

  private enum CanvasDecision {
    case placement(WatermarkPoint)
    case overflow(Double)
  }
  @State private var errorMessage: String?
  @State private var isRendering = false
  @State private var sourceReady = false
  @State private var previewRevision = 0

  init(options: Binding<WatermarkOptions>, asset: ImageAsset?,
    adjustments: ImageAdjustments, pipeline: ImagePipeline, close: @escaping () -> Void) {
    _committedOptions = options
    var draft = options.wrappedValue
    draft.isEnabled = true
    _options = State(initialValue: draft)
    self.asset = asset
    self.adjustments = adjustments
    self.pipeline = pipeline
    self.close = close
  }

  private var hasContent: Bool {
    !options.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !options.metadataFields.isEmpty || options.logoURL != nil
  }
  private var isValid: Bool {
    (try? options.validate()) != nil && (!options.isEnabled || hasContent)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label(WatermarkL10n.text("title"), systemImage: "signature")
          .font(.title2.bold())
        Spacer()
        Toggle(WatermarkL10n.text("enabled"), isOn: $options.isEnabled)
      }.padding(16)
      Divider()
      HStack(alignment: .top, spacing: 20) {
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            WatermarkSection(WatermarkL10n.text("text.title")) {
              VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $options.text)
                  .font(.body)
                  .frame(height: 44)
                  .accessibilityLabel(WatermarkL10n.text("text.placeholder"))
                  .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                HStack {
                  Text(WatermarkL10n.text("font"))
                  Spacer()
                  Button {
                    fontPicker.show(fontName: options.fontPostScriptName) { options.fontPostScriptName = $0 }
                  } label: {
                    Text(NSFont(name: options.fontPostScriptName, size: 12)?.displayName ?? options.fontPostScriptName)
                      .lineLimit(1).truncationMode(.middle)
                  }.accessibilityLabel(WatermarkL10n.text("font"))
                    .accessibilityValue(options.fontPostScriptName)
                }
                HStack {
                  Picker(WatermarkL10n.text("color"), selection: $options.textColor) {
                    ForEach(WatermarkColor.allCases, id: \.self) { color in
                      Text(WatermarkL10n.text("color." + color.rawValue)).tag(color)
                    }
                  }
                  Picker(WatermarkL10n.text("readability"), selection: $options.readability) {
                    ForEach(WatermarkReadability.allCases, id: \.self) { mode in
                      Text(WatermarkL10n.text("readability." + mode.rawValue)).tag(mode)
                    }
                  }
                }
              }.padding(2)
            }
            WatermarkSection(WatermarkL10n.text("metadata.title")) {
              VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                  let fields = WatermarkMetadataField.allCases
                  ForEach(Array(stride(from: 0, to: fields.count, by: 2)), id: \.self) { index in
                    GridRow {
                      metadataToggle(fields[index])
                      if index + 1 < fields.count { metadataToggle(fields[index + 1]) }
                    }
                  }
                }
                Text(WatermarkL10n.text("metadata.help"))
                  .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
              }.padding(2)
            }
            WatermarkSection(WatermarkL10n.text("logo.title")) {
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  Button(WatermarkL10n.text("logo.choose")) { chooseLogo() }
                  if options.logoURL != nil {
                    Button(WatermarkL10n.text("logo.remove")) { options.logoURL = nil }
                  }
                }
                Text(options.logoURL?.lastPathComponent ?? WatermarkL10n.text("logo.help"))
                  .font(.caption).foregroundStyle(.secondary).lineLimit(2)
              }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
            WatermarkSection(WatermarkL10n.text("layout.title")) {
              VStack(alignment: .leading, spacing: 8) {
                Picker(WatermarkL10n.text("position"), selection: Binding(
                  get: { options.customPosition == nil ? options.position.rawValue : "custom" },
                  set: { selected in
                    if let position = WatermarkPosition(rawValue: selected) {
                      options.position = position
                      options.customPosition = nil
                      proposedPosition = nil
                    }
                  })) {
                  if options.customPosition != nil {
                    Text(WatermarkL10n.text("position.custom")).tag("custom")
                  }
                  ForEach(WatermarkPosition.allCases, id: \.self) { position in
                    Text(WatermarkL10n.text("position." + position.rawValue)).tag(position.rawValue)
                  }
                }
                percentageSlider("size", value: $options.sizeFraction, range: 0.02...0.9)
                percentageSlider("margin", value: $options.marginFraction, range: 0...0.2)
                  .disabled(options.customPosition != nil)
                  .help(WatermarkL10n.text("margin.anchorHelp"))
                percentageSlider("opacity", value: $options.opacity, range: 0...1)
                Text(WatermarkL10n.text("layout.help"))
                  .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
              }.padding(2)
            }
          }.disabled(!options.isEnabled).padding(.bottom, 4)
        }.frame(width: 395)

        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text(WatermarkL10n.text("preview.title")).font(.headline)
            Spacer()
            if options.expandsCanvas {
              Button(WatermarkL10n.text("canvas.original")) { requestOriginalCanvas() }
                .controlSize(.small)
                .disabled(previewedOptions != options)
            }
          }
          Text(WatermarkL10n.text("drag.help"))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.92))
            if let image = baseImage {
              WatermarkPlacementPreview(source: image, result: previewResult,
                proposedPosition: proposedPosition, isEnabled: options.isEnabled) { point, isOutside in
                  proposedPosition = point
                  if isOutside && !options.expandsCanvas {
                    canvasDecision = .placement(point)
                    showsCanvasConfirmation = true
                  } else {
                    options.customPosition = point
                  }
                }
            }
            if isRendering || !sourceReady { ProgressView().tint(.white).allowsHitTesting(false) }
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(previewedOptions == options && !isRendering
              && !showsCanvasConfirmation && errorMessage == nil)
          if options.expandsCanvas {
            Text(WatermarkL10n.text("canvas.help"))
              .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
          Text(asset?.filename ?? "").font(.caption).lineLimit(1).truncationMode(.middle)
          Text(WatermarkL10n.text("preview.help"))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          if let errorMessage {
            Text(errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
          } else if options.isEnabled && !hasContent {
            Text(WatermarkL10n.text("empty"))
              .font(.caption).foregroundStyle(.secondary)
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }.padding(16)
      Divider()
      HStack {
        Text(WatermarkL10n.text("copy.help")).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button(WatermarkL10n.text("cancel")) { close() }.keyboardShortcut(.cancelAction)
        Button(WatermarkL10n.text("apply")) {
          committedOptions = options
          close()
        }.keyboardShortcut(.defaultAction)
          .disabled(!isValid || isRendering || !sourceReady
            || (options.isEnabled && (errorMessage != nil || previewedOptions != options)))
      }.padding(16)
    }
    .frame(width: 940, height: 730)
    .task { await loadSource() }
    .task(id: previewRevision) { await renderPreview() }
    .onChange(of: options) { _, _ in previewRevision &+= 1 }
    .onDisappear { fontPicker.close() }
    .alert(WatermarkL10n.text("canvas.confirm.title"), isPresented: $showsCanvasConfirmation,
      presenting: canvasDecision) { decision in
        Button(WatermarkL10n.text("canvas.confirm.allow")) { resolveCanvasDecision(decision, expand: true) }
        switch decision {
        case .placement:
          Button(WatermarkL10n.text("canvas.confirm.keep"), role: .cancel) {
            resolveCanvasDecision(decision, expand: false)
          }
        case .overflow:
          Button(WatermarkL10n.text("canvas.confirm.fit")) {
            resolveCanvasDecision(decision, expand: false)
          }
          Button(WatermarkL10n.text("cancel"), role: .cancel) {
            lastDeclinedOverflow = options
            canvasDecision = nil
          }
        }
      } message: { decision in
        switch decision {
        case .placement: Text(WatermarkL10n.text("canvas.confirm.body"))
        case .overflow: Text(WatermarkL10n.text("canvas.overflow.body"))
        }
      }
  }

  private func resolveCanvasDecision(_ decision: CanvasDecision, expand: Bool) {
    if expand {
      if case .placement(let point) = decision { options.customPosition = point }
      options.expandsCanvas = true
    } else {
      switch decision {
      case .placement(let point): keepInsideCurrentImage(point: point)
      case .overflow(let scale):
        options.expandsCanvas = false
        options.sizeFraction = max(0.02, options.sizeFraction * scale * 0.99)
        proposedPosition = nil
        lastDeclinedOverflow = options
      }
    }
    canvasDecision = nil
  }

  private func requestOriginalCanvas() {
    guard previewedOptions == options, let image = baseImage,
      let layout = previewResult?.layout else { return }
    let fit = min(1, min(Double(image.width) / layout.effectiveRect.width,
      Double(image.height) / layout.effectiveRect.height))
    if fit < 1 {
      canvasDecision = .overflow(fit)
      showsCanvasConfirmation = true
    } else {
      keepInsideCurrentImage()
    }
  }

  private func keepInsideCurrentImage(point: WatermarkPoint? = nil) {
    if let image = baseImage, let layout = previewResult?.layout {
      let originalSize = CGSize(width: image.width, height: image.height)
      let selectedPoint = point ?? options.customPosition ?? WatermarkPoint(
        x: layout.effectiveRect.midX / originalSize.width,
        y: layout.effectiveRect.midY / originalSize.height)
      options.customPosition = WatermarkPreviewGeometry.clampedPosition(selectedPoint,
        overlaySize: layout.effectiveRect.size,
        originalSize: originalSize)
    }
    options.expandsCanvas = false
    proposedPosition = nil
  }

  private func percentageSlider(_ key: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
    WatermarkPercentControl(title: WatermarkL10n.text(key), value: value, range: range)
  }

  private func metadataToggle(_ field: WatermarkMetadataField) -> some View {
    Toggle(WatermarkL10n.text("field." + field.rawValue), isOn: Binding(
      get: { options.metadataFields.contains(field) },
      set: { if $0 { options.metadataFields.insert(field) }
        else { options.metadataFields.remove(field) } }))
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func chooseLogo() {
    let panel = NSOpenPanel()
    panel.title = WatermarkL10n.text("logo.choose")
    panel.allowedContentTypes = [.image]
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { options.logoURL = url }
  }

  private func loadSource() async {
    guard let asset else { sourceReady = true; return }
    do {
      let frame = try await pipeline.renderFrame(url: asset.url, maxPixelSize: 1000,
        adjustments: adjustments, prefersHDR: false)
      try Task.checkCancellation()
      baseImage = frame.image
      sourceReady = true
      previewRevision &+= 1
    } catch {
      guard !Task.isCancelled else { return }
      sourceReady = true
      errorMessage = error.localizedDescription
    }
  }

  private func renderPreview() async {
    guard let image = baseImage, let asset else { return }
    let captured = options
    isRendering = true
    do {
      // Slider/text bursts replace one pending job instead of decoding for every event.
      try await Task.sleep(for: .milliseconds(160))
      let result = try await renderer.renderResult(image: image, sourceURL: asset.url, options: captured)
      try Task.checkCancellation()
      guard captured == options else { return }
      previewResult = result
      previewedOptions = captured
      proposedPosition = nil
      errorMessage = nil
      isRendering = false
    } catch {
      guard !Task.isCancelled, captured == options else { return }
      errorMessage = error.localizedDescription
      isRendering = false
      if case WatermarkError.contentOverflow(let scale) = error,
        captured != lastDeclinedOverflow, !showsCanvasConfirmation {
        canvasDecision = .overflow(scale)
        showsCanvasConfirmation = true
      }
    }
  }
}

private struct WatermarkSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.headline)
      content
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .contain)
  }
}

/// The system font panel loads its catalog on demand and supports font-family search.
@MainActor
private final class WatermarkFontPickerController: NSObject, ObservableObject {
  private var selection: ((String) -> Void)?
  private weak var previousTarget: AnyObject?
  private var previousAction: Selector?
  private var currentFont = NSFont.systemFont(ofSize: 24)
  private var previousWorksWhenModal = false

  func show(fontName: String, selection: @escaping (String) -> Void) {
    let manager = NSFontManager.shared
    if self.selection == nil {
      previousTarget = manager.target as AnyObject?
      previousAction = manager.action
      previousWorksWhenModal = manager.fontPanel(true)?.worksWhenModal ?? false
    }
    self.selection = selection
    manager.target = self
    manager.action = #selector(changeFont(_:))
    currentFont = NSFont(name: fontName, size: 24) ?? .systemFont(ofSize: 24)
    manager.setSelectedFont(currentFont, isMultiple: false)
    if let panel = manager.fontPanel(true) {
      panel.worksWhenModal = true
      panel.makeKeyAndOrderFront(nil)
    }
  }

  @objc private func changeFont(_ sender: NSFontManager) {
    currentFont = sender.convert(currentFont)
    selection?(currentFont.fontName)
  }

  func close() {
    guard selection != nil else { return }
    let manager = NSFontManager.shared
    if manager.target as AnyObject? === self {
      manager.fontPanel(false)?.orderOut(nil)
      manager.fontPanel(false)?.worksWhenModal = previousWorksWhenModal
      manager.target = previousTarget
      if let previousAction { manager.action = previousAction }
    }
    selection = nil
  }
}
