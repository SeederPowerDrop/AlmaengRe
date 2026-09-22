import Foundation
import Testing

@testable import ImageViewer

@Suite("다른 앱·메모리·저장장치를 배려하는 로딩 정책")
struct AdaptiveLoadingPolicyTests {
  private let mib = 1_024 * 1_024
  private let gib: UInt64 = 1_024 * 1_024 * 1_024

  private func machine(memoryGiB: UInt64 = 16, cores: Int = 8) -> ImageResourceSnapshot {
    ImageResourceSnapshot(
      physicalMemory: memoryGiB * gib, activeProcessorCount: cores, appleSilicon: true)
  }

  @Test("기본 쾌적 모드는 16·24GB Mac 모두 전체 파이프라인에 2개 슬롯과 작은 캐시를 제공한다")
  func comfortableDefaultsLeaveRoomForOtherApps() {
    #expect(ImageLoadingMode.defaultMode == .comfortable)
    for memory in [UInt64(16), 24] {
      let limits = AdaptiveLoadingPolicy.limits(
        mode: .comfortable, snapshot: machine(memoryGiB: memory), storage: .internalSSD)
      #expect(limits.totalConcurrentLoads == 2)
      #expect(limits.renderCacheBytes + limits.thumbnailCacheBytes == 192 * mib)
      #expect(limits.visibleTaskPriority == .utility)
      #expect(limits.prefetchCount == 2)
      #expect(limits.prefetchDelayMilliseconds >= 350)
    }
  }

  @Test("모드를 낮추면 동시 작업·캐시·미리 읽기 예산이 늘지 않는다")
  func orderedModesHaveMonotonicBudgets() throws {
    let values = ImageLoadingMode.allCases.map {
      AdaptiveLoadingPolicy.limits(mode: $0, snapshot: machine(), storage: .internalSSD)
    }
    for (higher, lower) in zip(values, values.dropFirst()) {
      #expect(lower.totalConcurrentLoads <= higher.totalConcurrentLoads)
      #expect(lower.renderCacheBytes <= higher.renderCacheBytes)
      #expect(lower.thumbnailCacheBytes <= higher.thumbnailCacheBytes)
      #expect(lower.prefetchCount <= higher.prefetchCount)
      #expect(lower.interLoadDelayMilliseconds >= higher.interLoadDelayMilliseconds)
    }
    let priority = try #require(values.first)
    #expect(priority.totalConcurrentLoads == 4)
    #expect(priority.visibleTaskPriority == .userInitiated)
    #expect(priority.renderCacheBytes <= 256 * mib)
    #expect(priority.thumbnailCacheBytes <= 128 * mib)
    let slow = try #require(values.last)
    #expect(slow.totalConcurrentLoads == 1)
    #expect(slow.visibleTaskPriority == .background)
    #expect(slow.interLoadDelayMilliseconds >= 100)
    #expect(!slow.permitsSpeculation)
  }

  @Test("외장 SSD의 병렬 읽기를 줄이고 SD·네트워크·미확인 장치의 미리 읽기를 멈춘다")
  func protectsSlowerAndUnknownStorage() {
    for mode in ImageLoadingMode.allCases {
      let external = AdaptiveLoadingPolicy.limits(mode: mode, snapshot: machine(), storage: .external)
      #expect(external.totalConcurrentLoads <= 2)
      #expect(external.prefetchCount <= 1)
      #expect(external.prefetchDelayMilliseconds >= 600)
      for storage in [ImageStorageKind.removable, .network, .unknown] {
        let limits = AdaptiveLoadingPolicy.limits(mode: mode, snapshot: machine(), storage: storage)
        #expect(limits.totalConcurrentLoads == 1)
        #expect(limits.prefetchCount == 0)
        #expect(!limits.permitsSpeculation)
        #expect(limits.interLoadDelayMilliseconds >= 40)
      }
    }
  }

