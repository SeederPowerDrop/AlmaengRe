import Foundation

struct SubtitleCue: Sendable, Equatable {
  let start: TimeInterval
  let end: TimeInterval
  let text: String

  var startSeconds: TimeInterval { start }
  var endSeconds: TimeInterval { end }
}

struct SubtitleTrack: Sendable, Equatable, Identifiable {
  let id: String
  let name: String
  let cues: [SubtitleCue]
  private let prefixMaximumEnd: [TimeInterval]
  private let maximumEndTree: [TimeInterval]
  private let treeLeafCount: Int

  static let maximumDisplayedCueCount = 16
  static let maximumDisplayedTextBytes = 16 * 1_024

  init(id: String, name: String, cues: [SubtitleCue]) {
    self.id = id
    self.name = name
    self.cues = cues.enumerated().filter { _, cue in
      cue.start.isFinite && cue.end.isFinite && cue.start >= 0
        && cue.end > cue.start && !cue.text.isEmpty
    }.sorted {
      $0.element.start == $1.element.start
        ? $0.offset < $1.offset : $0.element.start < $1.element.start
    }.map(\.element)
    var maximum: TimeInterval = 0
    prefixMaximumEnd = self.cues.map { cue in
      maximum = max(maximum, cue.end)
      return maximum
    }
    var leafCount = 1
    while leafCount < self.cues.count { leafCount *= 2 }
    treeLeafCount = leafCount
    var tree = Array(repeating: TimeInterval.zero, count: leafCount * 2)
    for (index, cue) in self.cues.enumerated() { tree[leafCount + index] = cue.end }
    if leafCount > 1 {
      for index in stride(from: leafCount - 1, through: 1, by: -1) {
        tree[index] = max(tree[index * 2], tree[index * 2 + 1])
      }
    }
    maximumEndTree = tree
  }

  /// Half-open intervals keep an ending caption from flashing beside its successor.
  /// A prefix maximum rejects inactive time ranges, then a maximum-end tree
  /// skips expired subranges even if an earlier, long caption still overlaps.
  func text(at seconds: TimeInterval) -> String? {
    guard seconds.isFinite, seconds >= 0, !cues.isEmpty else { return nil }
    var lower = 0
    var upper = cues.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if cues[middle].start <= seconds { lower = middle + 1 }
      else { upper = middle }
    }
    guard lower > 0, prefixMaximumEnd[lower - 1] > seconds else { return nil }
    var active: [String] = []
    var remainingBytes = Self.maximumDisplayedTextBytes - 4 // Reserve a newline and ellipsis.
    var truncated = false
    func visit(_ node: Int, _ start: Int, _ end: Int) {
      guard !truncated, start < lower, maximumEndTree[node] > seconds else { return }
      if end - start == 1 {
        guard active.count < Self.maximumDisplayedCueCount else { truncated = true; return }
        let text = cues[start].text
        let available = max(0, remainingBytes - (active.isEmpty ? 0 : 1))
        // Iterate at most the display budget even for a model constructed outside
        // the bounded reader, and never split a Unicode scalar at the byte limit.
        var bounded = String.UnicodeScalarView()
        var bytes = 0
        for scalar in text.unicodeScalars {
          let length = scalar.utf8.count
          guard bytes + length <= available else { truncated = true; break }
          bounded.append(scalar)
          bytes += length
        }
        if !bounded.isEmpty {
          active.append(String(bounded))
          remainingBytes -= bytes + (active.count > 1 ? 1 : 0)
        }
      } else {
        let middle = start + (end - start) / 2
        visit(node * 2, start, middle)
        visit(node * 2 + 1, middle, end)
      }
    }
    visit(1, 0, treeLeafCount)
    let result = active.joined(separator: "\n")
    return truncated ? result + "\n…" : (result.isEmpty ? nil : result)
  }
}

struct SubtitleDocument: Sendable, Equatable {
  let sourceURL: URL
  let tracks: [SubtitleTrack]
}
