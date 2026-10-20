import Testing

@testable import ImageViewer

@Suite("릴리스 진단의 명시적 발열 시작 조건")
struct OverviewBenchmarkThermalTargetTests {
  @Test("옵션이 없으면 기존 nominal 조건을 유지한다")
  func defaultIsNominal() {
    #expect(OverviewBenchmarkThermalTarget(environmentValue: nil) == .nominal)
  }

  @Test("nominal과 fair만 명시적으로 선택할 수 있다")
  func explicitSupportedTargets() {
    #expect(OverviewBenchmarkThermalTarget(environmentValue: "nominal") == .nominal)
    #expect(OverviewBenchmarkThermalTarget(environmentValue: "fair") == .fair)
    #expect(OverviewBenchmarkThermalTarget.nominal.rawValue == 0)
    #expect(OverviewBenchmarkThermalTarget.fair.rawValue == 1)
  }

  @Test("잘못된 값은 기본 조건으로 숨기지 않고 거절한다",
    arguments: ["", "serious", "critical", "0", "1", "2", "Fair", " fair", "nominal "])
  func invalidValuesAreRejected(_ value: String) {
    #expect(OverviewBenchmarkThermalTarget(environmentValue: value) == nil)
  }

  @Test("각 조건은 정확히 같은 발열 단계만 허용하고 serious와 critical은 거절한다")
  func exactLevelMatching() {
    for level in -1...4 {
      #expect(OverviewBenchmarkThermalTarget.nominal.accepts(level: level) == (level == 0))
      #expect(OverviewBenchmarkThermalTarget.fair.accepts(level: level) == (level == 1))
    }
  }

  @Test("기존 nominal 실패 단계는 유지하고 fair 실패 단계는 구분한다")
  func phaseNamesPreserveNominalEvidence() {
    #expect(OverviewBenchmarkThermalTarget.nominal.timeoutFailurePhase
      == "comparable_native_idle_nominal_start_timeout")
    #expect(OverviewBenchmarkThermalTarget.fair.timeoutFailurePhase
      == "comparable_native_idle_fair_start_timeout")
    #expect(OverviewBenchmarkThermalTarget.nominal.progressStage
      == "waiting_comparable_native_idle_nominal")
    #expect(OverviewBenchmarkThermalTarget.fair.progressStage
      == "waiting_comparable_native_idle_fair")
  }
}
