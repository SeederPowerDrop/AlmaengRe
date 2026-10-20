import Foundation
import Testing

@testable import ImageViewer

@Suite("작은 몽땅보기 선읽기의 점진적 자원 사용")
struct OverviewWarmPacingPolicyTests {
  private func machine() -> ImageResourceSnapshot {
    ImageResourceSnapshot(physicalMemory: 16 * 1_024 * 1_024 * 1_024,
      activeProcessorCount: 8, appleSilicon: true, isAppActive: false,
      cpuBusyFraction: 0.1)
  }

  @Test("35%를 넘는 CPU·메모리 경고·약한 열에서는 간격을 늘려 계속 진행한다")
  func ordinaryContentionNeverStarvesCompactWork() throws {
    let snapshot = machine()
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: snapshot, storage: .internalSSD) == 300)
    for cpu in [0.35, 0.53, 0.65, 0.79, 0.85, 1.0] {
      var busy = snapshot
      busy.cpuBusyFraction = cpu
      let delay = try #require(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
        snapshot: busy, storage: .internalSSD))
      #expect(delay >= 500 && delay <= 3_000)
      busy.memoryPressure = .warning
      busy.thermal = .fair
      let warningDelay = try #require(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
        snapshot: busy, storage: .internalSSD))
      #expect(warningDelay >= 1_200 && warningDelay <= 3_000)
    }
    var unknown = snapshot
    unknown.cpuBusyFraction = nil
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: unknown, storage: .internalSSD) == 1_500)
  }

  @Test("실제 작업 시간이 길면 20~25% 단일 작업자 목표 간격을 늘리고 상한을 지킨다")
  func measuredWorkDurationDeterminesBoundedPacing() {
    let snapshot = machine()
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: snapshot, storage: .internalSSD, estimatedWorkSeconds: 0.25) == 750)
    var busy = snapshot
    busy.cpuBusyFraction = 0.8
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: busy, storage: .internalSSD, estimatedWorkSeconds: 0.25) == 1_000)
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: busy, storage: .internalSSD, estimatedWorkSeconds: 10) == 3_000)
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: snapshot, storage: .internalSSD, estimatedWorkSeconds: -.infinity) == 300)
  }

  @Test("내장 SSD의 짧은 내장 미리보기는 고정 대기를 줄이되 실측 작업 비율을 유지한다")
  func embeddedPreviewUsesMeasuredWorkInsteadOfSourceMinimum() {
    let snapshot = machine()
    let fast = OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: snapshot, storage: .internalSSD, estimatedWorkSeconds: 0.005,
      workKind: .embeddedPreview)
    #expect(fast == 60)
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: snapshot, storage: .internalSSD, estimatedWorkSeconds: 0.25,
      workKind: .embeddedPreview) == 750)

    var busy = snapshot
    busy.cpuBusyFraction = 0.5
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: busy, storage: .internalSSD, workKind: .embeddedPreview) == 150)
    busy.cpuBusyFraction = 0.75
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: busy, storage: .internalSSD, estimatedWorkSeconds: 0.25,
      workKind: .embeddedPreview) == 1_000)
    busy.cpuBusyFraction = 0.9
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: busy, storage: .internalSSD, workKind: .embeddedPreview) == 500)

    var active = snapshot
    active.isAppActive = true
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: active, storage: .external, workKind: .embeddedPreview) == 300)
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .normal,
      snapshot: snapshot, storage: .internalSSD, workKind: .embeddedPreview) == 900)
    var warning = snapshot
    warning.memoryPressure = .warning
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: warning, storage: .internalSSD, workKind: .embeddedPreview) == 300)
    warning.thermal = .fair
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: warning, storage: .internalSSD, workKind: .embeddedPreview) == 300)
  }

  @Test("메모리 경고의 작은 내장 미리보기는 CPU 경합과 실측 20% 작업 비율을 지킨다")
  func warningEmbeddedPreparationRetainsContentionAndMeasuredDuty() {
    var warning = machine()
    warning.memoryPressure = .warning
    for (cpu, expected) in [(0.1, 300), (0.5, 300), (0.65, 500), (0.85, 500)] {
      warning.cpuBusyFraction = cpu
      #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
        snapshot: warning, storage: .internalSSD, workKind: .embeddedPreview) == expected)
    }
    warning.cpuBusyFraction = nil
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: warning, storage: .internalSSD, workKind: .embeddedPreview) == 1_500)

    warning.cpuBusyFraction = 0.1
    for (work, expected) in [(0.073, 300), (0.125, 500), (0.25, 1_000), (0.75, 3_000)] {
      #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
        snapshot: warning, storage: .internalSSD, estimatedWorkSeconds: work,
        workKind: .embeddedPreview) == expected)
    }
  }

  @Test("높은 전체 CPU에서도 작은 내장 미리보기는 실측 20% 간격을 지키고 원본·일반 모드 제한은 유지한다")
  func highCPUEmbeddedGapRetainsMeasuredDutyAndSourceProtection() {
    var busy = machine()
    busy.cpuBusyFraction = 0.99
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: busy, storage: .internalSSD, estimatedWorkSeconds: 0.005,
      workKind: .embeddedPreview) == 500)
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: busy, storage: .internalSSD, estimatedWorkSeconds: 0.25,
      workKind: .embeddedPreview) == 1_000)
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .normal,
      snapshot: busy, storage: .internalSSD, workKind: .embeddedPreview) == 1_200)
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: busy, storage: .internalSSD, workKind: .sourceFallback) == 1_200)
    busy.thermal = .fair
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: busy, storage: .internalSSD, workKind: .embeddedPreview) == 500)
  }

  @Test("약한 열의 작은 내장 미리보기는 실측 간격을 유지하고 원본·일반 모드 및 심한 열을 구분한다")
  func fairThermalEmbeddedGapRetainsMeasuredDutyAndProtection() {
    var warm = machine()
    warm.thermal = .fair
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: warm, storage: .internalSSD, estimatedWorkSeconds: 0.005,
      workKind: .embeddedPreview) == 300)
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: warm, storage: .internalSSD, estimatedWorkSeconds: 0.25,
      workKind: .embeddedPreview) == 1_000)
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .normal,
      snapshot: warm, storage: .internalSSD, workKind: .embeddedPreview) == 1_200)
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: warm, storage: .internalSSD, workKind: .sourceFallback) == 1_200)
    warm.cpuBusyFraction = nil
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: warm, storage: .internalSSD, workKind: .embeddedPreview) == 1_500)
    warm.cpuBusyFraction = 0.1
    warm.memoryPressure = .warning
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: warm, storage: .internalSSD, workKind: .embeddedPreview) == 300)
    for cpu in [0.65, 0.85, 0.99] {
      warm.cpuBusyFraction = cpu
      #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
        snapshot: warm, storage: .internalSSD, workKind: .embeddedPreview) == 500)
    }
    warm.thermal = .serious
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: warm, storage: .internalSSD, workKind: .embeddedPreview) == nil)
  }

  @Test("경고 대기 단축은 내부 SSD의 내장 미리보기에만 적용하고 원본·일반 모드 제한을 유지한다")
  func warningEmbeddedGapDoesNotRelaxSourceOrModeProtection() {
    var warning = machine()
    warning.memoryPressure = .warning
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: warning, storage: .internalSSD, workKind: .sourceFallback) == 900)
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .normal,
      snapshot: warning, storage: .internalSSD, workKind: .embeddedPreview) == 900)
    warning.isAppActive = true
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: warning, storage: .external, workKind: .embeddedPreview) == 900)
    warning.thermal = .fair
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: warning, storage: .internalSSD, workKind: .embeddedPreview) == 300)
    warning.memoryPressure = .normal
    warning.thermal = .nominal
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
      snapshot: warning, storage: .internalSSD, workKind: .embeddedPreview) == 60)
  }

  @Test("위급 메모리·심한 열·저전력·느림 및 지원하지 않는 배경 저장장치는 중단한다")
  func genuineProtectionConditionsStillPause() {
    let snapshot = machine()
    var critical = snapshot
    critical.memoryPressure = .critical
    var serious = snapshot
    serious.thermal = .serious
    var hot = snapshot
    hot.thermal = .critical
    var lowPower = snapshot
    lowPower.lowPowerMode = true
    for protected in [critical, serious, hot, lowPower] {
      for kind in [OverviewWarmWorkKind.embeddedPreview, .sourceFallback] {
        #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
          snapshot: protected, storage: .internalSSD, workKind: kind) == nil)
      }
    }
    for storage in [ImageStorageKind.external, .removable, .network, .unknown] {
      #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .comfortable,
        snapshot: snapshot, storage: storage) == nil)
    }
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .slow,
      snapshot: snapshot, storage: .internalSSD) == nil)
    #expect(OverviewWarmPacingPolicy.delayMilliseconds(mode: .normal,
      snapshot: snapshot, storage: .internalSSD) == 900)
  }

  @Test("실행 시간은 다음 선읽기에 반영하지만 표시 작업과 RAM 제한은 바꾸지 않는다")
  func governorLearnsWorkDurationWithoutChangingVisibleLimits() async throws {
    let snapshot = machine()
    let governor = ImageResourceGovernor(snapshot: snapshot, storageOverride: .internalSSD,
      monitorsMemoryPressure: false)
    let url = URL(fileURLWithPath: "/private/adaptive-overview.dng")
    let before = await governor.limits(for: url)
    #expect(await governor.overviewWarmDelay(for: url) == 300)
    await governor.recordOverviewWarmDuration(0.5, for: url)
    #expect(await governor.overviewWarmDelay(for: url) == 1_500)
    await governor.recordOverviewWarmDuration(0.1, for: url)
    let decayed = try #require(await governor.overviewWarmDelay(for: url))
    #expect(decayed >= 300 && decayed < 1_500)
    #expect(await governor.limits(for: url) == before)
    var warning = snapshot
    warning.memoryPressure = .warning
    warning.cpuBusyFraction = 0.79
    await governor.update(warning)
    #expect(await governor.overviewWarmDelay(for: url) != nil)
    #expect(await governor.limits(for: url).thumbnailCacheBytes == before.thumbnailCacheBytes)
    var critical = warning
    critical.memoryPressure = .critical
    await governor.update(critical)
    #expect(await governor.overviewWarmDelay(for: url) == nil)
    #expect(await governor.limits(for: url).thumbnailCacheBytes == 0)
  }

  @Test("비싼 RAW 보완과 싼 내장 미리보기의 작업 시간은 서로 덮어쓰지 않는다")
  func embeddedAndSourceDurationEstimatesStaySeparate() async throws {
    let governor = ImageResourceGovernor(snapshot: machine(), storageOverride: .internalSSD,
      monitorsMemoryPressure: false)
    let url = URL(fileURLWithPath: "/private/separate-overview-warm-work.dng")
    let limits = await governor.limits(for: url)
    await governor.recordOverviewWarmDuration(0.5, for: url)
    #expect(await governor.overviewWarmDelay(for: url) == 1_500)
    #expect(await governor.overviewWarmDelay(for: url, workKind: .embeddedPreview) == 60)
    await governor.recordOverviewWarmDuration(0.125, for: url, workKind: .embeddedPreview)
    #expect(await governor.overviewWarmDelay(for: url, workKind: .embeddedPreview) == 375)
    #expect(await governor.overviewWarmDelay(for: url) == 1_500)
    #expect(await governor.limits(for: url) == limits)
  }

  @Test("경고 중 내장 미리보기의 실측 대기는 원본 작업 추정이나 표시·캐시 예산을 바꾸지 않는다")
  func warningEmbeddedBudgetLeavesSourceAndVisibleLimitsIntact() async {
    var warning = machine()
    warning.memoryPressure = .warning
    let governor = ImageResourceGovernor(snapshot: warning, storageOverride: .internalSSD,
      monitorsMemoryPressure: false)
    let url = URL(fileURLWithPath: "/private/warning-embedded-overview.dng")
    let limits = await governor.limits(for: url)
    #expect(await governor.overviewWarmDelay(for: url, workKind: .embeddedPreview) == 300)
    #expect(await governor.overviewWarmDelay(for: url, workKind: .sourceFallback) == 900)
    await governor.recordOverviewWarmDuration(0.125, for: url, workKind: .embeddedPreview)
    #expect(await governor.overviewWarmDelay(for: url, workKind: .embeddedPreview) == 500)
    #expect(await governor.overviewWarmDelay(for: url, workKind: .sourceFallback) == 900)
    #expect(await governor.limits(for: url) == limits)
  }

  @Test("전용 선읽기 대기는 중복 원본 간격만 생략하고 위급 상태의 실행을 허용하지 않는다")
  func dedicatedPacingRetainsIdleAdmissionProtection() async {
    #expect(ImageResourceWorkload.source.pacingDelayMilliseconds(150) == 150)
    #expect(ImageResourceWorkload.overviewPreview.pacingDelayMilliseconds(150) == 0)
    var critical = machine()
    critical.memoryPressure = .critical
    let governor = ImageResourceGovernor(snapshot: critical, storageOverride: .internalSSD,
      monitorsMemoryPressure: false)
    do {
      _ = try await governor.value(for: ImageResourceWorkKey(namespace: UUID(), key: 1),
        url: URL(fileURLWithPath: "/private/protected-overview.dng"),
        priority: .idleThumbnail, workload: .overviewPreview) { _ in
          Issue.record("A protected overview job must not start")
          return true
        }
      Issue.record("Expected CancellationError")
    } catch is CancellationError {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(await governor.stateSnapshot().runningCount == 0)
    #expect(await governor.stateSnapshot().queuedCount == 0)
  }
}
