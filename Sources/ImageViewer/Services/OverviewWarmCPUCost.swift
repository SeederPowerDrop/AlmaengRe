import Darwin
import Foundation

/// Embedded-only preparation has its own CPU estimate. Executor and disk waits
/// must not be learned as CPU work and then repeated as extra pacing delay.
enum OverviewWarmCPUCost {
  static func processCPUSeconds() -> Double? {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    let seconds = user + system
    return seconds.isFinite && seconds >= 0 ? seconds : nil
  }

  static func embeddedCostSeconds(wallSeconds: Double,
    cpuBefore: Double?, cpuAfter: Double?) -> Double {
    guard let cpuBefore, let cpuAfter,
      cpuBefore.isFinite, cpuAfter.isFinite,
      cpuBefore >= 0, cpuAfter >= cpuBefore else { return wallSeconds }
    // Include concurrent work in this process conservatively. Parallel CPU time
    // can exceed wall time; this is neither a per-job nor a whole-machine meter.
    return cpuAfter - cpuBefore
  }
}