  @Test("최우선 모드도 CPU·발열·절전·메모리 압박에서는 한 작업씩 진행한다")
  func everyModeYieldsUnderEveryPressureSignal() {
    var lowPower = machine()
    lowPower.lowPowerMode = true
    var hot = machine()
    hot.thermal = .serious
    var busy = machine()
    busy.cpuBusyFraction = 0.8
    var warning = machine()
    warning.memoryPressure = .warning
    var inactive = machine()
    inactive.isAppActive = false

    for snapshot in [lowPower, hot, busy, warning, inactive] {
      for mode in ImageLoadingMode.allCases {
        let limits = AdaptiveLoadingPolicy.limits(mode: mode, snapshot: snapshot, storage: .internalSSD)
        #expect(limits.totalConcurrentLoads == 1)
        #expect(limits.prefetchCount == 0)
        #expect(!limits.permitsSpeculation)
        #expect(limits.visibleTaskPriority != .userInitiated)
        #expect(limits.interLoadDelayMilliseconds >= 60)
      }
    }
  }

  @Test("메모리 경고는 캐시를 1/4로 줄이고 위급 상태는 재생성 가능한 캐시를 비운다")
  func reclaimsCachesAndRestoresOnlyAfterSignalClears() {
    for mode in ImageLoadingMode.allCases {
      let initial = AdaptiveLoadingPolicy.limits(mode: mode, snapshot: machine(), storage: .internalSSD)
      var snapshot = machine()
      snapshot.memoryPressure = .warning
      let warning = AdaptiveLoadingPolicy.limits(mode: mode, snapshot: snapshot, storage: .internalSSD)
      #expect(warning.renderCacheBytes == initial.renderCacheBytes / 4)
      #expect(warning.thumbnailCacheBytes == initial.thumbnailCacheBytes / 4)

      snapshot.memoryPressure = .critical
      let critical = AdaptiveLoadingPolicy.limits(mode: mode, snapshot: snapshot, storage: .internalSSD)
      #expect(critical.renderCacheBytes == 0)
      #expect(critical.thumbnailCacheBytes == 0)
      #expect(critical.totalConcurrentLoads == 1)
      #expect(!critical.permitsSpeculation)

      snapshot.memoryPressure = .normal
      #expect(AdaptiveLoadingPolicy.limits(mode: mode, snapshot: snapshot, storage: .internalSSD) == initial)
    }
  }

  @Test("다른 앱으로 전환하면 캐시와 우선순위를 낮추고 돌아온 뒤 예산을 복원한다")
  func backgroundWorkStaysQuiet() {
    var snapshot = machine()
    let initial = AdaptiveLoadingPolicy.limits(mode: .priority, snapshot: snapshot, storage: .internalSSD)
    snapshot.isAppActive = false
    let background = AdaptiveLoadingPolicy.limits(mode: .priority, snapshot: snapshot, storage: .internalSSD)
    #expect(background.visibleTaskPriority == .background)
    #expect(background.renderCacheBytes == initial.renderCacheBytes / 4)
    #expect(background.thumbnailCacheBytes == initial.thumbnailCacheBytes / 4)
    #expect(background.totalConcurrentLoads == 1)
    #expect(!background.permitsSpeculation)
    snapshot.memoryPressure = .warning
    let pressureWhileInactive = AdaptiveLoadingPolicy.limits(
      mode: .priority, snapshot: snapshot, storage: .internalSSD)
    #expect(pressureWhileInactive.renderCacheBytes <= background.renderCacheBytes)
    snapshot.isAppActive = true
    snapshot.memoryPressure = .normal
    #expect(AdaptiveLoadingPolicy.limits(mode: .priority, snapshot: snapshot, storage: .internalSSD) == initial)
  }

