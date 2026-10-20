import Foundation
import Testing

@testable import ImageViewer

@Suite("실제 셀 비트맵 준비와 뷰포트 진입의 계측")
struct OverviewBitmapVisitLedgerTests {
  @Test("진입 전에 준비된 동일 셀은 새 콜백 없이 준비 완료로 기록한다")
  func retainedBitmap() {
    var ledger = OverviewBitmapVisitLedger()
    let sample = sample(ready: true)
    ledger.observe([sample], at: 10)
    ledger.observe([sample], at: 11)
    let report = ledger.report()
    #expect(report.observedVisits == 1)
    #expect(report.readyBeforeEntry == 1)
    #expect(report.readyAfterEntry == 0)
    #expect(report.unresolvedAtEnd == 0)
    #expect(report.readyLatency.maximumSeconds == 0)
  }

  @Test("진입 후 준비 지연과 준비되지 않은 채 떠난 셀을 구분한다")
  func delayedAndMissing() {
    var ledger = OverviewBitmapVisitLedger()
    let id = UUID()
    ledger.observe([sample(id: id, ready: false)], at: 10)
    ledger.observe([sample(id: id, ready: true)], at: 10.025)
    ledger.observe([], at: 11)
    ledger.observe([sample(ready: false)], at: 12)
    ledger.observe([], at: 13)
    let report = ledger.report()
    #expect(report.observedVisits == 2)
    #expect(report.readyAfterEntry == 1)
    #expect(report.leftWithoutBitmap == 1)
    #expect(abs(report.readyLatency.maximumSeconds - 0.025) < 0.000_001)
  }

  @Test("과거 인스턴스와 원본 버전은 새 셀의 준비 상태를 증명하지 않는다")
  func instanceAndSourceVersion() {
    var ledger = OverviewBitmapVisitLedger()
    let id = UUID()
    ledger.observe([sample(id: id, ready: true)], at: 1)
    ledger.observe([sample(id: id, bytes: 11, ready: false)], at: 2)
    ledger.observe([], at: 3)
    ledger.observe([sample(ready: false)], at: 4)
    let report = ledger.report()
    #expect(report.observedVisits == 3)
    #expect(report.readyBeforeEntry == 1)
    #expect(report.leftWithoutBitmap == 1)
    #expect(report.unresolvedAtEnd == 1)
  }

  @Test("State가 비워진 재등장은 과거 준비를 물려받지 않고 빈 원본은 제외한다")
  func clearedAndEmpty() {
    var ledger = OverviewBitmapVisitLedger()
    let id = UUID()
    ledger.observe([sample(id: id, ready: true)], at: 1)
    ledger.observe([sample(id: id, ready: false), sample(bytes: 0, ready: false)], at: 2)
    let report = ledger.report()
    #expect(report.observedVisits == 2)
    #expect(report.readyBeforeEntry == 1)
    #expect(report.unresolvedAtEnd == 1)
  }

  private func sample(id: UUID = UUID(), bytes: Int64 = 10, ready: Bool) -> OverviewBitmapProbeSample {
    OverviewBitmapProbeSample(instance: id, assetURL: URL(fileURLWithPath: "/fixture/frame.dng"),
      byteCount: bytes, modificationDate: Date(timeIntervalSince1970: 1),
      hasBitmap: ready, pixelWidth: ready ? 256 : 0, pixelHeight: ready ? 192 : 0)
  }
}
