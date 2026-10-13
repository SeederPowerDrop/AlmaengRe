import CoreImage
import CoreImage.CIFilterBuiltins

/// Runs inside the existing decoder budget, using the same graph for preview and export.
/// Point operations unpremultiply explicitly and retain values above SDR white.
enum AdvancedImageProcessor {
  static func apply(_ adjustments: ImageAdjustments, to input: CIImage) -> CIImage {
    var image = input
    let black = finite(adjustments.blackPoint, -1...1)
    let whites = finite(adjustments.whites, -1...1)
    let dehaze = finite(adjustments.dehaze, -1...1)
    if black != 0 || whites != 0 || dehaze != 0,
      let output = tonalKernel?.apply(extent: image.extent,
        arguments: [image, black, whites, dehaze]) { image = output }

    if !adjustments.toneCurves.isIdentity {
      let curves = ToneCurveChannel.allCases.map { adjustments.toneCurves[$0].normalizedValues }
      let vectors = curves.map { CIVector(x: $0[0], y: $0[1], z: $0[2], w: $0[3]) }
      let ends = CIVector(x: curves[0][4], y: curves[1][4], z: curves[2][4], w: curves[3][4])
      if let output = curveKernel?.apply(extent: image.extent,
        arguments: [image] + vectors + [ends]) { image = output }
    }

    if !adjustments.colorMixer.isIdentity {
      let vectors = ColorMixerBand.allCases.map { band in
        let values = adjustments.colorMixer[band]
        return CIVector(x: finite(values.hue, -30...30) / 360,
          y: finite(values.saturation, -1...1), z: finite(values.lightness, -1...1))
      }
      if let output = mixerKernel?.apply(extent: image.extent,
        arguments: [image] + vectors) { image = output }
    }

    // Radii are image-relative so a reduced preview closely matches full-size export.
    let scale = max(image.extent.width, image.extent.height) / 1_024
    let texture = finite(adjustments.texture, 0...1)
    let clarity = finite(adjustments.clarity, 0...1)
    for (amount, radius) in [(texture, max(0.25, scale * 1.6)),
      (clarity, max(0.5, scale * 14))] where amount > 0 {
      let extent = image.extent
      let filter = CIFilter.unsharpMask()
      filter.inputImage = image.clampedToExtent()
      filter.radius = Float(min(radius, 128))
      filter.intensity = Float(amount * 0.65)
      if let output = filter.outputImage { image = output.cropped(to: extent) }
    }

    let strength = finite(adjustments.filmStrength, 0...1)
    if adjustments.filmLook != .none && strength > 0 {
      let look: Double
      switch adjustments.filmLook {
      case .none: look = 0
      case .tealOrange: look = 1
      case .faded: look = 2
      case .coolNight: look = 3
      }
      if let output = filmKernel?.apply(extent: image.extent,
        arguments: [image, look, strength]) { image = output }
    }

    // Spatial filters may also process alpha. Preserve the source coverage exactly.
    if texture > 0 || clarity > 0,
      let output = alphaKernel?.apply(extent: input.extent, arguments: [image, input]) {
      image = output
    }
    return image
  }

  private static func finite(_ value: Double, _ range: ClosedRange<Double>) -> Double {
    ImageToneCurve.finite(value, in: range)
  }

  // CIKernel language supports both the GPU and Core Image's CPU fallback.
  // Immutable kernels are compiled once, not once per slider update or decoded photo.
  private static let tonalKernel = CIColorKernel(source: """
    kernel vec4 tonalEnds(__sample sample, float black, float whites, float haze) {
      vec4 c = unpremultiply(sample);
      vec3 rgb = linear_to_srgb(c.rgb);
      float luminance = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
      float dark = 1.0 - smoothstep(0.0, 0.6, luminance);
      float light = smoothstep(0.35, 1.0, luminance);
      rgb = rgb - black * 0.25 * dark + whites * 0.3 * light;
      rgb = (rgb - haze * 0.14) / (1.0 - haze * 0.2);
      c.rgb = srgb_to_linear(max(rgb, vec3(0.0)));
      return premultiply(c);
    }
    """)

  private static let curveKernel = CIColorKernel(source: """
    float curve(float x, vec4 p, float end) {
      if (x < 0.0) return x + p.x;
      if (x < 0.25) return mix(p.x, p.y, x * 4.0);
      if (x < 0.5) return mix(p.y, p.z, (x - 0.25) * 4.0);
      if (x < 0.75) return mix(p.z, p.w, (x - 0.5) * 4.0);
      if (x < 1.0) return mix(p.w, end, (x - 0.75) * 4.0);
      return x + end - 1.0;
    }
    kernel vec4 toneCurves(__sample sample, vec4 master, vec4 red, vec4 green,
      vec4 blue, vec4 ends) {
      vec4 c = unpremultiply(sample);
      vec3 rgb = linear_to_srgb(c.rgb);
      rgb = vec3(curve(rgb.r, master, ends.x), curve(rgb.g, master, ends.x),
        curve(rgb.b, master, ends.x));
      rgb = vec3(curve(rgb.r, red, ends.y), curve(rgb.g, green, ends.z),
        curve(rgb.b, blue, ends.w));
      c.rgb = srgb_to_linear(rgb);
      return premultiply(c);
    }
    """)

