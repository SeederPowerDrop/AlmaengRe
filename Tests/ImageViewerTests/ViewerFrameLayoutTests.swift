import CoreGraphics
import Foundation
import Testing

@testable import ImageViewer

@Suite("다중보기 프레임 배치와 크기")
struct ViewerFrameLayoutTests {
  @Test("네 장 기본 배치는 넓은 창에서도 2×2이다")
  func fourFramesUseTwoByTwo() throws {
    let configuration = ViewerFrameLayoutConfiguration(count: 4)
    #expect(configuration.rows.map(\.slots) == [[0, 1], [2, 3]])
    for size in [CGSize(width: 3_500, height: 800), CGSize(width: 700, height: 1_200)] {
      let frames = configuration.geometry(in: size).frames
      #expect(frames.count == 4)
      #expect(frames[0].rect.minY == frames[1].rect.minY)
      #expect(frames[2].rect.minY == frames[3].rect.minY)
      #expect(frames[2].rect.minY > frames[0].rect.maxY)
      #expect(frames[0].rect.width == frames[1].rect.width)
    }
  }

  @Test("가로 한 줄·세로 한 줄·직접 고른 열 수를 지원한다")
  func presets() {
    #expect(ViewerFrameLayoutConfiguration(count: 4, preset: .horizontal).rows.map(\.slots) == [[0, 1, 2, 3]])
    #expect(ViewerFrameLayoutConfiguration(count: 4, preset: .vertical).rows.map(\.slots) == [[0], [1], [2], [3]])
    #expect(ViewerFrameLayoutConfiguration(count: 7, preset: .customColumns, columns: 3).rows.map(\.slots)
      == [[0, 1, 2], [3, 4, 5], [6]])
    #expect(ViewerFrameLayoutConfiguration(count: 10).rows.map { $0.slots.count } == [4, 3, 3])
    #expect(ViewerFrameLayoutConfiguration(count: 0).rows.isEmpty)
    #expect(ViewerFrameLayoutConfiguration(count: -1).rows.isEmpty)
    #expect(ViewerFrameLayoutConfiguration(count: 100).count == 10)
  }

  @Test("남은 행의 프레임도 창의 가로 공간을 채운다", arguments: [3, 5, 7, 8, 10])
  func lastRowFillsAvailableWidth(count: Int) throws {
    let configuration = ViewerFrameLayoutConfiguration(count: count)
    let geometry = configuration.geometry(in: CGSize(width: 1_200, height: 800))
    for row in configuration.rows {
      let first = try #require(geometry.frames.first { $0.slot == row.slots.first })
      let last = try #require(geometry.frames.first { $0.slot == row.slots.last })
      #expect(abs(first.rect.minX - 3) < 0.001)
      #expect(abs(last.rect.maxX - 1_197) < 0.001)
    }
  }

  @Test("좁거나 아주 작은 창에서도 프레임은 겹치거나 화면 밖으로 나가지 않는다",
    arguments: Array(1...10), ViewerFrameLayoutPreset.allCases)
  func geometryStaysWithinBounds(count: Int, preset: ViewerFrameLayoutPreset) {
    var configuration = ViewerFrameLayoutConfiguration(count: count, preset: preset, columns: 3)
    configuration.heights = configuration.rows.indices.map { pow(10, Double($0)) }
    for index in configuration.rows.indices {
      configuration.rows[index].widths = configuration.rows[index].slots.indices.map { pow(10, Double($0)) }
    }
    for size in [CGSize.zero, CGSize(width: 1, height: 2), CGSize(width: 10, height: 9),
      CGSize(width: 320, height: 240), CGSize(width: 710, height: 600), CGSize(width: 2_400, height: 900)] {
      let geometry = configuration.geometry(in: size)
      #expect(geometry.frames.count == count)
      #expect(Set(geometry.frames.map(\.slot)) == Set(0..<count))
      #expect(Set(geometry.dividers.map(\.id)).count == geometry.dividers.count)
      for frame in geometry.frames {
        let rect = frame.rect
        #expect(rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite)
        #expect(rect.minX >= 0 && rect.minY >= 0 && rect.width >= 0 && rect.height >= 0)
        #expect(rect.maxX <= size.width + 0.000_1 && rect.maxY <= size.height + 0.000_1)
        for other in geometry.frames where frame.slot != other.slot {
          let intersection = rect.intersection(other.rect)
          #expect(intersection.isNull || intersection.width == 0 || intersection.height == 0)
        }
      }
      for divider in geometry.dividers {
        #expect(divider.rect.minX >= 0 && divider.rect.minY >= 0)
        #expect(divider.rect.maxX <= size.width + 0.000_1 && divider.rect.maxY <= size.height + 0.000_1)
      }
    }
  }

  @Test("손상된 슬롯·크기 정보는 안전한 배치로 복구한다")
  func invalidConfigurationRecovers() {
    var configuration = ViewerFrameLayoutConfiguration(count: 4)
    configuration.rows[0].slots = [0, 0]
    configuration.rows[1].slots = [999, -1]
    let recovered = configuration.normalized(count: 4)
    #expect(recovered == ViewerFrameLayoutConfiguration(count: 4))

    configuration = ViewerFrameLayoutConfiguration(count: 4)
    configuration.heights = [.nan, .infinity]
    configuration.rows[0].widths = [-1, 0]
    configuration.rows[1].widths = []
    #expect(configuration.normalized(count: 4) == ViewerFrameLayoutConfiguration(count: 4))
    configuration.heights = [Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude]
    #expect(configuration.normalized(count: 4).heights == [0.5, 0.5])

    let geometry = configuration.geometry(in: CGSize(width: .infinity, height: -.infinity))
    #expect(geometry.frames.allSatisfy { $0.rect == .zero })
  }

  @Test("프레임 이동은 슬롯의 위치만 바꾸고 크기를 유지한다")
  func swapsPreserveFramesAndSourceIdentity() {
    let original = ViewerFrameLayoutConfiguration(count: 4)
    let swapped = original.swapping(0, with: 3)
    #expect(swapped.rows.map(\.slots) == [[3, 1], [2, 0]])
    let old = original.geometry(in: CGSize(width: 1_200, height: 800))
    let next = swapped.geometry(in: CGSize(width: 1_200, height: 800))
    #expect(next.frames[0].rect == old.frames[3].rect)
    #expect(next.frames[3].rect == old.frames[0].rect)
    #expect(next.frames[1] == old.frames[1])
    #expect(swapped.swapping(3, with: 0) == original)
    #expect(original.swapping(1, with: 1) == original)
    #expect(original.swapping(-1, with: 99) == original)
  }

  @Test("세로 구분선은 해당 행의 인접 프레임만 바꾼다")
  func columnResizePreservesOtherRows() throws {
    let original = ViewerFrameLayoutConfiguration(count: 4)
    let size = CGSize(width: 1_200, height: 800)
    let before = original.geometry(in: size)
    let divider = try #require(before.dividers.first { $0.axis == .vertical && $0.row == 0 })
    let resized = original.resizing(divider, translation: CGSize(width: 125, height: 900), in: size)
    let after = resized.geometry(in: size)
    #expect(abs(after.frames[0].rect.width - before.frames[0].rect.width - 125) < 0.001)
    #expect(abs(after.frames[1].rect.width - before.frames[1].rect.width + 125) < 0.001)
    #expect(after.frames[2] == before.frames[2])
    #expect(after.frames[3] == before.frames[3])
    #expect(resized.visualSlots == original.visualSlots)
  }

  @Test("가로 구분선은 인접 행의 높이만 바꾼다")
  func rowResizePreservesOtherRows() throws {
    let original = ViewerFrameLayoutConfiguration(count: 6, preset: .customColumns, columns: 2)
    let size = CGSize(width: 1_200, height: 1_000)
    let before = original.geometry(in: size)
    let divider = try #require(before.dividers.first { $0.axis == .horizontal && $0.index == 0 })
    let after = original.resizing(divider, translation: CGSize(width: 900, height: 70), in: size).geometry(in: size)
    #expect(abs(after.frames[0].rect.height - before.frames[0].rect.height - 70) < 0.001)
    #expect(abs(after.frames[2].rect.height - before.frames[2].rect.height + 70) < 0.001)
    for slot in [4, 5] {
      #expect(abs(after.frames[slot].rect.minY - before.frames[slot].rect.minY) < 0.001)
      #expect(abs(after.frames[slot].rect.height - before.frames[slot].rect.height) < 0.001)
      #expect(after.frames[slot].rect.minX == before.frames[slot].rect.minX)
      #expect(after.frames[slot].rect.width == before.frames[slot].rect.width)
    }
  }

  @Test("아주 큰 드래그도 최소 프레임 크기를 지키며 되돌릴 수 있다")
  func resizeClampsAndUsesDragBaseline() throws {
    let original = ViewerFrameLayoutConfiguration(count: 4)
    let size = CGSize(width: 1_200, height: 800)
    let before = original.geometry(in: size)
    let divider = try #require(before.dividers.first { $0.axis == .vertical })
    for delta in [-1_000_000.0, 1_000_000.0] {
      let after = original.resizing(divider, translation: CGSize(width: delta, height: 0), in: size).geometry(in: size)
      #expect(after.frames[0].rect.width >= 80 - 0.001)
      #expect(after.frames[1].rect.width >= 80 - 0.001)
    }
    let restored = original.resizing(divider, translation: .zero, in: size).geometry(in: size)
    #expect(restored == before)
    #expect(original.resizing(divider, translation: CGSize(width: CGFloat.nan, height: 0), in: size) == original)

    let tiny = CGSize(width: 90, height: 90)
    let tinyGeometry = original.geometry(in: tiny)
    let tinyDivider = try #require(tinyGeometry.dividers.first { $0.axis == .vertical })
    #expect(original.resizing(tinyDivider, translation: CGSize(width: 500, height: 0), in: tiny).geometry(in: tiny)
      == tinyGeometry)
  }

  @Test("키보드 위아래 이동은 바뀐 시각적 프레임 위치를 따른다")
  func navigationFollowsVisualRows() {
    let configuration = ViewerFrameLayoutConfiguration(count: 4).swapping(0, with: 3)
    #expect(configuration.rowTarget(from: 3, direction: 1) == 2)
    #expect(configuration.rowTarget(from: 1, direction: 1) == 0)
    #expect(configuration.rowTarget(from: 0, direction: -1) == 1)
    #expect(configuration.rowTarget(from: 3, direction: -1) == 3)
    #expect(configuration.rowTarget(from: 0, direction: 1) == 0)
    #expect(configuration.rowTarget(from: 1, direction: 0) == 1)
    #expect(ViewerFrameLayoutConfiguration(count: 4, preset: .horizontal).rowTarget(from: 2, direction: 1) == 2)
    #expect(ViewerFrameLayoutConfiguration(count: 4, preset: .vertical).rowTarget(from: 2, direction: -1) == 1)
  }

  @Test("크기를 바꾼 불균등 행에서는 가장 가까운 열로 이동한다")
  func navigationFollowsResizedColumns() throws {
    let configuration = ViewerFrameLayoutConfiguration(count: 5)
    let size = CGSize(width: 1_200, height: 800)
    let divider = try #require(configuration.geometry(in: size).dividers.first { $0.row == 1 })
    let resized = configuration.resizing(divider, translation: CGSize(width: -400, height: 0), in: size)
    #expect(resized.rowTarget(from: 0, direction: 1) == 3)
    #expect(resized.rowTarget(from: 1, direction: 1) == 4)
    #expect(resized.rowTarget(from: 2, direction: 1) == 4)
  }

  @Test("좁은 창에서 최소 너비가 적용되면 실제 보이는 중심을 따라 이동한다")
  func navigationUsesMinimumClampedViewport() {
    var configuration = ViewerFrameLayoutConfiguration(count: 4)
    configuration.rows[0].widths = [0.8, 0.2]
    configuration.rows[1].widths = [0.2, 0.8]
    // At a large width, the top-left center is closer to the bottom-right.
    #expect(configuration.rowTarget(from: 0, direction: 1) == 3)
    // At 200 points, both small panes are held at 80 points. The visible
    // top-left center is now closer to the bottom-left instead.
    let size = CGSize(width: 200, height: 400)
    let geometry = configuration.geometry(in: size)
    #expect(abs(geometry.frames[1].rect.width - 80) < 0.001)
    #expect(abs(geometry.frames[2].rect.width - 80) < 0.001)
    #expect(configuration.rowTarget(from: 0, direction: 1, in: size) == 2)
  }

  @Test("여섯 장의 네 방향 선택은 행·열을 유지하며 해당 방향의 반대쪽 끝으로 순환한다")
  func spatialSelectionFollowsRowsAndColumns() {
    let configuration = ViewerFrameLayoutConfiguration(count: 6)
    let cases: [(direction: ViewerSelectionDirection, targets: [Int])] = [
      (.left, [2, 0, 1, 5, 3, 4]), (.right, [1, 2, 0, 4, 5, 3]),
      (.up, [3, 4, 5, 0, 1, 2]), (.down, [3, 4, 5, 0, 1, 2]),
    ]
    for item in cases {
      for source in 0..<6 {
        #expect(configuration.selectionTarget(from: source, direction: item.direction) == item.targets[source])
      }
    }
  }

  @Test("프레임을 교환하면 네 방향 선택은 파일 번호 대신 바뀐 위치를 따른다")
  func spatialSelectionFollowsSwappedFrames() {
    let configuration = ViewerFrameLayoutConfiguration(count: 4).swapping(0, with: 3)
    #expect(configuration.rows.map(\.slots) == [[3, 1], [2, 0]])
    let cases: [(direction: ViewerSelectionDirection, targets: [Int])] = [
      (.left, [2, 3, 0, 1]), (.right, [2, 3, 0, 1]),
      (.up, [1, 0, 3, 2]), (.down, [1, 0, 3, 2]),
    ]
    for item in cases {
      for source in 0..<4 {
        #expect(configuration.selectionTarget(from: source, direction: item.direction) == item.targets[source])
      }
    }
  }

  @Test("짧은 행과 맨 위·아래의 순환도 가장 가까운 가로 중심을 고른다")
  func spatialSelectionUsesNearestCenterOnUnequalRows() {
    let configuration = ViewerFrameLayoutConfiguration(count: 7, preset: .customColumns, columns: 3)
    #expect(configuration.selectionTarget(from: 6, direction: .left) == 6)
    #expect(configuration.selectionTarget(from: 6, direction: .right) == 6)
    #expect(configuration.selectionTarget(from: 6, direction: .up) == 4)
    #expect(configuration.selectionTarget(from: 6, direction: .down) == 1)
    #expect(configuration.selectionTarget(from: 1, direction: .up) == 6)
    #expect(configuration.selectionTarget(from: 5, direction: .down) == 6)
  }

  @Test("프레임 너비 변경과 좁은 화면의 최소 너비가 네 방향 선택의 실제 중심에 반영된다")
  func spatialSelectionUsesResizingAndClampedGeometry() throws {
    let original = ViewerFrameLayoutConfiguration(count: 5)
    let large = CGSize(width: 1_200, height: 800)
    let divider = try #require(original.geometry(in: large).dividers.first { $0.row == 1 })
    let resized = original.resizing(divider, translation: CGSize(width: -400, height: 0), in: large)
    #expect(original.selectionTarget(from: 1, direction: .down, in: large) == 3)
    #expect(resized.selectionTarget(from: 1, direction: .down, in: large) == 4)
    #expect(resized.selectionTarget(from: 1, direction: .up, in: large) == 4)
    #expect(resized.selectionTarget(from: 0, direction: .right, in: large) == 1)

    var narrow = ViewerFrameLayoutConfiguration(count: 4)
    narrow.rows[0].widths = [0.8, 0.2]
    narrow.rows[1].widths = [0.2, 0.8]
    for direction in [ViewerSelectionDirection.up, .down] {
      #expect(narrow.selectionTarget(from: 0, direction: direction, in: large) == 3)
      #expect(narrow.selectionTarget(from: 0, direction: direction,
        in: CGSize(width: 200, height: 400)) == 2)
      #expect(narrow.selectionTarget(from: 3, direction: direction, in: large) == 0)
      #expect(narrow.selectionTarget(from: 3, direction: direction,
        in: CGSize(width: 200, height: 400)) == 1)
    }
  }

  @Test("한 행의 위아래·한 열의 좌우·한 프레임의 모든 방향은 제자리에 머문다")
  func spatialSelectionStaysWhenNoNeighborAxisExists() {
    let row = ViewerFrameLayoutConfiguration(count: 4, preset: .horizontal)
    let column = ViewerFrameLayoutConfiguration(count: 4, preset: .vertical)
    for source in 0..<4 {
      for direction in [ViewerSelectionDirection.up, .down] {
        #expect(row.selectionTarget(from: source, direction: direction) == source)
      }
      for direction in [ViewerSelectionDirection.left, .right] {
        #expect(column.selectionTarget(from: source, direction: direction) == source)
      }
    }
    #expect(row.selectionTarget(from: 3, direction: .right) == 0)
    #expect(column.selectionTarget(from: 3, direction: .down) == 0)
    for direction in ViewerSelectionDirection.allCases {
      #expect(ViewerFrameLayoutConfiguration(count: 1).selectionTarget(from: 0, direction: direction) == 0)
      #expect(ViewerFrameLayoutConfiguration(count: 0).selectionTarget(from: 0, direction: direction) == 0)
      #expect(row.selectionTarget(from: -1, direction: direction) == -1)
      #expect(row.selectionTarget(from: 99, direction: direction) == 99)
    }
  }
}

