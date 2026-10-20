import Combine
import CoreGraphics
import Foundation

@MainActor
final class ViewerFrameLayoutStore: ObservableObject {
  static let defaultsKey = "ImageViewer.ViewerFrameLayouts.v1"

  @Published var isEditing = false
  @Published private(set) var configurations: [Int: ViewerFrameLayoutConfiguration]

  private let defaults: UserDefaults

  private struct SavedLayouts: Codable {
    var version: Int
    var configurations: [Int: ViewerFrameLayoutConfiguration]
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: Self.defaultsKey), data.count <= 131_072,
      let saved = try? JSONDecoder().decode(SavedLayouts.self, from: data), saved.version == 1 {
      configurations = saved.configurations.reduce(into: [:]) { result, entry in
        guard (1...10).contains(entry.key) else { return }
        result[entry.key] = entry.value.normalized(count: entry.key)
      }
    } else {
      configurations = [:]
    }
  }

  func configuration(for count: Int) -> ViewerFrameLayoutConfiguration {
    let count = min(10, max(0, count))
    return (configurations[count] ?? ViewerFrameLayoutConfiguration(count: count)).normalized(count: count)
  }

  func geometry(for count: Int, in size: CGSize) -> ViewerFrameLayoutGeometry {
    configuration(for: count).geometry(in: size)
  }

  /// Preview updates publish immediately; only the completed drag is persisted.
  func set(_ configuration: ViewerFrameLayoutConfiguration, for count: Int, persist: Bool = true) {
    guard (1...10).contains(count) else { return }
    let clean = configuration.normalized(count: count)
    if configurations[count] != clean { configurations[count] = clean }
    if persist { save() }
  }

  func commit(_ configuration: ViewerFrameLayoutConfiguration, count: Int) {
    set(configuration, for: count)
  }

  func swap(_ sourceSlot: Int, with targetSlot: Int, count: Int) {
    set(configuration(for: count).swapping(sourceSlot, with: targetSlot), for: count)
  }

  func setPreset(_ preset: ViewerFrameLayoutPreset, count: Int) {
    let current = configuration(for: count)
    var next = ViewerFrameLayoutConfiguration(count: count, preset: preset, columns: current.columnCount)
    next = keepingVisualOrder(current.visualSlots, in: next)
    set(next, for: count)
  }

  func setColumns(_ columns: Int, count: Int) {
    let current = configuration(for: count)
    let next = ViewerFrameLayoutConfiguration(count: count, preset: .customColumns, columns: columns)
    set(keepingVisualOrder(current.visualSlots, in: next), for: count)
  }

  func reset(count: Int) {
    set(ViewerFrameLayoutConfiguration(count: count), for: count)
  }

  func rowTarget(from sourceSlot: Int, direction: Int, count: Int, in size: CGSize? = nil) -> Int {
    configuration(for: count).rowTarget(from: sourceSlot, direction: direction, in: size)
  }

  func selectionTarget(from sourceSlot: Int, direction: ViewerSelectionDirection, count: Int,
    in size: CGSize? = nil) -> Int {
    configuration(for: count).selectionTarget(from: sourceSlot, direction: direction, in: size)
  }

  private func keepingVisualOrder(_ slots: [Int], in configuration: ViewerFrameLayoutConfiguration)
    -> ViewerFrameLayoutConfiguration {
    guard slots.count == configuration.count else { return configuration }
    var result = configuration
    var position = 0
    for rowIndex in result.rows.indices {
      for columnIndex in result.rows[rowIndex].slots.indices {
        result.rows[rowIndex].slots[columnIndex] = slots[position]
        position += 1
      }
    }
    return result
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(SavedLayouts(version: 1, configurations: configurations)) else { return }
    defaults.set(data, forKey: Self.defaultsKey)
  }
}
