import Foundation

/// Cheap, already-embedded pixels and a possible full-source fallback have
/// separate duration estimates. An expensive RAW must not delay every following
/// embedded preview, and a cheap preview must not under-pace a full decode.
enum OverviewWarmWorkKind: Hashable, Sendable {
  case embeddedPreview
  case sourceFallback
}

/// Pacing targets a 20–25% duty cycle of one serial worker, using observed
/// CPU cost for embedded work and elapsed native work for source fallbacks.
/// It is not a process CPU reservation or hard cap.
enum OverviewWarmPacingPolicy {
  static func delayMilliseconds(mode: ImageLoadingMode, snapshot: ImageResourceSnapshot,
    storage: ImageStorageKind, estimatedWorkSeconds: Double = 0,
    workKind: OverviewWarmWorkKind = .sourceFallback) -> Int? {
    guard mode != .slow, !snapshot.lowPowerMode, snapshot.memoryPressure != .critical,
      snapshot.thermal == .nominal || snapshot.thermal == .fair else { return nil }
    guard storage == .internalSSD || (snapshot.isAppActive && storage == .external) else { return nil }

    // Embedded-only work cannot fall through to a full decode. Keep its fixed
    // gap small on an internal SSD; observed costly work still raises the gap.
    let isEmbedded = workKind == .embeddedPreview && storage == .internalSSD
    let cpu = snapshot.cpuBusyFraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    var minimumDelay = isEmbedded ? 60 : 300
    var duty = 0.25
    if let cpu {
      if cpu >= 0.85 {
        minimumDelay = isEmbedded && mode == .comfortable ? 500 : 1_200
        duty = 0.20
      } else if cpu >= 0.65 {
        minimumDelay = isEmbedded ? 500 : 700
        duty = 0.20
      } else if cpu >= 0.35 {
        minimumDelay = isEmbedded ? 150 : 500
      }
    } else {
      // An unavailable sample must not permanently starve an open folder.
      minimumDelay = 1_500
      duty = 0.20
    }
    if snapshot.memoryPressure == .warning {
      // Embedded-only preparation writes one small bitmap before admitting the
      // next job and retains no RAM-cache entry. Keep its warning gap distinct
      // from a possible full-source decode, with the stricter measured duty.
      minimumDelay = max(minimumDelay, isEmbedded ? 300 : 900)
      duty = 0.20
    }
    if snapshot.thermal == .fair {
      minimumDelay = max(minimumDelay, isEmbedded && mode == .comfortable ? 300 : 1_200)
      duty = 0.20
    }
    if mode == .normal {
      minimumDelay = max(minimumDelay, 900)
      duty = 0.20
    }
    let work = estimatedWorkSeconds.isFinite ? min(10, max(0, estimatedWorkSeconds)) : 0
    let dutyDelay = work * (1 / duty - 1) * 1_000
    return Int(ceil(min(3_000, max(Double(minimumDelay), dutyDelay))))
  }
}
