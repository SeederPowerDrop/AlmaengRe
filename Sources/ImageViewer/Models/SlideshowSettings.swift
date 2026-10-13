import Foundation

/// 전자 앨범의 시간과 끝 처리 규칙. UI·저장값·타이머가 같은 범위를 사용합니다.
enum SlideshowSettings {
  static let defaultInterval: TimeInterval = 5
  static let intervalRange: ClosedRange<TimeInterval> = 1...300
  static let presets: [TimeInterval] = [1, 3, 5, 10, 15, 30, 60, 300]

  static func normalized(_ interval: TimeInterval) -> TimeInterval {
    guard interval.isFinite else { return defaultInterval }
    return min(intervalRange.upperBound, max(intervalRange.lowerBound, interval.rounded()))
  }

  static func nextIndex(after index: Int, count: Int, repeats: Bool) -> Int? {
    guard count > 0, (0..<count).contains(index) else { return nil }
    if index + 1 < count { return index + 1 }
    return repeats ? 0 : nil
  }
}

/// 재생 중에만 화면의 자동 잠자기를 막고, 일시정지/종료 시 반드시 해제합니다.
/// 시스템 잠자기·화면 잠금·사용자의 직접 잠자기 명령을 막지는 않습니다.
final class SlideshowDisplayActivity {
  private let token: NSObjectProtocol

  init() {
    token = ProcessInfo.processInfo.beginActivity(
      options: [.idleDisplaySleepDisabled], reason: "Image viewer photo album")
  }

  deinit { ProcessInfo.processInfo.endActivity(token) }
}
