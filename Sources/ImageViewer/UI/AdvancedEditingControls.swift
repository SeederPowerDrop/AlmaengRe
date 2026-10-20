import SwiftUI

struct AdvancedEditingControls: View {
  @ObservedObject var store: AppStore
  @State private var curveChannel: ToneCurveChannel = .rgb
  @State private var mixerBand: ColorMixerBand = .red
  @State private var selectedPoint = 2
  @State private var curvesExpanded = true
  @State private var mixerExpanded = false
  @State private var presenceExpanded = false
  @State private var filmExpanded = true

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 12) {
        Label("톤 조정", systemImage: "sun.min")
          .font(ViewerUIMetrics.font(size: 12, weight: .semibold))
        slider("그림자", value: binding(\.shadows), range: -1...1)
        slider("블랙 포인트", value: binding(\.blackPoint), range: -1...1)
        slider("흰색", value: binding(\.whites), range: -1...1)
      }
      Divider()
      DisclosureGroup(isExpanded: $curvesExpanded) {
        curveControls.viewerPadding(.top, 10)
      } label: { sectionLabel("톤 커브", icon: "point.3.connected.trianglepath.dotted") }
      Divider()
      DisclosureGroup(isExpanded: $mixerExpanded) {
        mixerControls.viewerPadding(.top, 10)
      } label: { sectionLabel("컬러 믹서", icon: "paintpalette") }
      Divider()
      DisclosureGroup(isExpanded: $presenceExpanded) {
        presenceControls.viewerPadding(.top, 10)
      } label: { sectionLabel("프레즌스", icon: "circle.lefthalf.filled") }
      Divider()
      DisclosureGroup(isExpanded: $filmExpanded) {
        filmControls.viewerPadding(.top, 10)
      } label: { sectionLabel("필름 룩", icon: "camera.filters") }
    }
    .font(ViewerUIMetrics.font(size: 11))
    .disabled(store.currentAsset == nil)
  }

  private var curveControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("채널", selection: $curveChannel) {
        ForEach(ToneCurveChannel.allCases) { Text(L10n.text($0.title)).tag($0) }
      }
      .pickerStyle(.segmented)
      ToneCurveGraph(curve: curveBinding, channel: curveChannel, selectedPoint: $selectedPoint)
        .viewerFrame(height: 180)
      Text("다섯 제어점을 위아래로 드래그하세요.")
        .font(ViewerUIMetrics.font(.caption2)).foregroundStyle(.secondary)
      HStack(spacing: 6) {
        curvePreset("선형", .identity)
        curvePreset("중간 대비", .mediumContrast)
        curvePreset("강한 대비", .strongContrast)
      }
      HStack {
        Text("제어점")
        Picker("제어점", selection: $selectedPoint) {
          ForEach(0..<5) { Text("\($0 + 1)").tag($0) }
        }
        .labelsHidden()
        Text("X \((Double(selectedPoint) / 4).formatted(.number.precision(.fractionLength(2))))")
          .monospacedDigit().foregroundStyle(.secondary)
      }
      slider("출력", value: Binding(
        get: { curveBinding.wrappedValue.normalizedValues[selectedPoint] },
        set: { value in
          var curve = curveBinding.wrappedValue
          curve.setValue(value, at: selectedPoint)
          curveBinding.wrappedValue = curve
        }), range: 0...1)
      Button("톤 커브 초기화") { store.updateAdjustments { $0.toneCurves = .init() } }
        .buttonStyle(.borderless)
    }
  }

  private var mixerControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("색상", selection: $mixerBand) {
        ForEach(ColorMixerBand.allCases) { Text(L10n.text($0.title)).tag($0) }
      }
      slider("색조", value: mixerBinding(\.hue), range: -30...30, suffix: "°")
      slider("채도", value: mixerBinding(\.saturation), range: -1...1, percent: true)
      slider("명도", value: mixerBinding(\.lightness), range: -1...1, percent: true)
      Button("컬러 믹서 초기화") { store.updateAdjustments { $0.colorMixer = .init() } }
        .buttonStyle(.borderless)
    }
  }

  private var presenceControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      slider("텍스처", value: binding(\.texture), range: 0...1, percent: true)
      slider("명료도", value: binding(\.clarity), range: 0...1, percent: true)
      slider("안개 제거", value: binding(\.dehaze), range: -1...1, percent: true)
      Text("텍스처는 작은 디테일을, 명료도는 넓은 윤곽을 강조합니다. 안개 제거는 어두운 톤과 대비를 조절합니다.")
        .font(ViewerUIMetrics.font(.caption2)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("프레즌스 초기화") {
        store.updateAdjustments { $0.texture = 0; $0.clarity = 0; $0.dehaze = 0 }
      }
      .buttonStyle(.borderless)
    }
  }

  private var filmControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(ImageFilmLook.allCases) { look in
        Button {
          store.updateAdjustments { $0.filmLook = look }
        } label: {
          HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 5)
              .fill(LinearGradient(colors: swatchColors(look), startPoint: .leading, endPoint: .trailing))
              .viewerFrame(width: 38, height: 27)
            Text(L10n.text(look.title)).foregroundStyle(.primary)
            Spacer(minLength: 0)
            if store.currentAdjustments.filmLook == look {
              Image(systemName: "checkmark.circle.fill").foregroundStyle(ViewerTheme.accent)
            }
          }
          .viewerPadding(8)
          .background(store.currentAdjustments.filmLook == look
            ? ViewerTheme.accent.opacity(0.13) : Color.primary.opacity(0.035))
          .clipShape(RoundedRectangle(cornerRadius: 7))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(store.currentAdjustments.filmLook == look ? .isSelected : [])
      }
      slider("강도", value: binding(\.filmStrength), range: 0...1, percent: true)
        .disabled(store.currentAdjustments.filmLook == .none)
    }
  }

  private func swatchColors(_ look: ImageFilmLook) -> [Color] {
    switch look {
    case .none: [.gray, .white]
    case .tealOrange: [Color(red: 0.12, green: 0.43, blue: 0.46), Color(red: 0.97, green: 0.62, blue: 0.35)]
    case .faded: [Color(red: 0.46, green: 0.43, blue: 0.40), Color(red: 0.87, green: 0.82, blue: 0.73)]
    case .coolNight: [Color(red: 0.10, green: 0.17, blue: 0.34), Color(red: 0.49, green: 0.70, blue: 0.79)]
    }
  }

  private func sectionLabel(_ title: String, icon: String) -> some View {
    Label(L10n.text(title), systemImage: icon).font(ViewerUIMetrics.font(size: 12, weight: .semibold))
  }

  private func curvePreset(_ title: String, _ curve: ImageToneCurve) -> some View {
    Button(L10n.text(title)) { curveBinding.wrappedValue = curve }
      .buttonStyle(.bordered).controlSize(.mini)
  }

  private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
    suffix: String = "", percent: Bool = false) -> some View
  {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(L10n.text(title))
        Spacer()
        Text((value.wrappedValue * (percent ? 100 : 1))
          .formatted(.number.precision(.fractionLength(percent ? 0 : 2))) + (percent ? " %" : suffix))
          .monospacedDigit().foregroundStyle(.secondary)
      }
      Slider(value: value, in: range).accessibilityLabel(L10n.text(title))
    }
  }

  private func binding(_ keyPath: WritableKeyPath<ImageAdjustments, Double>) -> Binding<Double> {
    Binding(get: { store.currentAdjustments[keyPath: keyPath] },
      set: { value in store.updateAdjustments { $0[keyPath: keyPath] = value } })
  }

  private var curveBinding: Binding<ImageToneCurve> {
    Binding(get: { store.currentAdjustments.toneCurves[curveChannel] },
      set: { value in store.updateAdjustments { $0.toneCurves[curveChannel] = value } })
  }

  private func mixerBinding(_ keyPath: WritableKeyPath<ColorMixerValues, Double>) -> Binding<Double> {
    Binding(get: { store.currentAdjustments.colorMixer[mixerBand][keyPath: keyPath] },
      set: { value in
        store.updateAdjustments {
          var band = $0.colorMixer[mixerBand]
          band[keyPath: keyPath] = value
          $0.colorMixer[mixerBand] = band
        }
      })
  }
}

