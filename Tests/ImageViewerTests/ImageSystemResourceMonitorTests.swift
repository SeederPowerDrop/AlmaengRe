import Foundation
import Testing

@testable import ImageViewer

@Suite("시스템 자원 감지·저장장치 분류")
struct ImageSystemResourceMonitorTests {
  @Test("모니터가 초기 비활성 상태를 전달하고 타이머나 알림 때문에 남지 않는다")
  func monitorDeliversInitialStateAndReleases() async throws {
    let probe = ImageResourceSnapshotProbe()
    var monitor: ImageSystemResourceMonitor? = ImageSystemResourceMonitor(isAppActive: false) {
      snapshot in Task { await probe.record(snapshot) }
    }
    weak let weakMonitor = monitor
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await probe.first == nil && clock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let initial = try #require(await probe.first)
    #expect(!initial.isAppActive)
    #expect(initial.physicalMemory > 0)
    #expect(initial.activeProcessorCount > 0)
    monitor = nil
    while weakMonitor != nil && clock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(weakMonitor == nil)
  }

  @Test("CPU 부하는 두 번 높아야 제한하고 세 번 회복한 뒤에 제한을 푼다")
  func cpuContentionUsesHysteresis() {
    var filter = ImageCPUActivityFilter()
    #expect(filter.update(nil) == nil)
    #expect(filter.update(0.95) == 0.79)
    #expect(!filter.isBusy)
    #expect(filter.update(0.85) == 0.85)
    #expect(filter.isBusy)
    #expect(filter.update(0.4) == 0.8)
    #expect(filter.update(0.5) == 0.8)
    #expect(filter.update(0.3) == 0.3)
    #expect(!filter.isBusy)
  }

  @Test("짧은 CPU 급증은 심한 제한을 걸지 않고 중간 부하는 회복 계수를 초기화한다")
  func transientLoadAndFailedSamplesDoNotOscillate() {
    var filter = ImageCPUActivityFilter()
    #expect(filter.update(0.9) == 0.79)
    #expect(filter.update(0.4) == 0.4)
    #expect(filter.update(0.9) == 0.79)
    #expect(filter.update(0.9) == 0.9)
    #expect(filter.update(0.4) == 0.8)
    #expect(filter.update(0.7) == 0.8)
    #expect(filter.update(0.4) == 0.8)
    #expect(filter.update(.nan) == 0.8)
    #expect(filter.update(0.4) == 0.8)
    #expect(filter.update(0.4) == 0.8)
    #expect(filter.update(0.4) == 0.4)
  }

  @Test("시스템 CPU 사용량은 idle과 nice를 반영하고 카운터 순환을 처리한다")
  func cpuTicksHandleWrapAndEmptyIntervals() throws {
    let start = ImageCPUTicks(user: .max - 9, system: 20, idle: 40, nice: 10)
    let end = ImageCPUTicks(user: 10, system: 30, idle: 100, nice: 20)
    #expect(try #require(end.busyFraction(since: start)) == 0.4)
    #expect(start.busyFraction(since: start) == nil)
  }

  @Test("외장 SSD와 SD 카드를 구분하고 알 수 없는 이동식 장치는 보수적으로 처리한다")
  func removableMediaTakesPrecedenceOverSolidState() {
    #expect(ImageStorageProperties(
      isInternal: true, isLocal: true, isRemovable: false, isEjectable: false,
      isSolidState: true).storageKind == .internalSSD)
    #expect(ImageStorageProperties(
      isInternal: false, isLocal: true, isRemovable: false, isEjectable: true,
      isSolidState: true).storageKind == .external)
    #expect(ImageStorageProperties(
      isInternal: false, isLocal: true, isRemovable: true, isEjectable: true,
      isSolidState: true).storageKind == .removable)
    #expect(ImageStorageProperties(
      isInternal: true, isLocal: true, isRemovable: false, isEjectable: false,
      isSolidState: true, physicalInterconnect: "Secure Digital").storageKind == .removable)
    #expect(ImageStorageProperties(
      isInternal: false, isLocal: true, isRemovable: false, isEjectable: true
    ).storageKind == .removable)
    #expect(ImageStorageProperties().storageKind == .unknown)
    #expect(ImageStorageProperties(
      isInternal: false, isLocal: true, isRemovable: false, isEjectable: false
    ).storageKind == .unknown)
    #expect(ImageStorageProperties(
      isInternal: true, isLocal: true, isSolidState: true
    ).storageKind == .unknown)
    #expect(ImageStorageProperties(
      isInternal: false, isLocal: false, isRemovable: true, isSolidState: true
    ).storageKind == .network)
  }

  @Test("파티션 값이 전체 디스크의 이동식 정보나 SD 프로토콜을 덮어쓰지 않는다")
  func wholeDeviceAndSDFlagsRemainConservative() {
    var device = ImageStorageProperties(
      isInternal: false, isLocal: true, isRemovable: false, isEjectable: false,
      isSolidState: true, physicalInterconnect: "USB")
    device.mergeDeviceFlags(isRemovable: true, isEjectable: true)
    #expect(device.storageKind == .removable)
    device.mergeDeviceFlags(isInternal: true, isRemovable: false, isEjectable: false)
    #expect(device.isInternal == false)
    #expect(device.isRemovable == true)
    #expect(device.isEjectable == true)
    device.mergeDeviceFlags(physicalInterconnect: "Secure Digital")
    device.mergeDeviceFlags(physicalInterconnect: "USB")
    #expect(device.physicalInterconnect == "Secure Digital")
    device.mergeMediumType("Rotational")
    device.mergeMediumType("Solid State")
    #expect(device.isSolidState == false)
  }

  @Test("네트워크 URL은 로컬 볼륨을 조회하지 않는다")
  func classifiesNetworkURL() async throws {
    let classifier = ImageStorageClassifier()
    let url = try #require(URL(string: "smb://example.invalid/photos/image.jpg"))
    #expect(await classifier.storageKind(for: url) == .network)
  }
}

private actor ImageResourceSnapshotProbe {
  private(set) var first: ImageResourceSnapshot?

  func record(_ snapshot: ImageResourceSnapshot) {
    if first == nil { first = snapshot }
  }
}
