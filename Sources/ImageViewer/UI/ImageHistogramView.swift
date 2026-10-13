import SwiftUI

private struct ImageHistogramResult {
  let request: ImageHistogramRequest
  let histogram: ImageHistogram?
}

private enum ImageHistogramChannel: Hashable {
  case rgb, luminance
}

/// A small, cancellable analysis panel shared by image information and editing.
struct ImageHistogramView: View {
  let asset: ImageAsset
  let adjustments: ImageAdjustments
  let pipeline: ImagePipeline

  @State private var channel: ImageHistogramChannel = .rgb
  @State private var result: ImageHistogramResult?
  @State private var requestGate = LatestRequestGate<ImageHistogramRequest>()

  private var request: ImageHistogramRequest {
    ImageHistogramRequest(asset: asset, adjustments: adjustments)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Label(L10n.text("히스토그램"), systemImage: "chart.bar.xaxis")
          .font(.system(size: 12, weight: .semibold))
        Spacer()
      }
      Picker(L10n.text("히스토그램 채널"), selection: $channel) {
        Text("RGB").tag(ImageHistogramChannel.rgb)
        Text(L10n.text("휘도")).tag(ImageHistogramChannel.luminance)
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      if let result, result.request == request {
        if let histogram = result.histogram, !histogram.isEmpty {
          chart(histogram)
          HStack {
            Text(L10n.format("완전 검정 %.1f%%", histogram.blackPercentage))
            Spacer(minLength: 4)
            Text(L10n.format("완전 흰색 %.1f%%", histogram.whitePercentage))
          }
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.secondary)
          .help(L10n.text("미리보기에서 RGB가 모두 0 또는 255인 픽셀의 투명도 가중 비율입니다."))
        } else {
          placeholder(result.histogram == nil
            ? L10n.text("히스토그램을 불러올 수 없습니다.")
            : L10n.text("분석할 불투명 픽셀이 없습니다."))
        }
      } else {
        ZStack {
          RoundedRectangle(cornerRadius: 6).fill(ViewerTheme.canvas)
          ProgressView().controlSize(.small)
        }
        .frame(height: 112)
        .accessibilityLabel(L10n.text("히스토그램 계산 중"))
      }

      Text(L10n.text("SDR 미리보기 · 투명도 가중"))
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .help(L10n.text("보정된 sRGB 미리보기의 256구간 분포입니다. 휘도는 0.2126R + 0.7152G + 0.0722B로 계산하며 HDR 원본 분포와 다를 수 있습니다."))
    }
    .onDisappear {
      requestGate.invalidate()
      result = nil
    }
    .task(id: request) {
      guard !Task.isCancelled else { return }
      let requested = request
      let generation = requestGate.begin(requested)
      result = nil
      do {
        // Scrubbing sliders or rapidly browsing never builds a queue of analysis jobs.
        try await Task.sleep(for: .milliseconds(180))
        let histogram = try await ImageHistogramAnalyzer.shared.histogram(
          for: requested, pipeline: pipeline)
        try Task.checkCancellation()
        guard requestGate.accepts(generation, for: requested) else { return }
        result = ImageHistogramResult(request: requested, histogram: histogram)
      } catch is CancellationError {
        // A different asset, edit, or hidden panel owns the next result.
      } catch {
        guard !Task.isCancelled, requestGate.accepts(generation, for: requested) else { return }
        result = ImageHistogramResult(request: requested, histogram: nil)
      }
    }
  }

  private func placeholder(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity)
      .frame(height: 112)
      .background(ViewerTheme.panel, in: RoundedRectangle(cornerRadius: 6))
  }

  private func chart(_ histogram: ImageHistogram) -> some View {
    Canvas { context, size in
      var grid = Path()
      for fraction in [0.25, 0.5, 0.75] {
        grid.move(to: CGPoint(x: size.width * fraction, y: 0))
        grid.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
        grid.move(to: CGPoint(x: 0, y: size.height * fraction))
        grid.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
      }
      context.stroke(grid, with: .color(.white.opacity(0.12)),
        style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
      let series: [([Double], Color)] = channel == .rgb
        ? [(histogram.red, .red), (histogram.green, .green), (histogram.blue, .blue)]
        : [(histogram.luminance, .white)]
      let peak = max(1, series.flatMap { $0.0 }.max() ?? 1)
      for (bins, color) in series {
        var line = Path()
        for index in bins.indices {
          let point = CGPoint(x: Double(index) / 255 * size.width,
            y: size.height - (bins[index] / peak) * (size.height - 4))
          if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
        }
        var fill = line
        fill.addLine(to: CGPoint(x: size.width, y: size.height))
        fill.addLine(to: CGPoint(x: 0, y: size.height))
        fill.closeSubpath()
        context.fill(fill, with: .color(color.opacity(channel == .rgb ? 0.28 : 0.36)))
        context.stroke(line, with: .color(color.opacity(0.9)), lineWidth: 0.8)
      }
    }
    .frame(height: 112)
    .background(ViewerTheme.canvas)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .accessibilityLabel(L10n.text(channel == .rgb ? "RGB 히스토그램" : "휘도 히스토그램"))
  }
}