private struct ToneCurveGraph: View {
  @Binding var curve: ImageToneCurve
  let channel: ToneCurveChannel
  @Binding var selectedPoint: Int

  private var curveColor: Color {
    switch channel { case .rgb: .primary; case .red: .red; case .green: .green; case .blue: .blue }
  }

  var body: some View {
    GeometryReader { geometry in
      let plot = CGRect(x: 12, y: 12, width: max(1, geometry.size.width - 24),
        height: max(1, geometry.size.height - 24))
      ZStack {
        RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.055))
        graphLines(plot: plot)
        ForEach(0..<5) { index in
          controlPoint(index, plot: plot)
        }
      }
      .coordinateSpace(name: "imageToneCurve")
    }
  }

  private func graphLines(plot: CGRect) -> some View {
    Canvas { context, _ in
      var grid = Path()
      for index in 0...4 {
        let x = plot.minX + CGFloat(index) * plot.width / 4
        let y = plot.minY + CGFloat(index) * plot.height / 4
        grid.move(to: CGPoint(x: x, y: plot.minY)); grid.addLine(to: CGPoint(x: x, y: plot.maxY))
        grid.move(to: CGPoint(x: plot.minX, y: y)); grid.addLine(to: CGPoint(x: plot.maxX, y: y))
      }
      context.stroke(grid, with: .color(.secondary.opacity(0.22)),
        style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
      var reference = Path()
      reference.move(to: CGPoint(x: plot.minX, y: plot.maxY))
      reference.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
      context.stroke(reference, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
      var line = Path()
      let values = curve.normalizedValues
      for index in 0..<5 {
        let position = point(index, values: values, plot: plot)
        if index == 0 { line.move(to: position) } else { line.addLine(to: position) }
      }
      context.stroke(line, with: .color(curveColor), lineWidth: 2)
    }
    .accessibilityHidden(true)
  }

  private func controlPoint(_ index: Int, plot: CGRect) -> some View {
    let values = curve.normalizedValues
    let fill: Color = index == selectedPoint ? ViewerTheme.accent : Color(nsColor: .windowBackgroundColor)
    return Circle()
      .fill(fill)
      .overlay(Circle().stroke(curveColor, lineWidth: 2))
      .viewerFrame(width: 11, height: 11)
      .viewerFrame(width: 24, height: 24)
      .contentShape(Circle())
      .position(point(index, values: values, plot: plot))
      .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("imageToneCurve"))
        .onChanged { value in
          selectedPoint = index
          let outputValue: CGFloat = 1 - (value.location.y - plot.minY) / plot.height
          curve.setValue(Double(outputValue), at: index)
        })
      .accessibilityLabel(L10n.format("제어점 %d", index + 1))
      .accessibilityValue(values[index].formatted(.number.precision(.fractionLength(2))))
      .accessibilityAdjustableAction { direction in
        curve.setValue(values[index] + (direction == .increment ? 0.01 : -0.01), at: index)
      }
  }

  private func point(_ index: Int, values: [Double], plot: CGRect) -> CGPoint {
    CGPoint(x: plot.minX + CGFloat(index) / 4 * plot.width,
      y: plot.maxY - CGFloat(values[index]) * plot.height)
  }
}