  @Test("작은 메모리·적은 코어·Intel에서는 최우선 모드도 하드웨어 상한을 넘지 않는다")
  func boundsHardwareBudgetsEvenForExtremeInputs() {
    for mode in ImageLoadingMode.allCases {
      let small = AdaptiveLoadingPolicy.limits(
        mode: mode, snapshot: machine(memoryGiB: 4), storage: .internalSSD)
      #expect(small.totalConcurrentLoads == 1)
      #expect(small.renderCacheBytes <= 64 * mib)
      #expect(small.thumbnailCacheBytes <= 32 * mib)
      let fewCores = AdaptiveLoadingPolicy.limits(
        mode: mode, snapshot: machine(cores: 2), storage: .internalSSD)
      #expect(fewCores.totalConcurrentLoads == 1)
      var unknownHardware = machine(memoryGiB: 0, cores: 0)
      unknownHardware.appleSilicon = false
      let unknown = AdaptiveLoadingPolicy.limits(mode: mode, snapshot: unknownHardware, storage: .unknown)
      #expect(unknown.totalConcurrentLoads == 1)
      #expect(unknown.renderCacheBytes == 0)
      #expect(unknown.thumbnailCacheBytes == 0)
    }
    var intel = machine(memoryGiB: 128, cores: 32)
    intel.appleSilicon = false
    #expect(AdaptiveLoadingPolicy.limits(mode: .priority, snapshot: intel, storage: .internalSSD).totalConcurrentLoads == 2)
    let huge = ImageResourceSnapshot(physicalMemory: .max, activeProcessorCount: .max, appleSilicon: true)
    let capped = AdaptiveLoadingPolicy.limits(mode: .priority, snapshot: huge, storage: .internalSSD)
    #expect(capped.totalConcurrentLoads == 4)
    #expect(capped.renderCacheBytes == 256 * mib)
    #expect(capped.thumbnailCacheBytes == 128 * mib)
  }

  @Test("중간 CPU 부하는 미리 읽기부터 줄이고 더 큰 부하는 직렬 처리한다")
  func CPUContentionDegradesWithoutStarvingVisibleWork() {
    var snapshot = machine()
    snapshot.cpuBusyFraction = 0.7
    let moderate = AdaptiveLoadingPolicy.limits(mode: .priority, snapshot: snapshot, storage: .internalSSD)
    #expect(moderate.totalConcurrentLoads == 2)
    #expect(!moderate.permitsSpeculation)
    snapshot.cpuBusyFraction = 0.95
    let heavy = AdaptiveLoadingPolicy.limits(mode: .priority, snapshot: snapshot, storage: .internalSSD)
    #expect(heavy.totalConcurrentLoads == 1)
    #expect(!heavy.permitsSpeculation)
    #expect(heavy.visibleTaskPriority == .utility)
    for sample in [Double.nan, Double.infinity, -1] {
      snapshot.cpuBusyFraction = sample
      let unavailable = AdaptiveLoadingPolicy.limits(mode: .priority, snapshot: snapshot, storage: .internalSSD)
      #expect(unavailable.totalConcurrentLoads == 4)
    }
  }

  @Test("가벼운 발열에서는 미리 읽기를 줄이고 심각한 발열은 모든 모드에서 물러난다")
  func escalatingThermalStatesAreConservative() {
    var snapshot = machine()
    snapshot.thermal = .fair
    let warm = AdaptiveLoadingPolicy.limits(mode: .priority, snapshot: snapshot, storage: .internalSSD)
    #expect(warm.totalConcurrentLoads <= 2)
    #expect(warm.prefetchCount <= 1)
    for mode in ImageLoadingMode.allCases {
      snapshot.thermal = .critical
      let critical = AdaptiveLoadingPolicy.limits(mode: mode, snapshot: snapshot, storage: .internalSSD)
      #expect(critical.totalConcurrentLoads == 1)
      #expect(!critical.permitsSpeculation)
      #expect(critical.visibleTaskPriority == .background)
      #expect(critical.interLoadDelayMilliseconds >= 150)
    }
  }

  @Test("모든 모드·장치 조합에서 선읽기 플래그와 실제 예산이 일치한다")
  func neverAdvertisesSpeculationWithoutBudget() {
    for mode in ImageLoadingMode.allCases {
      for storage in [ImageStorageKind.internalSSD, .external, .removable, .network, .unknown] {
        let limits = AdaptiveLoadingPolicy.limits(mode: mode, snapshot: machine(), storage: storage)
        #expect(limits.permitsSpeculation == (limits.prefetchCount > 0))
        #expect((1...4).contains(limits.totalConcurrentLoads))
        #expect(limits.interLoadDelayMilliseconds >= 0)
      }
    }
  }
}
