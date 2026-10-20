import Foundation
import Testing

@testable import ImageViewer

@Suite("내장 미리보기의 CPU 작업 비용")
struct OverviewWarmCPUCostTests {
  @Test("실행 대기는 CPU로 중복 계산하지 않고 병렬 CPU 비용은 줄이지 않는다")
  func elapsedWaitingIsExcludedButParallelCPUIsPreserved() {
    #expect(abs(OverviewWarmCPUCost.embeddedCostSeconds(wallSeconds: 3,
      cpuBefore: 10, cpuAfter: 10.05) - 0.05) < 0.000_000_001)
    #expect(OverviewWarmCPUCost.embeddedCostSeconds(wallSeconds: 0.5,
      cpuBefore: 10, cpuAfter: 11.5) == 1.5)
    #expect(OverviewWarmCPUCost.embeddedCostSeconds(wallSeconds: 3,
      cpuBefore: 10, cpuAfter: 10) == 0)
  }

  @Test("CPU 계수를 읽지 못하거나 값이 무효·역행하면 기존 경과시간을 사용한다")
  func unavailableOrInvalidCountersFallBackToElapsedTime() {
    let cases: [(Double?, Double?)] = [
      (nil, 10), (10, nil), (nil, nil),
      (Double.nan, 10), (10, Double.nan), (Double.infinity, 10), (10, Double.infinity),
      (-Double.infinity, 10), (10, -Double.infinity), (-1, 10), (10, -1), (11, 10),
    ]
    for (before, after) in cases {
      #expect(OverviewWarmCPUCost.embeddedCostSeconds(wallSeconds: 3,
        cpuBefore: before, cpuAfter: after) == 3)
    }
  }

  @Test("실제 프로세스 CPU 계수는 유한하고 음수가 아니며 역행하지 않는다")
  func realProcessCounterIsNonnegativeAndMonotonic() throws {
    let before = try #require(OverviewWarmCPUCost.processCPUSeconds())
    let after = try #require(OverviewWarmCPUCost.processCPUSeconds())
    #expect(before.isFinite && before >= 0)
    #expect(after.isFinite && after >= before)
  }
}
