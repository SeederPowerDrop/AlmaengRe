import SwiftUI

/// Draft crop stays local until Apply; Cancel leaves the image's edits untouched.
struct CropEditorView: View {
  let asset: ImageAsset
  let adjustments: ImageAdjustments
  let pipeline: ImagePipeline
  let prefersHDR: Bool
  let onApply: (NormalizedCrop?) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var selection: NormalizedCrop
  @State private var frame: RenderedFrame?
  @State private var errorMessage: String?
  @State private var aspect = "free"
  @State private var dragStart: NormalizedCrop?

  init(asset: ImageAsset, adjustments: ImageAdjustments, pipeline: ImagePipeline,
    prefersHDR: Bool, onApply: @escaping (NormalizedCrop?) -> Void)
  {
    self.asset = asset
    self.adjustments = adjustments
    self.pipeline = pipeline
    self.prefersHDR = prefersHDR
    self.onApply = onApply
    _selection = State(initialValue: adjustments.effectiveCrop ?? .full)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("잘라내기", systemImage: "crop").font(.headline)
        Spacer()
        Text(asset.filename).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      }
      Text("드래그해서 영역을 선택하고 모서리로 크기를 조절하세요.")
        .font(.caption).foregroundStyle(.secondary)

      GeometryReader { geometry in
        ZStack {
          Color.black
          if let frame {
            let size = fittedSize(frame.image, in: geometry.size)
            cropCanvas(frame.image, size: size)
          } else if let errorMessage {
            ContentUnavailableView("미리보기를 불러올 수 없음",
              systemImage: "exclamationmark.triangle", description: Text(errorMessage))
          } else {
            ProgressView().controlSize(.large)
          }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }

      HStack {
        Picker("비율", selection: $aspect) {
          Text("자유").tag("free")
          Text("원본 비율").tag("original")
          ForEach(["1:1", "4:3", "3:4", "3:2", "2:3", "16:9", "9:16"], id: \.self) {
            Text($0).tag($0)
          }
        }
        .frame(width: 205)
        .onChange(of: aspect) { _, _ in
          if let ratio = normalizedRatio { selection = CropSelectionGeometry.fit(selection, ratio: ratio) }
        }
        Button("전체 선택") {
          aspect = "free"
          selection = .full
        }
        Spacer()
        if let frame {
          let pixels = selection.pixelRect(in: frame.sourcePixelSize ?? frame.image.size)
          Text("\(Int(pixels.width)) × \(Int(pixels.height)) px")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
      }
      .disabled(frame == nil)

      DisclosureGroup("자르기 영역") {
        HStack(spacing: 16) {
          numericControl("가로 위치", keyPath: \.x, upper: 1 - selection.width)
          numericControl("세로 위치", keyPath: \.y, upper: 1 - selection.height)
          numericControl("너비", keyPath: \.width, upper: 1 - selection.x)
          numericControl("높이", keyPath: \.height, upper: 1 - selection.y)
        }
        .padding(.top, 6)
      }
      .font(.caption)
      .disabled(frame == nil)

      Divider()
      HStack {
        Spacer()
        Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button("적용") {
          onApply(selection.isFullImage ? nil : selection.normalized)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(frame == nil)
      }
    }
    .padding(18)
    .frame(width: 780, height: 620)
    .task {
      var preview = adjustments
      preview.crop = nil
      do {
        let rendered = try await pipeline.renderFrame(url: asset.url, maxPixelSize: 1600,
          adjustments: preview, prefersHDR: prefersHDR)
        try Task.checkCancellation()
        frame = rendered
      } catch is CancellationError {
      } catch {
        if !Task.isCancelled { errorMessage = error.localizedDescription }
      }
    }
  }

  private var normalizedRatio: Double? {
    guard let frame else { return nil }
    if aspect == "original" { return 1 }
    let parts = aspect.split(separator: ":").compactMap { Double($0) }
    guard parts.count == 2 else { return nil }
    let size = frame.sourcePixelSize ?? frame.image.size
    return parts[0] / parts[1] * size.height / size.width
  }

  private func fittedSize(_ image: CGImage, in available: CGSize) -> CGSize {
    let scale = min((available.width - 24) / CGFloat(image.width),
      (available.height - 24) / CGFloat(image.height))
    return CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
  }

  private func cropCanvas(_ image: CGImage, size: CGSize) -> some View {
    let rect = CGRect(x: selection.x * size.width, y: selection.y * size.height,
      width: selection.width * size.width, height: selection.height * size.height)
    return ZStack(alignment: .topLeading) {
      ExtendedRangeImageView(image: image, prefersHDR: prefersHDR, interpolationMode: .smooth)
        .allowsHitTesting(false)
      Color.clear.contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("cropCanvas")).onChanged { value in
          selection = CropSelectionGeometry.draw(
            from: CGPoint(x: value.startLocation.x / size.width, y: value.startLocation.y / size.height),
            to: CGPoint(x: value.location.x / size.width, y: value.location.y / size.height),
            ratio: normalizedRatio)
        })
      Path { path in
        path.addRect(CGRect(origin: .zero, size: size))
        path.addRect(rect)
      }
      .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
      .allowsHitTesting(false)

      Rectangle().fill(.white.opacity(0.001))
        .overlay { Rectangle().stroke(.white, lineWidth: 1.5) }
        .overlay {
          Path { path in
            for fraction in [1.0 / 3, 2.0 / 3] {
              path.move(to: CGPoint(x: rect.width * fraction, y: 0))
              path.addLine(to: CGPoint(x: rect.width * fraction, y: rect.height))
              path.move(to: CGPoint(x: 0, y: rect.height * fraction))
              path.addLine(to: CGPoint(x: rect.width, y: rect.height * fraction))
            }
          }.stroke(.white.opacity(0.4), lineWidth: 0.5)
          .allowsHitTesting(false)
        }
        .frame(width: rect.width, height: rect.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(coordinateSpace: .named("cropCanvas")).onChanged { value in
          if dragStart == nil { dragStart = selection }
          if dragStart?.isFullImage == true {
            selection = CropSelectionGeometry.draw(
              from: CGPoint(x: value.startLocation.x / size.width, y: value.startLocation.y / size.height),
              to: CGPoint(x: value.location.x / size.width, y: value.location.y / size.height),
              ratio: normalizedRatio)
          } else {
            selection = CropSelectionGeometry.move(dragStart ?? selection,
              by: CGSize(width: value.translation.width / size.width, height: value.translation.height / size.height))
          }
        }.onEnded { _ in dragStart = nil })
        .accessibilityLabel(L10n.text("영역 이동"))
        .offset(x: rect.minX, y: rect.minY)

      ForEach(CropCorner.allCases) { corner in
        Circle().fill(.white)
          .overlay { Circle().stroke(.black.opacity(0.6), lineWidth: 1) }
          .frame(width: 12, height: 12)
          .padding(7)
          .contentShape(Rectangle())
          .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("cropCanvas")).onChanged { value in
            if dragStart == nil { dragStart = selection }
            selection = CropSelectionGeometry.resize(dragStart ?? selection, corner: corner,
              by: CGSize(width: value.translation.width / size.width, height: value.translation.height / size.height),
              ratio: normalizedRatio)
          }.onEnded { _ in dragStart = nil })
          .accessibilityLabel(corner.title)
          .position(x: corner.isLeft ? rect.minX : rect.maxX, y: corner.isTop ? rect.minY : rect.maxY)
      }
    }
    .frame(width: size.width, height: size.height)
    .coordinateSpace(name: "cropCanvas")
  }

  private func numericControl(_ title: String, keyPath: WritableKeyPath<NormalizedCrop, Double>,
    upper: Double) -> some View
  {
    VStack(alignment: .leading, spacing: 3) {
      Text(L10n.text(title))
      TextField("", value: Binding(
        get: { selection[keyPath: keyPath] * 100 },
        set: { value in
          guard value.isFinite else { return }
          aspect = "free"
          let minimum = keyPath == \.width || keyPath == \.height ? 0.01 : 0
          selection[keyPath: keyPath] = min(max(value / 100, minimum), upper)
          selection = selection.normalized
        }), format: .number.precision(.fractionLength(1)))
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel(L10n.text(title) + " (%)")
    }
  }
}

private extension CGImage {
  var size: CGSize { CGSize(width: width, height: height) }
}
