import Combine
import Foundation
import Testing

@testable import ImageViewer

@MainActor
struct OverviewThumbnailSizeStateTests {
  @Test func rapidDragSizesUpdateTheGridOnceWithoutPersistingIntermediateInput() async throws {
    let suite = "OverviewThumbnailSizeStateTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let state = OverviewThumbnailSizeState(defaults: defaults)
    var sizes: [CGFloat] = []
    let observation = state.$value.sink { sizes.append($0) }
    defer { observation.cancel() }

    state.previewAfterDragPause(210)
    state.previewAfterDragPause(160)
    state.previewAfterDragPause(90)
    #expect(sizes == [OverviewThumbnailSizing.defaultSize])
    let deadline = ContinuousClock.now + .seconds(2)
    while state.value != 90, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(sizes == [OverviewThumbnailSizing.defaultSize, 90])
    #expect(OverviewThumbnailSizeState(defaults: defaults).value == OverviewThumbnailSizing.defaultSize)

    state.set(80)
    #expect(sizes.last == 80)
    #expect(OverviewThumbnailSizeState(defaults: defaults).value == 80)
  }

  @Test func immediateCommitCancelsThePendingGridUpdate() async throws {
    let suite = "OverviewThumbnailSizeStateTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let state = OverviewThumbnailSizeState(defaults: defaults)
    state.previewAfterDragPause(90)
    state.set(80)
    #expect(state.value == 80)
    try await Task.sleep(for: .milliseconds(240))
    #expect(state.value == 80)
    #expect(OverviewThumbnailSizeState(defaults: defaults).value == 80)
  }
}