  private static let mixerKernel = CIColorKernel(source: """
    float bandWeight(float hue, float center, float width) {
      float distance = abs(hue - center);
      distance = min(distance, 1.0 - distance);
      return 1.0 - smoothstep(0.0, width, distance);
    }
    kernel vec4 colorMixer(__sample sample, vec3 red, vec3 orange, vec3 yellow,
      vec3 green, vec3 aqua, vec3 blue, vec3 purple, vec3 magenta) {
      vec4 c = unpremultiply(sample);
      vec3 rgb = linear_to_srgb(c.rgb);
      float headroom = max(1.0, max(rgb.r, max(rgb.g, rgb.b)));
      vec3 base = clamp(rgb / headroom, 0.0, 1.0);
      float hi = max(base.r, max(base.g, base.b));
      float lo = min(base.r, min(base.g, base.b));
      float delta = hi - lo;
      if (delta < 0.00001) return sample;
      float light = (hi + lo) * 0.5;
      float sat = delta / max(0.00001, 1.0 - abs(2.0 * light - 1.0));
      float hue = 0.0;
      if (hi == base.r) hue = (base.g - base.b) / delta;
      else if (hi == base.g) hue = (base.b - base.r) / delta + 2.0;
      else hue = (base.r - base.g) / delta + 4.0;
      hue = fract(hue / 6.0 + 1.0);
      vec3 change = red * bandWeight(hue, 0.0, 0.125)
        + orange * bandWeight(hue, 0.08333333, 0.08333333)
        + yellow * bandWeight(hue, 0.16666667, 0.125)
        + green * bandWeight(hue, 0.33333333, 0.16666667)
        + aqua * bandWeight(hue, 0.5, 0.16666667)
        + blue * bandWeight(hue, 0.66666667, 0.125)
        + purple * bandWeight(hue, 0.75, 0.08333333)
        + magenta * bandWeight(hue, 0.83333333, 0.125);
      hue = fract(hue + change.x + 1.0);
      sat = clamp(sat + change.y * (change.y > 0.0 ? (1.0 - sat) : sat), 0.0, 1.0);
      light = clamp(light + change.z * 0.5 * (change.z > 0.0 ? (1.0 - light) : light), 0.0, 1.0);
      vec3 wheel = clamp(abs(fract(vec3(hue) + vec3(0.0, 0.66666667, 0.33333333))
        * 6.0 - 3.0) - 1.0, 0.0, 1.0);
      vec3 result = (wheel - 0.5) * ((1.0 - abs(2.0 * light - 1.0)) * sat) + light;
      c.rgb = srgb_to_linear(result * headroom);
      return premultiply(c);
    }
    """)

  private static let filmKernel = CIColorKernel(source: """
    kernel vec4 filmLook(__sample sample, float look, float strength) {
      vec4 c = unpremultiply(sample);
      vec3 rgb = linear_to_srgb(c.rgb);
      float luminance = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
      float shadow = 1.0 - smoothstep(0.0, 0.75, luminance);
      float light = smoothstep(0.25, 1.0, luminance);
      vec3 result = rgb;
      if (look < 1.5) {
        result += vec3(-0.04, 0.035, 0.055) * shadow + vec3(0.055, 0.015, -0.045) * light;
        result = (result - 0.5) * 1.08 + 0.5;
      } else if (look < 2.5) {
        result = mix(vec3(luminance), rgb, 0.78);
        result += vec3(0.09, 0.075, 0.07) * shadow - vec3(0.03, 0.035, 0.025) * light;
      } else {
        result = rgb * vec3(0.91, 0.96, 1.05) + vec3(-0.015, 0.005, 0.045) * shadow;
        result = (result - 0.5) * 1.1 + 0.47;
      }
      c.rgb = srgb_to_linear(max(mix(rgb, result, strength), vec3(0.0)));
      return premultiply(c);
    }
    """)

  private static let alphaKernel = CIColorKernel(source: """
    kernel vec4 retainAlpha(__sample edited, __sample original) {
      vec4 c = unpremultiply(edited);
      c.a = original.a;
      return premultiply(c);
    }
    """)
}