@Suite("프레임 배치 저장과 복원")
@MainActor
struct ViewerFrameLayoutStoreTests {
  @Test("저장소의 위아래 탐색에도 실제 뷰포트 크기를 전달한다")
  func navigationForwardsViewport() throws {
    try withDefaults { defaults in
      let store = ViewerFrameLayoutStore(defaults: defaults)
      var configuration = ViewerFrameLayoutConfiguration(count: 4)
      configuration.rows[0].widths = [0.8, 0.2]
      configuration.rows[1].widths = [0.2, 0.8]
      store.set(configuration, for: 4, persist: false)
      #expect(store.rowTarget(from: 0, direction: 1, count: 4) == 3)
      #expect(store.rowTarget(from: 0, direction: 1, count: 4, in: CGSize(width: 200, height: 400)) == 2)
      for direction in [ViewerSelectionDirection.up, .down] {
        #expect(store.selectionTarget(from: 0, direction: direction, count: 4) == 3)
        #expect(store.selectionTarget(from: 0, direction: direction, count: 4,
          in: CGSize(width: 200, height: 400)) == 2)
      }
    }
  }

  @Test("프레임 개수별 설정을 저장하고 편집 상태는 저장하지 않는다")
  func preferencesPersistPerCount() throws {
    try withDefaults { defaults in
      let store = ViewerFrameLayoutStore(defaults: defaults)
      store.isEditing = true
      store.setPreset(.horizontal, count: 4)
      store.swap(0, with: 3, count: 4)
      store.setPreset(.vertical, count: 6)
      let restored = ViewerFrameLayoutStore(defaults: defaults)
      #expect(!restored.isEditing)
      #expect(restored.configuration(for: 4).rows.map(\.slots) == [[3, 1, 2, 0]])
      #expect(restored.configuration(for: 6).preset == .vertical)
      #expect(restored.configuration(for: 5).preset == .balanced)
      #expect(restored.configuration(for: 4) == store.configuration(for: 4))
    }
  }

  @Test("배치 프리셋 변경은 이동한 순서를 유지하며 초기화로 복원한다")
  func presetsPreserveOrderAndResetRestoresIt() throws {
    try withDefaults { defaults in
      let store = ViewerFrameLayoutStore(defaults: defaults)
      store.swap(0, with: 3, count: 4)
      store.setPreset(.horizontal, count: 4)
      #expect(store.configuration(for: 4).visualSlots == [3, 1, 2, 0])
      store.setColumns(3, count: 4)
      #expect(store.configuration(for: 4).rows.map(\.slots) == [[3, 1, 2], [0]])
      #expect(store.configuration(for: 4).preset == .customColumns)
      store.reset(count: 4)
      #expect(store.configuration(for: 4) == ViewerFrameLayoutConfiguration(count: 4))
      #expect(ViewerFrameLayoutStore(defaults: defaults).configuration(for: 4) == store.configuration(for: 4))
    }
  }

  @Test("드래그 미리보기는 저장하지 않고 완료할 때만 저장한다")
  func previewWaitsForCommit() throws {
    try withDefaults { defaults in
      let store = ViewerFrameLayoutStore(defaults: defaults)
      let original = store.configuration(for: 4)
      store.commit(original, count: 4)
      let savedData = defaults.data(forKey: ViewerFrameLayoutStore.defaultsKey)
      let preview = original.swapping(0, with: 3)
      store.set(preview, for: 4, persist: false)
      #expect(store.configuration(for: 4) == preview)
      #expect(defaults.data(forKey: ViewerFrameLayoutStore.defaultsKey) == savedData)
      #expect(ViewerFrameLayoutStore(defaults: defaults).configuration(for: 4) == original)
      store.commit(preview, count: 4)
      #expect(ViewerFrameLayoutStore(defaults: defaults).configuration(for: 4) == preview)
    }
  }

  @Test("잘못된 환경설정·범위 밖 개수는 기본 배치로 안전하게 처리한다")
  func malformedPreferencesRecover() throws {
    try withDefaults { defaults in
      for data in [Data("not JSON".utf8), Data("{\"version\":99,\"configurations\":{}}".utf8),
        Data(repeating: 0, count: 131_073)] {
        defaults.set(data, forKey: ViewerFrameLayoutStore.defaultsKey)
        let store = ViewerFrameLayoutStore(defaults: defaults)
        #expect(store.configuration(for: 4) == ViewerFrameLayoutConfiguration(count: 4))
      }
      let invalid = """
        {"version":1,"configurations":{"4":{"preset":"balanced","columnCount":2,
        "rows":[{"slots":[0,0],"widths":[1,1]},{"slots":[2,9],"widths":[1,1]}],"heights":[1,1]}}}
        """
      defaults.set(Data(invalid.utf8), forKey: ViewerFrameLayoutStore.defaultsKey)
      let store = ViewerFrameLayoutStore(defaults: defaults)
      #expect(store.configuration(for: 4) == ViewerFrameLayoutConfiguration(count: 4))
      let before = defaults.data(forKey: ViewerFrameLayoutStore.defaultsKey)
      store.setPreset(.vertical, count: -1)
      store.setPreset(.vertical, count: 11)
      #expect(defaults.data(forKey: ViewerFrameLayoutStore.defaultsKey) == before)
      #expect(store.configuration(for: 0).rows.isEmpty)
    }
  }

  private func withDefaults(_ operation: (UserDefaults) throws -> Void) throws {
    let suite = "ViewerFrameLayoutStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try operation(defaults)
  }
}
