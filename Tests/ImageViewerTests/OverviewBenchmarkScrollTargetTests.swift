import AppKit
import Testing

@testable import ImageViewer

@Suite("몽땅보기 릴리스 진단의 실제 그리드 스크롤 선택", .serialized)
@MainActor
struct OverviewBenchmarkScrollTargetTests {
  @Test("더 긴 220pt 사이드바 문서가 있어도 진단 마커가 있는 넓은 그리드를 선택한다")
  func markedGridWinsOverTallerSidebar() throws {
    let (root, sidebar, grid) = fixture()
    let marker = addMarker(to: grid)
    try #require(marker.enclosingScrollView === grid)
    try #require((sidebar.documentView?.bounds.height ?? 0) > (grid.documentView?.bounds.height ?? 0))
    #expect(OverviewBenchmarkScrollTarget.find(in: root) === grid)
    #expect(OverviewBenchmarkScrollTarget.hasOverviewViewportDimensions(grid, in: root))
    #expect(!OverviewBenchmarkScrollTarget.hasOverviewViewportDimensions(sidebar, in: root))
  }

  @Test("마커가 없거나 둘 이상이면 문서 높이 추측으로 다른 패널을 선택하지 않는다")
  func absentOrAmbiguousMarkerIsRejected() {
    let (root, sidebar, grid) = fixture()
    #expect(OverviewBenchmarkScrollTarget.find(in: root) == nil)
    addMarker(to: sidebar)
    addMarker(to: grid)
    #expect(OverviewBenchmarkScrollTarget.find(in: root) == nil)
  }

  @Test("잘못 표시된 좁은 패널은 실제 뷰포트 폭 가드에서 거부한다")
  func narrowMarkedPanelFailsWidthGuard() {
    let (root, sidebar, _) = fixture()
    addMarker(to: sidebar)
    #expect(OverviewBenchmarkScrollTarget.find(in: root) === sidebar)
    #expect(!OverviewBenchmarkScrollTarget.hasOverviewViewportDimensions(sidebar, in: root))
    sidebar.setFrameSize(NSSize(width: root.bounds.width * 0.5, height: 729))
    sidebar.tile()
    #expect(!OverviewBenchmarkScrollTarget.hasOverviewViewportDimensions(sidebar, in: root),
      "The marked viewport must be wider than half the root, not merely equal")
  }

  @Test("숨겨진 마커나 그리드와 스크롤되지 않는 문서는 선택하지 않는다")
  func hiddenAndNonScrollingTargetsAreRejected() throws {
    let (root, _, grid) = fixture()
    let marker = addMarker(to: grid)
    marker.isHidden = true
    #expect(OverviewBenchmarkScrollTarget.find(in: root) == nil)
    marker.isHidden = false
    grid.isHidden = true
    #expect(OverviewBenchmarkScrollTarget.find(in: root) == nil)
    grid.isHidden = false
    let document = try #require(grid.documentView)
    document.setFrameSize(NSSize(width: grid.contentView.bounds.width, height: 100))
    #expect(OverviewBenchmarkScrollTarget.find(in: root) == nil)
  }

  private func fixture() -> (root: NSView, sidebar: NSScrollView, grid: NSScrollView) {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 1_728, height: 900))
    let sidebar = scroll(frame: NSRect(x: 0, y: 0, width: 220, height: 729), documentHeight: 51_350)
    let grid = scroll(frame: NSRect(x: 228, y: 0, width: 1_500, height: 800), documentHeight: 38_000)
    root.addSubview(sidebar)
    root.addSubview(grid)
    return (root, sidebar, grid)
  }

  private func scroll(frame: NSRect, documentHeight: CGFloat) -> NSScrollView {
    let scroll = NSScrollView(frame: frame)
    scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: frame.width, height: documentHeight))
    scroll.tile()
    return scroll
  }

  @discardableResult
  private func addMarker(to scroll: NSScrollView) -> NSView {
    let marker = NSView(frame: .zero)
    marker.identifier = OverviewBenchmarkScrollTarget.markerIdentifier
    scroll.documentView?.addSubview(marker)
    return marker
  }
}
